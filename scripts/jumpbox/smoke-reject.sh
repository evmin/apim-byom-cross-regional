#!/usr/bin/env bash
# =============================================================================
# scripts/jumpbox/smoke-reject.sh — APIM authz negative test.
# =============================================================================
# Proves the APIM `validate-azure-ad-token` policy is actually enforcing by
# issuing a chat-completion against APIM with a token whose AUDIENCE is NOT
# one of the two allowed audiences (cognitiveservices / ai.azure.com).
#
# Why wrong-audience and not "no header" or "wrong oid":
#   - "No header" only proves the policy fires when there's nothing to
#     evaluate — useful but a weaker signal than a positive audience-claim
#     check (some misconfigurations skip the policy altogether on missing
#     header and pass straight to the backend).
#   - "Wrong oid" would require minting a token from a *different* MI; the
#     jumpbox only has its own UAMI, which IS in the allowlist (it must be,
#     for `smoke-bridge.sh` to work). Wrong-audience is the meaningful
#     negative we can produce from a single MI.
#
# Expected outcome: HTTP 401 (or 403). Any 2xx is a SECURITY FAILURE because
# it would mean the policy is not validating the `aud` claim.
#
# Required env (set by /etc/profile.d/mreg-validate.sh):
#   APIM_GATEWAY_HOSTNAME  — e.g. mreg-fdev-apim-sc-xxxx.azure-api.net
#   MODEL_DEPLOYMENT_NAME  — e.g. gpt-5.4-nano
#   AZURE_CLIENT_ID        — jumpbox UAMI client ID
#
# Exit: 0 if APIM returned 401/403 (good); non-zero otherwise.
# =============================================================================

set -euo pipefail

: "${APIM_GATEWAY_HOSTNAME:?APIM_GATEWAY_HOSTNAME required}"
: "${MODEL_DEPLOYMENT_NAME:?MODEL_DEPLOYMENT_NAME required}"

# Audience that the policy will REJECT. Vault is a safe choice — every Azure
# tenant supports it, but the APIM policy's `<audiences>` list does NOT
# include it.
WRONG_AUDIENCE="https://vault.azure.net"

PY_BIN=/opt/mreg-validate/venv/bin/python
if [[ ! -x "${PY_BIN}" ]]; then
  PY_BIN=$(command -v python3)
fi

set +e
TOKEN=$(
  AZURE_CLIENT_ID="${AZURE_CLIENT_ID:-}" \
  WRONG_AUDIENCE="${WRONG_AUDIENCE}" \
  "${PY_BIN}" - <<'PY'
import os, sys
try:
    from azure.identity import ManagedIdentityCredential
except Exception as exc:
    print(f"ImportError: {exc}", file=sys.stderr)
    sys.exit(1)
cid = os.environ.get("AZURE_CLIENT_ID", "").strip() or None
aud = os.environ["WRONG_AUDIENCE"]
cred = ManagedIdentityCredential(client_id=cid) if cid else ManagedIdentityCredential()
try:
    print(cred.get_token(f"{aud}/.default").token)
except Exception as exc:
    print(f"token: {exc}", file=sys.stderr)
    sys.exit(1)
PY
)
TOK_RC=$?
set -e

if [[ "${TOK_RC}" -ne 0 || -z "${TOKEN}" ]]; then
  echo "smoke-reject: failed to acquire wrong-audience token (rc=${TOK_RC})" >&2
  exit 1
fi

PAYLOAD='{"messages":[{"role":"user","content":"ping"}],"max_completion_tokens":1}'
URL="https://${APIM_GATEWAY_HOSTNAME}/openai/deployments/${MODEL_DEPLOYMENT_NAME}/chat/completions?api-version=2024-10-21"

echo "smoke-reject: POST ${URL} with wrong-audience token (expecting 401/403)"
HTTP=$(curl -sS -o /tmp/smoke-reject.json -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -X POST "${URL}" -d "${PAYLOAD}" || echo "000")

echo "smoke-reject: HTTP=${HTTP}"
head -c 200 /tmp/smoke-reject.json 2>/dev/null || true
echo

case "${HTTP}" in
  401|403)
    echo "smoke-reject: PASS — APIM correctly rejected wrong-audience token"
    exit 0
    ;;
  2*)
    echo "smoke-reject: FAIL — APIM accepted a wrong-audience token (policy leak)" >&2
    exit 1
    ;;
  *)
    echo "smoke-reject: FAIL — unexpected HTTP ${HTTP} (network/DNS issue?)" >&2
    exit 1
    ;;
esac
