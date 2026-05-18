// =============================================================================
// foundry-data-connections.bicep — BYO data-plane project connections.
// =============================================================================
//
// Authors three project-scoped connections referenced by the project capability
// host (`projcaphost`) for the Foundry "standard agent setup with private
// networking" topology:
//
//   - `cosmos-byom`   — connection to the BYO Cosmos DB account
//                       (capabilityHost.threadStorageConnections[0])
//   - `storage-byom`  — connection to the BYO Storage account
//                       (capabilityHost.storageConnections[0])
//   - `search-byom`   — connection to the BYO AI Search service
//                       (capabilityHost.vectorStoreConnections[0])
//
// These are MANDATORY for `RunStatus` to ever leave `failed/server_error`:
// without them the Foundry runtime cannot resolve where to persist threads,
// blobs, and vector stores during an agent run.
//
// AVM gap: AVM `cognitive-services/account@0.14.2` does NOT author
// `projects/connections` children. Native fallback per R-01 / R-06 / R-A1.
// Retire when an AVM `account-project-connection` module ships first-class
// coverage with category-specific overloads.
// =============================================================================

targetScope = 'resourceGroup'

@description('WE Foundry account name (parent of the project).')
param weFoundryAccountName string

@description('WE Foundry project name (parent of the connections).')
param weFoundryProjectName string

@description('BYO Cosmos DB account name (in the same RG).')
param cosmosAccountName string

@description('BYO Storage account name (in the same RG).')
param storageAccountName string

@description('BYO AI Search service name (in the same RG).')
param searchServiceName string

@description('Agent region (used for connection metadata.location). Matches the agent RG location.')
param agentRegion string

// Existing parent resources — we author the connections as grandchildren of
// the account. We also reference the BYO services as existing for ID lookup.
resource weAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: weFoundryAccountName
}

resource weProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' existing = {
  parent: weAccount
  name: weFoundryProjectName
}

resource cosmosExisting 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' existing = {
  name: cosmosAccountName
}

resource storageExisting 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource searchExisting 'Microsoft.Search/searchServices@2024-03-01-preview' existing = {
  name: searchServiceName
}

// -----------------------------------------------------------------------------
// Cosmos connection — category = CosmosDB
// -----------------------------------------------------------------------------
// `target` MUST be the Cosmos data-plane endpoint (.documents.azure.com:443).
// Foundry agents use this hostname when issuing data-plane reads/writes against
// the three required containers (agent-entity-store, thread-message-store,
// system-thread-message-store). The data-plane SQL role assignment authored in
// `cosmos-sql-role-assignment.bicep` is what authorizes the runtime against
// these containers.
resource cosmosConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: weProject
  name: 'cosmos-byom'
  properties: {
    authType: 'AAD'
    category: 'CosmosDB'
    target: 'https://${cosmosAccountName}.documents.azure.com:443/'
    isSharedToAll: false
    metadata: {
      ApiType: 'Azure'
      ResourceId: cosmosExisting.id
      location: agentRegion
    }
  }
}

// -----------------------------------------------------------------------------
// Storage connection — category = AzureStorageAccount
// -----------------------------------------------------------------------------
// `target` MUST be the blob endpoint. The runtime provisions two BYO containers
// at first agent run: `<workspaceId>-azureml-blobstore` (intermediate system data,
// chunks, embeddings) and `<workspaceId>-agents-blobstore` (user-uploaded files).
resource storageConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: weProject
  name: 'storage-byom'
  properties: {
    authType: 'AAD'
    category: 'AzureStorageAccount'
    target: 'https://${storageAccountName}.blob.${environment().suffixes.storage}/'
    isSharedToAll: false
    metadata: {
      ApiType: 'Azure'
      ResourceId: storageExisting.id
      location: agentRegion
    }
  }
}

// -----------------------------------------------------------------------------
// Search connection — category = CognitiveSearch
// -----------------------------------------------------------------------------
// `target` is the search service endpoint. Vector stores created by the agent
// (File Search tool, etc.) live in indexes on this search service.
resource searchConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-06-01' = {
  parent: weProject
  name: 'search-byom'
  properties: {
    authType: 'AAD'
    category: 'CognitiveSearch'
    target: 'https://${searchServiceName}.search.windows.net'
    isSharedToAll: false
    metadata: {
      ApiType: 'Azure'
      ResourceId: searchExisting.id
      location: agentRegion
    }
  }
}

output cosmosConnectionName string = cosmosConnection.name
output storageConnectionName string = storageConnection.name
output searchConnectionName string = searchConnection.name
