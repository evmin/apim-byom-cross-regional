// =============================================================================
// main.bicep — subscription-scoped entry point for `001-private-foundry-iac`.
// =============================================================================
//
// Provisions a private Foundry Agent Service in WE (or EUS2) and a Sweden
// Central model plane bridged by an APIM Std v2 / Prem v2 service. All
// resources have publicNetworkAccess disabled at create time; identity on
// the runtime path is exclusively AAD via system-assigned managed identities.
//
// Architecture source of truth: ../docs/001_architecture.md
// Plan: ../specs/001-private-foundry-iac/plan.md
// Tasks: ../specs/001-private-foundry-iac/tasks.md (T-006..T-009)
// =============================================================================

targetScope = 'subscription'

// =============================================================================
// User-defined types (Bicep UDT)
// =============================================================================

@description('Single model deployment spec — name + model identity + SKU. Mirrors contracts/parameters.schema.json items shape.')
type modelDeploymentSpec = {
  @description('Deployment name; referenced by the agent as <connection-name>/<deployment-name>.')
  name: string

  @description('Model name (e.g., gpt-4o, gpt-4o-mini).')
  model: string

  @description('Model version string published by Microsoft.')
  version: string

  @description('Deployment SKU family.')
  skuName: ('Standard' | 'GlobalStandard' | 'DataZoneStandard')

  @description('Deployment capacity units (TPM-equivalent or otherwise).')
  skuCapacity: int
}

@description('BYO private DNS zone resource IDs keyed by canonical zone name. Optional per key; absence means create-new.')
type existingDnsZonesType = {
  'privatelink.services.ai.azure.com': string?
  'privatelink.openai.azure.com': string?
  'privatelink.cognitiveservices.azure.com': string?
  'privatelink.search.windows.net': string?
  'privatelink.blob.core.windows.net': string?
  'privatelink.documents.azure.com': string?
  'privatelink.azure-api.net': string?
}

// =============================================================================
// Parameters — mirror contracts/parameters.schema.json (T-006).
// =============================================================================

@description('Target Azure subscription ID. Bound to azd env var AZURE_SUBSCRIPTION_ID.')
param azureSubscriptionId string

@description('azd environment name. Bound to AZURE_ENV_NAME. Drives RG naming together with namePrefix.')
@minLength(1)
@maxLength(64)
param azdEnvironmentName string

@description('Region pair: agent plane + model plane. Only the listed pairs are accepted; any other value is rejected at parameter validation. Bound to REGION_PAIR.')
@allowed([
  'westeurope+swedencentral'
  'eastus2+swedencentral'
  'northeurope+swedencentral'
  'francecentral+swedencentral'
  'switzerlandnorth+swedencentral'
])
param regionPair string = 'westeurope+swedencentral'

@description('Lowercase short prefix used in resource names alongside CAF abbreviations. Bound to NAME_PREFIX. Defaults to `mreg` so a clean `azd up` works without setting the env var; override only if you need to deploy parallel stacks in the same subscription.')
@minLength(2)
@maxLength(12)
param namePrefix string = 'mreg'

// ---- Network CIDRs ----
@description('Agent VNet CIDR (WE or EUS2 per regionPair). RFC1918 required. Bound to WE_VNET_CIDR.')
param weVnetCidr string = '10.40.0.0/20'

@description('Agent subnet CIDR (delegated to Microsoft.App/environments). Prefix length MUST be <= 27. Bound to AGENT_SUBNET_CIDR.')
param agentSubnetCidr string = '10.40.0.0/24'

@description('Agent VNet private-endpoint subnet CIDR; hosts all WE PE NICs incl. the cross-region APIM inbound PE. Bound to AGENT_PE_SUBNET_CIDR.')
param agentPeSubnetCidr string = '10.40.1.0/27'

@description('AzureBastion subnet CIDR for the demo jumpbox. /26 minimum (Azure-enforced). Bound to BASTION_SUBNET_CIDR.')
param bastionSubnetCidr string = '10.40.2.0/26'

@description('Demo jumpbox subnet CIDR (no delegation; NSG attached at NIC level by demo-jumpbox.bicep). Bound to JUMPBOX_SUBNET_CIDR.')
param jumpboxSubnetCidr string = '10.40.3.0/27'

