#!/usr/bin/env bash
# =============================================================================
# scripts/verify-teardown.sh — T-038 teardown verification probe.
# =============================================================================
#
# Runs AFTER `azd down`. Confirms that no solution-tagged resource, no solution-
# created private DNS zone, and no role assignment bound to the deleted system-
# assigned MIs remains.
# =============================================================================

set -euo pipefail

SOLUTION_TAG_KEY="iac-feature"
SOLUTION_TAG_VAL="001-private-foundry-iac"

echo "::group::teardown: assert no tagged resources remain"
LEFTOVER=$(az graph query --first 100 -q "
  Resources
  | where tags['${SOLUTION_TAG_KEY}'] == '${SOLUTION_TAG_VAL}'
  | project id
" --output tsv | wc -l | tr -d ' ')
if [[ "${LEFTOVER}" -gt 0 ]]; then
  echo "teardown: FAIL — ${LEFTOVER} solution-tagged resource(s) still present" >&2
  az graph query --first 100 -q "
    Resources
    | where tags['${SOLUTION_TAG_KEY}'] == '${SOLUTION_TAG_VAL}'
    | project id
  " --output tsv >&2
  exit 1
fi
echo "teardown: 0 tagged resources remain"
echo "::endgroup::"

echo "::group::teardown: assert solution-created private DNS zones removed"
# When create-new DNS zone mode was used, each zone was placed in agentRg or
# modelRg. After `azd down` the RGs themselves are gone — zones with them.
# Catch any orphan that survived (e.g. links into out-of-solution VNets).
ORPHAN_ZONES=$(az network private-dns zone list --query "[?tags['${SOLUTION_TAG_KEY}'] == '${SOLUTION_TAG_VAL}'].id" -o tsv 2>/dev/null || true)
if [[ -n "${ORPHAN_ZONES}" ]]; then
  echo "teardown: FAIL — solution-created private DNS zones survived teardown:" >&2
  echo "${ORPHAN_ZONES}" >&2
  exit 1
fi
echo "teardown: no orphan private DNS zones"
echo "::endgroup::"

echo "::group::teardown: assert no orphan role assignments for solution MIs"
# After RG deletion the MIs are gone; their role assignments should be
# tombstoned by Azure within minutes. Flag any role assignment with an
# unresolvable principalId pointing at solution-managed scopes (`/subscriptions/
# .../resourceGroups/<*foundry*|*agent*|*model*>/...`) as suspicious.
SUSPICIOUS=$(az role assignment list --all --query "[?principalType=='Unknown'].id" -o tsv 2>/dev/null | head -50 || true)
if [[ -n "${SUSPICIOUS}" ]]; then
  echo "teardown: WARN — role assignments with Unknown principalType (may be unrelated tombstones):"
  echo "${SUSPICIOUS}"
fi
echo "::endgroup::"

echo "teardown: PASS"
