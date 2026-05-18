---
description: "Tasks — demo-scripts/: crystal-clear cross-region demo suite"
---

# Tasks: `demo-scripts/` — Crystal-clear cross-region demo (Switzerland North → APIM SC → AOAI SC)

**Feature directory**: `specs/002-demo-scripts/`

**Canonical plan**: `~/.copilot/session-state/<session-uuid>/plan.md` — top section `## ⏭️ Next: \`demo-scripts/\` — Crystal-clear cross-region demo`. The plan was authored in-session and is the source of truth for this feature; this `tasks.md` is its executable projection. `plan.md` and `spec.md` are intentionally NOT duplicated under `specs/002-demo-scripts/` — re-run `/speckit.plan` / `/speckit.specify` against this directory only if the team needs a disk-resident copy.

**Tests**: NOT requested. The demo scripts themselves are the validation (each script asserts PASS/FAIL via exit code). No separate test phase.

**Predecessor**: `specs/001-private-foundry-iac/` is DONE and deployed (azd env `fdev`, region pair `switzerlandnorth+swedencentral`). This feature is purely additive on top of that live deploy. **No edits** to existing `infra/`, `hooks/`, or `scripts/` files — `demo-scripts/` is a new top-level folder at the repo root.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1…US6)
- Each task lists exact file paths.

## Live environment values (from `azd env get-values --environment fdev`)

These are the values `00_env.sh` must export. Hard-coded fallbacks listed here for reference, but every script MUST resolve them via `azd env get-values` at runtime — no string literals in the body of any script.

| Variable | Value |
|---|---|
| `AGENT_RG` | `mreg-fdev-agent-chn-rg` |
| `MODEL_RG` | `mreg-fdev-model-sc-rg` |
| `SN_FOUNDRY_PROJECT_ENDPOINT` | `https://mregfdevfdrychnl33kar.services.ai.azure.com/api/projects/agent-project` |
| `APIM_GATEWAY_HOSTNAME` | `mreg-fdev-apim-sc-qx3thf.azure-api.net` |
| `FOUNDRY_CONNECTION_NAME` | `apim-byom` |
| `MODEL_DEPLOYMENT_NAME` | `gpt-5.4-nano` |
| `JUMPBOX_VM_NAME` | `mreg-fdev-jb-chn` |
| `JUMPBOX_BASTION_NAME` | `mreg-fdev-bastion-chn` |

## Token audiences (reference)

- **Foundry v1** (`*.services.ai.azure.com`, the SN endpoint) → audience `https://ai.azure.com`.
- **APIM** (`*.azure-api.net`) → audience `https://cognitiveservices.azure.com/` (also accepts `https://ai.azure.com`).

## Helper reuse

- `scripts/jumpbox-run.sh "<remote-command>"` — opens `az network bastion tunnel` + ssh, runs the given command on the jumpbox UAMI, tears the tunnel down. ~30 s tunnel-setup overhead per invocation. Use for **any** call against `*.services.ai.azure.com` or `*.azure-api.net` (private-endpoint reachable only from inside the VNet).
- Pure `az` cli commands (control plane: resource listings, deployments, policy XML, connection definitions) run **directly from the Mac** — no jumpbox needed.

---

## Phase 1: Setup

**Purpose**: Project skeleton.

- [X] T001 Create the `demo-scripts/` directory at repo root with `chmod 0755`; add a `.gitkeep` only if no other files are committed in the same change. No edits to `infra/`, `hooks/`, or `scripts/`.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Env-resolution helper that every stage script sources. Must exist before any US task can be implemented.

**⚠️ CRITICAL**: No user-story script can be authored until T002 lands, since each one will `source ./00_env.sh` at the top.

- [X] T002 Implement `demo-scripts/00_env.sh` — bash, `set -euo pipefail`. Runs `azd env get-values --environment fdev` once, parses out and `export`s the 8 variables listed in the live-values table above (`AGENT_RG`, `MODEL_RG`, `SN_FOUNDRY_PROJECT_ENDPOINT`, `APIM_GATEWAY_HOSTNAME`, `FOUNDRY_CONNECTION_NAME`, `MODEL_DEPLOYMENT_NAME`, `JUMPBOX_VM_NAME`, `JUMPBOX_BASTION_NAME`) plus derived `SN_FOUNDRY_ACCOUNT_NAME` (host-part of `SN_FOUNDRY_PROJECT_ENDPOINT`) and `SN_FOUNDRY_PROJECT_NAME` (`agent-project`). If any required value is empty or `azd env get-values` itself fails, print a single-line error `ERROR 00_env: <VAR_NAME> missing — run \`azd env select fdev\` first` and exit 1. Designed to be `source`d, not executed; safe to source multiple times.

