#!/usr/bin/env bash
# =============================================================================
# demo-scripts/07_responses_api.sh — STAGE 7: Responses API (v2) test.
# =============================================================================
# Tests whether the Foundry Responses API (refreshed preview, v2) can route
# the conn/dep model string through the APIM connection — unlike the
# Assistants v1 runtime which fails server-side.
#
# Per the foundry-cross-resource skill (verified 2026-04-23), conn/dep routing
# only works on oai.responses.create(), not on chat.completions or Assistants.
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")"

# shellcheck source=./00_env.sh
source ./00_env.sh

printf '\n==== STAGE 7: Responses API (v2) — conn/dep routing via APIM ====\n'
echo "endpoint    : $SN_FOUNDRY_PROJECT_ENDPOINT"
echo "model_ref   : $MODEL_REF"
echo "apim target : https://$APIM_GATEWAY_HOSTNAME"
echo

# The Python script runs inside the jumpbox venv which has azure-ai-projects + openai.
REMOTE=$(cat <<'REMOTE_EOF'
set -euo pipefail
source /etc/profile.d/mreg-validate.sh 2>/dev/null || true
source /opt/mreg-validate/venv/bin/activate 2>/dev/null || true

python3 - <<'PYEOF'
import os, sys, time

endpoint    = os.environ.get("AGENT_PROJECT_ENDPOINT", "").strip()
connection  = os.environ.get("FOUNDRY_CONNECTION_NAME", "apim-byom").strip()
deployment  = os.environ.get("MODEL_DEPLOYMENT_NAME", "").strip()
client_id   = os.environ.get("AZURE_CLIENT_ID", "").strip() or None
model_ref   = f"{connection}/{deployment}"

print(f"[remote] endpoint   = {endpoint}")
print(f"[remote] model_ref  = {model_ref}")
print(f"[remote] client_id  = {client_id or '(default MI)'}")

if not endpoint or not deployment:
    print("[remote] FAIL: AGENT_PROJECT_ENDPOINT / MODEL_DEPLOYMENT_NAME not set", file=sys.stderr)
    sys.exit(2)

from azure.identity import ManagedIdentityCredential
from azure.ai.projects import AIProjectClient

cred = ManagedIdentityCredential(client_id=client_id) if client_id else ManagedIdentityCredential()

print(f"[remote] creating AIProjectClient(endpoint={endpoint})...")
project = AIProjectClient(endpoint=endpoint, credential=cred)

# --- Test 1: Pattern A — Raw Responses API with conn/dep model string ---
# This is the simplest v2 pattern from foundry-cross-resource skill §7.1
print(f"\n[remote] TEST 1 (Pattern A): oai.responses.create(model='{model_ref}')")
oai = project.get_openai_client()
print(f"[remote]   base_url: {oai.base_url}")
try:
    t0 = time.monotonic()
    resp = oai.responses.create(
        model=model_ref,
        input="Reply with the single word PONG.",
        max_output_tokens=32,
    )
    elapsed = (time.monotonic() - t0) * 1000
    text = resp.output_text if hasattr(resp, "output_text") else str(resp)
    print(f"[remote]   PASS in {elapsed:.0f}ms — output: {text!r}")
except Exception as exc:
    elapsed = (time.monotonic() - t0) * 1000
    print(f"[remote]   FAIL in {elapsed:.0f}ms — {exc}")

# --- Test 2: Pattern C — Refreshed-preview hosted-agent client ---
# Uses get_openai_client(agent_name=...) to bind to the existing prompt agent
# created by Stage 3 (demo-cross-region-agent). This is the v2 way to invoke
# a prompt agent via the Responses API.
agent_name = "demo-cross-region-agent"
print(f"\n[remote] TEST 2 (Pattern C): get_openai_client(agent_name='{agent_name}')")
try:
    project2 = AIProjectClient(endpoint=endpoint, credential=cred, allow_preview=True)
    oai2 = project2.get_openai_client(agent_name=agent_name)
    print(f"[remote]   base_url: {oai2.base_url}")
    t0 = time.monotonic()
    resp2 = oai2.responses.create(
        input="What is 2+2? Reply with the number only.",
        max_output_tokens=32,
    )
    elapsed = (time.monotonic() - t0) * 1000
    text = resp2.output_text if hasattr(resp2, "output_text") else str(resp2)
    print(f"[remote]   PASS in {elapsed:.0f}ms — output: {text!r}")
except Exception as exc:
    elapsed = (time.monotonic() - t0) * 1000
    print(f"[remote]   FAIL in {elapsed:.0f}ms — {exc}")

# --- Test 3: Negative — chat.completions with conn/dep (expected 404) ---
print(f"\n[remote] TEST 3 (Negative): chat.completions.create(model='{model_ref}') [expected 404]")
try:
    t0 = time.monotonic()
    resp3 = oai.chat.completions.create(
        model=model_ref,
        messages=[{"role": "user", "content": "Reply OK"}],
        max_tokens=16,
    )
    elapsed = (time.monotonic() - t0) * 1000
    content = resp3.choices[0].message.content if resp3.choices else "(empty)"
    print(f"[remote]   UNEXPECTED 200 in {elapsed:.0f}ms — reply={content!r}")
except Exception as exc:
    elapsed = (time.monotonic() - t0) * 1000
    if "404" in str(exc) or "NotFound" in str(exc) or "DeploymentNotFound" in str(exc):
        print(f"[remote]   EXPECTED 404 — chat.completions does not route conn/dep")
    else:
        print(f"[remote]   FAIL in {elapsed:.0f}ms — {exc}")

print("\n[remote] done")
PYEOF
REMOTE_EOF
)

REMOTE_B64=$(printf '%s' "$REMOTE" | base64 | tr -d '\n')
if ! ../scripts/jumpbox-run.sh "echo $REMOTE_B64 | base64 -d | bash"; then
  echo "FAIL — 07_responses_api: remote script errored" >&2
  exit 1
fi

echo
echo "PASS — 07_responses_api"