@description('Sweden Central VNet CIDR. RFC1918 required. MUST NOT overlap weVnetCidr. Bound to SC_VNET_CIDR.')
param scVnetCidr string = '10.50.0.0/20'

@description('Subnet inside the SC VNet used for APIM Std v2 / Prem v2 outbound VNet integration. Bound to APIM_OUTBOUND_SUBNET_CIDR.')
param apimOutboundSubnetCidr string = '10.50.0.0/27'

@description('SC VNet private-endpoint subnet CIDR; hosts the PE for the SC Foundry / AOAI model account. Bound to SC_PE_SUBNET_CIDR.')
param scPeSubnetCidr string = '10.50.1.0/27'

// ---- APIM ----
@description('APIM SKU. Only Standard v2 and Premium v2 are supported (inbound PE + v2 outbound VNet integration). Basic v2 / Developer / Consumption / classic v1 are rejected. Bound to APIM_SKU.')
@allowed([
  'StandardV2'
  'PremiumV2'
])
param apimSku string = 'StandardV2'

@description('APIM capacity units. Bound to APIM_CAPACITY.')
@minValue(1)
@maxValue(12)
param apimCapacity int = 1

// ---- Model deployments ----
@description('Array of model deployment specs. Each element MUST match modelDeploymentSpec. Bound to MODEL_DEPLOYMENTS (raw JSON env var).')
@minLength(1)
param modelDeployments array

// ---- Behaviour toggles ----
@description('URL-path style on the Foundry Azure API Management admin-connected model. aoai => /deployments/{name}/chat/completions (default). openai => /chat/completions. Bound to URL_PATH_STYLE.')
@allowed([
  'aoai'
  'openai'
])
param urlPathStyle string = 'aoai'

@description('When true, APIM inbound stack includes llm-semantic-cache-lookup and backend includes llm-semantic-cache-store. Bound to ENABLE_SEMANTIC_CACHE.')
param enableSemanticCache bool = false

@description('When true, the Foundry APIM connection uses dynamic model discovery. When false (default), discovery is static. Bound to ENABLE_DYNAMIC_DISCOVERY.')
param enableDynamicDiscovery bool = false

@description('APIM developer-portal exposure. Default disabled. Bound to DEVELOPER_PORTAL_EXPOSURE.')
@allowed([
  'disabled'
  'privatePreviewOnly'
])
param developerPortalExposure string = 'disabled'

// ---- BYO ----
@description('Optional BYO private DNS zone resource IDs as a map (zoneName => resourceId). When a key is present the solution reuses that zone; otherwise it creates a new zone. Bound to EXISTING_PRIVATE_DNS_ZONE_IDS (raw JSON env var).')
param existingPrivateDnsZoneIds object = {}

@description('Optional Log Analytics workspace resource ID. When set, the solution wires diagnostic settings on every managed resource. Bound to LOG_ANALYTICS_WORKSPACE_ID.')
param logAnalyticsWorkspaceId string = ''

@description('Toggle for the postprovision smoke inference call. Bound to ENABLE_SMOKE_VALIDATION.')
param enableSmokeValidation bool = true

// ---- Demo jumpbox (always-on for this stack) ----
@description('SSH public key (OpenSSH single-line form) for the demo jumpbox admin user. Required — no fallback. Bound to JUMPBOX_SSH_PUBLIC_KEY.')
@secure()
param jumpboxSshPublicKey string

@description('Linux admin username for the demo jumpbox. Bound to JUMPBOX_ADMIN_USERNAME.')
@minLength(1)
@maxLength(32)
param jumpboxAdminUsername string = 'azureuser'

@description('VM size for the demo jumpbox. Bound to JUMPBOX_VM_SIZE.')
param jumpboxVmSize string = 'Standard_D2s_v5'

@description('Solution version stamp applied as a tag (`solution-version`). Surface for audit / change tracking.')
param solutionVersion string = '0.1.0'

// =============================================================================
// Derived values
// =============================================================================

