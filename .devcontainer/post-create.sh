#!/usr/bin/env bash
# Tools the repository's own scripts and CI use, at CI's versions. Nothing here
# starts ClickHouse or reads S3: ./up.sh does that, when you ask for it.
set -euo pipefail
cd "$(dirname "$0")/.."

sudo chown -R node:node /home/node/.claude

HURL_VERSION=8.1.0
HURL_SHA256=b497e7ab328100c507f1f3323ebe7cc5990d831ae4f9473b74d40b02971da4ca
f=hurl-$HURL_VERSION-x86_64-unknown-linux-gnu
if [ "$(uname -m)" = x86_64 ] && ! command -v hurl >/dev/null; then
  tmp=$(mktemp -d)
  curl -sSfL -o "$tmp/$f.tar.gz" "https://github.com/Orange-OpenSource/hurl/releases/download/$HURL_VERSION/$f.tar.gz"
  echo "$HURL_SHA256  $tmp/$f.tar.gz" | sha256sum -c
  tar xzf "$tmp/$f.tar.gz" -C "$tmp"
  sudo install "$tmp/$f/bin/hurl" /usr/local/bin/hurl
  rm -rf "$tmp"
fi

[ -x ./clickhouse ] || curl -sSL https://clickhouse.com/ | sh

(cd api && npm ci)
