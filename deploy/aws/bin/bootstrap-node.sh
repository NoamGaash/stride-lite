#!/usr/bin/env bash
# Brings a bare Linux server up as a stride-lite node, as root. Runs on Amazon
# Linux 2023 (deploy/aws/bootstrap.sh calls it from user_data) and on Ubuntu (run it
# over SSH on any other server):
#
#   curl -fsSL https://raw.githubusercontent.com/NoamGaash/stride-lite/main/deploy/aws/bin/bootstrap-node.sh |
#     sudo DATA_DEVICE=/dev/sdb BACKUP_URL=s3://some-bucket/full/ bash
#
# Everything here is idempotent except the filesystem creation, which is
# guarded: the data volume survives instance replacement, and reformatting it
# would be the one genuinely destructive step in this repository.
#
# Settings, all from the environment:
#   DATA_DEVICE      the empty disk for ClickHouse's data (required)
#   BRANCH           the branch to clone (default main)
#   AWS_REGION       the region s3:// backup URLs resolve in (default us-east-1)
#   BACKUP_URL       where to restore the first load from, if anywhere
#   BACKUP_PUBLISH   where the first load publishes a backup (default BACKUP_URL)
#   BACKUP_ROLE_ARN  on AWS: the role ClickHouse assumes for the backup bucket
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#                    off AWS: the key the backup is signed with
#   START_FIRST_LOAD 0 to leave the first load unstarted (default 1)
#   OPEN_BUS_MOT_KEY the Ministry's SIRI key; without it the requester stays off
set -euxo pipefail

DEV=${DATA_DEVICE:?set DATA_DEVICE to the empty disk for ClickHouse data}
DATA=/var/lib/clickhouse
REPO=/opt/stride-lite
BRANCH=${BRANCH:-main}

# ---- data volume -----------------------------------------------------------
for _ in $(seq 1 60); do [ -b "$DEV" ] && break; sleep 2; done
if ! blkid "$DEV" >/dev/null 2>&1; then
  mkfs.ext4 -L stride-data "$DEV"
fi
mkdir -p "$DATA"
grep -q "^LABEL=stride-data" /etc/fstab || echo "LABEL=stride-data $DATA ext4 defaults,noatime 0 2" >> /etc/fstab
mount -a

# ---- packages --------------------------------------------------------------
if command -v dnf >/dev/null; then
  dnf install -y git tar zstd unzip cronie brotli
  systemctl enable --now crond
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git tar zstd unzip cron curl ca-certificates brotli
  systemctl enable --now cron
fi

# scripts/first-load.sh asks the aws CLI whether a backup exists. Amazon Linux
# ships it; elsewhere it comes from AWS's own installer.
if ! command -v aws >/dev/null; then
  work=$(mktemp -d)
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "$work/awscli.zip"
  unzip -q "$work/awscli.zip" -d "$work"
  "$work/aws/install"
  rm -rf "$work"
fi

if [ ! -x /usr/local/bin/clickhouse ]; then
  (cd "$(mktemp -d)" && curl -fsSL https://clickhouse.com/ | sh && mv ./clickhouse /usr/local/bin/clickhouse)
fi

# The release binary is a decompressor stub wrapped around a compressed ELF: the
# first run extracts the real binary in place next to itself, guarded by a lock
# file in the same directory. Done here, as root, that write lands in
# /usr/local/bin, which root owns. Left for later, it is done by the systemd
# unit's `User=clickhouse` instead, which cannot write there and fails with
# "Decompressing the binary... lock open: Permission denied" before the server
# ever starts — the failure this comment exists because of.
/usr/local/bin/clickhouse --version >/dev/null

useradd -r -s "$(command -v nologin)" clickhouse || true
chown -R clickhouse:clickhouse "$DATA"
install -d -o clickhouse -g clickhouse /etc/clickhouse-server /var/log/clickhouse-server

# ---- the repository --------------------------------------------------------
[ -d "$REPO/.git" ] || git clone --branch "$BRANCH" --depth 1 https://github.com/NoamGaash/stride-lite "$REPO"
cd "$REPO"

# What only this node knows, for the units in deploy/aws/node to read. Everything
# else on the node — ClickHouse's config, the units, the cron entries — comes
# from deploy/aws/node through install-node-config.sh, which every deploy runs again.
# Only what is set, so an unset default stays a default; 0600 because a key may
# be among them, and with tracing off for the same reason.
set +x
install -d /etc/stride-lite
install -m 0600 /dev/null /etc/stride-lite/node.env
AWS_REGION=${AWS_REGION:-us-east-1}
for name in BRANCH AWS_REGION BACKUP_URL BACKUP_PUBLISH BACKUP_ROLE_ARN AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY OPEN_BUS_MOT_KEY; do
  if [ -n "${!name:-}" ]; then echo "$name=${!name}" >> /etc/stride-lite/node.env; fi
done
set -x
./deploy/aws/bin/install-node-config.sh
systemctl start clickhouse

for _ in $(seq 1 60); do clickhouse client --query 'SELECT 1' >/dev/null 2>&1 && break; sleep 2; done
# Tables, migrations and views. The ingest and enrichment chains are
# deliberately NOT installed here: scripts/first-load.sh installs them after it
# has loaded the history, because the dump carries its own ids and the chain
# mints ids as max(id) + row_number(). Both writing at once hands one id to two
# different readings, which is the failure that cost this project twenty-nine
# days of data. The projections wait for the first deploy after the load.
PROJECTIONS=0 CH_CLIENT="clickhouse client" CH_DB=stride ./scripts/apply-schema.sh

systemctl start stride-api

# ---- the first load -------------------------------------------------------
# The one thing a launch cannot leave until later, because without it this node
# serves a working API over an empty database: the refreshable views poll the
# running hour, so data accumulates from go-live forward and nothing before it
# exists, and ingest/catchup.sh refuses an empty database by design.
#
# --no-block so the bootstrap finishes: a deploy waits for the marker below,
# and a load measured in hours must not be what it waits for. The load takes
# /var/lock/stride-catchup, so the hourly catch-up and deploy/aws/bin/deploy.sh both
# see it is running rather than writing alongside it.
if [ "${START_FIRST_LOAD:-1}" != 0 ]; then
  systemctl start --no-block stride-first-load
fi

echo "bootstrap complete" > /var/log/stride-bootstrap.done
