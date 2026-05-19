// Cross-property validation helper module for `main.bicep`.

// Bicep does not (yet, on stable) expose a free-form `error` function; the
// idiom we use here is `@allowed(['ok'])` on every check parameter. Callers
// pass either 'ok' (when the check passes) or a descriptive failure string
// (when it fails); the `@allowed` decorator then aborts the deployment with
// the failing string in the error message, which is far more useful than a
// generic "deployment failed".

// This module declares NO resources — it exists only to surface validation
// failures at `azd provision --preview` time, before any resource is queued.

// Implements parameters.schema.json § $defs.validationNotes.

targetScope = 'subscription'

@description('OK if regionPair maps to one of the two approved pairs.')
@allowed(['ok'])
param regionPairOk string

@description('OK if namePrefix matches its lowercase pattern.')
@allowed(['ok'])
param namePrefixOk string

@description('OK if agent subnet prefix length is <= 27.')
@allowed(['ok'])
param agentSubnetPrefixLengthOk string

@description('OK if every CIDR is RFC1918 (10/8 | 172.16/12 | 192.168/16).')
@allowed(['ok'])
param cidrsRfc1918Ok string

@description('OK if WE VNet CIDR contains both child subnets.')
@allowed(['ok'])
param weVnetContainsChildrenOk string

@description('OK if SC VNet CIDR contains both child subnets.')
@allowed(['ok'])
param scVnetContainsChildrenOk string

@description('OK if agent subnet and agent PE subnet do not overlap.')
@allowed(['ok'])
param weChildSubnetsNoOverlapOk string

@description('OK if APIM-outbound and SC PE subnets do not overlap.')
@allowed(['ok'])
param scChildSubnetsNoOverlapOk string

@description('OK if WE and SC VNet CIDRs do not overlap.')
@allowed(['ok'])
param weScVnetsNoOverlapOk string

@description('OK if modelDeployments array has at least one entry.')
@allowed(['ok'])
param modelDeploymentsNonEmptyOk string

@description('OK if APIM SKU is StandardV2 or PremiumV2 (defence in depth — main.bicep also has @allowed).')
@allowed(['ok'])
param apimSkuOk string

// No resources — this module is pure validation. The `output validated = ...` is
// just a sentinel so callers see a deterministic success marker in deployment logs.
// Emitting each param in `checks` keeps the no-unused-params linter quiet AND
// shows up in deployment logs (handy for debugging dry-run output).
output validated string = 'all-checks-passed'
output checks object = {
  regionPairOk: regionPairOk
  namePrefixOk: namePrefixOk
  agentSubnetPrefixLengthOk: agentSubnetPrefixLengthOk
  cidrsRfc1918Ok: cidrsRfc1918Ok
  weVnetContainsChildrenOk: weVnetContainsChildrenOk
  scVnetContainsChildrenOk: scVnetContainsChildrenOk
  weChildSubnetsNoOverlapOk: weChildSubnetsNoOverlapOk
  scChildSubnetsNoOverlapOk: scChildSubnetsNoOverlapOk
  weScVnetsNoOverlapOk: weScVnetsNoOverlapOk
  modelDeploymentsNonEmptyOk: modelDeploymentsNonEmptyOk
  apimSkuOk: apimSkuOk
}
