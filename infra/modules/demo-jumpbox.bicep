// =============================================================================
// demo-jumpbox.bicep — DJ-002 — always-on operator jumpbox + Azure Bastion.
// =============================================================================
//
// Single-file module that provisions, in the agent regional resource group:
//   - User-Assigned Managed Identity (UAMI) the VM runs as.
//   - NSG for the jumpbox NIC (inbound 22 from VirtualNetwork only — the
//     Bastion subnet is inside the same VNet, so this captures Bastion
//     traffic while denying anything from outside the VNet).
//   - Public IP for the Bastion host (Bastion's only public surface).
//   - Bastion (Standard SKU — required for `az network bastion ssh` and
//     `az network bastion tunnel`).
//   - Linux jumpbox VM (Ubuntu 22.04 LTS, Standard_D2s_v5, SSH-key auth).
//   - cloud-init that materialises the validation scripts under
//     /opt/mreg-validate/ and runs bootstrap.sh on first boot.
//
// Cross-cutting:
//   - The VM has NO public IP (only Bastion does).
//   - The NSG is attached to the *NIC* (not the subnet) — keeps this module
//     fully self-contained and avoids touching the subnet object that the
//     AVM virtual-network module owns in we-agent-plane.bicep.
//   - The UAMI is granted Reader on both RGs + Azure AI Developer on the
//     project + Cognitive Services User on the agent Foundry account in
//     main.bicep (DJ-005). No role on APIM — that's intentional, so the
//     smoke-reject test exercises the policy honestly.
//
// AVM pins (resolved against MCR — latest stable as of the planning session):
//   br/public:avm/res/compute/virtual-machine:0.22.1
//   br/public:avm/res/network/bastion-host:0.8.2
//   br/public:avm/res/managed-identity/user-assigned-identity:0.5.1
//   br/public:avm/res/network/network-security-group:0.5.3
//   br/public:avm/res/network/public-ip-address:0.12.0
// =============================================================================

targetScope = 'resourceGroup'

// =============================================================================
// Parameters
// =============================================================================

@description('Resource name prefix; matches namePrefix used elsewhere.')
param namePrefix string

@description('azd environment name.')
param azdEnvironmentName string

@description('Short token for the agent region (we / eus2 / neu).')
param agentRegionShort string

@description('Common tags stamped on every resource.')
param solutionTags object

@description('Jumpbox subnet resource ID (subnet is authored by we-agent-plane.bicep).')
param jumpboxSubnetId string

@description('Agent VNet resource ID — required by Bastion (Bastion locates AzureBastionSubnet inside it).')
param agentVnetId string

@description('SSH public key (OpenSSH single-line form). Operator-supplied — required, no fallback.')
@secure()
param sshPublicKey string

@description('VM admin username; default azureuser.')
param adminUsername string = 'azureuser'

@description('VM size; default Standard_D2s_v5 (2 vCPU / 8 GiB).')
param vmSize string = 'Standard_D2s_v5'

@description('Foundry account name (used to compose the agent project endpoint in cloud-init).')
param weFoundryAccountName string

@description('Foundry project name (used to compose the agent project endpoint in cloud-init).')
param weFoundryProjectName string

@description('Foundry connection name (e.g. apim-byom) — surfaced into cloud-init env for the on-VM smokes.')
param foundryConnectionName string

@description('APIM private gateway hostname (e.g. <apim>.azure-api.net).')
param apimGatewayHostname string

@description('SC Foundry account FQDN used for the DNS smoke check.')
param scFoundryAccountFqdn string

@description('Model deployment name surfaced to the on-VM smoke (one of MODEL_DEPLOYMENTS[*].name) — the SC AOAI deployment behind the APIM bridge.')
param modelDeploymentName string

@description('Agent resource group name (propagated into smoke env so `az resource list -g <rg>` works without inferring).')
param agentResourceGroupName string

@description('Model resource group name (same rationale as agentResourceGroupName).')
param modelResourceGroupName string

