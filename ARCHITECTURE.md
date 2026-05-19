# Architecture overview

This repo deploys a private Azure Foundry agent that calls Sweden Central models — without exposing anything to the public internet. The stack is Bicep, packaged for [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/), and ships with a jumpbox you can drive through Azure Bastion to validate the path end-to-end.

This page is the two-minute introduction. For the full technical narrative read [`docs/001_architecture.md`](./docs/001_architecture.md). For decisions and rationale read the ADRs in [`docs/madr/`](./docs/madr/).

## The problem

You want to run a Foundry agent privately, on the newest Azure OpenAI models. Two facts pull in opposite directions:

1. **The AI landing zones are in East US 2 and West Europe.** Private Foundry workloads — the agent platform, the BYO data plane, the operational tooling — live in those two regions by design.
2. **The newest first-party Azure OpenAI / Foundry models ship in Sweden Central first.** The model endpoint is bound to the model account's home region. New capabilities can land in Sweden Central months before they reach EUS2 or WE.

On top of that, **public access has to be off everywhere**: no public ingress on the agent, none on the model.

One Azure platform rule closes the obvious workaround: the Foundry agent runtime must live in the same region as its VNet, and that constraint is enforced at the API level. You can't just stand up a Foundry account next to the model in Sweden Central — your landing zones aren't there, and Foundry can't natively reach a model under a different account in a different region anyway. Waiting for the model to be promoted to EUS2 / WE costs weeks or months of capability lag.

So the agent has to reach across regions, and both ends have to stay private.

## The solution

Bridge the two regions with **Azure API Management (APIM)**, wired into Foundry as a **BYOM (Bring Your Own Model)** connection.

```
   AI landing zone (EUS2 / WE)                       Sweden Central
 ┌────────────────────────────────────┐       ┌──────────────────────────────┐
 │ Foundry project + agent runtime    │       │ Sweden Central model         │
 │ BYO Cosmos / AI Search / Blob      │       │ (Foundry / Azure OpenAI)     │
 │                                    │       │                              │
 │ Agent VNet                         │       │ SC VNet                      │
 │  ├ agent subnet                    │       │  ├ APIM outbound subnet      │
 │  └ PE subnet ──► APIM inbound PE ──┼──────►│  └ PE for model account      │
 │                  (cross-region)    │ MSFT  │            ▲                 │
 │                                    │ back- │            │                 │
 │                                    │ bone  │  APIM ─────┘                 │
 └────────────────────────────────────┘       └──────────────────────────────┘

         Public network access: OFF on every resource in this picture.
```

APIM lives in Sweden Central. Its **inbound** endpoint is a private endpoint inside the agent VNet — cross-region, on the Microsoft backbone. Its **outbound** side reaches the model through another private endpoint in the Sweden Central VNet. The agent calls APIM like any other private dependency. The model never sees a public caller.

## How a request flows

1. The agent runtime asks Foundry for a model reference like `apim-byom/gpt-5-nano`.
2. Foundry resolves the BYOM connection and dials the APIM private endpoint in the agent VNet over TLS.
3. The request travels the Microsoft backbone to the APIM gateway in Sweden Central.
4. APIM validates the caller (api-key or AAD token), strips the inbound credential, and attaches its own managed-identity bearer for the model.
5. APIM forwards the call through its outbound VNet integration to the model's private endpoint.
6. The model responds along the same path.

No segment of the path is publicly reachable.

## What stays private

| Resource | Region | Public network access |
|---|---|---|
| Foundry agent project + capability host | EUS2 / WE | Off — private endpoint only |
| APIM gateway | Sweden Central | Off — private endpoint in the agent VNet |
| Sweden Central model account (Foundry / AOAI) | Sweden Central | Off — private endpoint in the SC VNet |
| Cosmos DB, AI Search, Blob storage (BYO data) | EUS2 / WE | Off — private endpoints only |

## How callers are authenticated

APIM accepts two credentials and replaces them both with its own identity before calling the model:

- **The Foundry agent runtime** sends an `api-key` header that the BYOM connection holds. APIM checks it against a stored secret.
- **Direct AAD callers** (the jumpbox smoke suite, future SDK clients on the VNet) send an `Authorization: Bearer …` token. APIM validates it against a tenant + object-id allow-list.

Either way, APIM strips the inbound credential and calls the model using its own managed identity. The model account only ever sees APIM as the caller.

## Tradeoffs

- **APIM is on the critical path.** If APIM is down, agents can't reach models. Mitigate with APIM zone-redundancy (Standard v2 or Premium v2).
- **Two regions, two VNets, two RBAC scopes.** This stack is heavier to operate than a single-region one.
- **BYOM legal terms apply.** Microsoft documents BYOM connections as customer-responsible for content safety and Responsible-AI mitigations. For first-party Azure OpenAI models the practical posture is unchanged, but get compliance sign-off before go-live.

## What's in this repo

| Path | What's there |
|---|---|
| `infra/` | The Bicep stack (Azure Verified Modules where available), wired into `azure.yaml` for `azd up`. |
| `demo-scripts/` | Three-stage proof: model in SC, APIM in SC, end-to-end through the v2 Responses API. |
| `scripts/jumpbox/` | Bootstrap + smoke suite that runs inside the agent VNet through Azure Bastion. |
| `docs/madr/` | Architecture Decision Records — what we chose, what we ruled out, why. |
| `docs/001_architecture.md` | Long-form technical narrative — topology, DNS, policies, identity. |
| `docs/002_quickstart.md`, `docs/003_portal_tunnel.md` | Day-2 operating procedures. |
| `docs/004_research.md` | AVM coverage analysis and IaC design decisions. |

## Read next

- **First time here?** → [`docs/001_architecture.md`](./docs/001_architecture.md) for the full technical narrative.
- **Want to run it?** → [`docs/002_quickstart.md`](./docs/002_quickstart.md) for deploy / verify / tear down.
- **Want the decisions, not the diagrams?** → [`docs/madr/README.md`](./docs/madr/README.md).
- **Need IaC rationale and AVM gaps?** → [`docs/004_research.md`](./docs/004_research.md).
- **Need portal access while public network is off?** → [`docs/003_portal_tunnel.md`](./docs/003_portal_tunnel.md).
