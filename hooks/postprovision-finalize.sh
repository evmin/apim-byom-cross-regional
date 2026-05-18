#!/usr/bin/env bash
# =============================================================================
# hooks/postprovision-finalize.sh — post-deploy state corrections that the
# Azure ARM control plane refuses at create time.
# =============================================================================
#
# Currently the only step:
#   * APIM Std v2 / Prem v2 cannot be created with publicNetworkAccess=Disabled
#     (the platform rejects with ActivateServiceWithPrivateEndpointAccessNotAllowed).
#     We create with Enabled, then immediately patch it to Disabled here.
#
# Idempotent: if APIM is already Disabled, the patch is a no-op.
# Required env (supplied by azd):
#   - MODEL_RESOURCE_GROUP_NAME — Sweden Central model RG
# =============================================================================

set -euo pipefail

MODEL_RG="${MODEL_RESOURCE_GROUP_NAME:-}"
if [[ -z "${MODEL_RG}" ]]; then
  # Fall back to discovery by tag.
  MODEL_RG=$(az group list --query "[?tags.\"iac-feature\"=='001-private-foundry-iac' && contains(name, '-model-')].name | [0]" -o tsv 2>/dev/null || true)
fi

if [[ -z "${MODEL_RG}" ]]; then
  echo "finalize: MODEL_RESOURCE_GROUP_NAME not set and tag-based discovery failed — skipping APIM patch" >&2
  exit 0
fi

APIM_NAME=$(az resource list --resource-group "${MODEL_RG}" --resource-type Microsoft.ApiManagement/service --query "[0].name" -o tsv)
if [[ -z "${APIM_NAME}" ]]; then
  echo "finalize: no APIM service found in ${MODEL_RG} — skipping" >&2
  exit 0
fi

CURRENT=$(az apim show --resource-group "${MODEL_RG}" --name "${APIM_NAME}" --query "publicNetworkAccess" -o tsv 2>/dev/null || echo "")
echo "finalize: APIM ${APIM_NAME} publicNetworkAccess=${CURRENT:-<unknown>}"

if [[ "${CURRENT}" == "Disabled" ]]; then
  echo "finalize: APIM already Disabled — no-op"
else
  echo "finalize: patching APIM ${APIM_NAME} publicNetworkAccess -> Disabled"
  az resource patch \
    --resource-group "${MODEL_RG}" \
    --name "${APIM_NAME}" \
    --resource-type Microsoft.ApiManagement/service \
    --api-version 2024-05-01 \
    --properties '{"publicNetworkAccess":"Disabled"}' \
    --latest-include-preview >/dev/null

  # Confirm.
  AFTER=$(az apim show --resource-group "${MODEL_RG}" --name "${APIM_NAME}" --query "publicNetworkAccess" -o tsv)
  echo "finalize: APIM ${APIM_NAME} publicNetworkAccess=${AFTER}"
  if [[ "${AFTER}" != "Disabled" ]]; then
    echo "finalize: ERROR — patch reported success but property is still ${AFTER}" >&2
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# Lock down solution-tagged managed disks (jumpbox OS disk).
# Managed disks default to publicNetworkAccess=Enabled (controls disk export over
# the public Internet). Disks attached to a running VM cannot be exported anyway,
# but the posture-audit (postprovision-audit.sh) treats this property uniformly
# across all solution-tagged resources — so we patch the disk to Disabled here.
# Idempotent: skipped if already Disabled.
# -----------------------------------------------------------------------------
AGENT_RG="${AGENT_RESOURCE_GROUP_NAME:-${AZURE_RESOURCE_GROUP:-}}"
if [[ -z "${AGENT_RG}" ]]; then
  AGENT_RG=$(az group list --query "[?tags.\"iac-feature\"=='001-private-foundry-iac' && contains(name, '-agent-')].name | [0]" -o tsv 2>/dev/null || true)
fi
if [[ -n "${AGENT_RG}" ]]; then
  DISK_IDS=$(az disk list --resource-group "${AGENT_RG}" --query "[?tags.\"iac-feature\"=='001-private-foundry-iac' && publicNetworkAccess=='Enabled'].id" -o tsv 2>/dev/null || true)
  if [[ -n "${DISK_IDS}" ]]; then
    while IFS= read -r DID; do
      [[ -z "${DID}" ]] && continue
      DNAME=$(basename "${DID}")
      echo "finalize: patching disk ${DNAME} publicNetworkAccess -> Disabled, networkAccessPolicy -> DenyAll"
      az disk update --ids "${DID}" --public-network-access Disabled --network-access-policy DenyAll >/dev/null
    done <<< "${DISK_IDS}"

    # Resource Graph is eventually consistent (~30-90s lag). The posture audit
    # uses `az graph query` to enumerate solution-tagged resources, so we must
    # wait for the patch to propagate before the audit runs, otherwise the
    # audit will see stale `publicNetworkAccess=Enabled` and fail.
    echo "finalize: waiting for Resource Graph to reflect disk patch..."
    for i in $(seq 1 30); do
      STALE=$(az graph query --first 100 -q "
        Resources
        | where type == 'microsoft.compute/disks'
        | where tags['iac-feature'] == '001-private-foundry-iac'
        | where properties.publicNetworkAccess == 'Enabled'
        | count
      " --output json 2>/dev/null | jq -r '.data[0].Count // .data[0].count_ // 0')
      if [[ "${STALE}" == "0" ]]; then
        echo "finalize: Resource Graph updated after ${i} attempt(s)"
        break
      fi
      sleep 5
    done
    if [[ "${STALE}" != "0" ]]; then
      echo "finalize: WARNING — Resource Graph still reports stale disk state after 150s; audit may flake" >&2
    fi
  else
    echo "finalize: no solution-tagged disks with publicNetworkAccess=Enabled — no-op"
  fi
else
  echo "finalize: AGENT_RESOURCE_GROUP_NAME not set and tag-based discovery failed — skipping disk patch" >&2
fi

echo "finalize: OK"
