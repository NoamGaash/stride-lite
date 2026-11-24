#!/usr/bin/env bash
# Makes the image of the checked-out commit available to stride-api.service:
# Docker installed and running, ghcr.io/<owner>/<repo>:<commit> pulled, and
# its name in /etc/stride-lite/image.env. Run by install-node-config.sh, so
# every deploy and every bootstrap does it.
#
# The image is the one Dockerfile every environment runs, so the API's runtime
# (Node and its packages) is chosen there and nowhere on this host.
set -euo pipefail
cd "$(dirname "$0")/../../.."
ROOT=${NODE_ROOT:-}

sha=$(git rev-parse HEAD)
repo=${IMAGE_REPO:-$(git remote get-url origin | sed -E 's#.*github\.com[/:]##; s#\.git$##' | tr '[:upper:]' '[:lower:]')}
image=ghcr.io/$repo:$sha

if ! command -v docker >/dev/null; then
  if command -v dnf >/dev/null; then dnf install -y docker; else apt-get install -y docker.io; fi
fi
systemctl enable --now docker >/dev/null

# CI publishes the image a few minutes after the commit lands on main, and the
# timer may get here first: wait for it rather than fail.
if ! docker image inspect "$image" >/dev/null 2>&1; then
  for _ in $(seq 40); do
    docker pull -q "$image" && break
    echo "waiting for $image"
    sleep 30
  done
fi
docker image inspect "$image" >/dev/null

env="$ROOT/etc/stride-lite/image.env"
want="STRIDE_IMAGE=$image"
if [ "$(cat "$env" 2>/dev/null)" != "$want" ]; then
  install -d "$(dirname "$env")"
  echo "$want" > "$env"
  echo "image $image"
fi
