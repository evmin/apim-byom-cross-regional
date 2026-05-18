#!/usr/bin/env bash
# =============================================================================
# demo-scripts/01_sc_model.sh — STAGE 1: model in Sweden Central.
# =============================================================================
# What this proves:
#   The model behind the demo lives in Sweden Central. Pure az control-plane
#   reads from the operator's Mac — no jumpbox needed.
# Exit: 0 + final line `PASS — 01_sc_model` on success.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./00_env.sh
source ./00_env.sh

printf '\n==== STAGE 1: model in Sweden Central ====\n'
echo "resource group : $MODEL_RG"
echo "expected region: swedencentral"
echo "expected dep'l : $MODEL_DEPLOYMENT_NAME"
echo

echo "--- AOAI / Foundry account ($MODEL_RG) ---"
ACCOUNTS_JSON=$(az cognitiveservices account list -g "$MODEL_RG" \
  --query "[].{name:name,location:location,kind:kind}" -o json)
echo "$ACCOUNTS_JSON" | jq -r '. | (["NAME","LOCATION","KIND"] | @tsv), (.[] | [.name,.location,.kind] | @tsv)' | column -t -s $'\t'

ACCT_COUNT=$(echo "$ACCOUNTS_JSON" | jq 'length')
if [[ "$ACCT_COUNT" -ne 1 ]]; then
  echo "FAIL — 01_sc_model: expected exactly 1 Cognitive Services account in $MODEL_RG, got $ACCT_COUNT" >&2
  exit 1
fi
SC_ACCT=$(echo "$ACCOUNTS_JSON" | jq -r '.[0].name')
SC_LOC=$(echo "$ACCOUNTS_JSON" | jq -r '.[0].location')
SC_LOC_NORM=$(echo "$SC_LOC" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

if [[ "$SC_LOC_NORM" != "swedencentral" ]]; then
  echo "FAIL — 01_sc_model: account $SC_ACCT is in '$SC_LOC', expected Sweden Central" >&2
  exit 1
fi

echo
echo "--- deployments on $SC_ACCT ---"
az cognitiveservices account deployment list \
  -g "$MODEL_RG" -n "$SC_ACCT" \
  --query "[].{name:name,model:properties.model.name,version:properties.model.version,sku:sku.name,capacity:sku.capacity}" \
  -o table

if ! az cognitiveservices account deployment list -g "$MODEL_RG" -n "$SC_ACCT" \
       --query "[?name=='${MODEL_DEPLOYMENT_NAME}'] | length(@)" -o tsv | grep -qx 1; then
  echo "FAIL — 01_sc_model: deployment '${MODEL_DEPLOYMENT_NAME}' not found on $SC_ACCT" >&2
  exit 1
fi

echo
echo "PASS — 01_sc_model"