**Checkpoint**: Foundation ready. User-story script tasks T003–T008 can now proceed in parallel.

---

## Phase 3: User Story 1 — Stage 1 evidence: Sweden Central model deployment (Priority: P1) 🎯 MVP

**Goal**: On stage, the operator runs one command and the audience sees the live Sweden Central Foundry / AOAI account and the `gpt-5.4-nano` deployment that lives on it. Proves the model side of the demo.

**Independent Test**: `cd demo-scripts && ./01_sc_model.sh` exits 0; stdout contains a banner naming the SC AOAI account, the resource group `mreg-fdev-model-sc-rg`, location `swedencentral`, and a table row for the `gpt-5.4-nano` deployment with its model name + capacity; final line is `PASS — 01_sc_model`.

### Implementation for User Story 1

- [X] T003 [P] [US1] Implement `demo-scripts/01_sc_model.sh` — bash, `set -euo pipefail`. Sources `./00_env.sh`. Prints the banner `=== STAGE 1: model in Sweden Central ===`. Runs `az cognitiveservices account list -g "$MODEL_RG" --query "[].{name:name,location:location,kind:kind}" -o table` and `az cognitiveservices account deployment list -g "$MODEL_RG" -n <sc-account-name> -o table` (resolve `<sc-account-name>` from the first `az` query — assert exactly one account is returned and abort with a clear error otherwise). Exit 0 on success and print `PASS — 01_sc_model`; on any `az` non-zero exit, print `FAIL — 01_sc_model: <reason>` and exit 1. **No** `scripts/jumpbox-run.sh` calls — all reads are control-plane.

**Checkpoint**: US1 is independently demoable. The Mac can show the SC model live on stage.

---

## Phase 4: User Story 2 — Stage 2 evidence: APIM in Sweden Central fronting the model (Priority: P1)

**Goal**: Operator shows the APIM service in SC, proves `publicNetworkAccess=Disabled`, and prints the `openai` API + the policy excerpt (validate-azure-ad-token + backend rewrite) so the audience sees the bridge.

**Independent Test**: `cd demo-scripts && ./02_sc_apim.sh` exits 0; stdout contains a banner, the APIM service name `mreg-fdev-apim-sc-qx3thf`, `location=swedencentral`, `publicNetworkAccess=Disabled`, a list of operations under the `openai` API, and the first ~30 lines of the inbound policy XML; final line is `PASS — 02_sc_apim`.

### Implementation for User Story 2

- [X] T004 [P] [US2] Implement `demo-scripts/02_sc_apim.sh` — bash, `set -euo pipefail`. Sources `./00_env.sh`. Prints the banner `=== STAGE 2: APIM in Sweden Central ===`. Runs:
  1. `az apim list -g "$MODEL_RG" --query "[].{name:name,location:location,publicNetworkAccess:publicNetworkAccess}" -o table` (one row expected; assert `publicNetworkAccess=Disabled`).
  2. `az apim api list -g "$MODEL_RG" -n <apim-name> --query "[?contains(name,'openai')].{name:name,path:path,serviceUrl:serviceUrl}" -o table`.
  3. `az apim api operation list -g "$MODEL_RG" -n <apim-name> --api-id openai -o table`.
  4. `az apim api policy show -g "$MODEL_RG" -n <apim-name> --api-id openai --query value -o tsv | head -n 30`.
  Resolve `<apim-name>` from step 1. Final `PASS — 02_sc_apim` on clean exit; `FAIL — 02_sc_apim: <reason>` + exit 1 on any failure. **No** `scripts/jumpbox-run.sh` calls — APIM management-plane reads work from the Mac.

**Checkpoint**: US2 independently demoable.

---

## Phase 5: User Story 3 — Stage 3 evidence: SN Foundry connection + demo agent (Priority: P1)

**Goal**: Operator shows the Switzerland North Foundry account, the `apim-byom` connection definition pointing at APIM in SC, and the demo prompt agent (`demo-cross-region-agent`) configured with `model: apim-byom/gpt-5.4-nano`. Creates the agent on the fly if missing.

**Independent Test**: `cd demo-scripts && ./03_sn_connection_and_agent.sh` exits 0; stdout contains a banner, the SN Foundry account name + `location=switzerlandnorth`, the `apim-byom` connection JSON with `target` set to the APIM gateway hostname, and the demo agent JSON with `id`, `instructions: "You are a helpful assistant. Reply concisely."`, and `model: apim-byom/gpt-5.4-nano`; final line is `PASS — 03_sn_connection_and_agent`.

