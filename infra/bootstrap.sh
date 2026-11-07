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
useradd -r -s /sbin/nologin clickhouse || true
chown -R clickhouse:clickhouse "$DATA"

install -d -o clickhouse -g clickhouse /etc/clickhouse-server /var/log/clickhouse-server
cat > /etc/clickhouse-server/config.xml <<'CFG'
<clickhouse>
    <path>/var/lib/clickhouse/</path>
    <tmp_path>/var/lib/clickhouse/tmp/</tmp_path>
    <user_files_path>/var/lib/clickhouse/user_files/</user_files_path>
    <listen_host>127.0.0.1</listen_host>
    <tcp_port>9000</tcp_port>
    <http_port>8123</http_port>
    <logger><level>warning</level><log>/var/log/clickhouse-server/clickhouse.log</log></logger>
    <users_config>users.xml</users_config>
    <default_profile>default</default_profile>
</clickhouse>
CFG
cat > /etc/clickhouse-server/users.xml <<'USR'
<clickhouse>
    <profiles><default>
        <max_memory_usage>6000000000</max_memory_usage>
        <max_bytes_before_external_group_by>3000000000</max_bytes_before_external_group_by>
    </default></profiles>
    <users><default>
        <password></password>
        <networks><ip>127.0.0.1</ip></networks>
        <profile>default</profile>
        <quota>default</quota>
        <access_management>1</access_management>
    </default></users>
    <quotas><default/></quotas>
</clickhouse>
USR

cat > /etc/systemd/system/clickhouse.service <<'SVC'
[Unit]
Description=ClickHouse
After=network.target
[Service]
User=clickhouse
Group=clickhouse
ExecStart=/usr/local/bin/clickhouse server --config-file=/etc/clickhouse-server/config.xml
Restart=always
LimitNOFILE=500000
[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload
systemctl enable --now clickhouse

# ---- the repository --------------------------------------------------------
git clone --branch "$BRANCH" --depth 1 https://github.com/NoamGaash/stride-lite "$REPO"
cd "$REPO"
(cd api && npm ci --omit=dev)

for _ in $(seq 1 60); do clickhouse client --query 'SELECT 1' >/dev/null 2>&1 && break; sleep 2; done
# Tables, migrations, views and projections, all of it. The ingest and
# enrichment chains are deliberately NOT installed here: scripts/first-load.sh
# installs them after it has loaded the history, because the dump carries its
# own ids and the chain mints ids as max(id) + row_number(). Both writing at
# once hands one id to two different readings, which is the failure that cost
# this project twenty-nine days of data.
CH_CLIENT="clickhouse client" CH_DB=stride ./scripts/apply-schema.sh

cat > /etc/systemd/system/stride-api.service <<'SVC'
[Unit]
Description=stride-lite API
After=clickhouse.service
[Service]
WorkingDirectory=/opt/stride-lite/api
Environment=CH_DB=stride
Environment=PORT=80
Environment=NODE_ENV=production
ExecStart=/usr/bin/npx tsx src/server.ts
Restart=always
AmbientCapabilities=CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload
systemctl enable --now stride-api

# ---- the two things that need a scheduler ---------------------------------
# ClickHouse reads S3 itself for SIRI, but it cannot open a multi-file zip, so
# the daily GTFS feed is one cron entry.
cat > /etc/cron.d/stride-gtfs <<'CRON'
MAILTO=""
20 4 * * * root cd /opt/stride-lite && CH_DB=stride CH_CLIENT="clickhouse client" ./ingest/gtfs.sh >> /var/log/stride-gtfs.log 2>&1
CRON

# And the catch-up is the other. The views in ingest/siri.sql cover the running
# hour and the one before it, which heals a missed refresh and not a week of
# downtime; ingest/catchup.sh starts from the newest snapshot actually loaded and
# walks forward to today. At boot because that is when a gap exists, and hourly
# because an outage shorter than a reboot still leaves one.
#
# flock because a week-long catch-up takes hours and the next hourly tick must
# not start a second one. -n so the tick simply does not run rather than queueing.
cat > /etc/cron.d/stride-catchup <<'CRON'
MAILTO=""
@reboot root sleep 120; flock -n /var/lock/stride-catchup -c 'cd /opt/stride-lite && CH_DB=stride CH_CLIENT="clickhouse client" ./ingest/catchup.sh' >> /var/log/stride-catchup.log 2>&1
17 * * * * root flock -n /var/lock/stride-catchup -c 'cd /opt/stride-lite && CH_DB=stride CH_CLIENT="clickhouse client" ./ingest/catchup.sh' >> /var/log/stride-catchup.log 2>&1
CRON

# ---- the first load -------------------------------------------------------
# The one thing a launch cannot leave until later, because without it this node
# serves a working API over an empty database: the refreshable views poll the
# running hour, so data accumulates from go-live forward and nothing before it
# exists, and ingest/catchup.sh refuses an empty database by design.
#
# A unit and not a cron entry, because it is one job that must run once, may run
# for hours, and has to survive the end of cloud-init. Type=oneshot with
# TimeoutStartSec=infinity: the default start timeout is 90 seconds and this is
# measured in hours, so without that line systemd kills the load and reports a
# failure that looks like the script's.
#
# Restart=on-failure with ten minutes between tries, because every stage is
# resumable and the usual reason to fail is the network. The script keeps its
# own state on the data volume and skips what finished.
cat > /etc/systemd/system/stride-first-load.service <<SVC
[Unit]
Description=stride-lite first load
After=clickhouse.service stride-api.service
[Service]
Type=oneshot
WorkingDirectory=/opt/stride-lite
Environment=CH_DB=stride
Environment="CH_CLIENT=clickhouse client"
Environment=AWS_REGION=$REGION
Environment=BACKUP_URL=$BACKUP_URL
Environment=BACKUP_ROLE_ARN=$BACKUP_ROLE_ARN
ExecStart=/opt/stride-lite/scripts/first-load.sh
TimeoutStartSec=infinity
Restart=on-failure
RestartSec=600
StandardOutput=append:/var/log/stride-first-load.log
StandardError=append:/var/log/stride-first-load.log
[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload
systemctl enable stride-first-load
# --no-block so user_data finishes: a deploy waits for the marker below, and a
# load measured in hours must not be what it waits for. The load takes
# /var/lock/stride-catchup, so the hourly catch-up and scripts/deploy.sh both
# see it is running rather than writing alongside it.
systemctl start --no-block stride-first-load

echo "bootstrap complete" > /var/log/stride-bootstrap.done
