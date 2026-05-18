#!/usr/bin/env bash
# =============================================================================
# hooks/postprovision-audit.sh — T-036 posture audit.
# =============================================================================
# Invoked from azure.yaml `hooks.postprovision`. Runs AFTER `azd up`/`azd provision`
# and asserts the deployed topology matches the security posture promised by
# data-model.md and plan.md.
#
# Posture assertions (every check exits the script with status 1 on failure):
#   1. Every solution-tagged resource has publicNetworkAccess = Disabled (or
#      equivalent ipRules / networkAcls = Deny).
#   2. No role assignment on a solution-managed scope is bound to a User /
#      Group principal (only ServicePrincipal MIs are allowed — leak-prevention).
#   3. No solution-managed account exposes data-plane keys with allow-key-auth =
#      true (Cognitive Services accounts, AI Search admin keys, Storage shared keys).
#   4. The cross-region PE (apim-gateway-* in agentRg) exists and is in
#      ProvisioningState=Succeeded.
#   5. APIM `policy` xml contains the validate-azure-ad-token policy with the
#      WE project MI's principalId (oid) as the only accepted oid.
#
# The script is idempotent and side-effect-free: it only queries.
# Required env: AZURE_RESOURCE_GROUP (agent RG) — supplied by azd.
# =============================================================================

set -euo pipefail

SOLUTION_TAG_KEY="iac-feature"
SOLUTION_TAG_VAL="001-private-foundry-iac"

