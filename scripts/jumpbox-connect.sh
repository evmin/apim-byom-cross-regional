#!/usr/bin/env bash
# =============================================================================
# scripts/jumpbox-connect.sh — DJ-013 — interactive Bastion SSH to the
# demo jumpbox.
# =============================================================================
# Resolves the Bastion resource group + name and VM resource ID from `azd env
# get-values`, then opens an interactive SSH session via the Azure Bastion
# SSH proxy. Requires:
#   - az CLI logged in (`az login`)
#   - SSH private key locally (path passed via JUMPBOX_SSH_PRIVATE_KEY or
#     ~/.ssh/mreg-jumpbox by default)
#
# Usage:
#   scripts/jumpbox-connect.sh
#   JUMPBOX_SSH_PRIVATE_KEY=~/.ssh/my-key scripts/jumpbox-connect.sh
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."

KEY="${JUMPBOX_SSH_PRIVATE_KEY:-${HOME}/.ssh/mreg-jumpbox}"
USER="${JUMPBOX_ADMIN_USERNAME:-azureuser}"

ENV_VALUES=$(azd env get-values)
get() { echo "${ENV_VALUES}" | awk -F= -v k="$1" '$1==k {gsub(/^"|"$/,"",$2); print $2}'; }

BASTION_NAME=$(get jumpboxBastionName)
BASTION_RG=$(get jumpboxBastionResourceGroup)
VM_ID=$(get jumpboxVmId)

if [[ -z "${BASTION_NAME}" || -z "${BASTION_RG}" || -z "${VM_ID}" ]]; then
  echo "jumpbox-connect: jumpbox outputs missing — has \`azd up\` run?" >&2
  exit 2
fi

if [[ ! -f "${KEY}" ]]; then
  echo "jumpbox-connect: SSH private key not found at ${KEY}" >&2
  echo "                  generate one with:  ssh-keygen -t ed25519 -f ${KEY}" >&2
  echo "                  then set JUMPBOX_SSH_PUBLIC_KEY=\"\$(cat ${KEY}.pub)\" and re-run \`azd up\`." >&2
  exit 2
fi

echo "jumpbox-connect: bastion=${BASTION_NAME} rg=${BASTION_RG} vm=${VM_ID}"

exec az network bastion ssh \
  --name "${BASTION_NAME}" \
  --resource-group "${BASTION_RG}" \
  --target-resource-id "${VM_ID}" \
  --auth-type ssh-key \
  --username "${USER}" \
  --ssh-key "${KEY}"
