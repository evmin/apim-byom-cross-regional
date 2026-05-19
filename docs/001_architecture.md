# Private Foundry agent with cross-region model access — technical reference

This is the long-form technical narrative. For the two-minute overview start with [`/ARCHITECTURE.md`](../ARCHITECTURE.md). For decision rationale see [`docs/madr/`](./madr/).

## The forces

Two facts pull the design in opposite directions:

- **AI landing zones live in East US 2 and West Europe.** The Foundry agent plane, the BYO data plane (Cosmos DB, AI Search, Blob), and the operational tooling all run there.
- **New first-party Azure OpenAI / Foundry models ship in Sweden Central first.** The model endpoint is bound to the model account's home region.

Add a third, non-negotiable constraint: **public network access is off on every Foundry, OpenAI, APIM, Cosmos, AI Search, and Storage resource on the runtime path.** The only network-reachable surfaces are private endpoints in customer VNets.

Two Microsoft platform rules close the obvious shortcuts:

- The Foundry account that hosts the Agent Service capability host must be in the **same Azure region as the agent VNet**. The `Microsoft.App/environments` validator enforces this. There is no override.
- The capability host **cannot natively reach a model deployed under a different Foundry / OpenAI account in a different region.**

These rules forbid keeping the Foundry account in Sweden Central beside the model while stretching a private endpoint into West Europe. The remaining Microsoft-supported answer is **BYOM (Bring Your Own Model)** through a Foundry `Azure API Management` admin-connected model. APIM bridges the region gap; both ends stay private.

## The solution

Deploy the agent in an AI landing zone region (EUS2 or WE — Switzerland North, North Europe, and France Central are also supported in this IaC). Reach the Sweden Central model through Azure API Management. APIM lives in Sweden Central; its **outbound** path reaches the model over a private endpoint inside an SC VNet; its **inbound** path is exposed only through a private endpoint inside the agent VNet.

### Topology

| # | Component | Region | Network exposure |
|---|---|---|---|
| 1 | Foundry account (agent-side) + project | Agent region | Public access off. PE in agent-VNet PE subnet. |
| 2 | Agent VNet — two subnets | Agent region | Customer-owned. |
|   | ↳ agent subnet, `/24`, delegated `Microsoft.App/environments` | Agent region | Container-Apps-backed agent runtime IPs. |
|   | ↳ private-endpoint subnet | Agent region | PE NICs for every dependency, including the cross-region APIM PE. |
| 3 | Cosmos DB, AI Search, Storage (BYO data plane) | Agent region | Public access off. PEs in the agent-VNet PE subnet. |
| 4 | Foundry / OpenAI account (model-side) | Sweden Central | **Public access off.** PE in SC PE subnet. |
| 5 | SC VNet — two subnets | Sweden Central | Customer-owned. Isolated from the agent VNet. No peering. |
|   | ↳ APIM outbound delegated subnet | Sweden Central | APIM Std v2 / Prem v2 outbound VNet integration. |
|   | ↳ private-endpoint subnet | Sweden Central | PE NIC for the SC model account. |
| 6 | APIM — Standard v2 or Premium v2 | Sweden Central | Outbound VNet integration into the SC VNet. **Public gateway off.** Inbound only via private endpoint. |
| 7 | APIM inbound private endpoint | **Agent region** — in the agent VNet's PE subnet | The cross-region bridge. The PE NIC may live in a region different from the APIM instance. |

Each request crosses **two private endpoints in two regions**: an agent-region PE that fronts APIM, and an SC PE that fronts the model account. Neither resource has a public ingress.

### Packet path — single inference call

```
Agent runtime  (agent subnet, private IP)
   │  TLS over private connectivity
   ▼
PE for APIM   (agent PE subnet, privatelink.azure-api.net)
   │  Microsoft backbone, cross-region, internal
   ▼
APIM gateway listener  (SC, Std v2 / Prem v2, public ingress off)
   │  Inbound policy stack — see below.
   ▼
APIM outbound VNet integration  (SC VNet, delegated subnet)
   │  DNS resolves the SC account hostname to the PE's private IP.
   ▼
PE for Foundry / AOAI model account  (SC PE subnet, privatelink.openai.azure.com)
   │  Public access on the account: off.
   ▼
Sweden Central model deployment
```

No segment is publicly reachable. The customer's agent-region flow logs see one egress: agent subnet → APIM PE in the agent-region PE subnet. APIM's egress in Sweden Central sees one: APIM-outbound subnet → model PE in the SC PE subnet.

## Locking down the Sweden Central model endpoint

The SC Foundry / OpenAI account is provisioned with:

