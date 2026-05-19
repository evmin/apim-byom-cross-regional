# 0006 — v2 PromptAgent + Responses API as the canonical agent path

- Status: accepted
- Date: 2026-05-19
- Depends on: [MADR-0005](./0005-foundry-connection-byom-wiring.md)

## Context and Problem Statement

Foundry exposes two agent runtimes against the same project endpoint:

- **v1 Assistants/Threads** — `AgentsClient.create_agent` + `threads.create` + `runs.create`. Older preview surface.
- **v2 Prompt Agents + Responses API** — `agents.create_version(PromptAgentDefinition(...))` + `oai.responses.create(..., extra_body={"agent_reference": ...})`. Newer preview surface.

Empirical evidence across multiple regions (NEU / WE / EUS2 / FRC / CHN, SN): the v1 Assistants runtime fails server-side when models are reached through a BYOM connection — runs reach terminal `failed` with `last_error.code: server_error` and **no upstream APIM traffic** is observed during failed runs. No public PIR. v2 works on both `PromptAgentDefinition` and raw `responses.create` patterns.

## Considered Options

- **Keep both runtimes; mark v1 as `EXPECTED_FAIL`.** Adds a confusing failure that operators have to remember is "fine". The v1 SDK (`azure-ai-agents`) stays in the venv, the `/threads/<id>/runs` failure demo stays in the repo.
- **Drop v1 entirely; v2 is the canonical path.** Smaller surface, no `EXPECTED_FAIL` noise, smaller jumpbox venv.
- **Wait for Microsoft to fix v1.** No fix ETA; the platform team has not opened a PIR. Blocks adoption indefinitely.

## Decision Outcome

**v2 PromptAgent + Responses API is the canonical agent path.** v1 Assistants/Threads is removed from the demo and validation surface.

Concretely (PR #4, commit `4cd7b55`):

- Removed: `scripts/jumpbox/smoke-sdk.py`, `demo-scripts/03_sn_connection_and_agent.sh`, `demo-scripts/04_call_sn_routes_to_sc.sh`, `demo-scripts/05_replay_agent.sh`, `demo-scripts/06_attempt_runtime.sh`.
- Renamed: `demo-scripts/07_responses_api.sh` → `03_responses_api.sh` (sole Stage 3 — runs both `PromptAgentDefinition + Responses API` and raw `responses.create`, both must return `'PONG'`).
- `scripts/jumpbox-smoke.sh` — drop `smoke-sdk` + the `EXPECTED_FAIL` tolerance map.
- `scripts/jumpbox/bootstrap.sh` — drop `azure-ai-agents` from the venv.

## Consequences

- Demo is collapsed to three stages (model in SC, APIM in SC, end-to-end through Responses API).
- Net cleanup: `+98 / -934` lines.
- If v1 Assistants is ever needed again (e.g. Microsoft fixes the runtime and a customer needs the older REST surface), this ADR will be superseded by a new ADR re-introducing the v1 path with explicit scope.

## References

- `demo-scripts/03_responses_api.sh` — the canonical Stage 3 proof.
- PR #4 (`evmin/cleanup/v1-assistants-threads`, commit `4cd7b55`) — landed this cleanup.
- Foundry Prompt Agents + Responses API: https://learn.microsoft.com/en-us/azure/ai-foundry/agents/concepts/runtime-components
