#!/usr/bin/env bash
# Prefixes each line of stdin with the UTC time it arrived.
export TZ=UTC
while IFS= read -r line || [ -n "$line" ]; do
  printf '%(%Y-%m-%dT%H:%M:%SZ)T %s\n' -1 "$line"
done
