#!/usr/bin/env bash
# =============================================================================
# demo-scripts/02_sc_apim.sh — STAGE 2: APIM in Sweden Central.
# =============================================================================
# What this proves:
#   The APIM service fronting the SC model is in Sweden Central, has its
#   public network access disabled (PE-only), exposes the `openai` API, and
#   carries the validate-azure-ad-token + backend-rewrite policy. Pure
#   control-plane reads from the operator's Mac.
# Exit: 0 + `PASS — 02_sc_apim` on success.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./00_env.sh
source ./00_env.sh

printf '\n==== STAGE 2: APIM in Sweden Central ====\n'
echo "resource group   : $MODEL_RG"
echo "expected service : $APIM_SERVICE_NAME"
echo "expected region  : swedencentral"
echo "expected access  : publicNetworkAccess=Disabled"
echo

echo "--- APIM service ---"
APIM_JSON=$(az apim list -g "$MODEL_RG" \
  --query "[].{name:name,location:location,publicNetworkAccess:publicNetworkAccess,sku:sku.name}" -o json)
echo "$APIM_JSON" | jq -r '. | (["NAME","LOCATION","PUBNET","SKU"] | @tsv), (.[] | [.name,.location,.publicNetworkAccess,.sku] | @tsv)' | column -t -s $'\t'

if [[ "$(echo "$APIM_JSON" | jq 'length')" -ne 1 ]]; then
  echo "FAIL — 02_sc_apim: expected exactly 1 APIM service in $MODEL_RG" >&2
  exit 1
fi

APIM_NAME=$(echo "$APIM_JSON" | jq -r '.[0].name')
APIM_LOC=$(echo "$APIM_JSON" | jq -r '.[0].location')
APIM_ACCESS=$(echo "$APIM_JSON" | jq -r '.[0].publicNetworkAccess')

# az apim returns the display name ("Sweden Central"); normalize for compare.
APIM_LOC_NORM=$(echo "$APIM_LOC" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

if [[ "$APIM_NAME" != "$APIM_SERVICE_NAME" ]]; then
  echo "FAIL — 02_sc_apim: discovered APIM '$APIM_NAME' != derived '$APIM_SERVICE_NAME'" >&2
  exit 1
fi
if [[ "$APIM_LOC_NORM" != "swedencentral" ]]; then
  echo "FAIL — 02_sc_apim: APIM is in '$APIM_LOC', expected Sweden Central" >&2
  exit 1
fi
if [[ "$APIM_ACCESS" != "Disabled" ]]; then
  echo "FAIL — 02_sc_apim: publicNetworkAccess='$APIM_ACCESS', expected Disabled" >&2
  exit 1
fi

echo
echo "--- openai API on $APIM_NAME ---"
az apim api list -g "$MODEL_RG" -n "$APIM_NAME" \
  --query "[?contains(name,'openai')].{name:name,path:path,serviceUrl:serviceUrl,protocols:protocols}" \
  -o table

OPENAI_API_ID=$(az apim api list -g "$MODEL_RG" -n "$APIM_NAME" \
  --query "[?contains(name,'openai')].name | [0]" -o tsv)
if [[ -z "$OPENAI_API_ID" ]]; then
  echo "FAIL — 02_sc_apim: no API with name containing 'openai' on $APIM_NAME" >&2
  exit 1
fi

echo
echo "--- operations on API '$OPENAI_API_ID' ---"
az apim api operation list -g "$MODEL_RG" -n "$APIM_NAME" \
  --api-id "$OPENAI_API_ID" \
  --query "[].{name:name,method:method,urlTemplate:urlTemplate}" -o table

echo
echo "--- inbound policy excerpt (first 30 lines, service-level) ---"
SUB_ID=$(az account show --query id -o tsv)
POLICY_URL="https://management.azure.com/subscriptions/${SUB_ID}/resourceGroups/${MODEL_RG}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/policies/policy?api-version=2022-08-01&format=rawxml"
# `az rest` warns when the response is XML — pipe through 2>/dev/null and rely on the body.
az rest --method GET --url "$POLICY_URL" --query 'properties.value' -o tsv 2>/dev/null | head -n 30

echo
echo "PASS — 02_sc_apim"