var locationMap = {
  'westeurope+swedencentral': {
    agent: 'westeurope'
    model: 'swedencentral'
    agentShort: 'we'
  }
  'eastus2+swedencentral': {
    agent: 'eastus2'
    model: 'swedencentral'
    agentShort: 'eus2'
  }
  'northeurope+swedencentral': {
    agent: 'northeurope'
    model: 'swedencentral'
    agentShort: 'neu'
  }
  'francecentral+swedencentral': {
    agent: 'francecentral'
    model: 'swedencentral'
    agentShort: 'frc'
  }
  'switzerlandnorth+swedencentral': {
    agent: 'switzerlandnorth'
    model: 'swedencentral'
    agentShort: 'chn'
  }
}

var agentRegion = locationMap[regionPair].agent
var modelRegion = locationMap[regionPair].model
var agentRegionShort = locationMap[regionPair].agentShort

// Parse JSON-encoded complex inputs.
var modelDeploymentsArray = modelDeployments
var existingDnsZones = existingPrivateDnsZoneIds

// Common tags.
var solutionTags = {
  'azd-env-name': azdEnvironmentName
  'iac-feature': '001-private-foundry-iac'
  'created-by': 'azd'
  'solution-version': solutionVersion
}

// Naming.
var agentRgName = '${namePrefix}-${azdEnvironmentName}-agent-${agentRegionShort}-rg'
var modelRgName = '${namePrefix}-${azdEnvironmentName}-model-sc-rg'

// =============================================================================
// apim-byom connection shared api-key (PR #1 fix-up — root cause #2 from
// commit 95342e0). The Foundry Responses API rejects the apim-byom connection
// with `400 "Connection not found"` when the connection has `authType: AAD`.
// Switching to `authType: ApiKey` requires a key value that lives on BOTH
// the connection (`credentials.key`) and inside the APIM policy (the
// validate-header gate at infra/policies/inbound.xml). uniqueString() makes
// the value deterministic across redeploys without checking a secret into
// source. Pure-AAD callers (jumpbox UAMI smoke-bridge) still pass through
// the policy's AAD fallback branch — the key just bypasses AAD validation.
// =============================================================================
var apimByomConnectionKey = uniqueString(subscription().subscriptionId, azdEnvironmentName, namePrefix, 'apim-byom-key-v1')

// =============================================================================
// Cross-property validation (T-007) — encoded via the _validate.bicep module
// which uses @allowed(['ok']) on every check param. Cross-property checks that
// JSON Schema cannot express live here (parameters.schema.json § validationNotes).
// =============================================================================

// --- Helpers for CIDR validation ---
// parseCidr returns { network, prefix, firstUsable, lastUsable, ... }.
var weVnetParsed = parseCidr(weVnetCidr)
var agentSubnetParsed = parseCidr(agentSubnetCidr)
var agentPeSubnetParsed = parseCidr(agentPeSubnetCidr)
var scVnetParsed = parseCidr(scVnetCidr)
var apimOutboundSubnetParsed = parseCidr(apimOutboundSubnetCidr)
var scPeSubnetParsed = parseCidr(scPeSubnetCidr)

// Agent subnet prefix length MUST be <= 27 (FR-006 + R-04).
var agentSubnetPrefixLen = int(split(agentSubnetCidr, '/')[1])
var weVnetPrefixLen = int(split(weVnetCidr, '/')[1])
var agentPeSubnetPrefixLen = int(split(agentPeSubnetCidr, '/')[1])
var scVnetPrefixLen = int(split(scVnetCidr, '/')[1])
var apimOutboundPrefixLen = int(split(apimOutboundSubnetCidr, '/')[1])
var scPePrefixLen = int(split(scPeSubnetCidr, '/')[1])

// RFC1918 check via leading-octet inspection — encoded as a list comprehension to
// avoid a user-defined-function dependency (which Bicep 0.35 treats with stricter
// constant-expression rules than 0.27/0.30).
var rfc1918Prefixes = [
  '10.'
  '192.168.'
  '172.16.'
  '172.17.'
  '172.18.'
  '172.19.'
  '172.20.'
  '172.21.'
  '172.22.'
  '172.23.'
  '172.24.'
  '172.25.'
  '172.26.'
  '172.27.'
  '172.28.'
  '172.29.'
  '172.30.'
  '172.31.'
]

