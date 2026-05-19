# mreg — private Foundry agent across regions

A demo IaC stack that runs an Azure AI Foundry agent privately in an AI landing zone (East US 2 or West Europe) and lets it call the newest Azure OpenAI models in Sweden Central. No public network access on either end.

The bridge is Azure API Management wired into Foundry as a Bring Your Own Model (BYOM) connection. Bicep + Azure Verified Modules, packaged for `azd up`.

## Where to read

| If you want to | Read |
|---|---|
| Two-minute overview of what this is and why | [`ARCHITECTURE.md`](./ARCHITECTURE.md) |
| Full technical narrative — topology, DNS, policies, identity | [`docs/001_architecture.md`](./docs/001_architecture.md) |
| Deploy and validate the stack | [`docs/002_quickstart.md`](./docs/002_quickstart.md) |
| Browse the Foundry portal through Bastion | [`docs/003_portal_tunnel.md`](./docs/003_portal_tunnel.md) |
| AVM coverage and design rationale | [`docs/004_research.md`](./docs/004_research.md) |
| What we decided and why (ADRs in MADR format) | [`docs/madr/`](./docs/madr/) |

## Repo layout

```
ARCHITECTURE.md           — top-level overview (start here)
azure.yaml                — azd manifest
docs/                     — long-form docs + ADRs
infra/                    — Bicep stack (AVM-first), contracts, policies
scripts/                  — operator + demo + on-jumpbox scripts
hooks/                    — azd lifecycle hooks (audit, smoke, finalize)
```

## Quick start

```bash
azd env new fdev
azd env set NAME_PREFIX mreg
azd up
./scripts/verify-bicep.sh    # confirm clean
bash scripts/demo/run-all.sh # three-stage end-to-end proof
```

Full instructions including BYO DNS / Log Analytics, verification, redeploy, and teardown live in [`docs/002_quickstart.md`](./docs/002_quickstart.md).
