#!/usr/bin/env bash
# The API's image for the checked-out commit, pulled and named for
# stride-api.service. Run by install-node-config.sh. If CI has not published it
# yet, this fails and the deploy is retried by the timer.
set -euo pipefail
cd "$(dirname "$0")/../../.."
repo=$(git remote get-url origin | sed -E 's#.*github\.com[/:]##; s#\.git$##' | tr '[:upper:]' '[:lower:]')
image=ghcr.io/$repo:$(git rev-parse HEAD)

command -v docker >/dev/null || dnf install -y docker || apt-get install -y docker.io
systemctl enable --now docker
docker image inspect "$image" >/dev/null 2>&1 || docker pull -q "$image"
echo "STRIDE_IMAGE=$image" > "${NODE_ROOT:-}/etc/stride-lite/image.env"
