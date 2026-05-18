#!/usr/bin/env bash
# =============================================================================
# demo-scripts/05_replay_agent.sh — STAGE 4 (replay): agent config end-to-end.
# =============================================================================
# What this proves:
#   The agent's stored `instructions` are real and the model honours them.
#   We pull the system prompt from /assistants on the Swiss project (proves
#   the agent definition is genuine), then feed it back to the SC AOAI
#   deployment through the same APIM bridge with a deterministic user
#   prompt ("What is 2+2?"). The reply must start with `4`.
#
# Same drift caveat as Stage 4: the Swiss project's /chat/completions REST
# surface does not route connection-prefixed model names, so the bridged
# chat call goes upstream to APIM (Sweden) directly. The agent's instructions
# come from the Swiss project (Stage 3 created them via /assistants).
#
# Depends on demo-cross-region-agent existing (Stage 3 creates it on demand).
# Exit: 0 + `PASS — 05_replay_agent` on success.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./00_env.sh
source ./00_env.sh

AGENT_NAME="demo-cross-region-agent"
USER_PROMPT="What is 2+2? Reply with the number only."
APIM_URL="https://${APIM_GATEWAY_HOSTNAME}/openai/deployments/${MODEL_DEPLOYMENT_NAME}/chat/completions?api-version=2024-10-21"

printf '\n==== STAGE 4 (replay): agent config end-to-end ====\n'
echo "agent name        : $AGENT_NAME    (lives on $SN_FOUNDRY_ACCOUNT_NAME, CH)"
echo "user prompt       : $USER_PROMPT"
echo "bridged call to   : $APIM_URL"
echo "(pull .instructions from SN /assistants, then POST to APIM bridge"
echo " with system+user prompts; reply must start with '4')"
echo

REMOTE=$(cat <<REMOTE_EOF
set -euo pipefail

echo "[remote] acquiring AAD token (audience https://ai.azure.com) via IMDS..."
TOKEN=\$(curl -sS -H 'Metadata:true' \
  'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://ai.azure.com' \
  | jq -r .access_token)
if [[ -z "\$TOKEN" || "\$TOKEN" == "null" ]]; then
  echo "[remote] FAIL: IMDS token returned empty" >&2; exit 1
fi

echo "[remote] GET ${SN_FOUNDRY_PROJECT_ENDPOINT}/assistants?api-version=v1"
LIST=\$(curl -sS -w '\nHTTP %{http_code}\n' -H "Authorization: Bearer \$TOKEN" \
  '${SN_FOUNDRY_PROJECT_ENDPOINT}/assistants?api-version=v1')
HTTP=\$(printf '%s' "\$LIST" | awk '/^HTTP /{print \$2}')
BODY=\$(printf '%s' "\$LIST" | sed '/^HTTP /d')
if [[ "\$HTTP" != "200" ]]; then
  echo "[remote] FAIL: list /assistants returned HTTP \$HTTP" >&2
  printf '%s\n' "\$BODY" | head -c 400 >&2; echo >&2
  exit 1
fi

INSTR=\$(printf '%s' "\$BODY" | jq -r --arg n '${AGENT_NAME}' \
  '.data[]? | select(.name==\$n) | .instructions' | head -n1)
if [[ -z "\$INSTR" ]]; then
  echo "[remote] FAIL: agent '${AGENT_NAME}' not found — run 03_sn_connection_and_agent.sh first" >&2
  exit 1
fi
echo "[remote] pulled system prompt: \$INSTR"
echo "[remote] user prompt        : ${USER_PROMPT}"

REQ=\$(jq -nc --arg sys "\$INSTR" --arg usr '${USER_PROMPT}' \
  '{messages: [{role:"system", content:\$sys}, {role:"user", content:\$usr}], max_completion_tokens: 32}')

echo "[remote] POST ${APIM_URL}"
echo "[remote] body: \$REQ"
RESP=\$(curl -sS -w '\nHTTP %{http_code}\n' \
  -H "Authorization: Bearer \$TOKEN" -H 'Content-Type: application/json' \
  -X POST '${APIM_URL}' -d "\$REQ")
HTTP=\$(printf '%s' "\$RESP" | awk '/^HTTP /{print \$2}')
JSON=\$(printf '%s' "\$RESP" | sed '/^HTTP /d')

if [[ "\$HTTP" != "200" ]]; then
  echo "[remote] FAIL: /chat/completions returned HTTP \$HTTP" >&2
  printf '%s\n' "\$JSON" | head -c 600 >&2; echo >&2
  exit 1
fi

REPLY=\$(printf '%s' "\$JSON" | jq -r '.choices[0].message.content // empty')
echo "[remote] reply: \$REPLY"
if ! printf '%s' "\$REPLY" | grep -Eq '^[[:space:]]*4\b'; then
  echo "[remote] FAIL: model did not honour system prompt (expected reply starts with '4', got: '\$REPLY')" >&2
  exit 1
fi
echo "[remote] OK — reply matches ^\\\\s*4\\\\b"
REMOTE_EOF
)

REMOTE_B64=$(printf '%s' "$REMOTE" | base64 | tr -d '\n')
if ! ../scripts/jumpbox-run.sh "echo $REMOTE_B64 | base64 -d | bash"; then
  echo "FAIL — 05_replay_agent: remote call returned non-zero (see [remote] lines above)" >&2
  exit 1
fi

echo
echo "PASS — 05_replay_agent"