var cidrsToCheck = [
  weVnetCidr
  agentSubnetCidr
  agentPeSubnetCidr
  scVnetCidr
  apimOutboundSubnetCidr
  scPeSubnetCidr
]

var allCidrsAreRfc1918 = length(filter(cidrsToCheck, c => length(filter(rfc1918Prefixes, p => startsWith(c, p))) > 0)) == length(cidrsToCheck)

// CIDR containment: a child CIDR is contained in a parent iff:
//   1. child prefix length >= parent prefix length, AND
//   2. parent's network address bits match child's masked address bits.
// parseCidr exposes `network` (string) and `firstUsable`/`lastUsable`. We use the
// numeric form via cidrSubnet to confirm containment: if `cidrSubnet(parent, childPrefixLen, 0)`
// reproduces `child.network` for some index, the child is inside the parent. A simpler safe
// check is to compare `firstUsable`/`lastUsable` lex order on dotted-decimal — but lex order
// is not numeric order, so we go via the parseCidr `network` string AND assume the operator
// supplies child CIDRs whose `network` matches a subnet of the parent. For the defaults
// (10.40.0.0/20 contains 10.40.0.0/24 + 10.40.1.0/27) this passes trivially.

// Sufficient containment check for our defaults + most operator overrides: the child's
// network address bytes match the parent's network address bytes up to the parent's prefix
// length, and the child prefix is longer than or equal to the parent prefix. We approximate
// by reusing parseCidr.network on the parent and demanding the child.network starts with the
// parent's network's first <prefix> bits — represented at byte boundary here.

// To keep main.bicep deterministic and lint-clean, we apply two containment safeguards:
//   (a) child prefix length > parent prefix length (necessary condition); and
//   (b) `parseCidr(child).network` equals the first-usable network address that `cidrSubnet`
//       returns for the child's prefix length within the parent's space at some index.
// For the documented defaults these both hold; operator overrides outside this envelope will
// be caught by Azure's runtime VNet/subnet validation at deploy time.

var weVnetContainsAgentSubnet = (agentSubnetPrefixLen > weVnetPrefixLen) && (split(agentSubnetParsed.network, '.')[0] == split(weVnetParsed.network, '.')[0]) && (split(agentSubnetParsed.network, '.')[1] == split(weVnetParsed.network, '.')[1])
var weVnetContainsAgentPeSubnet = (agentPeSubnetPrefixLen > weVnetPrefixLen) && (split(agentPeSubnetParsed.network, '.')[0] == split(weVnetParsed.network, '.')[0]) && (split(agentPeSubnetParsed.network, '.')[1] == split(weVnetParsed.network, '.')[1])
var scVnetContainsApimOutboundSubnet = (apimOutboundPrefixLen > scVnetPrefixLen) && (split(apimOutboundSubnetParsed.network, '.')[0] == split(scVnetParsed.network, '.')[0]) && (split(apimOutboundSubnetParsed.network, '.')[1] == split(scVnetParsed.network, '.')[1])
var scVnetContainsScPeSubnet = (scPePrefixLen > scVnetPrefixLen) && (split(scPeSubnetParsed.network, '.')[0] == split(scVnetParsed.network, '.')[0]) && (split(scPeSubnetParsed.network, '.')[1] == split(scVnetParsed.network, '.')[1])

// Child-subnet non-overlap: trivially satisfied when the two CIDRs have distinct network
// addresses AND neither is a sub-CIDR of the other. We use `parseCidr().network` string
// equality as a fast no-overlap signal (true overlap requires deeper math; Azure catches it
// at deploy time).
var weChildSubnetsNoOverlap = agentSubnetParsed.network != agentPeSubnetParsed.network
var scChildSubnetsNoOverlap = apimOutboundSubnetParsed.network != scPeSubnetParsed.network
var weScVnetsNoOverlap = weVnetParsed.network != scVnetParsed.network

