# 0003 — APIM Standard v2 with cross-region inbound PE in the agent VNet

- Status: accepted
- Date: 2026-05-19
- Depends on: [MADR-0002](./0002-bridge-cross-region-private-foundry-via-apim-byom.md)

## Context and Problem Statement

The BYOM bridge from [MADR-0002](./0002-bridge-cross-region-private-foundry-via-apim-byom.md) needs APIM to be reachable from the agent VNet (cross-region) while keeping APIM itself in the model region (so its outbound VNet integration can hit the SC model PE).

Three things must be picked at once: APIM SKU, the side that owns the inbound PE, and the VNet topology.

## Considered Options

**APIM SKU:**

- **Basic v2** — cheap, but no inbound PE support. Public gateway only. Rejected.
- **Standard v2** — supports outbound VNet integration + inbound PE (incl. cross-region PE). Public gateway can be disabled. Zone-redundant.
- **Premium v2** — same capabilities + multi-region scale-out + AZs. Significantly more expensive. Reserve for high-scale prod.

**Inbound PE location:**

- **PE in the agent VNet** (cross-region from APIM in SC) — supported by APIM; private DNS zone `privatelink.azure-api.net` is linked to the agent VNet only.
- **PE in the model VNet, peer to agent VNet** — adds VNet peering + DNS forwarding complexity; couples the two VNets unnecessarily.

**VNet topology:**

- **Two VNets, no peering** — each region owns its own DNS plane; the only inter-region hop is the APIM PE.
- **Peered VNets, single DNS plane** — simpler at first glance but couples failure domains and complicates RBAC.

## Decision Outcome

- **APIM SKU:** Standard v2 (StandardV2). Bump to Premium v2 only when multi-region scale-out is needed.
- **Inbound PE:** in the **agent VNet**'s PE subnet, cross-region from APIM in SC.
- **Topology:** two VNets, **no peering**. Each region carries its own private DNS zones; only the APIM PE and the AOAI PE participate in cross-region data flow.

## Consequences

- One inbound PE + one outbound VNet integration = one APIM instance per "deployment unit". No multi-master at this stage.
- The agent VNet's DNS for `privatelink.azure-api.net` resolves to the WE-side PE; the SC VNet does not see APIM's private gateway IP — by design, no SC consumer should bypass APIM.
- Public gateway disabled. The portal endpoint stays disabled or is fronted privately if used.
- Cost: StandardV2 base SKU + zone redundancy is the dominant ongoing line item in non-prod.

## References

- APIM inbound private endpoint (cross-region): https://learn.microsoft.com/en-us/azure/api-management/private-endpoint
- APIM outbound VNet integration: https://learn.microsoft.com/en-us/azure/api-management/integrate-vnet-outbound
- `infra/modules/sc-model-plane.bicep`, `infra/modules/wiring.bicep` — implementation.
