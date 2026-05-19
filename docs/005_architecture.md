# Private Foundry Agent Service with cross-region model deployments



## Context

The platform runs on Microsoft Foundry Agent Service and must always carry the latest first-party Azure OpenAI / Foundry models. Three non-negotiable constraints apply:

- **Private networking is qualified only in West Europe and East US 2.** All agent traffic, dependency traffic, and management traffic must stay on customer-owned private VNets in one of these regions. Public network access is disabled on every Foundry-related resource.
- **The model API endpoint is in Sweden Central.** Independent of deployment SKU (regional `Standard`, `GlobalStandard`, `DataZone Standard EU`), the URL the agent calls — `*.openai.azure.com` or `*.services.ai.azure.com` — is bound to the account's home region. New first-party models become available in Sweden Central first, so the model-owning Foundry / Azure OpenAI account lives there.
- **Defense in depth applies on both ends.** The Sweden Central model endpoint must be private as well. No leg of the runtime path may be publicly reachable.

Two Microsoft platform rules shape the design:

- The Foundry Account that hosts the Agent Service capability host must be in the same Azure region as the agent VNet. The constraint is enforced at the API level by the `Microsoft.App/environments` validator. There is no override.
- The capability host cannot natively reach a model deployed under a different Foundry / Azure OpenAI account in a different region.

These rules forbid the obvious shortcut — keeping the Foundry Account in Sweden Central beside the model and stretching a private endpoint into a West Europe VNet. The remaining Microsoft-supported answer is **BYOM (Bring Your Own Model)** through a Foundry `Azure APIM` connection. APIM bridges the region gap, and both ends of the path are kept private.

## Solution Concept

Deploy the agent in West Europe (or East US 2) and reach the Sweden Central model through Azure API Management. 
APIM lives in Sweden Central; its **outbound** path reaches the Sweden Central model over a private endpoint inside an SC VNet; its **inbound** path is exposed only through a private endpoint inside the West Europe agent VNet. 
Public network access is disabled on every Foundry, Azure OpenAI, and APIM resource.

### Topology

| # | Component | Region | Network exposure |
|---|---|---|---|
| 1 | Foundry Account (agent-side) + Project | West Europe | Public access disabled. PE in WE PE subnet. |
| 2 | Agent VNet — two subnets | West Europe | Customer-owned. |
|   | ↳ Agent subnet, `/24`, delegated `Microsoft.App/environments` | West Europe | Container-Apps-backed agent runtime IPs. |
|   | ↳ Private-endpoint subnet | West Europe | PE NICs for all dependencies, including the cross-region APIM PE. |
| 3 | Cosmos DB, AI Search, Storage Account (BYO data plane) | West Europe | Public access disabled. PEs in WE PE subnet. |
| 4 | Foundry Account / Azure OpenAI (model-side) | Sweden Central | **Public network access disabled.** PE in SC PE subnet. |
| 5 | SC VNet — two subnets | Sweden Central | Customer-owned. Isolated from WE; no peering required. |
|   | ↳ APIM outbound delegated subnet | Sweden Central | APIM Std v2 / Prem v2 outbound VNet integration. |
|   | ↳ Private-endpoint subnet | Sweden Central | PE NIC for the SC Foundry / AOAI account. |
| 6 | APIM — Standard v2 or Premium v2 | Sweden Central | Outbound VNet integration into the SC VNet. **Public gateway disabled.** Inbound only via private endpoint. |
| 7 | APIM inbound private endpoint | West Europe — in the agent VNet's PE subnet | The cross-region bridge. The PE may be in a different region than the APIM instance. |

The agent-to-model path therefore crosses **two private endpoints in two regions**: a WE-side PE that fronts APIM, and an SC-side PE that fronts the model account. Neither resource has a public ingress.

### Locking down the Sweden Central model endpoint

The Foundry / Azure OpenAI account in Sweden Central is provisioned with:

- **Public network access: Disabled.** No firewall allow-list, no service tag bypass. The only way in is the PE in the SC VNet's PE subnet.
- A **private endpoint** on the `account` sub-resource, registered in the SC VNet, with private DNS zones `privatelink.openai.azure.com`, `privatelink.services.ai.azure.com`, and `privatelink.cognitiveservices.azure.com` linked to the SC VNet so that the account's canonical hostname resolves to the PE's private IP from inside the VNet.
- Inbound from APIM only. APIM's outbound VNet integration uses the SC VNet's DNS, so APIM resolves `https://<sc-account>.openai.azure.com` to the PE's private IP and reaches the model over Private Link.
- No other consumers. Direct agent-to-SC-model traffic is impossible because the agent VNet is in West Europe and is not peered to the SC VNet; the only documented routing into the SC model is through APIM.

### Locking down APIM

- APIM SKU: Standard v2 with outbound VNet integration + inbound private endpoint. Premium v2 if availability zones or multi-region scale-out are needed. Basic v2 is excluded — no inbound PE support.
- Outbound VNet integration into the SC VNet's APIM-outbound subnet. This is what lets APIM reach the SC model PE.
- Public gateway disabled. The APIM gateway endpoint accepts traffic only through the WE-side inbound PE. The `developer portal` is left disabled or also fronted privately.

### Locking down the West Europe agent plane

- Foundry Account, Cosmos DB, AI Search, Storage Account: **public network access disabled**. PEs only.
- Agent subnet: delegated `Microsoft.App/environments`, `/24` recommended (`/27` minimum), RFC1918, dedicated to one Foundry Account.
- Azure Firewall (optional): if integrated as egress for the agent subnet, allow the Service Tag `AzureActiveDirectory` and the Container Apps managed-identity FQDNs from Microsoft's documented list. No TLS inspection on this egress.

