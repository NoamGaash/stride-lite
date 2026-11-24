#!/usr/bin/env bash
# deploy/aws/bin/auto-deploy.sh against local repositories, with a deploy.sh stub that
# records each call and can be made to fail.
set -euo pipefail
cd "$(dirname "$0")/../../.."
SRC=$PWD
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }

g init -q "$W/origin"
mkdir -p "$W/origin/deploy/aws/bin"
cp "$SRC/deploy/aws/bin/auto-deploy.sh" "$W/origin/deploy/aws/bin/"
cat > "$W/origin/deploy/aws/bin/deploy.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
git fetch --quiet --depth 1 origin "$BRANCH"
git reset --quiet --hard FETCH_HEAD
echo "$(git rev-parse HEAD)" >> "$CALLS"
[ "${DEPLOY_FAILS:-0}" = 0 ] || exit 1
git rev-parse HEAD > "$DEPLOY_STATE"
STUB
chmod +x "$W/origin/deploy/aws/bin/"*.sh
g -C "$W/origin" add -A && g -C "$W/origin" commit -qm one
g clone -q "file://$W/origin" "$W/node"

export CALLS=$W/calls DEPLOY_STATE=$W/deployed BOOTSTRAP_DONE=$W/bootstrap.done REPO_URL=file://$W/origin
run() { : > "$CALLS"; (cd "$W/node" && deploy/aws/bin/auto-deploy.sh > /dev/null); }
commit() { echo "$1" > "$W/origin/$1"; g -C "$W/origin" add -A; g -C "$W/origin" commit -qm "$1"; }

run
[ -s "$CALLS" ] && fail "deployed before the bootstrap finished"
touch "$BOOTSTRAP_DONE"
git -C "$W/node" rev-parse HEAD > "$DEPLOY_STATE"

run
[ -s "$CALLS" ] && fail "deployed although main has not moved"

commit two
run
[ "$(cat "$CALLS")" = "$(git -C "$W/origin" rev-parse HEAD)" ] || fail "did not deploy the new commit once"
run
[ -s "$CALLS" ] && fail "deployed the same commit twice"

commit three
DEPLOY_FAILS=1 run || true
[ -s "$CALLS" ] || fail "did not try the third commit"
run
[ -s "$CALLS" ] || fail "a failed deploy was not retried, because the checkout had already moved"

g init -q --bare "$W/moved.git"
git -C "$W/origin" push -q "$W/moved.git" main
REPO_URL=file://$W/moved.git run
[ "$(git -C "$W/node" remote get-url origin)" = "file://$W/moved.git" ] || fail "origin did not follow REPO_URL"

echo "auto-deploy: deploys main when it moves, once, and retries a failure"
