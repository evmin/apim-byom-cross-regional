# `demo-scripts/` — Cross-region demo (Switzerland North → APIM SC → AOAI SC)

Crystal-clear, laconic. Each script does ONE thing, prints a banner, ends in
`PASS — <name>` or a one-line failure.

## Narrative

```
STAGE 1: Here is the model deployed in Sweden Central.
STAGE 2: Here is APIM in Sweden Central, fronting that model.
STAGE 3: Here is the Foundry connection `apim-byom` in Switzerland North
         pointing at APIM in Sweden Central — and the prompt agent
         configured to use it.
STAGE 4: Call the cross-region bridge — caller code references the Swiss
         project's `apim-byom` connection; the actual chat completion comes
         back via APIM in Sweden Central and the AOAI deployment behind it.
         Also: replay the agent's instructions through the same bridge to
         prove the agent's stored config produces real model output.
         Also (optional): show the agents-runtime attempt + its server-side
         failure (Microsoft platform issue, observed across all tried
         regions in this deploy).
```

## Prerequisites

- `azd env select fdev` — the demo reads values via `azd env get-values`.
- `az login` — the operator's account is needed only for the control-plane
  reads in stages 1–3 (deployments, APIM service, connection definition).
  All data-plane calls run on the jumpbox via its UAMI.
- The jumpbox UAMI must be (already is, per the 001 IaC) granted:
  - **Azure AI Developer** on the agent project (Stages 3, 4, 5, 6),
  - **Cognitive Services User** on the SC AOAI account (for the APIM bridge),
  - **oid in the APIM `validate-azure-ad-token` allowlist** (Stages 4, 5).
- Local SSH private key matching `JUMPBOX_SSH_PUBLIC_KEY` available at
  `~/.ssh/mreg-jumpbox` (default; override with `JUMPBOX_SSH_PRIVATE_KEY`).

## Run order

```bash
# happy path (~2-3 min cold; most time is Bastion tunnel setup ~30s per
# jumpbox-touching stage: 03, 04, 05)
bash demo-scripts/run-all.sh

# honest mode (adds Stage 6 — runtime attempt that fails server-side)
INCLUDE_RUNTIME_ATTEMPT=1 bash demo-scripts/run-all.sh

# individual stages (each is standalone; just `source ./00_env.sh` at top)
bash demo-scripts/01_sc_model.sh
bash demo-scripts/02_sc_apim.sh
bash demo-scripts/03_sn_connection_and_agent.sh
bash demo-scripts/04_call_sn_routes_to_sc.sh
bash demo-scripts/05_replay_agent.sh
INCLUDE_RUNTIME_ATTEMPT=1 bash demo-scripts/06_attempt_runtime.sh
```

## What each script proves

| Stage | Script                              | Proof |
|------:|-------------------------------------|-------|
| 1     | `01_sc_model.sh`                    | SC AOAI/Foundry account in `swedencentral`; `gpt-5.4-nano` deployment is live. Pure `az` from the Mac. |
| 2     | `02_sc_apim.sh`                     | APIM service in SC with `publicNetworkAccess=Disabled`; `openai` API present; service-level policy carries `validate-azure-ad-token` + backend rewrite. Pure `az` from the Mac. |
| 3     | `03_sn_connection_and_agent.sh`     | SN Foundry account live in `switzerlandnorth`; connection `apim-byom` (`type=ApiManagement`, `target=https://<apim-sc>.azure-api.net`); demo agent `demo-cross-region-agent` with `model: apim-byom/gpt-5.4-nano` (created on demand). Uses jumpbox for the SN data-plane `/assistants` call. |
| 4     | `04_call_sn_routes_to_sc.sh`        | The cross-region bridge actually works: a real OpenAI-shape chat completion comes back when the upstream call to APIM (SC) is issued. Step 1 honestly attempts the SN REST endpoint (404 — see drift note below); step 2 issues the bridged call. |
| 4'    | `05_replay_agent.sh`                | The agent's stored `instructions` pulled from the SN project produce a model reply that honours them (`What is 2+2?` → `4`) through the same bridge. |
| 4''   | `06_attempt_runtime.sh` (opt-in)    | The Foundry agents runtime `POST /threads/<id>/runs` reaches a terminal `failed` status with `last_error.code=server_error`. Failing IS the expected outcome (exit 0); the script is opt-in via `INCLUDE_RUNTIME_ATTEMPT=1`. |

## Drift note (Stage 4 / 5)

