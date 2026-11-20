#!/usr/bin/env bash
# Installs Hasadna's own SIRI requester (github.com/hasadna/open-bus-siri-requester)
# at a pinned commit, for infra/node/systemd/siri-requester.service. The same code
# that writes openbus-stride-public, so this node's snapshots are the same files.
# Run by bootstrap-node.sh and by every deploy; a no-op once that commit is installed.
#
# Its setup.py names the package version after time.time() unless VERSION.txt
# exists, and pip refuses the wheel that builds, so VERSION.txt is written here.
set -euo pipefail

REQUESTER_REPO=https://github.com/hasadna/open-bus-siri-requester
REQUESTER_SHA=1e344943c341176a6b97b0456cba5474392aaeeb
DEST=${REQUESTER_DEST:-/opt/siri-requester}

[ "$(cat "$DEST/installed" 2>/dev/null)" = "$REQUESTER_SHA" ] && exit 0

# It compresses each snapshot by piping it through the `brotli` command.
if ! command -v brotli >/dev/null || ! python3 -m venv --help >/dev/null 2>&1; then
  if command -v dnf >/dev/null; then
    dnf install -y brotli python3-pip
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y brotli python3-venv
  fi
fi

src=$(mktemp -d); trap 'rm -rf "$src"' EXIT
git -C "$src" init -q
git -C "$src" fetch -q --depth 1 "$REQUESTER_REPO" "$REQUESTER_SHA"
git -C "$src" checkout -q FETCH_HEAD
echo "0.0.0+${REQUESTER_SHA:0:7}" > "$src/VERSION.txt"

rm -rf "$DEST/venv"
python3 -m venv "$DEST/venv"
"$DEST/venv/bin/pip" install -q -r "$src/requirements.txt"
"$DEST/venv/bin/pip" install -q "$src"
"$DEST/venv/bin/open-bus-siri-requester" --help >/dev/null
echo "$REQUESTER_SHA" > "$DEST/installed"
echo "installed open-bus-siri-requester ${REQUESTER_SHA:0:7}"