- **Public network access: off.** No firewall allow-list, no service-tag bypass. The only way in is the PE in the SC VNet.
- A **private endpoint** on the `account` sub-resource, registered in the SC VNet, with the private DNS zones `privatelink.openai.azure.com`, `privatelink.services.ai.azure.com`, and `privatelink.cognitiveservices.azure.com` linked to the SC VNet. The account's canonical hostnames resolve to the PE's private IP from inside the VNet.
- **Inbound from APIM only.** APIM's outbound VNet integration uses the SC VNet's DNS, so APIM resolves the SC account hostname to the PE IP and reaches the model over Private Link.
- **No other consumers.** Direct agent-to-SC-model traffic is impossible: the agent VNet and the SC VNet are not peered, and the only documented routing into the SC model is through APIM.

## Locking down APIM

- **SKU:** Standard v2 (with outbound VNet integration and inbound private endpoint). Premium v2 when availability zones or multi-region scale-out are needed. Basic v2 is excluded — no inbound PE support.
- **Outbound VNet integration** into the SC VNet's APIM-outbound subnet. This lets APIM reach the SC model PE.
- **Public gateway off.** The APIM gateway accepts traffic only through the agent-region inbound PE. The developer portal is disabled.

## Locking down the agent plane

- Foundry account, Cosmos DB, AI Search, Storage account: **public network access off**, PEs only.
- Agent subnet: delegated `Microsoft.App/environments`, `/24` recommended (`/27` minimum), RFC1918, dedicated to one Foundry account.

## Private DNS

Zones linked to the **agent VNet**:

- `privatelink.services.ai.azure.com`
- `privatelink.openai.azure.com`
- `privatelink.cognitiveservices.azure.com`
- `privatelink.search.windows.net`
- `privatelink.blob.core.windows.net`
- `privatelink.documents.azure.com`
- `privatelink.azure-api.net` — resolves the cross-region APIM PE to its agent-VNet private IP.

Zones linked to the **SC VNet**:

- `privatelink.openai.azure.com`
- `privatelink.services.ai.azure.com`
- `privatelink.cognitiveservices.azure.com`

The two DNS planes are independent. That's the point: each region's resources resolve to their own region's PEs.

## Identity and authentication

Two managed identities carry the runtime path. No keys are minted by the operator — the one shared secret is generated by Bicep at deploy time via `uniqueString()`.

**Agent project's managed identity** (system- or user-assigned, on the agent project):