// =============================================================================
// Locals
// =============================================================================

var rgLocation = resourceGroup().location

var uniq = take(uniqueString(resourceGroup().id, namePrefix, azdEnvironmentName, 'jumpbox'), 6)

var vmName        = '${namePrefix}-${azdEnvironmentName}-jb-${agentRegionShort}'
var nsgName       = '${vmName}-nsg'
var bastionName   = '${namePrefix}-${azdEnvironmentName}-bastion-${agentRegionShort}'
var bastionPipName = '${bastionName}-pip'
var uamiName      = '${vmName}-uami-${uniq}'
var osDiskName    = '${vmName}-osdisk'

// Compose the agent project endpoint inline so cloud-init can hand it off
// to the on-VM smoke scripts without a second `azd env get-values` pass.
var agentProjectEndpoint = 'https://${weFoundryAccountName}.services.ai.azure.com/api/projects/${weFoundryProjectName}'

// =============================================================================
// User-Assigned Managed Identity
// =============================================================================

module uami 'br/public:avm/res/managed-identity/user-assigned-identity:0.5.1' = {
  name: 'demo-jb-uami'
  params: {
    name: uamiName
    location: rgLocation
    tags: solutionTags
  }
}

// =============================================================================
// NSG — inbound 22 from VirtualNetwork only (covers Bastion subnet)
// =============================================================================

module nsg 'br/public:avm/res/network/network-security-group:0.5.3' = {
  name: 'demo-jb-nsg'
  params: {
    name: nsgName
    location: rgLocation
    tags: solutionTags
    securityRules: [
      {
        name: 'allow-bastion-ssh-inbound'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
          description: 'Permit SSH from VirtualNetwork (the Bastion subnet is inside this VNet).'
        }
      }
      {
        name: 'deny-all-other-inbound'
        properties: {
          access: 'Deny'
          direction: 'Inbound'
          priority: 4096
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Default-deny inbound (override the platform default-allow-VNet rule for everything except SSH).'
        }
      }
    ]
  }
}

// =============================================================================
// Bastion (Standard) + public IP
// =============================================================================

module bastionPip 'br/public:avm/res/network/public-ip-address:0.12.0' = {
  name: 'demo-jb-bastion-pip'
  params: {
    name: bastionPipName
    location: rgLocation
    tags: solutionTags
    publicIPAllocationMethod: 'Static'
    skuName: 'Standard'
    skuTier: 'Regional'
    availabilityZones: []
  }
}

module bastion 'br/public:avm/res/network/bastion-host:0.8.2' = {
  name: 'demo-jb-bastion'
  params: {
    name: bastionName
    location: rgLocation
    tags: solutionTags
    skuName: 'Standard'
    virtualNetworkResourceId: agentVnetId
    bastionSubnetPublicIpResourceId: bastionPip.outputs.resourceId
    // Standard SKU automatically enables tunneling (verified against the
    // module's main.json — see DJ-002 implementation notes). No explicit
    // enableTunneling param exists.
    enableShareableLink: false
    enableIpConnect: false
    enableFileCopy: false
    disableCopyPaste: false
    scaleUnits: 2
  }
}

// =============================================================================
// cloud-init — materialise validation scripts + run bootstrap
// =============================================================================
//
// We pre-load the scripts at Bicep compile time (loadTextContent) and embed
// them base64-encoded in a #cloud-config write_files block. This avoids the
// need for the VM to reach any internal artifact endpoint at boot.
// =============================================================================

