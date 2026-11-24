#!/usr/bin/env bash
# deploy/aws/bin/pull-image.sh with docker and systemctl stubbed, on a host
# root that has no /etc/stride-lite yet, as the AWS node had none.
set -euo pipefail
cd "$(dirname "$0")/../../.."
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/bin/docker"; cp "$ROOT/bin/docker" "$ROOT/bin/systemctl"
chmod +x "$ROOT/bin/"*
PATH=$ROOT/bin:$PATH NODE_ROOT=$ROOT deploy/aws/bin/pull-image.sh \
  || { echo "FAIL: pull-image.sh failed on a host without /etc/stride-lite" >&2; exit 1; }
grep -qE '^STRIDE_IMAGE=ghcr\.io/[a-z0-9._-]+/[a-z0-9._-]+:[0-9a-f]{40}$' "$ROOT/etc/stride-lite/image.env" \
  || { echo "FAIL: image.env does not name the commit's image: $(cat "$ROOT/etc/stride-lite/image.env")" >&2; exit 1; }
echo "pull-image: ok"
