#!/usr/bin/env bash
# Deploys the branch when it has moved, every few minutes from
# deploy/aws/node/systemd/stride-deploy.timer. The node pulls rather than CI pushing,
# so it needs no inbound access and CI holds no key to it. /ops/logs?sources=deploy
# shows what each run did.
set -euo pipefail
cd "$(dirname "$0")/../../.."
# Moving the repository is then one commit to this line: the node fetches that
# commit through GitHub's redirect and points itself at the new home.
REPO_URL=${REPO_URL:-https://github.com/NoamGaash/stride-lite}
export BRANCH=${BRANCH:-main}
# Written by deploy/aws/bin/deploy.sh when a deploy completes. Compared rather than the
# checkout, which a failed deploy has already moved, so a failure is retried.
export DEPLOY_STATE=${DEPLOY_STATE:-/var/lib/stride-deploy/deployed}
BOOTSTRAP_DONE=${BOOTSTRAP_DONE:-/var/log/stride-bootstrap.done}

# The bootstrap is still installing ClickHouse and the schema until it writes
# this, and a deploy alongside it is two writers to one database.
[ -f "$BOOTSTRAP_DONE" ] || { echo "the bootstrap has not finished"; exit 0; }

git remote set-url origin "$REPO_URL"
git fetch --quiet --depth 1 origin "$BRANCH"
target=$(git rev-parse FETCH_HEAD)
deployed=$(cat "$DEPLOY_STATE" 2> /dev/null || true)
[ "$target" = "$deployed" ] && exit 0

echo "deploying $BRANCH at ${target:0:7}, over ${deployed:0:7}"
exec ./deploy/aws/bin/deploy.sh
