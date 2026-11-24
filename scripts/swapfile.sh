#!/usr/bin/env bash
# Moved to deploy/aws/bin/. Kept for the one deploy that crosses the move: a
# node still on the old tree runs this path (from its systemd units, its cron
# entries, the timer's auto-deploy.sh, and the SSM command in aws-deploy.yml)
# before it has the new one. Delete once every node has deployed past it.
exec "$(dirname "$0")/../deploy/aws/bin/$(basename "$0")" "$@"
