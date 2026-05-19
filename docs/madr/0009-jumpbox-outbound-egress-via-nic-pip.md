# 0009 — Jumpbox outbound egress via a NIC public IP (demo posture)

- Status: accepted
- Date: 2026-05-19

## Context and Problem Statement

Microsoft retired default outbound access for new Azure VMs in September 2025. Every new VM must declare an explicit egress mechanism — NAT Gateway, NIC public IP, public load-balancer outbound rule, VPN, or ExpressRoute — or it cannot reach internet endpoints, including the Azure control plane at `management.azure.com`.

The demo jumpbox ([`MADR-0008`](./0008-jumpbox-bastion-validation-surface.md)) needs outbound to `management.azure.com` so the `posture-from-vnet` smoke check can query Azure Resource Graph and verify every solution-managed resource still has `publicNetworkAccess: Disabled`. Without explicit egress, that check fails with a connection timeout (`http_code=000`).

The decision is scoped to a **single demo VM**, not a fleet.

## Considered Options

- **NAT Gateway in a dedicated subnet.** Production-grade pattern. ~$32 / month idle plus data egress. Adds an AVM module, a subnet wiring change, and a NAT-Gateway-aware idempotency check. Right answer when there are multiple VMs sharing one VNet.
- **Standard public IP on the VM NIC.** ~$3 / month plus data egress. Six lines of Bicep inside the existing `compute/virtual-machine` AVM `nicConfigurations` block. The NIC NSG already denies all inbound except the VirtualNetwork source (Bastion subnet only), so the PIP grants outbound only in practice.
- **Public load balancer with outbound rule.** Same cost as NAT Gateway; useful for VMSS, overkill for a single VM.
- **VPN gateway / ExpressRoute.** Customer-side dependency; out of scope for a self-contained demo.
- **Accept the regression and skip `posture-from-vnet`.** Loses a useful audit signal during validation.

## Decision Outcome

Attach a **Standard-SKU, Static-allocation public IP** to the jumpbox NIC, modeled in `infra/modules/demo-jumpbox.bicep` via the AVM `compute/virtual-machine:0.22.1` module's `nicConfigurations[0].ipConfigurations[0].pipConfiguration` block.

Why a PIP, not a NAT Gateway:

- **Demo simplicity.** Six lines of inline Bicep beats a new module, a new subnet, and a new idempotency rule.
- **Cost shape matches the audience.** ~$3 / month is appropriate for a single operator VM that runs occasionally; $32 / month is not.
- **Inbound posture is preserved by the NSG, not by the absence of a PIP.** The NIC NSG keeps the inbound surface at zero regardless. `posture-from-vnet.sh` filters its Resource Graph query to data-plane resource types only (`microsoft.cognitiveservices/accounts`, `microsoft.documentdb/databaseaccounts`, `microsoft.search/searchservices`, `microsoft.storage/storageaccounts`, `microsoft.apimanagement/service`) — the new PIP is a `microsoft.network/publicIPAddresses` resource and is not flagged.
- **Production guidance is explicit.** For a fleet of jumpboxes, scale sets, or workers sharing one VNet, NAT Gateway is the right pattern. This stack is one operator VM.

## Consequences

- `posture-from-vnet.sh` returns to passing. The five-check smoke suite is 5/5 PASS again.
- One PIP per jumpbox; no shared egress and no fleet pattern. A future move to a multi-VM topology would require a follow-up ADR introducing NAT Gateway.
- **Brown-field rollout requires an out-of-band step.** AVM `compute/virtual-machine:0.22.1` re-emits `osProfile.customData` on every update; Azure rejects the change on an existing VM with `PropertyChangeNotAllowed: Changing property 'osProfile.customData' is not allowed.` Two options:
  - **One-time attach via Azure CLI:** `az network public-ip create -g <rg> -n <vm>-nic-ipconfig1-pip --sku Standard --allocation-method Static` followed by `az network nic ip-config update -g <rg> --nic-name <vm>-nic -n ipconfig1 --public-ip-address <vm>-nic-ipconfig1-pip`. Bicep stays the source of truth for the desired state; the live env converges on the next teardown + redeploy.
  - **Teardown the jumpbox** (`az vm delete` + `az network nic delete`) and re-run `azd provision` — the new VM picks up the PIP via Bicep.
- Bicep is the source of truth for green-field deploys; brown-field state may legitimately diverge until the next teardown.

## References

- [`MADR-0008`](./0008-jumpbox-bastion-validation-surface.md) — Jumpbox + Bastion as the validation surface (broader context).
- `infra/modules/demo-jumpbox.bicep` — `pipConfiguration` on the NIC ipConfigurations[0].
- `scripts/jumpbox-vm/posture-from-vnet.sh` — the smoke step that depends on outbound to `management.azure.com`.
- Default outbound access retirement: https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access
- NAT Gateway overview (for the fleet variant): https://learn.microsoft.com/en-us/azure/nat-gateway/nat-overview
