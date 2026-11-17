#!/usr/bin/env bash
# user_data for the AWS node, run once per instance launch, as root. Terraform
# renders the values below in; scripts/bootstrap-node.sh does the rest, the same
# way it does on a server outside AWS.
set -euxo pipefail

curl -fsSL "https://raw.githubusercontent.com/NoamGaash/stride-lite/${branch}/scripts/bootstrap-node.sh" \
  -o /root/bootstrap-node.sh

# The gp3 data volume, in nvme naming on Graviton.
DATA_DEVICE=/dev/nvme1n1 \
BRANCH="${branch}" \
AWS_REGION="${region}" \
BACKUP_URL="${backup_url}" \
BACKUP_ROLE_ARN="${backup_role_arn}" \
  bash /root/bootstrap-node.sh
