#!/usr/bin/env bash
# =============================================================================
# scripts/jumpbox-vm/posture-from-vnet.sh — DJ-012 — VNet-side posture audit.
# =============================================================================
# Mirrors the host-side `hooks/postprovision-audit.sh` checks but runs from
# *inside* the agent VNet using the jumpbox MI. Confirms that even from a
# privileged in-VNet host, every solution-managed data-plane resource still
# advertises `publicNetworkAccess: Disabled`.
#
# Required env (jumpbox-smoke.sh propagates):
#   AGENT_RESOURCE_GROUP_NAME, MODEL_RESOURCE_GROUP_NAME
#
# Exit: 0 if every audited resource is Disabled; 1 otherwise.
# =============================================================================

set -euo pipefail

: "${AGENT_RESOURCE_GROUP_NAME:?AGENT_RESOURCE_GROUP_NAME required}"
: "${MODEL_RESOURCE_GROUP_NAME:?MODEL_RESOURCE_GROUP_NAME required}"

# Ensure az is signed-in via the VM's UAMI (idempotent).
if ! az account show >/dev/null 2>&1; then
  echo "posture-from-vnet: az login --identity"
  if [[ -n "${AZURE_CLIENT_ID:-}" ]]; then
    az login --identity --client-id "${AZURE_CLIENT_ID}" --only-show-errors >/dev/null
  else
    az login --identity --only-show-errors >/dev/null
  fi
fi

# Resource Graph returns full properties (unlike `az resource list` which
# strips them) and works from inside the VNet (control-plane endpoint).
JSON=$(az graph query --first 200 -q "
  Resources
  | where tags['iac-feature'] == '001-private-foundry-iac'
  | where type in~ (
      'microsoft.cognitiveservices/accounts',
      'microsoft.documentdb/databaseaccounts',
      'microsoft.search/searchservices',
      'microsoft.storage/storageaccounts',
      'microsoft.apimanagement/service'
    )
  | project name, type, resourceGroup, pna = tostring(properties.publicNetworkAccess)
" --output json)

audited=0
failed=0
mapfile -t ROWS < <(echo "${JSON}" | jq -c '.data[]')
for row in "${ROWS[@]}"; do
  name=$(echo "${row}" | jq -r '.name')
  type=$(echo "${row}" | jq -r '.type')
  rg=$(echo "${row}" | jq -r '.resourceGroup')
  pna=$(echo "${row}" | jq -r '.pna')
  audited=$((audited + 1))
  # APIM exposes `publicNetworkAccess` only at the top-level resource (after
  # patch). Some types may return empty when public access is implicitly off
  # (e.g. due to virtualNetworkType=Internal). Treat empty as failure to be
  # strict — every data plane in this solution should explicitly be Disabled.
  if [[ "${pna}" == "Disabled" ]]; then
    echo "posture-from-vnet: OK   ${rg}/${name} (${type}) Disabled"
  else
    echo "posture-from-vnet: FAIL ${rg}/${name} (${type}) publicNetworkAccess='${pna}'" >&2
    failed=$((failed + 1))
  fi
done

echo "posture-from-vnet: audited=${audited} failed=${failed}"
if [[ "${failed}" -gt 0 ]]; then
  echo "posture-from-vnet: FAIL — ${failed} resource(s) expose public access" >&2
  exit 1
fi
echo "posture-from-vnet: PASS"
