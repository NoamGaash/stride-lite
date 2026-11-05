#!/usr/bin/env bash
# Regenerates infra/rates.json from AWS's own published price list.
#
# The rates in a cost estimate go stale silently, and a number nobody can
# re-derive is a number nobody should act on. This pulls them from the source:
# https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/ — public, no
# credentials, no account. The EC2 offer file for one region is ~280 MB, so it
# is streamed through a filter rather than kept.
set -euo pipefail

REGION=${REGION:-eu-west-1}
BASE=https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws
OUT=${1:-infra/rates.json}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "== fetching price lists for $REGION"
curl -sS "$BASE/AmazonEC2/current/$REGION/index.csv" -o "$WORK/ec2.csv"
curl -sS "$BASE/AmazonVPC/current/index.csv"          -o "$WORK/vpc.csv"
curl -sS "$BASE/AmazonS3/current/$REGION/index.csv"   -o "$WORK/s3.csv"
curl -sS "$BASE/AmazonCloudFront/current/index.csv"   -o "$WORK/cf.csv"

python3 -I "$(dirname "$0")/extract-rates.py" "$WORK" "$REGION" > "$OUT"
echo "== wrote $OUT"
