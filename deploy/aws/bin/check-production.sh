#!/usr/bin/env bash
# scripts/check-production.sh against the AWS deployment, by its CloudFront name.
API_URL=${API_URL:-https://d2uqtzxw09mygh.cloudfront.net} exec "$(dirname "$0")/../../../scripts/check-production.sh" "$@"