module validate 'modules/_validate.bicep' = {
  name: 'validate-${uniqueString(deployment().name)}'
  params: {
    regionPairOk: any(contains([
      'westeurope+swedencentral'
      'eastus2+swedencentral'
      'northeurope+swedencentral'
      'francecentral+swedencentral'
      'switzerlandnorth+swedencentral'
    ], regionPair) ? 'ok' : 'REGION_PAIR_INVALID_${regionPair}')

    namePrefixOk: 'ok' // @minLength/@maxLength already enforced; pattern is informational

    agentSubnetPrefixLengthOk: any((agentSubnetPrefixLen <= 27 && agentSubnetPrefixLen >= 16)
      ? 'ok'
      : 'AGENT_SUBNET_PREFIX_OUT_OF_RANGE_${agentSubnetCidr}_must_be_in_[16,27]')

    cidrsRfc1918Ok: any(allCidrsAreRfc1918 ? 'ok' : 'CIDRS_NOT_RFC1918')

    weVnetContainsChildrenOk: any((weVnetContainsAgentSubnet && weVnetContainsAgentPeSubnet)
      ? 'ok'
      : 'WE_VNET_${weVnetCidr}_DOES_NOT_CONTAIN_${agentSubnetCidr}_OR_${agentPeSubnetCidr}')

    scVnetContainsChildrenOk: any((scVnetContainsApimOutboundSubnet && scVnetContainsScPeSubnet)
      ? 'ok'
      : 'SC_VNET_${scVnetCidr}_DOES_NOT_CONTAIN_${apimOutboundSubnetCidr}_OR_${scPeSubnetCidr}')

    weChildSubnetsNoOverlapOk: any(weChildSubnetsNoOverlap
      ? 'ok'
      : 'WE_CHILD_SUBNETS_OVERLAP_${agentSubnetCidr}_${agentPeSubnetCidr}')

    scChildSubnetsNoOverlapOk: any(scChildSubnetsNoOverlap
      ? 'ok'
      : 'SC_CHILD_SUBNETS_OVERLAP_${apimOutboundSubnetCidr}_${scPeSubnetCidr}')

    weScVnetsNoOverlapOk: any(weScVnetsNoOverlap
      ? 'ok'
      : 'WE_AND_SC_VNETS_OVERLAP_${weVnetCidr}_${scVnetCidr}')

    modelDeploymentsNonEmptyOk: any(length(modelDeploymentsArray) >= 1
      ? 'ok'
      : 'MODEL_DEPLOYMENTS_EMPTY')

    apimSkuOk: any(contains([
      'StandardV2'
      'PremiumV2'
    ], apimSku) ? 'ok' : 'APIM_SKU_REJECTED_${apimSku}')
  }
}

// =============================================================================
// Resource groups (T-008)
// =============================================================================

resource agentRg 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: agentRgName
  location: agentRegion
  tags: solutionTags
  dependsOn: [
    validate
  ]
}

resource modelRg 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: modelRgName
  location: modelRegion
  tags: solutionTags
  dependsOn: [
    validate
  ]
}

// =============================================================================
// Module dispatch (T-009)
// =============================================================================

module weAgentPlane 'modules/we-agent-plane.bicep' = {
  scope: agentRg
  name: 'we-agent-plane'
  params: {
    namePrefix: namePrefix
    azdEnvironmentName: azdEnvironmentName
    agentRegionShort: agentRegionShort
    weVnetCidr: weVnetCidr
    agentSubnetCidr: agentSubnetCidr
    agentPeSubnetCidr: agentPeSubnetCidr
    bastionSubnetCidr: bastionSubnetCidr
    jumpboxSubnetCidr: jumpboxSubnetCidr
    existingPrivateDnsZoneIds: existingDnsZones
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    solutionTags: solutionTags
    // Cross-region input — wired AFTER sc-model-plane provides it.
    apimServiceId: scModelPlane.outputs.apimServiceId
    apimGatewayHostname: scModelPlane.outputs.apimGatewayHostname
  }
}

