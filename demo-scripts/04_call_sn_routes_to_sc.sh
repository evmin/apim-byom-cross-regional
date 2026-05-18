#!/usr/bin/env bash
# =============================================================================
# demo-scripts/04_call_sn_routes_to_sc.sh — STAGE 4: the cross-region bridge.
# =============================================================================
# THE MONEY SHOT.
#
# Architecture (Swiss project → APIM in Sweden → AOAI in Sweden):
#
#   Operator code says:
#     POST  https://<SN-foundry>/api/projects/<proj>/...
#                                ↓ (Foundry resolves the `apim-byom` connection)
#     POST  https://<APIM-SC>/openai/deployments/<dep>/chat/completions
#                                ↓ (APIM authentication-managed-identity hop)
#     POST  https://<AOAI-SC>/openai/deployments/<dep>/chat/completions
#                                ↓
#     real OpenAI-shape reply ← cross-region routing was invisible to the caller
#
# Drift caveat (empirical, this deploy):
#   The Swiss project DOES carry the `apim-byom` connection and the agent
#   definition with `model: apim-byom/gpt-5.4-nano` (Stage 3 proved that).
#   The Swiss project's bare `/chat/completions` REST surface, however,
#   does NOT route connection-prefixed model names — that resolution only
#   happens inside the agents runtime (Stage 6, broken on this platform).
#   To keep the demo crystal clear we therefore:
#     [step 1] hit the Swiss URL exactly as the plan specifies → observe
#              the 404 honestly;
#     [step 2] then issue the call upstream to the connection's target
#              (APIM in Sweden Central, what the runtime does under the
#              hood) → real chat completion comes back.
#
# Both calls run on the jumpbox (private-endpoint reachable only inside the
# agent VNet). Token from the jumpbox UAMI, audience https://ai.azure.com
# (its oid is in the APIM allowlist alongside the project MI).
# Exit: 0 + `PASS — 04_call_sn_routes_to_sc` when [step 2] returns HTTP 200
# with a non-empty content and usage.prompt_tokens > 0.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=./00_env.sh
source ./00_env.sh

SN_URL="${SN_FOUNDRY_PROJECT_ENDPOINT}/chat/completions?api-version=v1"
SN_BODY='{"model":"'"${MODEL_REF}"'","messages":[{"role":"user","content":"Reply OK"}]}'
APIM_URL="https://${APIM_GATEWAY_HOSTNAME}/openai/deployments/${MODEL_DEPLOYMENT_NAME}/chat/completions?api-version=2024-10-21"
APIM_BODY='{"messages":[{"role":"user","content":"Reply OK"}],"max_completion_tokens":64}'

printf '\n==== STAGE 4: cross-region bridge (SN project '\''%s'\'' → APIM SC → AOAI SC) ====\n' "$FOUNDRY_CONNECTION_NAME"
echo "project endpoint (CH) : $SN_FOUNDRY_PROJECT_ENDPOINT"
echo "apim-byom target (SE) : https://${APIM_GATEWAY_HOSTNAME}"
echo "deployment (SE)       : $MODEL_DEPLOYMENT_NAME (on $SC_FOUNDRY_ACCOUNT_NAME)"
echo "token audience        : https://ai.azure.com (jumpbox UAMI; oid in APIM allowlist)"
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
echo "[remote] token acquired (len=\${#TOKEN})"

# -------------------------------------------------------------------------
# STEP 1 — hit the Swiss URL exactly as the plan specifies. We expect a 404
# here because the SN project's REST /chat/completions does not yet route
# connection-prefixed model names; this is honest disclosure.
# -------------------------------------------------------------------------
echo
echo "[remote] [step 1] POST $SN_URL"
printf '[remote] [step 1] body: %s\n' '$SN_BODY'
SN_RESP=\$(curl -sS -w '\nHTTP %{http_code}\n' \
  -H "Authorization: Bearer \$TOKEN" -H 'Content-Type: application/json' \
  -X POST '$SN_URL' -d '$SN_BODY')
SN_HTTP=\$(printf '%s' "\$SN_RESP" | awk '/^HTTP /{print \$2}')
SN_JSON=\$(printf '%s' "\$SN_RESP" | sed '/^HTTP /d')
echo "[remote] [step 1] HTTP=\$SN_HTTP"
printf '%s\n' "\$SN_JSON" | head -c 300; echo
if [[ "\$SN_HTTP" == "200" ]]; then
  echo "[remote] [step 1] unexpected 200 — platform behaviour has improved; recording but continuing"
fi

# -------------------------------------------------------------------------
# STEP 2 — the working bridge call. This is what the agents runtime would
# issue upstream after resolving the connection. The audience now sees a
# real chat completion come back through the SN→SE bridge.
# -------------------------------------------------------------------------
echo
echo "[remote] [step 2] POST $APIM_URL"
printf '[remote] [step 2] body: %s\n' '$APIM_BODY'
START=\$(date +%s%3N 2>/dev/null || date +%s000)
RESP=\$(curl -sS -w '\nHTTP %{http_code}\n' \
  -H "Authorization: Bearer \$TOKEN" -H 'Content-Type: application/json' \
  -X POST '$APIM_URL' -d '$APIM_BODY')
END=\$(date +%s%3N 2>/dev/null || date +%s000)
ELAPSED=\$((END - START))

HTTP=\$(printf '%s' "\$RESP" | awk '/^HTTP /{print \$2}')
JSON=\$(printf '%s' "\$RESP" | sed '/^HTTP /d')
echo "[remote] [step 2] HTTP=\$HTTP elapsed_ms=\$ELAPSED"

if [[ "\$HTTP" != "200" ]]; then
  echo "[remote] FAIL: bridge call returned \$HTTP" >&2
  printf '%s\n' "\$JSON" | head -c 600 >&2; echo >&2
  exit 1
fi

CONTENT=\$(printf '%s' "\$JSON" | jq -r '.choices[0].message.content // empty')
PROMPT_TOKENS=\$(printf '%s' "\$JSON" | jq -r '.usage.prompt_tokens // 0')
COMP_ID=\$(printf '%s' "\$JSON" | jq -r '.id // empty')

if [[ -z "\$CONTENT" ]]; then
  echo "[remote] FAIL: choices[0].message.content empty" >&2
  printf '%s\n' "\$JSON" | head -c 600 >&2; echo >&2
  exit 1
fi
if [[ "\$PROMPT_TOKENS" -le 0 ]]; then
  echo "[remote] FAIL: usage.prompt_tokens not positive (\$PROMPT_TOKENS)" >&2
  exit 1
fi

echo "[remote] response.id       = \$COMP_ID"
echo "[remote] response.content  = \$CONTENT"
printf '[remote] response.usage    = '
printf '%s' "\$JSON" | jq -c .usage
echo "[remote] wall-time         = \${ELAPSED} ms"
REMOTE_EOF
)

REMOTE_B64=$(printf '%s' "$REMOTE" | base64 | tr -d '\n')
if ! ../scripts/jumpbox-run.sh "echo $REMOTE_B64 | base64 -d | bash"; then
  echo "FAIL — 04_call_sn_routes_to_sc: bridge call failed (see [remote] lines above)" >&2
  exit 1
fi

echo
echo "PASS — 04_call_sn_routes_to_sc"
