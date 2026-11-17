#!/usr/bin/env bash
# A node reads one backup bucket and writes another, and the two need not be in
# the same region, so an s3:// URL must resolve in its own bucket's region rather
# than in AWS_REGION. Asks real S3, anonymously, about a bucket in eu-west-1.
#
#   tests/bucket-region.sh
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0

region=$(scripts/bucket-region.sh openbus-stride-public 2> /dev/null || true)
[ "$region" = eu-west-1 ] || { echo "FAIL: bucket-region.sh said '$region', expected eu-west-1"; fail=1; }

query=$(AWS_REGION=us-east-1 AWS_ACCESS_KEY_ID=x AWS_SECRET_ACCESS_KEY=y CH_CLIENT=cat \
  scripts/backup.sh save s3://openbus-stride-public/somewhere/)
grep -q "https://openbus-stride-public.s3.eu-west-1.amazonaws.com/somewhere/" <<< "$query" ||
  { echo "FAIL: backup.sh built: $query"; fail=1; }

[ "$fail" = 0 ] && echo "bucket-region: s3:// URLs resolve in their own bucket's region"
exit "$fail"