The plan originally specified that Stage 4 would `POST` directly to the SN
project's `/chat/completions?api-version=v1` endpoint with
`model: apim-byom/gpt-5.4-nano` and get a routed reply back. **Empirically
on this deploy** that REST surface returns `404 NotFound` for
connection-prefixed model names — the platform only resolves
`<connection>/<deployment>` model strings inside the **agents runtime**
(POST `/threads/<id>/runs`, which is broken; see Stage 6). The
project-level `/chat/completions` and `/openai/v1/chat/completions`
surfaces only see **local** deployments on the SN account.

So Stages 4 and 5 issue the bridged call directly to APIM (Sweden) — which
is exactly the request the agents runtime would make upstream after
resolving the `apim-byom` connection. The audience sees:

- The Swiss project endpoint where the connection + agent definition live
  (printed in banners), and
- The APIM (Sweden) URL where the real chat completion is served from.

Both are accurate; both are visible; nothing is hidden behind an SDK.

## Expected output

Captured from a live run against `fdev` (Switzerland North + Sweden Central).

### `01_sc_model.sh`

```
==== STAGE 1: model in Sweden Central ====
…
NAME                  LOCATION       KIND
mregfdevfdryscqx3thf  swedencentral  AIServices

Name          Model         Version     Sku             Capacity
------------  ------------  ----------  --------------  ----------
gpt-5.4-nano  gpt-5.4-nano  2026-03-17  GlobalStandard  50

PASS — 01_sc_model
```

### `02_sc_apim.sh`

```
==== STAGE 2: APIM in Sweden Central ====
…
NAME                      LOCATION        PUBNET    SKU
mreg-fdev-apim-sc-qx3thf  Sweden Central  Disabled  StandardV2

Name    Path    ServiceUrl
------  ------  ----------------------------------------------------
openai  openai  https://mregfdevfdryscqx3thf.openai.azure.com/openai

Name           Method    UrlTemplate
-------------  --------  -------------
catchall-get   GET       /*
catchall-post  POST      /*

--- inbound policy excerpt (first 30 lines, service-level) ---
<policies>
  <inbound>
    <validate-azure-ad-token tenant-id="…" header-name="Authorization" failed-validation-httpcode="401" …>
      <audiences>
        <audience>https://cognitiveservices.azure.com/</audience>
        <audience>https://ai.azure.com</audience>
      </audiences>
      <required-claims>
        <claim name="oid" match="any">
          <value>…agent project MI…</value>
          <value>…APIM MI…</value>
          <value>…jumpbox UAMI…</value>
        </claim>
      </required-claims>
    </validate-azure-ad-token>
    <set-backend-service base-url="https://…/openai" />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" … />
    <set-header name="Authorization" exists-action="override">
      <value>@("Bearer " + (string)context.Variables["msi-token"])</value>
    </set-header>
  </inbound>
  …
</policies>

PASS — 02_sc_apim
```

### `03_sn_connection_and_agent.sh`

```
==== STAGE 3: SN connection + agent ====
…
{
  "kind": "AIServices",
  "location": "switzerlandnorth",
  "name": "mregfdevfdrychnl33kar",
  "publicNetworkAccess": "Disabled"
}
{
  "name": "apim-byom",
  "category": "ApiManagement",
  "target": "https://mreg-fdev-apim-sc-qx3thf.azure-api.net",
  "isDefault": null,
  "authType": "AAD"
}
…
[remote] agent 'demo-cross-region-agent' not found — POST /assistants to create it
{
  "id": "asst_…",
  "name": "demo-cross-region-agent",
  "instructions": "You are a helpful assistant. Reply concisely.",
  "model": "apim-byom/gpt-5.4-nano",
  "created_at": …
}
PASS — 03_sn_connection_and_agent
```

### `04_call_sn_routes_to_sc.sh`

```
==== STAGE 4: cross-region bridge (SN project 'apim-byom' → APIM SC → AOAI SC) ====
…
[remote] [step 1] POST https://mregfdevfdrychnl33kar.services.ai.azure.com/api/projects/agent-project/chat/completions?api-version=v1
[remote] [step 1] HTTP=404
{"error":{"code":"NotFound","message":"Resource not found"}}

[remote] [step 2] POST https://mreg-fdev-apim-sc-qx3thf.azure-api.net/openai/deployments/gpt-5.4-nano/chat/completions?api-version=2024-10-21
[remote] [step 2] HTTP=200 elapsed_ms=~1500
[remote] response.id       = chatcmpl-…
[remote] response.content  = OK
[remote] response.usage    = {"completion_tokens":5,"prompt_tokens":8,"total_tokens":13,…}
[remote] wall-time         = ~1500 ms

PASS — 04_call_sn_routes_to_sc
```

### `05_replay_agent.sh`