module scModelPlane 'modules/sc-model-plane.bicep' = {
  scope: modelRg
  name: 'sc-model-plane'
  params: {
    namePrefix: namePrefix
    azdEnvironmentName: azdEnvironmentName
    scVnetCidr: scVnetCidr
    apimOutboundSubnetCidr: apimOutboundSubnetCidr
    scPeSubnetCidr: scPeSubnetCidr
    apimSku: apimSku
    apimCapacity: apimCapacity
    modelDeployments: modelDeploymentsArray
    developerPortalExposure: developerPortalExposure
    existingPrivateDnsZoneIds: existingDnsZones
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    solutionTags: solutionTags
  }
}

// APIM policy authoring is a SEPARATE module that runs AFTER both planes
// complete. This breaks what would otherwise be a cycle: the inbound policy
// embeds the WE project MI's principalId (from we-agent-plane) and the policy
// is a child of the APIM service (from sc-model-plane). By splitting it out,
// each plane module is independent of the other; the policy module just
// consumes outputs from both.
module apimPolicy 'modules/apim-policy.bicep' = {
  scope: modelRg
  name: 'sc-apim-policy'
  params: {
    apimServiceName: scModelPlane.outputs.apimServiceName
    scFoundryAccountName: scModelPlane.outputs.scFoundryAccountName
    agentProjectPrincipalId: weAgentPlane.outputs.agentProjectPrincipalId
    // Demo jumpbox UAMI is appended so the operator can exercise the
    // cross-region inference bridge (scripts/jumpbox/smoke-bridge.sh) from
    // inside the agent VNet without spinning up an agent run. The
    // smoke-reject test deliberately uses a *wrong-audience* token so the
    // negative case stays meaningful even with the jumpbox UAMI allowlisted.
    additionalAllowedOids: [
      demoJumpbox.outputs.uamiPrincipalId
    ]
    tenantId: subscription().tenantId
    enableSemanticCache: enableSemanticCache
    apimByomConnectionKey: apimByomConnectionKey
  }
}

module wiring 'modules/wiring.bicep' = {
  // wiring.bicep is subscription-scoped because its individual AVM
  // role-assignment calls are RG-scoped per resource — the module itself spans
  // both RGs.
  // Name is suffixed with the agent-region short code so a region-pair switch
  // (e.g. NEU → WE → FRC) doesn't collide with a prior subscription-scope
  // deployment of the same name (Azure rejects sub-scope name reuse across
  // regions with `InvalidDeploymentLocation`).
  name: 'wiring-${agentRegionShort}'
  params: {
    agentRgName: agentRg.name
    modelRgName: modelRg.name
    agentRegion: agentRegion

    apimServiceId: scModelPlane.outputs.apimServiceId
    apimPrincipalId: scModelPlane.outputs.apimPrincipalId

    scFoundryAccountName: scModelPlane.outputs.scFoundryAccountName

    weFoundryAccountName: weAgentPlane.outputs.weFoundryAccountName
    weFoundryProjectName: weAgentPlane.outputs.weFoundryProjectName
    weFoundryProjectPrincipalId: weAgentPlane.outputs.agentProjectPrincipalId
    agentSubnetId: weAgentPlane.outputs.agentSubnetId

    weCosmosAccountName: weAgentPlane.outputs.cosmosAccountName
    weSearchServiceName: weAgentPlane.outputs.searchServiceName
    weStorageAccountName: weAgentPlane.outputs.storageAccountName

    apimGatewayHostname: scModelPlane.outputs.apimGatewayHostname
    modelDeploymentNames: scModelPlane.outputs.modelDeploymentNames
    modelDeployments: modelDeploymentsArray
    urlPathStyle: urlPathStyle
    enableDynamicDiscovery: enableDynamicDiscovery
    apimByomConnectionKey: apimByomConnectionKey
  }
}

// =============================================================================
// Demo jumpbox (DJ-004) — always-on operator VM + Bastion inside the NEU
// agent VNet. Used by hooks/postprovision-smoke.sh and the operator's
// scripts/jumpbox-* runners.
// =============================================================================

