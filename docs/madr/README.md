# Architecture Decision Records

This folder collects the architecture decisions for this project in [MADR](https://adr.github.io/madr/) (Markdown ADR) format. See [`0001`](./0001-record-architecture-decisions-with-madr.md) for the meta-decision.

## Index

| ID | Title | Status |
|---:|---|---|
| [0001](./0001-record-architecture-decisions-with-madr.md) | Record architecture decisions with MADR | accepted |
| [0002](./0002-bridge-cross-region-private-foundry-via-apim-byom.md) | Bridge cross-region private Foundry via APIM BYOM | accepted |
| [0003](./0003-apim-std-v2-with-cross-region-inbound-pe.md) | APIM Standard v2 with cross-region inbound PE in the agent VNet | accepted |
| [0004](./0004-apim-dual-auth-policy-with-aad-fallthrough.md) | APIM dual-auth policy: api-key + AAD fall-through | accepted |
| [0005](./0005-foundry-connection-byom-wiring.md) | Foundry BYOM connection wiring: `/openai` target + `authType: ApiKey` | accepted |
| [0006](./0006-v2-responses-api-canonical-agent-path.md) | v2 PromptAgent + Responses API as the canonical agent path | accepted |
| [0007](./0007-bicep-azd-avm-iac-stack.md) | IaC stack: Bicep + Azure Developer CLI + Azure Verified Modules | accepted |
| [0008](./0008-jumpbox-bastion-validation-surface.md) | Jumpbox + Bastion as the validation surface | accepted |
| [0009](./0009-jumpbox-outbound-egress-via-nic-pip.md) | Jumpbox outbound egress via a NIC public IP (demo posture) | accepted |

## Adding a new ADR

1. Pick the next free 4-digit ID.
2. Copy the structure of an existing ADR (Context and Problem Statement, Considered Options, Decision Outcome, Consequences, References).
3. Keep it short. The decision and its reason should fit on one screen.
4. When superseding an existing decision, set the old one's status to `superseded by 00NN` and link from the new one.

For the full MADR template, see https://adr.github.io/madr/.
