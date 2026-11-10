#!/usr/bin/env bash
# Brings a bare Amazon Linux 2023 arm64 instance up as a stride-lite node.
# Runs as cloud-init user_data, so it runs once per instance launch, as root.
#
# Everything here is idempotent except the filesystem creation, which is
# guarded: the data volume survives instance replacement, and reformatting it
# would be the one genuinely destructive step in this repository.
set -euxo pipefail

DEV=/dev/nvme1n1          # the gp3 data volume; nvme naming on Graviton
DATA=/var/lib/clickhouse
REPO=/opt/stride-lite
BRANCH=${branch}
# Where our own copy of the built database lives, if there is one. Empty means
# the first load rebuilds from public data instead — slower, and it reads a
# non-profit's bucket. See scripts/first-load.sh.
BACKUP_URL="${backup_url}"
BACKUP_ROLE_ARN="${backup_role_arn}"
REGION="${region}"

# ---- data volume -----------------------------------------------------------
for _ in $(seq 1 60); do [ -b "$DEV" ] && break; sleep 2; done
if ! blkid "$DEV" >/dev/null 2>&1; then
  mkfs.ext4 -L stride-data "$DEV"
fi
mkdir -p "$DATA"
grep -q "^LABEL=stride-data" /etc/fstab || echo "LABEL=stride-data $DATA ext4 defaults,noatime 0 2" >> /etc/fstab
mount -a

# ---- packages --------------------------------------------------------------
dnf install -y git tar zstd unzip cronie
systemctl enable --now crond
curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
dnf install -y nodejs

curl -fsSL https://clickhouse.com/ | sh
mv ./clickhouse /usr/local/bin/clickhouse

# The release binary is a decompressor stub wrapped around a compressed ELF: the
# first run extracts the real binary in place next to itself, guarded by a lock
# file in the same directory. Done here, as root, that write lands in
# /usr/local/bin, which root owns. Left for later, it is done by the systemd
# unit's `User=clickhouse` instead, which cannot write there and fails with
# "Decompressing the binary... lock open: Permission denied" before the server
# ever starts — the failure this comment exists because of.
/usr/local/bin/clickhouse --version >/dev/null

useradd -r -s /sbin/nologin clickhouse || true
chown -R clickhouse:clickhouse "$DATA"
install -d -o clickhouse -g clickhouse /etc/clickhouse-server /var/log/clickhouse-server

# ---- the repository --------------------------------------------------------
git clone --branch "$BRANCH" --depth 1 https://github.com/NoamGaash/stride-lite "$REPO"
cd "$REPO"
(cd api && npm ci --omit=dev)

# What only this instance knows, for the units in infra/node to read. Everything
# else on the node — ClickHouse's config, the units, the cron entries — comes
# from infra/node through install-node-config.sh, which every deploy runs again.
install -d /etc/stride-lite
cat > /etc/stride-lite/node.env <<ENV
AWS_REGION=$REGION
BACKUP_URL=$BACKUP_URL
BACKUP_ROLE_ARN=$BACKUP_ROLE_ARN
ENV
./scripts/install-node-config.sh
systemctl start clickhouse

for _ in $(seq 1 60); do clickhouse client --query 'SELECT 1' >/dev/null 2>&1 && break; sleep 2; done
# Tables, migrations, views and projections, all of it. The ingest and
# enrichment chains are deliberately NOT installed here: scripts/first-load.sh
# installs them after it has loaded the history, because the dump carries its
# own ids and the chain mints ids as max(id) + row_number(). Both writing at
# once hands one id to two different readings, which is the failure that cost
# this project twenty-nine days of data.
PROJECTIONS=0 CH_CLIENT="clickhouse client" CH_DB=stride ./scripts/apply-schema.sh

systemctl start stride-api

# ---- the first load -------------------------------------------------------
# The one thing a launch cannot leave until later, because without it this node
# serves a working API over an empty database: the refreshable views poll the
# running hour, so data accumulates from go-live forward and nothing before it
# exists, and ingest/catchup.sh refuses an empty database by design.
#
# --no-block so user_data finishes: a deploy waits for the marker below, and a
# load measured in hours must not be what it waits for. The load takes
# /var/lock/stride-catchup, so the hourly catch-up and scripts/deploy.sh both
# see it is running rather than writing alongside it.
systemctl start --no-block stride-first-load

echo "bootstrap complete" > /var/log/stride-bootstrap.done