### Implementation for User Story 3

- [X] T005 [P] [US3] Implement `demo-scripts/03_sn_connection_and_agent.sh` — bash, `set -euo pipefail`. Sources `./00_env.sh`. Prints the banner `=== STAGE 3: SN connection + agent ===`. Three calls:
  1. `az cognitiveservices account show -g "$AGENT_RG" -n "$SN_FOUNDRY_ACCOUNT_NAME" --query "{name:name,location:location,kind:kind}" -o json` (Mac, control plane).
  2. `az cognitiveservices account connection show -g "$AGENT_RG" -n "$SN_FOUNDRY_ACCOUNT_NAME" --connection-name "$FOUNDRY_CONNECTION_NAME" -o json` (Mac, control plane) — assert `properties.target` contains `$APIM_GATEWAY_HOSTNAME`.
  3. List/create the demo agent via the project's **data-plane** REST `/assistants` API. Since the SN Foundry project endpoint is on a private endpoint, this REST call MUST run through `scripts/jumpbox-run.sh`. Pattern:
     - Build a single remote bash snippet that: (a) `TOKEN=$(curl -s -H Metadata:true 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://ai.azure.com' | jq -r .access_token)`; (b) `GET ${SN_FOUNDRY_PROJECT_ENDPOINT}/assistants?api-version=v1` with `Authorization: Bearer $TOKEN`, filter for `name==demo-cross-region-agent`; (c) if missing, `POST ${SN_FOUNDRY_PROJECT_ENDPOINT}/assistants?api-version=v1` with body `{"name":"demo-cross-region-agent","instructions":"You are a helpful assistant. Reply concisely.","model":"apim-byom/gpt-5.4-nano"}`; (d) echo the final agent JSON.
     - Base64-encode that snippet locally, invoke `scripts/jumpbox-run.sh "echo <b64> | base64 -d | bash"` so cloud-init and the on-VM filesystem are not modified.
  Final `PASS — 03_sn_connection_and_agent` or `FAIL — 03_sn_connection_and_agent: <reason>` + exit 1.

**Checkpoint**: US3 independently demoable. The agent exists and is wired to `apim-byom`.

---

## Phase 6: User Story 4 — Stage 4 (the money shot): Cross-region call via SN endpoint (Priority: P1)

**Goal**: Audience sees a `curl POST` to a **Swiss** URL get a real OpenAI-shape chat completion back. Routing (SN Foundry → connection `apim-byom` → APIM in SC → AOAI in SC) is invisible to the caller. This is THE demo.

**Independent Test**: `cd demo-scripts && ./04_call_sn_routes_to_sc.sh` returns HTTP 200; stdout contains the exact URL hit (a `*.switzerlandnorth.*` host under `services.ai.azure.com`), the request body (model `apim-byom/gpt-5.4-nano`), the response `choices[0].message.content` (non-empty), `usage.prompt_tokens > 0`, and total wall-time; final line is `PASS — 04_call_sn_routes_to_sc`.

### Implementation for User Story 4

- [X] T006 [P] [US4] Implement `demo-scripts/04_call_sn_routes_to_sc.sh` — bash, `set -euo pipefail`. Sources `./00_env.sh`. Prints banner `=== STAGE 4: call SN, routed to SC, invisibly ===`. Builds a remote snippet that, on the jumpbox:
  1. Acquires a Bearer token via IMDS for resource `https://ai.azure.com`.
  2. Times and runs `curl -sS -w '\nHTTP %{http_code}\n' -X POST "$SN_FOUNDRY_PROJECT_ENDPOINT/chat/completions?api-version=v1" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"model":"apim-byom/gpt-5.4-nano","messages":[{"role":"user","content":"Reply OK"}]}'`.
  3. Pipes the JSON body through `jq` to extract `.choices[0].message.content`, `.usage`, and the `id` of the completion.
  Invoke via `scripts/jumpbox-run.sh "echo <b64> | base64 -d | bash"`. Assert HTTP 200, non-empty `content`, `usage.prompt_tokens > 0`. Print the URL, body, response excerpt, wall-time, and `PASS — 04_call_sn_routes_to_sc`. On any assertion failure, print `FAIL — 04_call_sn_routes_to_sc: <reason>` and exit 1.

**Checkpoint**: US4 independently demoable. This is the slide you actually want to land on.