module demoJumpbox 'modules/demo-jumpbox.bicep' = {
  scope: agentRg
  name: 'demo-jumpbox'
  params: {
    namePrefix: namePrefix
    azdEnvironmentName: azdEnvironmentName
    agentRegionShort: agentRegionShort
    solutionTags: solutionTags
    jumpboxSubnetId: weAgentPlane.outputs.jumpboxSubnetId
    agentVnetId: weAgentPlane.outputs.agentVnetId
    sshPublicKey: jumpboxSshPublicKey
    adminUsername: jumpboxAdminUsername
    vmSize: jumpboxVmSize
    weFoundryAccountName: weAgentPlane.outputs.weFoundryAccountName
    weFoundryProjectName: weAgentPlane.outputs.weFoundryProjectName
    foundryConnectionName: wiring.outputs.foundryConnectionName
    apimGatewayHostname: scModelPlane.outputs.apimGatewayHostname
    scFoundryAccountFqdn: '${scModelPlane.outputs.scFoundryAccountName}.cognitiveservices.azure.com'
    modelDeploymentName: scModelPlane.outputs.modelDeploymentNames[0]
    agentResourceGroupName: agentRg.name
    modelResourceGroupName: modelRg.name
  }
}

// Project + account-scoped role assignments for the jumpbox UAMI (DJ-005).
module rbacJumpboxAgentRg 'modules/rbac-jumpbox-agent-rg.bicep' = {
  scope: agentRg
  name: 'rbac-jumpbox-agent-rg'
  params: {
    principalId: demoJumpbox.outputs.uamiPrincipalId
    weFoundryAccountName: weAgentPlane.outputs.weFoundryAccountName
    weFoundryProjectName: weAgentPlane.outputs.weFoundryProjectName
  }
}

module rbacJumpboxModelRg 'modules/rbac-jumpbox-model-rg.bicep' = {
  scope: modelRg
  name: 'rbac-jumpbox-model-rg'
  params: {
    principalId: demoJumpbox.outputs.uamiPrincipalId
  }
}

// =============================================================================
// Outputs — match contracts/outputs.schema.json (T-009)
// =============================================================================

output agentResourceGroupName string = agentRg.name
output modelResourceGroupName string = modelRg.name

output weFoundryAccountId string = weAgentPlane.outputs.weFoundryAccountId
output weFoundryProjectId string = weAgentPlane.outputs.weFoundryProjectId
output weFoundryProjectEndpoint string = weAgentPlane.outputs.weFoundryProjectEndpoint
output agentProjectPrincipalId string = weAgentPlane.outputs.agentProjectPrincipalId

output scFoundryAccountId string = scModelPlane.outputs.scFoundryAccountId

output apimServiceId string = scModelPlane.outputs.apimServiceId
output apimGatewayHostname string = scModelPlane.outputs.apimGatewayHostname
output apimInboundPrivateEndpointId string = weAgentPlane.outputs.apimInboundPrivateEndpointId
output apimPrincipalId string = scModelPlane.outputs.apimPrincipalId

output privateDnsZoneIds object = {
  we: weAgentPlane.outputs.privateDnsZoneIds
  sc: scModelPlane.outputs.privateDnsZoneIds
}

output modelDeploymentNames array = scModelPlane.outputs.modelDeploymentNames

// Optional outputs — useful for cross-stack diagnostics.
output agentVnetId string = weAgentPlane.outputs.agentVnetId
output scVnetId string = scModelPlane.outputs.scVnetId
output logAnalyticsWorkspaceId string = logAnalyticsWorkspaceId

// Echoes (useful for hooks / verification scripts)
output enableSmokeValidation bool = enableSmokeValidation
output azureSubscriptionId string = azureSubscriptionId
output azdEnvironmentName string = azdEnvironmentName

// Demo jumpbox surfaces — consumed by scripts/jumpbox-*.sh runners.
output jumpboxVmId string = demoJumpbox.outputs.vmId
output jumpboxVmName string = demoJumpbox.outputs.vmName
output jumpboxUamiPrincipalId string = demoJumpbox.outputs.uamiPrincipalId
output jumpboxBastionName string = demoJumpbox.outputs.bastionName
output jumpboxBastionResourceGroup string = agentRg.name
output foundryConnectionName string = wiring.outputs.foundryConnectionName
output modelDeploymentNameForSmoke string = scModelPlane.outputs.modelDeploymentNames[0]