- Holds RBAC on the BYO Cosmos / AI Search / Storage resources in the agent region.
- Used by the jumpbox UAMI and direct-MI callers as their AAD identity to APIM (validated by APIM's `validate-azure-ad-token`).

**APIM's own managed identity** (system-assigned, on the APIM resource):

- Holds `Cognitive Services OpenAI User` on the SC Foundry / OpenAI account.
- Used by APIM's `authentication-managed-identity` policy to mint the Bearer token APIM presents on the backend hop.

The Foundry Responses runtime is a special caller: it cannot present an AAD token to a Foundry-internal connection target (the Responses API rejects the `apim-byom` connection with `400 "Connection not found"` when `authType: AAD`). Instead, the connection uses **`authType: ApiKey`** with a shared secret in `credentials.key`. The same value lives in an APIM named value `apim-byom-key` (`secret: true`); the inbound policy checks the incoming `api-key` header against it. AAD-only callers (the jumpbox smoke, future direct-MI consumers) skip the api-key match and fall through to AAD validation.

The shared secret is derived deterministically by Bicep via `uniqueString(subscription().subscriptionId, azdEnvironmentName, namePrefix, 'apim-byom-key-v1')` — no secret in source. Rotation = redeploy.

## APIM policy stack

Loaded from `infra/policies/inbound.xml`, composed at deploy by `infra/modules/apim-policy.bicep`.

**Inbound** (in order):

1. **`<choose>` api-key gate.** When the inbound `api-key` header **does not** equal `{{apim-byom-key}}`, run `validate-azure-ad-token`:
   - `tenant-id`: the deployment tenant.
   - `audiences`: `https://cognitiveservices.azure.com/` **and** `https://ai.azure.com`.
   - `required-claims`: `oid` must match the allow-list (the agent project's MI plus, optionally, the jumpbox UAMI for the smoke).
   When the api-key matches, AAD validation is skipped.
2. **Header strip.** `api-key` and `Ocp-Apim-Subscription-Key` are deleted before the backend hop. The model never sees them.
3. **`set-backend-service`** rewrites the backend URL to the SC Foundry / OpenAI account's `…/openai` private hostname.
4. **`authentication-managed-identity`** acquires APIM's MI token for `https://cognitiveservices.azure.com`, stored in variable `msi-token`.
5. **`set-header Authorization`** overrides the caller's Authorization with `Bearer <msi-token>` for the forward hop.

Optional, when `ENABLE_SEMANTIC_CACHE=true`:

- `llm-semantic-cache-lookup` is inserted into the inbound stack before `set-backend-service` (cache after auth, before backend).
- `llm-semantic-cache-store` is inserted into the backend stack before `forward-request`.

> **What is not in the stack:** an earlier draft included `<llm-token-limit>`. It was removed after the runtime intermittently dropped response bodies (200 OK with `Content-Length: 0`) under a hot counter-key. If a token cap is needed later, use a stable counter-key (a token fingerprint, not the raw Authorization header).

## Foundry connection wiring

A single Foundry **admin-connected model** of category `ApiManagement`, authored as a `Microsoft.CognitiveServices/accounts/projects/connections` child of the agent project.

| Property | Value |
|---|---|
| `category` | `ApiManagement` |
| `authType` | `ApiKey` |
| `target` | `https://<apim-hostname>/openai` — **with the `/openai` API-path suffix.** Without it, Responses returns `400 "Connection 'apim-byom' not found"` before any request leaves the agent runtime. |
| `credentials.key` | The `uniqueString()`-derived secret (matches APIM's named value). |
| `metadata.deploymentInPath` | `'true'` when `URL_PATH_STYLE=aoai` (`/deployments/{name}/chat/completions`); `'false'` for the OpenAI-shape `/chat/completions`. |
| `metadata.inferenceAPIVersion` | `2024-10-21` (GA AOAI API version). |
| `metadata.models` | JSON-stringified array of model entries with `name`, `format=OpenAI`, `version`, `publisher=Microsoft`. Static discovery — no startup round-trip to APIM. |

Agents reference the model as `<connection-name>/<deployment-name>` (e.g. `apim-byom/gpt-5.4-nano`).

## Consequences

### Tradeoffs

- **Two Foundry / Cognitive Services accounts, two VNets, two DNS planes, two RBAC scopes.** This stack is heavier to operate than a single-region one.
- **APIM is on the critical path.** Its availability is the agents' availability. Mitigate with APIM zone-redundancy (Std v2 / Prem v2).
- **Capability host is immutable.** The agent project's capability host cannot be moved later.
- **BYOM legal posture.** Microsoft's AI-Gateway docs place responsibility for content safety and Responsible-AI mitigations on the customer for any model reached through BYOM. For first-party Azure OpenAI models the practical posture is unchanged; get compliance sign-off on the disclaimer language before go-live.

### Benefits

- **No public ingress anywhere on the runtime path.** Foundry (agent-side), BYO data plane, APIM, and the SC model account all have public network access off. The only network-reachable surfaces are PEs in customer VNets.
- New Sweden Central models are usable on day 0, without waiting for region promotion.
- APIM centralises auth, quotas, semantic caching, and audit for all model traffic.
- Model promotion is a connection-level change. If a model later ships in the agent region, switching from APIM-BYOM to a native deployment requires no network redesign.

## References

| Topic | Link |
|---|---|
| Foundry Agent + APIM how-to (BYOM, `Azure APIM` connection) | https://learn.microsoft.com/en-us/azure/ai-foundry/agents/how-to/ai-gateway |
| Foundry Agents virtual networks — region rule | https://learn.microsoft.com/en-us/azure/ai-foundry/agents/how-to/virtual-networks |
| Foundry connections — `ApiManagement` and `ModelGateway` categories | https://learn.microsoft.com/en-us/azure/ai-foundry/concepts/connections |
| APIM inbound private endpoint — cross-region PE | https://learn.microsoft.com/en-us/azure/api-management/private-endpoint |
| APIM outbound VNet integration — same-region requirement | https://learn.microsoft.com/en-us/azure/api-management/integrate-vnet-outbound |
| APIM GenAI gateway policies | https://learn.microsoft.com/en-us/azure/api-management/genai-gateway-capabilities |
| APIM `validate-azure-ad-token` policy | https://learn.microsoft.com/en-us/azure/api-management/validate-azure-ad-token-policy |
| APIM `authentication-managed-identity` policy | https://learn.microsoft.com/en-us/azure/api-management/authentication-managed-identity-policy |
| Azure OpenAI / Foundry account private endpoints and DNS zones | https://learn.microsoft.com/en-us/azure/ai-foundry/foundry-models/how-to/configure-private-link |
| Reference Bicep: standard agent + APIM (private, preview) | https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/16-private-network-standard-agent-apim-setup-preview |
| Reference Bicep: standard agent private-network base | https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup |
