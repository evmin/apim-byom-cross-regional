#!/usr/bin/env bash
# =============================================================================
# hooks/postprovision-smoke.sh — DJ-016 — thin wrapper around the jumpbox
# validation suite.
# =============================================================================
# Replaces the original direct-curl smoke that ran from the operator host;
# that approach could never succeed because the APIM policy only accepts the
# agent project MI's `oid`. The end-to-end smoke must originate from inside
# the agent VNet via the Foundry project SDK.
#
# This wrapper simply delegates to `scripts/jumpbox-smoke.sh`, which uses
# the always-on demo jumpbox (provisioned by infra/modules/demo-jumpbox.bicep)
# to run smoke-sdk.py, smoke-reject.sh, smoke-dns.sh, and posture-from-vnet.sh.
#
# Gating:
#   - Respects ENABLE_SMOKE_VALIDATION (default: true). Skipped on `false`.
#   - Requires the jumpbox outputs to be present in `azd env get-values`
#     (jumpboxVmId, jumpboxBastionName, jumpboxBastionResourceGroup).
#   - Requires a local SSH private key matching JUMPBOX_SSH_PUBLIC_KEY. The
#     operator points to it via JUMPBOX_SSH_PRIVATE_KEY (default:
#     ~/.ssh/mreg-jumpbox).
#
# Wall-time: scripts/jumpbox-smoke.sh enforces its own 5-minute budget.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "${ENABLE_SMOKE_VALIDATION:-true}" != "true" ]]; then
  echo "smoke: ENABLE_SMOKE_VALIDATION=${ENABLE_SMOKE_VALIDATION:-unset} — skipped"
  exit 0
fi

# Sanity: jumpbox outputs present?
ENV_VALUES=$(azd env get-values 2>/dev/null || true)
if ! echo "${ENV_VALUES}" | grep -q '^jumpboxVmId='; then
  echo "smoke: jumpboxVmId missing from azd env — has \`azd provision\` finished?" >&2
  echo "smoke: skipping (FR-029 — no jumpbox available)" >&2
  exit 0
fi

# Sanity: SSH private key reachable locally?
KEY="${JUMPBOX_SSH_PRIVATE_KEY:-${HOME}/.ssh/mreg-jumpbox}"
if [[ ! -f "${KEY}" ]]; then
  echo "smoke: SSH private key not found at ${KEY}" >&2
  echo "       Generate with:  ssh-keygen -t ed25519 -f ${KEY}" >&2
  echo "       Then set JUMPBOX_SSH_PUBLIC_KEY=\"\$(cat ${KEY}.pub)\" and \`azd up\`." >&2
  echo "smoke: skipping (key absent on operator host)" >&2
  exit 0
fi

echo "smoke: delegating to scripts/jumpbox-smoke.sh (key=${KEY})"
exec ./scripts/jumpbox-smoke.sh
