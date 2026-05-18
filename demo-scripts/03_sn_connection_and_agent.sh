#!/usr/bin/env bash
# =============================================================================
# demo-scripts/03_sn_connection_and_agent.sh — STAGE 3: SN connection + agent.
# =============================================================================
# What this proves:
#   The Switzerland North Foundry account hosts a connection named
#   `apim-byom` pointing at APIM in Sweden Central, and a prompt agent
#   named `demo-cross-region-agent` configured to use that connection. The
#   agent is created on the fly if missing.
#
# Control-plane reads (account, connection) run from the Mac.
# Data-plane (/assistants REST) runs through scripts/jumpbox-run.sh because
# the SN project endpoint is on a private endpoint.
# Exit: 0 + `PASS — 03_sn_connection_and_agent` on success.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./00_env.sh
source ./00_env.sh

AGENT_NAME="demo-cross-region-agent"
AGENT_INSTRUCTIONS="You are a helpful assistant. Reply concisely."

printf '\n==== STAGE 3: SN connection + agent ====\n'
echo "agent rg          : $AGENT_RG"
echo "SN Foundry acct   : $SN_FOUNDRY_ACCOUNT_NAME"
echo "SN project        : $SN_FOUNDRY_PROJECT_NAME"
echo "connection name   : $FOUNDRY_CONNECTION_NAME"
echo "expected target ⊇ : $APIM_GATEWAY_HOSTNAME"
echo "agent to ensure   : $AGENT_NAME  (model: $MODEL_REF)"
echo

echo "--- SN Foundry account ---"
az cognitiveservices account show -g "$AGENT_RG" -n "$SN_FOUNDRY_ACCOUNT_NAME" \
  --query "{name:name,location:location,kind:kind,publicNetworkAccess:properties.publicNetworkAccess}" \
  -o json

SN_LOC=$(az cognitiveservices account show -g "$AGENT_RG" -n "$SN_FOUNDRY_ACCOUNT_NAME" \
  --query location -o tsv)
SN_LOC_NORM=$(echo "$SN_LOC" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
if [[ "$SN_LOC_NORM" != "switzerlandnorth" ]]; then
  echo "FAIL — 03_sn_connection_and_agent: SN account is in '$SN_LOC', expected Switzerland North" >&2
  exit 1
fi

echo
echo "--- connection '$FOUNDRY_CONNECTION_NAME' on $SN_FOUNDRY_ACCOUNT_NAME ---"
CONN_JSON=$(az cognitiveservices account connection show \
  -g "$AGENT_RG" -n "$SN_FOUNDRY_ACCOUNT_NAME" \
  --connection-name "$FOUNDRY_CONNECTION_NAME" -o json)
echo "$CONN_JSON" | jq '{name:.name, category:.properties.category, target:.properties.target, isDefault:.properties.isDefault, authType:.properties.authType}'

CONN_TARGET=$(echo "$CONN_JSON" | jq -r '.properties.target // empty')
if [[ "$CONN_TARGET" != *"$APIM_GATEWAY_HOSTNAME"* ]]; then
  echo "FAIL — 03_sn_connection_and_agent: connection target '$CONN_TARGET' does not contain '$APIM_GATEWAY_HOSTNAME'" >&2
  exit 1
fi

echo
echo "--- ensure agent '$AGENT_NAME' exists (via jumpbox → SN project /assistants) ---"

# Compose the remote bash snippet, with values interpolated locally so the
# viewer sees exactly the URL and body that hit the SN endpoint.
REMOTE=$(cat <<REMOTE_EOF
set -euo pipefail
echo "[remote] acquiring AAD token (audience https://ai.azure.com) via IMDS..."
TOKEN=\$(curl -sS -H 'Metadata:true' \
  'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://ai.azure.com' \
  | jq -r .access_token)
if [[ -z "\$TOKEN" || "\$TOKEN" == "null" ]]; then
  echo "[remote] FAIL: IMDS token returned empty" >&2; exit 1
fi
echo "[remote] token acquired (len=\${#TOKEN})"

echo "[remote] GET ${SN_FOUNDRY_PROJECT_ENDPOINT}/assistants?api-version=v1"
LIST=\$(curl -sS -w '\nHTTP %{http_code}\n' -H "Authorization: Bearer \$TOKEN" \
  '${SN_FOUNDRY_PROJECT_ENDPOINT}/assistants?api-version=v1')
HTTP=\$(printf '%s' "\$LIST" | awk '/^HTTP /{print \$2}')
BODY=\$(printf '%s' "\$LIST" | sed '/^HTTP /d')
if [[ "\$HTTP" != "200" ]]; then
  echo "[remote] FAIL: GET /assistants returned HTTP \$HTTP" >&2
  printf '%s\n' "\$BODY" | head -c 400 >&2; echo >&2
  exit 1
fi

AID=\$(printf '%s' "\$BODY" | jq -r '.data[]? | select(.name=="${AGENT_NAME}") | .id' | head -n1)

if [[ -z "\$AID" ]]; then
  echo "[remote] agent '${AGENT_NAME}' not found — POST /assistants to create it"
  CREATE=\$(curl -sS -w '\nHTTP %{http_code}\n' \
    -H "Authorization: Bearer \$TOKEN" -H 'Content-Type: application/json' \
    -X POST '${SN_FOUNDRY_PROJECT_ENDPOINT}/assistants?api-version=v1' \
    -d '{"name":"${AGENT_NAME}","instructions":"${AGENT_INSTRUCTIONS}","model":"${MODEL_REF}"}')
  HTTP=\$(printf '%s' "\$CREATE" | awk '/^HTTP /{print \$2}')
  BODY=\$(printf '%s' "\$CREATE" | sed '/^HTTP /d')
  if [[ "\$HTTP" != "200" && "\$HTTP" != "201" ]]; then
    echo "[remote] FAIL: POST /assistants returned HTTP \$HTTP" >&2
    printf '%s\n' "\$BODY" | head -c 400 >&2; echo >&2
    exit 1
  fi
  printf '%s' "\$BODY" | jq '{id,name,instructions,model,created_at}'
else
  echo "[remote] agent '${AGENT_NAME}' already exists (id=\$AID)"
  printf '%s' "\$BODY" | jq --arg n '${AGENT_NAME}' '.data[] | select(.name==\$n) | {id,name,instructions,model,created_at}'
fi
REMOTE_EOF
)

REMOTE_B64=$(printf '%s' "$REMOTE" | base64 | tr -d '\n')
../scripts/jumpbox-run.sh "echo $REMOTE_B64 | base64 -d | bash"

echo
echo "PASS — 03_sn_connection_and_agent"