### Private DNS

Linked to the **West Europe agent VNet**:

- `privatelink.services.ai.azure.com`
- `privatelink.openai.azure.com`
- `privatelink.cognitiveservices.azure.com`
- `privatelink.search.windows.net`
- `privatelink.blob.core.windows.net`
- `privatelink.documents.azure.com`
- `privatelink.azure-api.net` — resolves the cross-region APIM PE to its WE-VNet private IP.

Linked to the **Sweden Central VNet**:

- `privatelink.openai.azure.com`
- `privatelink.services.ai.azure.com`
- `privatelink.cognitiveservices.azure.com`

The two DNS planes are independent and do not share zones, which is the point: each region's resources resolve to their own region's PEs.

### Identity

Two managed identities, no API keys in the runtime path.

**Agent project's managed identity** (system- or user-assigned):
- Owns access to BYO Cosmos DB / AI Search / Storage in West Europe.
- Authenticates the agent runtime to APIM when the `Azure APIM` connection uses `authType: AAD`.
- APIM enforces validity via the `validate-azure-ad-token` policy. The audience configured on the Foundry connection (`https://cognitiveservices.azure.com/`) and the project MI's client (application) ID are matched in the policy.

**APIM's own managed identity** (system- or user-assigned on the APIM resource):
- Holds `Cognitive Services OpenAI User` on the Sweden Central Foundry / Azure OpenAI account.
- Used by APIM's `authentication-managed-identity` policy to inject `Authorization: Bearer …` on the outbound hop.

### Packet path — single inference call

```
Agent runtime (WE agent subnet, private IP)
   │  TLS over private connectivity
   ▼
PE for APIM (WE PE subnet, privatelink.azure-api.net)
   │  Microsoft backbone, cross-region, internal
   ▼
APIM gateway listener (SC, Std v2 / Prem v2, public ingress disabled)
   │  Inbound policy stack:
   │    1. validate-azure-ad-token   (verifies agent project MI)
   │    2. llm-token-limit            (quotas)
   │    3. llm-semantic-cache-lookup  (optional)
   │    4. set-backend-service        (selects SC model)
   │  Backend policy stack:
   │    1. authentication-managed-identity → Bearer for SC Foundry
   │    2. llm-semantic-cache-store   (optional)
   ▼
APIM outbound VNet integration (SC VNet, delegated subnet)
   │  DNS resolves SC account hostname to PE private IP
   ▼
PE for Foundry / AOAI model account (SC PE subnet, privatelink.openai.azure.com)
   │  Public access on the account: Disabled
   ▼
Sweden Central model deployment
```

No segment of the path traverses a public IP. The customer's WE-side flow logs see one egress: agent subnet → APIM PE in the WE PE subnet. APIM's egress in Sweden Central sees one egress: APIM-outbound subnet → model PE in the SC PE subnet.

### Foundry wiring

- On the West Europe Foundry project, add an **Admin-connected model** of type **Azure API Management** (Foundry portal: Admin console → Admin-connected models → Add → Azure API Management).
- The wizard collects: the Sweden Central APIM resource, authentication (Managed Identity preferred), audience (`https://cognitiveservices.azure.com/`), one or more model deployment entries, URL-path style (`/deployments/{name}/chat/completions` vs `/chat/completions`), and optional static headers / API version.
- Agents reference the model with `<connection-name>/<deployment-name>`.
- Model discovery is **static** (the connection lists the models) or **dynamic** (APIM serves `/deployments` or `/models`). Static is simpler and avoids startup round-trips.

### APIM wiring

**Inbound policy stack** (in order):
1. `validate-azure-ad-token` — verifies the agent project MI's bearer.
2. `llm-token-limit` — per-MI or per-subscription quotas.
3. `llm-semantic-cache-lookup` — optional.
4. `set-backend-service` — selects the SC Foundry / AOAI backend.

**Backend policy stack:**
1. `authentication-managed-identity` with resource `https://cognitiveservices.azure.com` — APIM swaps the inbound MI token for one acceptable to Foundry / AOAI.
2. `llm-semantic-cache-store` — optional.

## Consequences

### Considerations

- **Two Foundry / Cognitive Services accounts and two VNets** to operate: West Europe for agents, Sweden Central for the model owner. Two RBAC scopes, two private DNS planes, two sets of PEs.
- **APIM is a critical dependency.** Its availability is the agents' availability.
- **BYOM legal disclaimer applies.** Microsoft's AI-Gateway documentation places responsibility for content safety, RAI mitigations, and data-handling compliance on the customer for any model reached through a BYOM connection. For first-party Azure OpenAI models the practical posture is unchanged, but compliance should sign off on the generic disclaimer language before go-live.
- **Capability host is immutable.** The West Europe Foundry project's capability host cannot be moved later.
- **Playground support varies.** New models reached through the `Azure APIM` connection may not surface in the Foundry Playground during a model's preview window; the SDK is the reliable invocation path.

### Advantages

- **No public ingress anywhere.** Foundry (WE), BYO data plane (WE), APIM (SC), and Foundry / AOAI model account (SC) all have public network access disabled. The only network-reachable surfaces are private endpoints in customer VNets.
- New Sweden Central models are usable on day one through APIM, without waiting for `GlobalStandard` / `DataZone Standard EU` promotion to West Europe.
- APIM provides centralised token quotas, semantic caching, audit, and managed-identity-based auth for all model traffic.
- Model promotion is a connection-level change. When a model later ships from a West Europe account, switching it from the APIM connection to a native WE deployment requires no network redesign.

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