---

## Phase 7: User Story 5 — Stage 4 (deeper evidence): Agent replay via chat/completions (Priority: P2)

**Goal**: Pull the demo agent's stored `instructions` back from the SN project, then call `/chat/completions` with those instructions as the system prompt and a deterministic user prompt. Proves the agent's exact configuration produces real model output through the full cross-region chain (without going through the broken `/runs` runtime).

**Independent Test**: `cd demo-scripts && ./05_replay_agent.sh` exits 0; stdout contains the system prompt that was pulled (`"You are a helpful assistant. Reply concisely."`), the user prompt (`"What is 2+2? Reply with the number only."`), the model reply (a single-token-ish string matching `^\s*4\b`), `PASS — 05_replay_agent`.

### Implementation for User Story 5

- [X] T007 [P] [US5] Implement `demo-scripts/05_replay_agent.sh` — bash, `set -euo pipefail`. Sources `./00_env.sh`. Banner `=== STAGE 4 (replay): agent's own config end-to-end ===`. Remote snippet for `scripts/jumpbox-run.sh`:
  1. Token via IMDS for `https://ai.azure.com`.
  2. `GET ${SN_FOUNDRY_PROJECT_ENDPOINT}/assistants?api-version=v1` → filter for `name==demo-cross-region-agent` → extract `.instructions`. Abort with `FAIL — 05_replay_agent: agent not found, run 03 first` if missing.
  3. `POST ${SN_FOUNDRY_PROJECT_ENDPOINT}/chat/completions?api-version=v1` with body `{"model":"apim-byom/gpt-5.4-nano","messages":[{"role":"system","content":"<pulled instructions>"},{"role":"user","content":"What is 2+2? Reply with the number only."}]}`.
  4. Extract `.choices[0].message.content`, assert it matches `^\s*4\b` (regex via `grep -Eq`). Print system prompt, user prompt, raw reply, and `PASS — 05_replay_agent`. On regex miss: `FAIL — 05_replay_agent: model did not honor system prompt (got: <reply>)` + exit 1.

**Checkpoint**: US5 independently demoable. Note: depends on US3 having run at least once (agent must exist); script self-detects and gives a clean error message pointing the operator to `03_sn_connection_and_agent.sh`.

---

## Phase 8: User Story 6 — Stage 4 (honest mode): Foundry agents-runtime failure demo (Priority: P3, opt-in)

**Goal**: Show the broken `/threads/<id>/runs` path on demand, framed as a Microsoft-side platform issue. Empirically observed across NEU/WE/EUS2/FRC/CHN in this deploy, no upstream APIM traffic on failed runs. Off by default; opt-in via `INCLUDE_RUNTIME_ATTEMPT=1`.

**Independent Test**: `cd demo-scripts && INCLUDE_RUNTIME_ATTEMPT=1 ./06_attempt_runtime.sh` exits 0; stdout contains the thread creation response, message creation response, run dispatch response, polled status transitions ending in `failed`, the full `last_error` payload with `code: "server_error"`, a clear footer banner explaining "this is the broken piece — Microsoft-side runtime; observed across all tried regions in this deploy", and `PASS — 06_attempt_runtime (failure is the expected outcome)`. If `INCLUDE_RUNTIME_ATTEMPT` is unset/non-`1`, the script prints `SKIP — 06_attempt_runtime (set INCLUDE_RUNTIME_ATTEMPT=1 to opt in)` and exits 0.

### Implementation for User Story 6

