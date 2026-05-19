// =============================================================================
// apim-policy.bicep — APIM service-policy authoring (resource-group scope).
// =============================================================================
//
// Split out of sc-model-plane.bicep to break the WE↔SC module cycle: the
// inbound policy embeds the WE Foundry project MI's principalId (a we-agent-plane
// output), and the policy is a child of the APIM service (a sc-model-plane
// output). By authoring the policy in its own module dispatched from main.bicep
// AFTER both planes complete, each plane stays independent of the other.
//
// Implements T-027: assembles the policy XML via loadTextContent() from the four
// .xml fragments under ../policies/, in the order:
//   inbound: validate-azure-ad-token -> (optional llm-semantic-cache-lookup)
//            -> set-backend-service -> authentication-managed-identity
//            -> set-header Authorization
//   backend: (optional llm-semantic-cache-store) -> forward-request
// =============================================================================

targetScope = 'resourceGroup'

@description('APIM service name (parent of the policy child resource).')
param apimServiceName string

@description('SC Foundry / AOAI account name — used to compose the backend URL.')
param scFoundryAccountName string

@description('WE Foundry project system-assigned MI principalId. Embedded in validate-azure-ad-token as the primary accepted oid.')
param agentProjectPrincipalId string

@description('Additional oids to embed in the validate-azure-ad-token allowlist (e.g. demo jumpbox UAMI). Empty entries are filtered.')
param additionalAllowedOids array = []

@description('AAD tenant ID for validate-azure-ad-token.')
param tenantId string

@description('When true, semantic-cache lookup/store fragments are spliced into the assembled policy.')
param enableSemanticCache bool

@secure()
@description('Shared api-key value installed as a secret APIM named value (`apim-byom-key`). The inbound policy compares the request `api-key` header against `{{apim-byom-key}}` and skips AAD validation when it matches. This unblocks Foundry ApiKey-typed connections (v2 Responses API) while preserving the AAD-only path for direct MI callers.')
param apimByomConnectionKey string

// Existing parent.
resource apimExisting 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimServiceName
}

// APIM named value carrying the apim-byom shared api-key. Stored with
// `secret: true` so the value is not returned by listValue() and is masked
// in the portal. The policy references it via the standard `{{name}}` token
// which APIM resolves at policy execution time (NOT at Bicep deploy time —
// our Bicep replace() chain does not touch `{{apim-byom-key}}`).
resource apimByomKeyNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apimExisting
  name: 'apim-byom-key'
  properties: {
    displayName: 'apim-byom-key'
    secret: true
    value: apimByomConnectionKey
  }
}

// Fragment loaders — paths are relative to this .bicep file.
var inboundFragmentRaw = loadTextContent('../policies/inbound.xml')
var backendFragmentRaw = loadTextContent('../policies/backend.xml')
var inboundCacheFragmentRaw = loadTextContent('../policies/inbound-cache.xml')
var backendCacheFragmentRaw = loadTextContent('../policies/backend-cache.xml')

// Strip the synthetic <fragment> wrappers.
var inboundBody = replace(replace(inboundFragmentRaw, '<fragment>', ''), '</fragment>', '')
var backendBody = replace(replace(backendFragmentRaw, '<fragment>', ''), '</fragment>', '')
var inboundCacheBody = enableSemanticCache ? replace(replace(inboundCacheFragmentRaw, '<fragment>', ''), '</fragment>', '') : ''
var backendCacheBody = enableSemanticCache ? replace(replace(backendCacheFragmentRaw, '<fragment>', ''), '</fragment>', '') : ''

// Build the multi-oid XML block. The project MI is always first; jumpbox UAMI (and
// any other operator-supplied oid) is appended. Empty strings are filtered so the
// param surface stays optional.
var allOids = union([agentProjectPrincipalId], filter(additionalAllowedOids, oid => !empty(oid)))
var allowedOidsXml = join(map(allOids, oid => '<value>${oid}</value>'), '')

// Splice cache fragments into the right positions.
// Inbound: insert llm-semantic-cache-lookup BEFORE set-backend-service.
// Backend: insert llm-semantic-cache-store BEFORE forward-request.
var inboundComposed = enableSemanticCache
  ? replace(inboundBody, '<set-backend-service', '${inboundCacheBody}\n<set-backend-service')
  : inboundBody

var backendComposed = enableSemanticCache
  ? replace(backendBody, '<forward-request', '${backendCacheBody}\n<forward-request')
  : backendBody

// Placeholder substitution.
var inboundFinal = replace(replace(replace(replace(
    inboundComposed,
    '{{TENANT_ID}}', tenantId),
    '{{ALLOWED_OIDS_XML}}', allowedOidsXml),
    '{{BACKEND_URL}}', 'https://${scFoundryAccountName}.openai.azure.com/openai'),
    '{{BACKEND_AUDIENCE}}', 'https://cognitiveservices.azure.com')

var backendFinal = replace(
    backendComposed,
    '{{BACKEND_AUDIENCE}}', 'https://cognitiveservices.azure.com')

// Wrap into a full <policies> document. At service (global) scope, <base/> is not
// allowed because there is no parent policy to inherit from, so the outbound and
// on-error sections are emitted empty.
var policyXml = '<policies>\n  <inbound>${inboundFinal}\n  </inbound>\n  <backend>${backendFinal}\n  </backend>\n  <outbound />\n  <on-error />\n</policies>'

resource apimPolicy 'Microsoft.ApiManagement/service/policies@2024-05-01' = {
  parent: apimExisting
  name: 'policy'
  properties: {
    format: 'xml'
    value: policyXml
  }
  dependsOn: [
    apimByomKeyNamedValue  // policy references `{{apim-byom-key}}` — value must exist first
  ]
}

output policyId string = apimPolicy.id