var cloudInit = format('''#cloud-config
package_update: true
package_upgrade: false
write_files:
  - path: /etc/profile.d/mreg-validate.sh
    permissions: '0644'
    owner: root:root
    content: |
      # mreg-validate — operator env for the validation suite.
      export AGENT_PROJECT_ENDPOINT="{0}"
      export FOUNDRY_CONNECTION_NAME="{1}"
      export MODEL_DEPLOYMENT_NAME="{2}"
      export APIM_GATEWAY_HOSTNAME="{3}"
      export SC_FOUNDRY_FQDN="{4}"
      export AGENT_RESOURCE_GROUP_NAME="{5}"
      export MODEL_RESOURCE_GROUP_NAME="{6}"
      export AZURE_CLIENT_ID="{7}"
      export PATH="/opt/mreg-validate:$PATH"
  - path: /opt/mreg-validate/bootstrap.sh
    permissions: '0755'
    owner: root:root
    encoding: b64
    content: {8}
  - path: /opt/mreg-validate/smoke-reject.sh
    permissions: '0755'
    owner: root:root
    encoding: b64
    content: {9}
  - path: /opt/mreg-validate/smoke-dns.sh
    permissions: '0755'
    owner: root:root
    encoding: b64
    content: {10}
  - path: /opt/mreg-validate/posture-from-vnet.sh
    permissions: '0755'
    owner: root:root
    encoding: b64
    content: {11}
  - path: /opt/mreg-validate/smoke-bridge.sh
    permissions: '0755'
    owner: root:root
    encoding: b64
    content: {12}
runcmd:
  - [ /opt/mreg-validate/bootstrap.sh ]
''',
  agentProjectEndpoint,
  foundryConnectionName,
  modelDeploymentName,
  apimGatewayHostname,
  scFoundryAccountFqdn,
  agentResourceGroupName,
  modelResourceGroupName,
  uami.outputs.clientId,
  base64(loadTextContent('../../scripts/jumpbox/bootstrap.sh')),
  base64(loadTextContent('../../scripts/jumpbox/smoke-reject.sh')),
  base64(loadTextContent('../../scripts/jumpbox/smoke-dns.sh')),
  base64(loadTextContent('../../scripts/jumpbox/posture-from-vnet.sh')),
  base64(loadTextContent('../../scripts/jumpbox/smoke-bridge.sh'))
)

// =============================================================================
// VM
// =============================================================================

module vm 'br/public:avm/res/compute/virtual-machine:0.22.1' = {
  name: 'demo-jb-vm'
  params: {
    name: vmName
    location: rgLocation
    tags: solutionTags
    vmSize: vmSize
    osType: 'Linux'
    availabilityZone: -1
    encryptionAtHost: false
    imageReference: {
      publisher: 'Canonical'
      offer: '0001-com-ubuntu-server-jammy'
      sku: '22_04-lts-gen2'
      version: 'latest'
    }
    osDisk: {
      name: osDiskName
      caching: 'ReadWrite'
      diskSizeGB: 64
      createOption: 'FromImage'
      managedDisk: {
        storageAccountType: 'Premium_LRS'
      }
    }
    adminUsername: adminUsername
    disablePasswordAuthentication: true
    publicKeys: [
      {
        keyData: sshPublicKey
        path: '/home/${adminUsername}/.ssh/authorized_keys'
      }
    ]
    customData: cloudInit
    nicConfigurations: [
      {
        name: '${vmName}-nic'
        deleteOption: 'Delete'
        networkSecurityGroupResourceId: nsg.outputs.resourceId
        ipConfigurations: [
          {
            name: 'ipconfig1'
            subnetResourceId: jumpboxSubnetId
            privateIPAllocationMethod: 'Dynamic'
          }
        ]
      }
    ]
    managedIdentities: {
      systemAssigned: false
      userAssignedResourceIds: [
        uami.outputs.resourceId
      ]
    }
    enableAutomaticUpdates: false
    patchMode: 'ImageDefault'
    bootDiagnostics: true
  }
}

// =============================================================================
// Outputs
// =============================================================================

output vmId string = vm.outputs.resourceId
output vmName string = vmName
output uamiResourceId string = uami.outputs.resourceId
output uamiPrincipalId string = uami.outputs.principalId
output uamiClientId string = uami.outputs.clientId
output bastionName string = bastionName
output bastionResourceId string = bastion.outputs.resourceId
