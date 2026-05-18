// =============================================================================
// main.bicepparam — typed parameter resolution for main.bicep.
// =============================================================================
//
// Bound to azd environment variables via readEnvironmentVariable().
// JSON values (MODEL_DEPLOYMENTS, EXISTING_PRIVATE_DNS_ZONE_IDS) are parsed
// with json(); numeric / boolean values are coerced via int() / bool().
//
// Defaults here MUST match contracts/parameters.schema.json.
// =============================================================================

using './main.bicep'

param azureSubscriptionId = readEnvironmentVariable('AZURE_SUBSCRIPTION_ID')
param azdEnvironmentName = readEnvironmentVariable('AZURE_ENV_NAME')

param regionPair = readEnvironmentVariable('REGION_PAIR', 'westeurope+swedencentral')
param namePrefix = readEnvironmentVariable('NAME_PREFIX', 'mreg')

param weVnetCidr = readEnvironmentVariable('WE_VNET_CIDR', '10.40.0.0/20')
param agentSubnetCidr = readEnvironmentVariable('AGENT_SUBNET_CIDR', '10.40.0.0/24')
param agentPeSubnetCidr = readEnvironmentVariable('AGENT_PE_SUBNET_CIDR', '10.40.1.0/27')
param bastionSubnetCidr = readEnvironmentVariable('BASTION_SUBNET_CIDR', '10.40.2.0/26')
param jumpboxSubnetCidr = readEnvironmentVariable('JUMPBOX_SUBNET_CIDR', '10.40.3.0/27')

param scVnetCidr = readEnvironmentVariable('SC_VNET_CIDR', '10.50.0.0/20')
param apimOutboundSubnetCidr = readEnvironmentVariable('APIM_OUTBOUND_SUBNET_CIDR', '10.50.0.0/27')
param scPeSubnetCidr = readEnvironmentVariable('SC_PE_SUBNET_CIDR', '10.50.1.0/27')

param apimSku = readEnvironmentVariable('APIM_SKU', 'StandardV2')
param apimCapacity = int(readEnvironmentVariable('APIM_CAPACITY', '1'))

param modelDeployments = json(readEnvironmentVariable('MODEL_DEPLOYMENTS'))

param urlPathStyle = readEnvironmentVariable('URL_PATH_STYLE', 'aoai')
param enableSemanticCache = bool(readEnvironmentVariable('ENABLE_SEMANTIC_CACHE', 'false'))
param enableDynamicDiscovery = bool(readEnvironmentVariable('ENABLE_DYNAMIC_DISCOVERY', 'false'))
param developerPortalExposure = readEnvironmentVariable('DEVELOPER_PORTAL_EXPOSURE', 'disabled')

param existingPrivateDnsZoneIds = json(readEnvironmentVariable('EXISTING_PRIVATE_DNS_ZONE_IDS', '{}'))

param logAnalyticsWorkspaceId = readEnvironmentVariable('LOG_ANALYTICS_WORKSPACE_ID', '')
param enableSmokeValidation = bool(readEnvironmentVariable('ENABLE_SMOKE_VALIDATION', 'true'))

// Demo jumpbox — always-on. JUMPBOX_SSH_PUBLIC_KEY is REQUIRED at deploy time
// (no readEnvironmentVariable default — Bicep fails with a clear error if the
// env var is unset, which is the intended behaviour for this demo stack).
param jumpboxSshPublicKey = readEnvironmentVariable('JUMPBOX_SSH_PUBLIC_KEY')
param jumpboxAdminUsername = readEnvironmentVariable('JUMPBOX_ADMIN_USERNAME', 'azureuser')
param jumpboxVmSize = readEnvironmentVariable('JUMPBOX_VM_SIZE', 'Standard_D2s_v5')
