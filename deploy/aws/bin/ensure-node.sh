#!/usr/bin/env bash
# Puts Node $NODE_MAJOR at /usr/bin/node, from NodeSource, on Amazon Linux (dnf)
# or Debian/Ubuntu (apt), and moves a node that has another major. Run by
# bootstrap-node.sh on a new node and by deploy.sh before npm ci.
#
# The Dockerfile and ci.yml name the same major. Checked at /usr/bin/node,
# what stride-api.service runs, not whichever node comes first on PATH.
#
# On dnf, NodeSource's setup script points the same repo id at the new major,
# and dnf keeps the old major's cached metadata: `dnf install nodejs` then
# reports the old one as installed and changes nothing (measured on the AWS
# node, 2026-11-24). --refresh drops that cache.
set -euo pipefail
NODE_MAJOR=${NODE_MAJOR:-26}
major() { /usr/bin/node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true; }

[ "$(major)" = "$NODE_MAJOR" ] && exit 0
if command -v dnf >/dev/null; then
  curl -fsSL "https://rpm.nodesource.com/setup_$NODE_MAJOR.x" | bash -
  dnf install -y --refresh --allowerasing nodejs
  [ "$(major)" = "$NODE_MAJOR" ] || dnf upgrade -y --refresh nodejs
else
  curl -fsSL "https://deb.nodesource.com/setup_$NODE_MAJOR.x" | bash -
  apt-get install -y nodejs
fi
[ "$(major)" = "$NODE_MAJOR" ] || { echo "Node is $(major), not $NODE_MAJOR" >&2; exit 1; }
echo "Node $(/usr/bin/node --version)"
