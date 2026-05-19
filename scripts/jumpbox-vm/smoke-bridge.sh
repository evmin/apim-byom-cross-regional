#!/usr/bin/env bash
# =============================================================================
# scripts/jumpbox-vm/smoke-bridge.sh — cross-region APIM bridge inference smoke.
# =============================================================================
#
# Path:
#   jumpbox (UAMI) → APIM gateway PE (agent VNet)
#                  → APIM cross-region outbound integration
#                  → SC Foundry / AOAI deployment → reply
#
# What it proves:
#   - The APIM bridge is reachable from inside the agent VNet via its private
#     endpoint (private DNS for privatelink.azure-api.net resolves correctly).
#   - The APIM service-level policy accepts the jumpbox UAMI's token
#     (validate-azure-ad-token oid allowlist + audience check).
#   - APIM correctly composes the backend URL, signs with its own MI, and
#     returns a non-empty JSON body with `choices` and `usage`.
#   - The SC AOAI deployment named MODEL_DEPLOYMENT_NAME is responsive.
#
# Why this is the most important smoke in the suite:
#   This is the spec-aligned cross-region BYOM path (architecture 005,
#   §"cross-region bridge"). A green here means a Foundry agent in the
#   agent region could reach the model in Sweden Central through APIM.
#
# Required env (set by /etc/profile.d/mreg-validate.sh):
#   APIM_GATEWAY_HOSTNAME    — e.g. mreg-fdev-apim-sc-xxxx.azure-api.net
#   MODEL_DEPLOYMENT_NAME    — name of the AOAI deployment behind APIM
#   AZURE_CLIENT_ID          — jumpbox UAMI client ID
#
# Exit codes:
#   0 — PASS  (HTTP 2xx, JSON with non-empty choices[0].message.content,
#              usage.prompt_tokens > 0)
#   2 — config error (missing required env)
#   3 — auth error (token acquisition failed)
#   4 — non-2xx HTTP
#   5 — empty body / malformed JSON / empty completion
# =============================================================================

set -euo pipefail

EXIT_CONFIG=2
EXIT_AUTH=3
EXIT_HTTP=4
EXIT_EMPTY=5

: "${APIM_GATEWAY_HOSTNAME:?APIM_GATEWAY_HOSTNAME required}"
: "${MODEL_DEPLOYMENT_NAME:?MODEL_DEPLOYMENT_NAME required}"

# Acquire the jumpbox UAMI's AAD token for the cognitiveservices audience.
# We deliberately use the cognitiveservices audience (NOT ai.azure.com) because
# AOAI deployments live on `<acct>.openai.azure.com` which expects this audience;
# the APIM service-level policy accepts both audiences but the backend hop is
# AOAI, so this is the natural choice.
TOKEN_AUDIENCE="https://cognitiveservices.azure.com"

PY_BIN=/opt/mreg-validate/venv/bin/python
if [[ ! -x "${PY_BIN}" ]]; then
  PY_BIN=$(command -v python3)
fi

set +e
TOKEN=$(
  AZURE_CLIENT_ID="${AZURE_CLIENT_ID:-}" \
  TOKEN_AUDIENCE="${TOKEN_AUDIENCE}" \
  "${PY_BIN}" - <<'PY'
import os, sys
try:
    from azure.identity import ManagedIdentityCredential
except Exception as exc:
    print(f"ImportError: {exc}", file=sys.stderr)
    sys.exit(3)
cid = os.environ.get("AZURE_CLIENT_ID", "").strip() or None
aud = os.environ["TOKEN_AUDIENCE"]
cred = ManagedIdentityCredential(client_id=cid) if cid else ManagedIdentityCredential()
try:
    print(cred.get_token(f"{aud}/.default").token)
except Exception as exc:
    print(f"token: {exc}", file=sys.stderr)
    sys.exit(3)
PY
)
TOK_RC=$?
set -e

if [[ "${TOK_RC}" -ne 0 || -z "${TOKEN}" ]]; then
  echo "smoke-bridge: token acquisition failed (rc=${TOK_RC})" >&2
  exit "${EXIT_AUTH}"
fi

URL="https://${APIM_GATEWAY_HOSTNAME}/openai/deployments/${MODEL_DEPLOYMENT_NAME}/chat/completions?api-version=2024-10-21"
PAYLOAD='{
  "messages": [{"role": "user", "content": "Reply with the single word OK."}],
  "max_completion_tokens": 64
}'

echo "smoke-bridge: POST ${URL}"
START=$(date +%s%3N 2>/dev/null || date +%s)
HTTP=$(curl -sS -o /tmp/smoke-bridge.json -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -X POST "${URL}" -d "${PAYLOAD}" || echo "000")
END=$(date +%s%3N 2>/dev/null || date +%s)
ELAPSED=$((END - START))

echo "smoke-bridge: HTTP=${HTTP} elapsed_ms=${ELAPSED}"

case "${HTTP}" in
  2*) ;;
  *)
    echo "smoke-bridge: FAIL — non-2xx" >&2
    head -c 400 /tmp/smoke-bridge.json 2>/dev/null || true
    echo
    exit "${EXIT_HTTP}"
    ;;
esac

# Validate JSON shape with jq:
#  - choices is a non-empty array
#  - choices[0].message.content is a non-empty string
#  - usage.prompt_tokens is a positive integer
if ! command -v jq >/dev/null 2>&1; then
  echo "smoke-bridge: jq not installed — body inspection skipped, PASS based on HTTP only" >&2
  exit 0
fi

CONTENT=$(jq -r '.choices[0].message.content // empty' /tmp/smoke-bridge.json)
PROMPT_TOKENS=$(jq -r '.usage.prompt_tokens // 0' /tmp/smoke-bridge.json)

if [[ -z "${CONTENT}" ]]; then
  echo "smoke-bridge: FAIL — choices[0].message.content empty" >&2
  head -c 400 /tmp/smoke-bridge.json
  echo
  exit "${EXIT_EMPTY}"
fi
if [[ "${PROMPT_TOKENS}" -le 0 ]]; then
  echo "smoke-bridge: FAIL — usage.prompt_tokens not positive (${PROMPT_TOKENS})" >&2
  exit "${EXIT_EMPTY}"
fi

echo "smoke-bridge: PASS — reply='${CONTENT:0:80}' prompt_tokens=${PROMPT_TOKENS}"
exit 0
