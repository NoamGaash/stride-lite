#!/usr/bin/env bash
# Saves the database to S3, or restores it from there, as one ClickHouse
# BACKUP/RESTORE. This is what makes the first load cheap for the second
# instance onwards, and it is the only piece of this deployment that reads or
# writes a bucket of ours rather than a public one.
#
#   ./scripts/backup.sh save    s3://stride-lite-backup-123456789012/full/
#   ./scripts/backup.sh restore s3://stride-lite-backup-123456789012/full/
#
# Why it exists, against docs/DEPLOYMENT.md §"Availability is not a requirement
# here", which says this module deliberately has no backups: that argument is
# about losing the node, and it still holds — the node is a derived cache and
# the archive is the system of record. This is about *filling* a node. Rebuilding
# from public data reads 154.63 GB of a non-profit's S3 and re-parses 13.7
# billion rows; restoring reads a copy we already own, in our own region, and
# costs Hasadna nothing. So the backup is not insurance, it is the first load.
#
# Credentials on AWS: none. ClickHouse signs the S3 requests with a role it
# assumes through extra_credentials(role_arn = …), and that role trusts the
# instance role. Measured on 26.10: the one-argument S3() form is refused with
# ACCESS_DENIED ("not allowed to use the server's own credentials") unless
# s3_allow_server_credentials_in_user_queries is enabled, while the role_arn
# form is allowed with that setting left at its default — the server's ambient
# identity signs only the STS AssumeRole call, and the assumed role's own
# credentials sign every S3 request. So this needs no static key and no relaxed
# setting.
#
# A node outside AWS has no instance role to assume through, so it signs with a
# static key instead, from the standard AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY
# that the aws CLI in scripts/first-load.sh reads as well. The query goes in on
# stdin, so the secret never sits on a command line.
set -euo pipefail

ACTION=${1:?usage: backup.sh <save|restore> <s3-url>}
URL=${2:?usage: backup.sh <save|restore> <s3-url>}
CH_DB=${CH_DB:-stride}
CH=${CH_CLIENT:-clickhouse client}
# The database name inside the backup. Ours was built in a database called prod,
# so a restore renames it on the way in; a backup this script wrote matches.
BACKUP_DB=${BACKUP_DB:-$CH_DB}
BACKUP_ROLE_ARN=${BACKUP_ROLE_ARN:-}
AWS_REGION=${AWS_REGION:-us-east-1}

# ClickHouse's S3 backup engine takes an endpoint URL, not an s3:// one, in the
# bucket's own region: a node restores from one bucket and publishes to another.
case $URL in
  s3://*)
    rest=${URL#s3://}
    URL="https://${rest%%/*}.s3.$("$(dirname "$0")/bucket-region.sh" "${rest%%/*}").amazonaws.com/${rest#*/}"
    ;;
esac

if [ -n "$BACKUP_ROLE_ARN" ]; then
  dest="S3('$URL', extra_credentials(role_arn = '$BACKUP_ROLE_ARN'))"
elif [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  dest="S3('$URL', '$AWS_ACCESS_KEY_ID', '${AWS_SECRET_ACCESS_KEY:?AWS_ACCESS_KEY_ID is set without AWS_SECRET_ACCESS_KEY}')"
else
  echo "Neither BACKUP_ROLE_ARN nor AWS_ACCESS_KEY_ID is set: the request will be" >&2
  echo "sent unsigned, which only works against a public bucket. See infra/main.tf." >&2
  dest="S3('$URL')"
fi

case $ACTION in
  save)
    # Safe to run with the ingest chain live: BACKUP copies the parts that exist
    # when it starts, so rows written while it runs are simply not in it. A node
    # restoring from it lands slightly behind and closes the gap from the
    # archive, which is what scripts/first-load.sh's backfill stage is for.
    #
    # Not --async: the caller is a systemd unit or an operator who wants the
    # exit code to mean the backup is complete.
    $CH <<< "BACKUP DATABASE \`$CH_DB\` TO $dest"
    ;;
  restore)
    # allow_different_table_def because the tables are already there: the
    # bootstrap applies db/schema.sql before this runs, and a projection added
    # since the backup was taken is a difference that matters not at all for
    # the data being restored into an empty table.
    if [ "$BACKUP_DB" = "$CH_DB" ]; then
      $CH <<< "RESTORE DATABASE \`$CH_DB\` FROM $dest SETTINGS allow_different_table_def = 1"
    else
      $CH <<< "RESTORE DATABASE \`$BACKUP_DB\` AS \`$CH_DB\` FROM $dest SETTINGS allow_different_table_def = 1"
    fi
    ;;
  *)
    echo "usage: backup.sh <save|restore> <s3-url>" >&2
    exit 2
    ;;
esac
