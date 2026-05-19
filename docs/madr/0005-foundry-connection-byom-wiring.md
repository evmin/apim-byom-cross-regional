# 0005 — Foundry BYOM connection wiring: `/openai` target + `authType: ApiKey`

- Status: accepted
- Date: 2026-05-19
- Depends on: [MADR-0002](./0002-bridge-cross-region-private-foundry-via-apim-byom.md)
- Pairs with: [MADR-0004](./0004-apim-dual-auth-policy-with-aad-fallthrough.md), [MADR-0006](./0006-v2-responses-api-canonical-agent-path.md)

## Context and Problem Statement

A Foundry project connection of category `ApiManagement` exposes a model to agents via `<connection>/<deployment>` references. Three fields critically affect whether the Responses runtime can actually resolve and call the model:

1. The connection `target` URL.
2. The connection `authType` (and accompanying credentials).
3. The connection `metadata` (model list, deployment style, inference API version).

Empirical evidence: with the wrong combination, the v2 Responses runtime rejects requests with `400 "Connection 'apim-byom' not found"` before any traffic reaches APIM.

## Considered Options

- **`target: https://<apim-gw>` (no path), `authType: AAD`, minimal metadata.** Returns `400 "Connection not found"`. (Original PR #1 state in `main` until PR #3.)
- **`target: https://<apim-gw>/openai`, `authType: AAD`.** Still `400 "Connection not found"` on the v2 runtime. The combination is rejected.
- **`target: https://<apim-gw>/openai`, `authType: ApiKey`, `credentials.key: <value>`, full metadata.** Works end-to-end on both v2 surfaces (`PromptAgentDefinition` and raw `responses.create`).

## Decision Outcome

Set the Foundry connection as follows (see `infra/modules/foundry-connection.bicep`):

| Field | Value |
|---|---|
| `category` | `ApiManagement` |
| `target` | `https://${apimGatewayHostname}/openai` — the trailing `/openai` is mandatory; it matches the APIM API `path` literal. |
| `authType` | `ApiKey` |
| `credentials.key` | Deterministic value from `uniqueString(...)` — shared with the APIM named value (see [MADR-0004](./0004-apim-dual-auth-policy-with-aad-fallthrough.md)). |
| `metadata.models` | JSON array of `{ name, properties: { model: { name, format, version, publisher } } }` — one entry per deployment. |
| `metadata.deploymentInPath` | `true` (AOAI path style: `/deployments/{name}/chat/completions`). |
| `metadata.inferenceAPIVersion` | `2024-10-21`. |

## Consequences

- The Responses runtime resolves `apim-byom/<deployment>` correctly and issues the upstream POST to APIM.
- The connection now carries a credential (api-key). Treat the Foundry connection resource as secret-bearing — the APIM gateway is gated by the same value (see [MADR-0004](./0004-apim-dual-auth-policy-with-aad-fallthrough.md)).
- Rotation requires redeploying both the Foundry connection and the APIM named value; the deterministic `uniqueString()` derivation handles that in one shot.
- v1 Assistants/Threads is unaffected (and unused — see [MADR-0006](./0006-v2-responses-api-canonical-agent-path.md)).

## References

- `infra/modules/foundry-connection.bicep` — the connection resource.
- PR #3 (`evmin/fix/byom-target-openai`, commit `ac43704`) — landed this wiring.
- Foundry connections — `ApiManagement` category: https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/connections
