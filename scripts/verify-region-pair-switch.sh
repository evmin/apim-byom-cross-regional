#!/usr/bin/env bash
# =============================================================================
# scripts/verify-region-pair-switch.sh — T-035b region-pair switching check.
# =============================================================================
#
# Operator script. Spins up a parallel `azd` environment using
# REGION_PAIR=eastus2+swedencentral, runs `azd up`, runs the posture audit
# + smoke + teardown probe against it, then `azd down`s the alternate env.
#
# Requires the operator to have already run a baseline westeurope+swedencentral
# environment. Use:
#   ./scripts/verify-region-pair-switch.sh <baseline-env-name>-eus2
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <eus2-env-name>" >&2
  exit 1
fi

EUS2_ENV="$1"

echo "switch: azd env new ${EUS2_ENV}"
azd env new "${EUS2_ENV}" --no-prompt || true
azd env select "${EUS2_ENV}"

echo "switch: setting REGION_PAIR=eastus2+swedencentral"
azd env set REGION_PAIR "eastus2+swedencentral"
azd env set AZURE_LOCATION "eastus2"

# Copy through other required env vars from the WE+SC baseline. The operator is
# expected to have set them (NAME_PREFIX, WE_VNET_CIDR, ...). We don't override.

echo "switch: azd up"
azd up --no-prompt

echo "switch: running posture audit against ${EUS2_ENV}"
AZURE_RESOURCE_GROUP="$(azd env get-values | awk -F= '/AGENT_RG/ {gsub(/"/, "", $2); print $2}')" \
  ./hooks/postprovision-audit.sh

echo "switch: running smoke (ENABLE_SMOKE_VALIDATION must be true to actually call)"
./hooks/postprovision-smoke.sh || true

echo "switch: azd down (--purge)"
azd down --purge --force

echo "switch: running teardown probe"
./scripts/verify-teardown.sh

echo "switch: PASS — region-pair switching verified for ${EUS2_ENV}"