- [X] T008 [P] [US6] Implement `demo-scripts/06_attempt_runtime.sh` — bash, `set -euo pipefail`. Sources `./00_env.sh`. Honors `INCLUDE_RUNTIME_ATTEMPT` gate; SKIPs with exit 0 if unset. When opted in, banner `=== STAGE 4 (honest): runtime attempt — expected to fail server-side ===`. Remote snippet for `scripts/jumpbox-run.sh`:
  1. Token via IMDS for `https://ai.azure.com`.
  2. Resolve `demo-cross-region-agent` `id` from `/assistants`.
  3. `POST /threads?api-version=v1` → capture `thread_id`.
  4. `POST /threads/<thread_id>/messages` with `{"role":"user","content":"Reply OK"}`.
  5. `POST /threads/<thread_id>/runs` with `{"assistant_id":"<agent-id>"}` → capture `run_id`.
  6. Poll `GET /threads/<thread_id>/runs/<run_id>` every 2 s, up to 30 s, until `status` ∈ {`completed`, `failed`, `cancelled`, `expired`}.
  7. Print every API response in pretty-printed JSON as it arrives. Print final `status`, full `last_error` JSON. Footer:
     ```
     ───────────────────────────────────────────────────────
     The Foundry agents-runtime path (/threads/<id>/runs) is
     server-side broken in this environment (observed across
     all tried regions: NEU/WE/EUS2/FRC/CHN, no upstream APIM
     traffic during failed runs). The working paths shown in
     scripts 04 and 05 are unaffected.
     ───────────────────────────────────────────────────────
     ```
  Final line: `PASS — 06_attempt_runtime (failure is the expected outcome)`. Exit 0 even when the run failed — failing IS the expected outcome of this script. Only exit 1 if the script itself encounters a network/auth error before reaching a terminal `status` (i.e. couldn't even demonstrate the failure).

**Checkpoint**: US6 independently demoable. Optional; the demo is complete without it.

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Operator-facing entry point + docs + final live-environment validation.

- [X] T009 [P] Write `demo-scripts/README.md` — laconic. Sections, in order: **Narrative** (the 4-stage story verbatim from the plan); **Prerequisites** (`azd env select fdev`, `az login`, jumpbox UAMI must be granted Cognitive Services User on agent project — already done by 001 IaC, just cite); **Run order** (`./run-all.sh` for happy path; `INCLUDE_RUNTIME_ATTEMPT=1 ./run-all.sh` for honest mode); **What each script proves** (table from plan, mapping stage → script → proof); **Expected output** (placeholder section that T011 fills in with captured excerpts); **When something fails** (one paragraph per script with the most likely failure mode + which `az` / smoke script to consult in `scripts/`). No clever abstractions, no architecture diagrams (`005_architecture.md` already has those).

- [X] T010 Implement `demo-scripts/run-all.sh` — bash, `set -euo pipefail`. Sources `./00_env.sh` once at top. Runs `01_sc_model.sh`, `02_sc_apim.sh`, `03_sn_connection_and_agent.sh`, `04_call_sn_routes_to_sc.sh`, `05_replay_agent.sh` in order. Between each, prints a bold ASCII banner (`printf '\n\033[1m=== %s ===\033[0m\n\n'`). After 05, gated on `INCLUDE_RUNTIME_ATTEMPT=1`, runs `06_attempt_runtime.sh`. Final summary table: one row per script, `PASS` / `FAIL` / `SKIP` with wall-time. Overall exit code = `max` of child exits. Wall-time target ≤ 90 s on healthy deploy (cold cache + 5 jumpbox tunnels ≈ 60-90 s, mostly tunnel setup). Depends on T003–T008.

- [X] T011 End-to-end validation pass: against the live azd env `fdev`, run `./demo-scripts/run-all.sh` from the Mac. Capture stdout. Verify: (a) overall exit 0; (b) every script prints its own `PASS` line; (c) T006 (`04_call_sn_routes_to_sc.sh`) returns a non-empty `choices[0].message.content`; (d) T007 (`05_replay_agent.sh`) returns a `4`-ish reply matching `^\s*4\b`; (e) re-run with `INCLUDE_RUNTIME_ATTEMPT=1` and confirm T008 prints `status: failed` + `last_error.code: server_error` then `PASS — 06_attempt_runtime`. Paste a redacted excerpt (≤ 30 lines per script) into `demo-scripts/README.md` under the `Expected output` section. Depends on T009 + T010.

---

## Dependencies & Execution Order

### Phase dependencies

- **Phase 1 (Setup)**: no deps.
- **Phase 2 (Foundational)**: depends on Phase 1. **Blocks all US phases.**
- **Phases 3–8 (US1–US6)**: each depends on Phase 2. Independent of each other in terms of code (different files, different scripts). US5 has a **runtime** dependency on US3 (agent must exist) — but the US5 script detects and emits a clean error pointing to US3, so they remain independently testable.
- **Phase 9 (Polish)**: T009 (README) can be drafted in parallel with US phases. T010 (run-all) requires T003–T007 to exist (sources them). T011 requires T009 + T010.

### Task-level dependency graph

```
T001 ── T002 ──┬── T003 (US1)
                ├── T004 (US2)         ┐
                ├── T005 (US3) ─────┐  │
                ├── T006 (US4)      │  ├── T010 (run-all) ── T011 (validate)
                ├── T007 (US5) ←────┘  │                          ↑
                └── T008 (US6) ────────┘                          │
                                                                  │
                T009 (README) ───────────────────────────────────┘
```

- US5 ← US3 is a **runtime** dep only (agent existence at execution time). The script implementations can be authored in any order; T007 must not import or include code from T005, only call the live API.

### Parallel opportunities

- **T003, T004, T005, T006, T007, T008 are all [P]** — different files, no code-level deps. A single developer can stage all six in one editor session; multiple developers can parallelize trivially.
- **T009 (README) is [P]** — different file from every other task; can be drafted concurrently with any US task.
- **T010 (run-all)** and **T011 (validate)** are NOT parallel: T010 sources the per-stage scripts; T011 needs T010 + README skeleton.

### Parallel example

```bash
# Once T002 is in, six developers (or one developer in six tmux panes) can each take one US script:
Task: "Implement demo-scripts/01_sc_model.sh"             # T003 [US1]
Task: "Implement demo-scripts/02_sc_apim.sh"              # T004 [US2]
Task: "Implement demo-scripts/03_sn_connection_and_agent.sh"  # T005 [US3]
Task: "Implement demo-scripts/04_call_sn_routes_to_sc.sh" # T006 [US4]
Task: "Implement demo-scripts/05_replay_agent.sh"         # T007 [US5]
Task: "Implement demo-scripts/06_attempt_runtime.sh"      # T008 [US6]
Task: "Write demo-scripts/README.md skeleton"             # T009
```

---

## Implementation Strategy

### MVP first (US1–US4 only)

1. T001 (folder) → T002 (`00_env.sh`) → T003+T004+T005+T006 in parallel → T010 (`run-all.sh` calling 01–04).
2. **STOP** and run `./demo-scripts/run-all.sh` against `fdev`. If all four print `PASS` and stage 4 returns a real chat completion from a Swiss URL, **you have a demo**. Ship it.

### Incremental delivery

- **Slice 1**: T001 → T002 → T003 (US1). Operator can show the SC model live.
- **Slice 2**: + T004 (US2). Operator can show APIM in front.
- **Slice 3**: + T005 (US3). Operator can show the SN connection + agent.
- **Slice 4**: + T006 (US4). Money shot lands. **This is the minimum viable demo.**
- **Slice 5**: + T007 (US5). Deeper evidence of agent-config end-to-end.
- **Slice 6**: + T008 (US6), gated. Honesty footnote available on demand.
- **Slice 7**: + T009, T010, T011. One-shot `run-all.sh` + README + captured-output proof.

### Anti-goals (do NOT do)

- **Do not edit** any file under `infra/`, `hooks/`, or `scripts/`. The `scripts/jumpbox-run.sh` helper is consumed as-is.
- **Do not create** new Bicep modules, role assignments, model deployments, or identities.
- **Do not** add clever abstractions across scripts (shared logging library, retry wrappers, etc.). Each script does ONE thing with a banner and a `PASS` / `FAIL` line.
- **Do not** try to fix the Foundry agents-runtime path. T008 demonstrates the failure; it does not paper over it.
- **Do not** write `tasks.md` consumers (test suites) — exit-code-based assertions in each script ARE the test.

---

## Notes

- **Crystal-clear and laconic** is the dominant design constraint. If a task description seems to call for a helper library or shared utility, prefer duplication across the 2–3 scripts that need it.
- **Path conventions**: every produced artifact lives under `demo-scripts/` at the repo root. No nested subdirectories.
- **Token resolution** always happens **on the jumpbox** via IMDS — never embed a token in a script, never `az account get-access-token` from the Mac for any data-plane call.
- **Audience selection**: `https://ai.azure.com` for SN Foundry; `https://cognitiveservices.azure.com/` would also work for the APIM hop but the SN endpoint is what the scripts hit directly, so stick with `https://ai.azure.com` throughout.
- **`apim-byom/gpt-5.4-nano`** is the literal model string the SN endpoint accepts and routes via the `apim-byom` connection. If `FOUNDRY_CONNECTION_NAME` ever changes, every script that hard-codes `apim-byom/...` in a request body must be updated — keep that string sourced via `${FOUNDRY_CONNECTION_NAME}/${MODEL_DEPLOYMENT_NAME}` everywhere.
- **Failure messages** are short and actionable: `FAIL — <script>: <one-sentence reason; what to check next>`. No stack traces, no debug spew (operator can re-run with `bash -x` if they want detail).
- **No tests** are generated. Each script's exit code is its own assertion. If TDD is later requested, add `demo-scripts/tests/` per script — but the user explicitly said "ONE thing with a banner + a PASS/FAIL line", so resist.