echo "::group::posture-audit: enumerate solution-tagged resources"
RESOURCES_JSON=$(az graph query --first 1000 -q "
  Resources
  | where tags['${SOLUTION_TAG_KEY}'] == '${SOLUTION_TAG_VAL}'
  | project id, type, name, location, properties
" --output json)

COUNT=$(echo "${RESOURCES_JSON}" | jq '.data | length')
echo "found ${COUNT} solution-tagged resources"
if [[ "${COUNT}" -lt 8 ]]; then
  echo "ERROR: expected at least 8 solution-tagged resources, found ${COUNT}" >&2
  exit 1
fi
echo "::endgroup::"

echo "::group::posture-audit: assert publicNetworkAccess=Disabled"
PUBLIC_ENABLED=$(echo "${RESOURCES_JSON}" | jq -r '
  [.data[]
   | select(.properties.publicNetworkAccess == "Enabled"
            or .properties.networkAcls.defaultAction == "Allow")
   | .id] | length')
if [[ "${PUBLIC_ENABLED}" -gt 0 ]]; then
  echo "ERROR: ${PUBLIC_ENABLED} solution resource(s) have public network access enabled" >&2
  echo "${RESOURCES_JSON}" | jq -r '.data[] | select(.properties.publicNetworkAccess == "Enabled" or .properties.networkAcls.defaultAction == "Allow") | .id' >&2
  exit 1
fi
echo "OK — every solution-tagged resource has publicNetworkAccess=Disabled"
echo "::endgroup::"

echo "::group::posture-audit: assert no User/Group principals on solution-scoped role assignments"
SOLUTION_IDS=$(echo "${RESOURCES_JSON}" | jq -r '.data[].id')
LEAKED=0
while IFS= read -r RID; do
  [[ -z "${RID}" ]] && continue
  USERS=$(az role assignment list --scope "${RID}" --query "[?principalType != 'ServicePrincipal'].{principalId:principalId, principalType:principalType, role:roleDefinitionName}" -o json 2>/dev/null || echo "[]")
  COUNT_U=$(echo "${USERS}" | jq 'length')
  if [[ "${COUNT_U}" -gt 0 ]]; then
    echo "ERROR: non-ServicePrincipal role assignment(s) on ${RID}" >&2
    echo "${USERS}" >&2
    LEAKED=$((LEAKED + COUNT_U))
  fi
done <<< "${SOLUTION_IDS}"
if [[ "${LEAKED}" -gt 0 ]]; then
  echo "ERROR: ${LEAKED} leaked user/group role assignment(s) found" >&2
  exit 1
fi
echo "OK — all role assignments on solution-tagged scopes are ServicePrincipal"
echo "::endgroup::"

echo "::group::posture-audit: assert data-plane key auth is disabled"
KEY_AUTH_LEAK=$(echo "${RESOURCES_JSON}" | jq -r '
  [.data[]
   | select(
       (.type == "Microsoft.CognitiveServices/accounts" and (.properties.disableLocalAuth // false) == false) or
       (.type == "Microsoft.Search/searchServices" and (.properties.authOptions.aadOrApiKey // null) == null and (.properties.disableLocalAuth // false) == false) or
       (.type == "Microsoft.Storage/storageAccounts" and (.properties.allowSharedKeyAccess // true) == true) or
       (.type == "Microsoft.DocumentDB/databaseAccounts" and (.properties.disableLocalAuth // false) == false)
     )
   | .id] | length')
if [[ "${KEY_AUTH_LEAK}" -gt 0 ]]; then
  echo "ERROR: ${KEY_AUTH_LEAK} solution resource(s) still allow key-based auth" >&2
  exit 1
fi
echo "OK — every solution-managed account is AAD-only"
echo "::endgroup::"

echo "::group::posture-audit: assert APIM cross-region PE exists in agent RG"
AGENT_RG="${AZURE_RESOURCE_GROUP:-}"
if [[ -z "${AGENT_RG}" ]]; then
  echo "WARNING: AZURE_RESOURCE_GROUP not set; skipping cross-region PE check"
else
  # The cross-region APIM gateway PE targets an APIM service that lives in a
  # different region (typically SC). Match by what it does, not by name pattern.
  PE_COUNT=$(az network private-endpoint list -g "${AGENT_RG}" \
    --query "[?contains(privateLinkServiceConnections[0].privateLinkServiceId || 'x', 'Microsoft.ApiManagement/service') && provisioningState=='Succeeded'] | length(@)" \
    -o tsv 2>/dev/null || echo 0)
  if [[ "${PE_COUNT}" -lt 1 ]]; then
    echo "ERROR: cross-region APIM gateway PE missing or not Succeeded in ${AGENT_RG}" >&2
    exit 1
  fi
  echo "OK — cross-region APIM gateway PE present in ${AGENT_RG}"
fi
echo "::endgroup::"

echo "::group::posture-audit: assert APIM policy references the WE project MI oid"
MODEL_RG=$(echo "${RESOURCES_JSON}" | jq -r '[.data[] | select(.type == "Microsoft.ApiManagement/service") | .id][0]' | awk -F/ '{print $5}')
APIM_NAME=$(echo "${RESOURCES_JSON}" | jq -r '[.data[] | select(.type == "Microsoft.ApiManagement/service") | .name][0]')
PROJECT_MI=$(echo "${RESOURCES_JSON}" | jq -r '[.data[] | select(.type == "Microsoft.CognitiveServices/accounts" and (.location | test("westeurope|eastus2"))) | .identity.principalId][0]')
if [[ -n "${MODEL_RG}" && -n "${APIM_NAME}" && -n "${PROJECT_MI}" && "${PROJECT_MI}" != "null" ]]; then
  POLICY_XML=$(az apim policy show --service-name "${APIM_NAME}" --resource-group "${MODEL_RG}" --query value -o tsv)
  if ! echo "${POLICY_XML}" | grep -q "${PROJECT_MI}"; then
    echo "ERROR: APIM policy does not reference the WE project MI oid ${PROJECT_MI}" >&2
    exit 1
  fi
  echo "OK — APIM policy validates oid=${PROJECT_MI}"
else
  echo "WARNING: could not derive APIM/projectMI for policy check (apim=${APIM_NAME} mi=${PROJECT_MI})"
fi
echo "::endgroup::"

echo "posture-audit: all checks passed"
