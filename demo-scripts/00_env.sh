# shellcheck shell=bash
# =============================================================================
# demo-scripts/00_env.sh — single source of demo env vars.
# =============================================================================
# Intent (laconic):
#   Resolve the live azd env (`fdev`) values that every demo stage needs and
#   export them. Designed to be `source`d, not executed. Re-sourceable.
#
# Required azd env vars (read from `azd env get-values`):
#   - agentResourceGroupName
#   - modelResourceGroupName
#   - weFoundryProjectEndpoint
#   - apimGatewayHostname
#   - foundryConnectionName
#   - modelDeploymentNameForSmoke
#   - jumpboxVmName
#   - jumpboxBastionName
#
# Exports (canonical names used across every stage script):
#   AGENT_RG, MODEL_RG, SN_FOUNDRY_PROJECT_ENDPOINT, APIM_GATEWAY_HOSTNAME,
#   FOUNDRY_CONNECTION_NAME, MODEL_DEPLOYMENT_NAME, JUMPBOX_VM_NAME,
#   JUMPBOX_BASTION_NAME, SN_FOUNDRY_ACCOUNT_NAME, SN_FOUNDRY_PROJECT_NAME,
#   SC_FOUNDRY_ACCOUNT_NAME, APIM_SERVICE_NAME, MODEL_REF
#
# Failure mode: print a single `ERROR 00_env: <VAR> missing — run \`azd env
# select fdev\` first` line and exit 1 (kills the calling demo).
# =============================================================================

set -euo pipefail

if ! command -v azd >/dev/null 2>&1; then
  echo "ERROR 00_env: azd CLI not on PATH" >&2
  exit 1
fi

# Pull everything once.
if ! _DEMO_ENV_RAW="$(azd env get-values 2>/dev/null)"; then
  echo "ERROR 00_env: \`azd env get-values\` failed — run \`azd env select fdev\` first" >&2
  exit 1
fi

_demo_get() {
  # Echo the raw value (unquoted) of the named azd env key, or empty.
  awk -F= -v k="$1" '$1==k { sub(/^"/,"",$2); sub(/"$/,"",$2); print $2; exit }' <<<"$_DEMO_ENV_RAW"
}

AGENT_RG="$(_demo_get agentResourceGroupName)"
MODEL_RG="$(_demo_get modelResourceGroupName)"
SN_FOUNDRY_PROJECT_ENDPOINT="$(_demo_get weFoundryProjectEndpoint)"
APIM_GATEWAY_HOSTNAME="$(_demo_get apimGatewayHostname)"
FOUNDRY_CONNECTION_NAME="$(_demo_get foundryConnectionName)"
MODEL_DEPLOYMENT_NAME="$(_demo_get modelDeploymentNameForSmoke)"
JUMPBOX_VM_NAME="$(_demo_get jumpboxVmName)"
JUMPBOX_BASTION_NAME="$(_demo_get jumpboxBastionName)"

# Required from azd directly.
for _v in AGENT_RG MODEL_RG SN_FOUNDRY_PROJECT_ENDPOINT APIM_GATEWAY_HOSTNAME \
          FOUNDRY_CONNECTION_NAME MODEL_DEPLOYMENT_NAME JUMPBOX_VM_NAME \
          JUMPBOX_BASTION_NAME; do
  if [[ -z "${!_v:-}" ]]; then
    echo "ERROR 00_env: ${_v} missing — run \`azd env select fdev\` first" >&2
    exit 1
  fi
done

# Derived: SN Foundry account name + project name from the project endpoint URL.
# weFoundryProjectEndpoint = https://<account>.services.ai.azure.com/api/projects/<project>
_sn_host="${SN_FOUNDRY_PROJECT_ENDPOINT#https://}"   # strip scheme
_sn_host="${_sn_host%%/*}"                            # keep host only
SN_FOUNDRY_ACCOUNT_NAME="${_sn_host%%.*}"             # first DNS label
SN_FOUNDRY_PROJECT_NAME="${SN_FOUNDRY_PROJECT_ENDPOINT##*/}"

# Derived: SC Foundry account name from the scFoundryAccountId resource id basename,
# falling back to the live `az resource list` only if azd doesn't expose the id.
_sc_id="$(_demo_get scFoundryAccountId)"
if [[ -n "$_sc_id" ]]; then
  SC_FOUNDRY_ACCOUNT_NAME="${_sc_id##*/}"
else
  SC_FOUNDRY_ACCOUNT_NAME="$(az resource list -g "$MODEL_RG" \
    --resource-type Microsoft.CognitiveServices/accounts \
    --query '[0].name' -o tsv 2>/dev/null || true)"
fi

# Derived: APIM service name = first label of the gateway hostname.
APIM_SERVICE_NAME="${APIM_GATEWAY_HOSTNAME%%.*}"

# The literal model reference every cross-region call uses.
MODEL_REF="${FOUNDRY_CONNECTION_NAME}/${MODEL_DEPLOYMENT_NAME}"

for _v in SN_FOUNDRY_ACCOUNT_NAME SN_FOUNDRY_PROJECT_NAME SC_FOUNDRY_ACCOUNT_NAME \
          APIM_SERVICE_NAME; do
  if [[ -z "${!_v:-}" ]]; then
    echo "ERROR 00_env: ${_v} could not be derived from azd outputs" >&2
    exit 1
  fi
done

export AGENT_RG MODEL_RG SN_FOUNDRY_PROJECT_ENDPOINT APIM_GATEWAY_HOSTNAME \
       FOUNDRY_CONNECTION_NAME MODEL_DEPLOYMENT_NAME JUMPBOX_VM_NAME \
       JUMPBOX_BASTION_NAME SN_FOUNDRY_ACCOUNT_NAME SN_FOUNDRY_PROJECT_NAME \
       SC_FOUNDRY_ACCOUNT_NAME APIM_SERVICE_NAME MODEL_REF

unset _DEMO_ENV_RAW _sc_id _sn_host _v
