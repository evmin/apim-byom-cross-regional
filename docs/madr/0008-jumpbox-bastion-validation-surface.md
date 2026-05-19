# 0008 — Jumpbox + Bastion as the validation surface

- Status: accepted
- Date: 2026-05-19

## Context and Problem Statement

Every solution data-plane (Foundry account, AOAI account, APIM gateway, AI Search, Cosmos, Storage) has `publicNetworkAccess: Disabled`. The only network-reachable surfaces are private endpoints in customer VNets.

That means:

- The operator's laptop cannot directly call `mreg-fdev-apim-sc-qx3thf.azure-api.net` or `mregfdevfdrychnl33kar.services.ai.azure.com` — DNS resolves to PE IPs that are not routable from the public internet.
- `azd up` post-hooks (smoke validation, end-to-end demo scripts) need an in-VNet launch pad to issue real data-plane calls.

## Considered Options

- **Cloud Shell with VNet integration.** Limited in BYOM private scenarios; per-tenant policy may disable. Rejected for portability.
- **Site-to-Site VPN / ExpressRoute.** Heavy, requires customer-side network gear or ER circuit. Not justified for a demo / validation surface.
- **Point-to-Site VPN / Azure VPN Gateway.** Per-operator setup overhead; ongoing client config drift. Rejected.
- **Self-hosted runner inside the VNet.** Solves CI but not interactive validation; still needs Bastion-style access for SSH.
- **Demo jumpbox (small Linux VM) + Azure Bastion (Standard with tunneling) + UAMI.** No public IP on the VM; Bastion-tunnel + `az network bastion tunnel` opens an ephemeral `localhost:<port>` → port-22 forward; operator `ssh` over that.

## Decision Outcome

Provision a small Ubuntu jumpbox VM in the agent VNet (`infra/modules/demo-jumpbox.bicep`):

- **No public IP** on the NIC. NSG blocks all inbound except the VNet (Bastion subnet).
- **User-assigned managed identity** with `Azure AI Developer` on the agent project, `Cognitive Services User` on the SC AOAI account, and its `oid` in the APIM policy allowlist.
- **Azure Bastion** (Standard SKU, tunneling enabled) co-located in the agent VNet.
- Cloud-init writes a fixed set of smoke scripts under `/opt/mreg-validate/` and a Python venv with `azure-ai-projects`, `azure-identity`, `openai`, `httpx`.
- Operator entry point: `scripts/jumpbox-run.sh "<remote-bash>"` opens an `az network bastion tunnel`, ssh's in non-interactively, runs the command, tears down the tunnel.
- Validation entry point: `scripts/jumpbox-smoke.sh` — dns / reject / bridge / posture checks. Demo entry point: `demo-scripts/run-all.sh` — 01 / 02 / 03.

The Bastion is also used for browser access to the Foundry portal via SOCKS-over-SSH-over-Bastion — see `../003_portal_tunnel.md`.

## Consequences

- Every validation and demo step is reproducible from the operator's laptop with only `az login` + an SSH private key. No customer network gear or VPN client.
- Bastion + small VM is the dominant non-prod cost line item after APIM. Both can be deleted when the env is idle; redeployment is idempotent.
- Default outbound access on new Azure VMs was retired Sept 2025. Currently mitigated by a temporary public IP attached to the NIC (NSG still blocks inbound). Future follow-up: add a NAT Gateway in `demo-jumpbox.bicep`.

## References

- `infra/modules/demo-jumpbox.bicep` — VM, NIC, NSG, UAMI, cloud-init.
- `scripts/jumpbox-run.sh`, `scripts/jumpbox-smoke.sh` — operator entry points.
- `../003_portal_tunnel.md` — SOCKS tunnel for the Foundry portal.
- Default outbound access retirement: https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access