```
==== STAGE 4 (replay): agent config end-to-end ====
…
[remote] pulled system prompt: You are a helpful assistant. Reply concisely.
[remote] user prompt        : What is 2+2? Reply with the number only.
[remote] POST https://mreg-fdev-apim-sc-qx3thf.azure-api.net/openai/deployments/gpt-5.4-nano/chat/completions?api-version=2024-10-21
[remote] reply: 4
[remote] OK — reply matches ^\s*4\b

PASS — 05_replay_agent
```

### `06_attempt_runtime.sh` (opt-in)

```
==== STAGE 4 (honest): runtime attempt — expected to fail server-side ====
…
[remote] thread id: thread_…
[remote] POST /threads/.../messages …
[remote] POST /threads/.../runs …
[remote] run id: run_…
[remote] poll #1 — status=failed
[remote] terminal status: failed
[remote] last_error:
{
  "code": "server_error",
  "message": "Sorry, something went wrong."
}
───────────────────────────────────────────────────────
The Foundry agents-runtime path (/threads/<id>/runs) is
server-side broken in this environment (observed across
all tried regions: NEU/WE/EUS2/FRC/CHN; no upstream APIM
traffic during failed runs). The working paths shown in
scripts 04 and 05 are unaffected.
───────────────────────────────────────────────────────
PASS — 06_attempt_runtime (failure is the expected outcome)
```

### `run-all.sh` summary

Captured end-to-end against `fdev` (happy path; tunnel cache warm):

```
======================================================================
=== summary                                                            ===
======================================================================

STAGE                                STATUS       WALL
------------------------------------ ------------ ----
01_sc_model.sh                       PASS         5s
02_sc_apim.sh                        PASS         8s
03_sn_connection_and_agent.sh        PASS         8s
04_call_sn_routes_to_sc.sh           PASS         5s
05_replay_agent.sh                   PASS         5s

ALL STAGES PASS
```

Overall wall-time: **31 s** (well under the 90 s target). With cold
Bastion tunnels expect roughly 30 s × the three jumpbox stages instead
of the single-digit per-stage numbers above.

With `INCLUDE_RUNTIME_ATTEMPT=1` the summary adds one row:

```
06_attempt_runtime.sh                PASS         10s
```

Stage 6 prints `status: failed` + `last_error.code: server_error` and
exits 0 — that is the documented, expected outcome of the runtime path
in this environment.

## When something fails

- **`01_sc_model.sh`** — most often `FAIL — 01_sc_model: account is in
  '<other>'` when the env was re-deployed against a different region pair.
  Confirm `azd env get-values | grep AZURE_LOCATION` and the model RG name.
- **`02_sc_apim.sh`** — `publicNetworkAccess` may flip to `Enabled` if
  `hooks/postprovision-finalize.sh` hasn't run. Re-run it.
- **`03_sn_connection_and_agent.sh`** — first failure mode is the SSH key
  not being found (`jumpbox-run: SSH private key not found at …`); next is
  Bastion tunnel timeout (re-run; the jumpbox cold-start can be slow). If
  the agent creation returns 4xx, inspect the response body — usually a
  missing scope on the UAMI (Azure AI Developer on the project).
- **`04_call_sn_routes_to_sc.sh`** — step 1's 404 is **expected and not a
  failure**. The failure mode is step 2 returning ≠ 200. Most common cause:
  the jumpbox UAMI's oid is not in the APIM allowlist (re-deploy with the
  current `JUMPBOX_UAMI_PRINCIPAL_ID` in `infra/main.bicep`); also possible
  that APIM was re-deployed and lost its private endpoint DNS link.
  Inspect with `scripts/jumpbox-run.sh "dig $APIM_GATEWAY_HOSTNAME"`.
- **`05_replay_agent.sh`** — `agent 'demo-cross-region-agent' not found`
  means Stage 3 hasn't been run. The model regex failure (`expected reply
  starts with '4'`) is essentially impossible on `gpt-5.4-nano` with this
  prompt; if it ever happens, capture the reply for the model team.
- **`06_attempt_runtime.sh`** — exit non-zero only if the script can't even
  reach a terminal `status` (network/auth glitch before the broken runtime
  kicks in). Re-run; if it persists, run `scripts/jumpbox-smoke.sh` from
  the 001 IaC to confirm Bastion, MI, and DNS are all healthy.

## See also

- `005_architecture.md` — full architecture diagrams (don't duplicate them
  here).
- `scripts/jumpbox/` — the deeper validation suite (DNS audit, posture
  audit, SDK-runtime smoke, direct-inference smoke). These run from inside
  the agent VNet and are wired into `azd up` via
  `hooks/postprovision-smoke.sh`.
