# 0007 — IaC stack: Bicep + Azure Developer CLI + Azure Verified Modules

- Status: accepted
- Date: 2026-05-19

## Context and Problem Statement

The deployment provisions ~25 Azure resources across two regions, with cross-region wiring (private endpoints, DNS zone links, RBAC role assignments) and post-provision hooks (smoke validation). The team needs a deployment stack that:

- Is **Microsoft-native** (no third-party CLI or runtime to take a dependency on).
- Captures **all** resources in source (no portal clicks; no `az` scripts that imperatively wire things up).
- Has **first-class private-networking modules** for the resource types we use (Foundry, AOAI, APIM, AI Search, Cosmos, Storage, VNet, PE).
- Supports **environment isolation** (multiple parallel azd envs against the same subscription).
- Surfaces **pre/post hooks** for validation, cleanup, etc.

## Considered Options

- **Terraform + AzureRM provider.** Strong primitive coverage and a mature ecosystem, but lags Azure on new private-networking surfaces (Foundry Account, AOAI PE variants). Third-party state backend or remote state to manage.
- **Raw ARM JSON / hand-rolled `az` scripts.** Maximum control, minimum velocity. No diff/preview semantics worth the name. Rejected.
- **Pulumi / CDK for Terraform.** Adds a language runtime layer for arguably no win on this codebase.
- **Bicep + Azure Verified Modules (AVM) + Azure Developer CLI (`azd`).** Microsoft-native, first-party module library tested by the product teams, AZD provides env management + hooks + `.azure/` state + `azd up/down/provision` lifecycle.

## Decision Outcome

Use **Bicep + AZD + AVM**.

- Subscription-scope deployment entry point: `infra/main.bicep` (`targetScope = 'subscription'`).
- Cross-region wiring sub-deployment: `infra/modules/wiring.bicep` (resource-group scope).
- AVM modules consumed via `br/public:avm/res/...` references — locked to specific versions (e.g. `0.5.3`, `0.22.1`).
- Project-local module wrappers under `infra/modules/` only where AVM is missing a feature or composes multiple primitives.
- `azure.yaml` declares the AZD project, including `hooks` (`postprovision-smoke.sh`, `postprovision-finalize.sh`).
- Environment state lives in `.azure/<env>/` (gitignored except for `.azure/<env>/config.json` if needed).

## Consequences

- Day-to-day operator commands stay simple: `azd env select fdev` → `azd provision` → `azd up`. No state file to babysit.
- AVM version bumps are explicit in source — predictable upgrades. Trade-off: must wait for AVM to expose a feature before consuming it natively; otherwise wrap with a project-local module.
- Bicep is the only language in the IaC layer. Composes with shell scripts for post-provision steps (kept small and side-effect-free).
- Multi-cloud is out of scope; this stack is Azure-only by design.

## References

- Azure Verified Modules: https://aka.ms/avm
- Azure Developer CLI: https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/
- `azure.yaml`, `infra/main.bicep` — the entry points.
- `../004_research.md` — AVM coverage analysis, native-fallback rationales, and pin table for the IaC.
