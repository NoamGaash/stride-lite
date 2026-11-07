#!/usr/bin/env bash
# Stops the refreshable views for the duration of a one-off enrichment pass, and
# puts back exactly the ones that were running.
#
# Sourced, not executed: `. "$here/chain-guard.sh"` and then `chain_stop` under
# a trap. backfill-range.sh and repair-range.sh both need it, and it lives here
# so there is one implementation of the rule the whole ingest turns on — only
# one pass may mint ids at a time, because both paths mint `id` as
# max(id) + row_number() and two passes read the same starting max.
#
# ingest/enrich-once.sql refuses to run while the chain is enabled, so this is
# the half that makes a legitimate pass possible rather than the half that
# forbids an illegitimate one.
#
# Expects $CH_DB and a `ch` function that runs a query against it.

# The views to silence are discovered rather than listed, so one added later is
# covered without touching this file, and the ones already Disabled are skipped
# so the restart puts back exactly what was running. Starting a view somebody
# stopped on purpose would be this script changing state that is not its own.
chain_views() {
  ch --query "
    SELECT view FROM system.view_refreshes
    WHERE database = '$CH_DB' AND status != 'Disabled' FORMAT TSV"
}

chain_stopped_views=""

chain_restart() {
  [ -n "$chain_stopped_views" ] || return 0
  for v in $chain_stopped_views; do
    ch --query "SYSTEM START VIEW \`$v\`" || echo "  WARNING: could not restart view $v" >&2
  done
  echo "restarted the refresh chain"
  chain_stopped_views=""
}

# Stops the chain and waits for whatever refresh is already in flight, because
# SYSTEM STOP VIEW prevents the next refresh and does not cancel the running
# one. Without the wait, the pass that follows would overlap that refresh, which
# is the whole failure being prevented.
chain_stop() {
  chain_stopped_views=$(chain_views)
  [ -n "$chain_stopped_views" ] || return 0
  for v in $chain_stopped_views; do
    ch --query "SYSTEM STOP VIEW \`$v\`"
  done
  local waited=0 running
  while :; do
    running=$(ch --query "
      SELECT count() FROM system.view_refreshes
      WHERE database = '$CH_DB' AND status = 'Running'")
    [ "$running" = 0 ] && break
    [ "$waited" -ge 1800 ] && { echo "a refresh has been running for 30 min; giving up rather than racing it" >&2; exit 1; }
    echo "  waiting for $running refresh(es) already in flight"
    sleep 30
    waited=$((waited + 30))
  done
  echo "stopped the refresh chain for the duration of this pass"
}
