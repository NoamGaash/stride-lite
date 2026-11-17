#!/usr/bin/env bash
# Prints the region an S3 bucket lives in. S3 names it in a header on any
# answer, even a refusal and even to an anonymous caller, so this needs no
# credentials. Falls back to AWS_REGION when S3 cannot be reached.
#
#   scripts/bucket-region.sh openbus-stride-public    # eu-west-1
set -euo pipefail
BUCKET=${1:?usage: bucket-region.sh <bucket>}

region=$(curl -sSI --max-time 10 "https://$BUCKET.s3.amazonaws.com/" 2> /dev/null |
  tr -d '\r' | awk -F': ' 'tolower($1) == "x-amz-bucket-region" { print $2 }')
echo "${region:-${AWS_REGION:-us-east-1}}"
