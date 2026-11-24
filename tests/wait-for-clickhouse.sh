#!/usr/bin/env bash
# scripts/wait-for-clickhouse.sh with a client that refuses the first few
# connections, the way ClickHouse does while it loads its tables.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=$(mktemp -d); trap 'rm -rf "$DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cat > "$DIR/client" <<STUB
#!/bin/sh
n=\$(cat "$DIR/n" 2>/dev/null || echo 0); echo \$((n + 1)) > "$DIR/n"
[ "\$n" -ge 3 ]
STUB
chmod +x "$DIR/client"
run() { CH_CLIENT=$DIR/client CH_WAIT_SECONDS=0 CH_WAIT_TRIES=$1 ./scripts/wait-for-clickhouse.sh 2>/dev/null; }

run 10 || fail "gave up on a server that answered on the fourth try"
rm "$DIR/n"
run 2 && fail "reported ready a server that never answered"

# The deploy waits after the restart and before the first query.
awk '/^ *(RESTART_CHANGED=1 )?\.\/scripts\/install-node-config.sh/ {i=NR} /^ *\.\/scripts\/wait-for-clickhouse.sh/ {w=NR} /^ *\.\/scripts\/apply-schema.sh/ && !a {a=NR}
     END { exit !(i && w && a && i < w && w < a) }' scripts/deploy.sh \
  || fail "scripts/deploy.sh applies the schema without waiting for the ClickHouse it may just have restarted"

echo "wait-for-clickhouse: ok"
