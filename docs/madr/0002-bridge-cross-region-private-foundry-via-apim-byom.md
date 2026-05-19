# 0002 — Bridge cross-region private Foundry via APIM BYOM

- Status: accepted
- Date: 2026-05-19

## Context and Problem Statement

Three constraints collide:

1. The Foundry Agent Service capability host **must live in the same Azure region as the agent VNet**. The `Microsoft.App/environments` validator enforces this — no override.
2. First-party Azure OpenAI / Foundry models ship in **Sweden Central** first. Their endpoint URL is bound to the account's home region.
3. **Both legs of the runtime path must be private** — public network access disabled on the agent account, the model account, and any bridge.

How do we let an agent in (say) West Europe / Switzerland North call a model that only exists in Sweden Central, without ever opening a public ingress?

## Considered Options

- **Stretch a PE from the SC model into the agent VNet.** Forbidden by the same-region rule for the capability host: you would still need a Foundry account in the agent region, and Foundry can't natively reach a model under a different account in a different region.
- **Move the Foundry account to Sweden Central beside the model.** Breaks if the agent VNet cannot live in SC (private-network qualification is only in WE / EUS2 in the original ask).
- **Wait until the model promotes to West Europe** (`GlobalStandard` / `DataZone Standard EU`). Delays day-0 model availability by weeks to months.
- **BYOM through a Foundry `Azure APIM` connection.** APIM bridges the region gap; both ends stay private; this is Microsoft's documented pattern.

## Decision Outcome

Use **BYOM (Bring Your Own Model)** via a Foundry `Azure APIM` connection.

- Foundry agent account + project: in the agent region (WE / EUS2 / SN). PE-only.
- Model-owning Foundry / AOAI account: in **Sweden Central**. PE-only. Inbound only from APIM in the SC VNet.
- APIM: in Sweden Central with **outbound VNet integration** into the SC VNet (reaches the model PE) and an **inbound private endpoint** in the agent VNet (no public gateway).
- Agents reference the model as `<connection-name>/<deployment-name>` (e.g. `apim-byom/gpt-5.4-nano`).

## Consequences

- No public ingress anywhere on the runtime path; both PEs are in customer VNets.
- New SC models are usable on day 0 — no waiting for region promotion.
- APIM is on the critical path and becomes a single point of failure for inference. Mitigate with APIM's own zone-redundancy (Std v2 / Prem v2).
- Two VNets, two RBAC scopes, two DNS planes — see [MADR-0003](./0003-apim-std-v2-with-cross-region-inbound-pe.md).
- BYOM legal disclaimer applies (Microsoft AI-Gateway docs).

## References

- Foundry Agent + APIM (BYOM): https://learn.microsoft.com/en-us/azure/ai-foundry/agents/how-to/ai-gateway
- Foundry virtual-network region rule: https://learn.microsoft.com/en-us/azure/ai-foundry/agents/how-to/virtual-networks
- `../001_architecture.md` — full architecture narrative.
