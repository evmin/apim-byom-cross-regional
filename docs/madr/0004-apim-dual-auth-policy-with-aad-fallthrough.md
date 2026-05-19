# 0004 — APIM dual-auth policy: api-key + AAD fall-through

- Status: accepted
- Date: 2026-05-19
- Depends on: [MADR-0002](./0002-bridge-cross-region-private-foundry-via-apim-byom.md), [MADR-0005](./0005-foundry-connection-byom-wiring.md)

## Context and Problem Statement

Two kinds of callers hit the APIM gateway in front of the Sweden Central model:

1. **The Foundry Responses runtime**, on behalf of an agent that resolves a `apim-byom/<deployment>` model reference. It sends an `api-key` request header (set by the Foundry connection's `credentials.key`, see [MADR-0005](./0005-foundry-connection-byom-wiring.md)).
2. **AAD-only callers** — the jumpbox UAMI smoke (`smoke-bridge.sh`) and any future direct-MI consumer. They send `Authorization: Bearer <token>` and no `api-key`.

APIM must accept both, and forward both to the SC AOAI account via APIM's managed identity (the inbound credential is never passed through).

The original PR #1 commit message proposed enabling APIM `subscriptionRequired: true` on the API. We rejected that path.

## Considered Options

- **`subscriptionRequired: true` + APIM subscription resource (literal PR #1 design).** The gateway gates the request **before** policy runs, returning 401 to any caller without an `Ocp-Apim-Subscription-Key` or `api-key` header. The jumpbox AAD-only smoke would fail at the gateway and never reach `validate-azure-ad-token`. Rejected.
- **Pure AAD (no api-key).** Foundry Responses returns `400 "Connection 'apim-byom' not found"` when the connection's `authType` is `AAD`. Rejected — see [MADR-0005](./0005-foundry-connection-byom-wiring.md).
- **Dual-auth in policy (Design B).** Keep `subscriptionRequired: false`; let the inbound policy `<choose>` validate the `api-key` header against a stored APIM named value; on mismatch, fall through to `validate-azure-ad-token`. Strip caller-supplied `api-key` / `Ocp-Apim-Subscription-Key` headers before backend forward.

## Decision Outcome

Implement **Design B** (dual-auth in policy):

```xml
<choose>
  <when condition='@(context.Request.Headers.GetValueOrDefault("api-key","") != "{{apim-byom-key}}")'>
    <validate-azure-ad-token …/>
  </when>
</choose>
<set-header name="api-key" exists-action="delete" />
<set-header name="Ocp-Apim-Subscription-Key" exists-action="delete" />
<set-backend-service base-url="…/openai" />
<authentication-managed-identity resource="https://cognitiveservices.azure.com" …/>
```

- Shared secret lives in an APIM named value `apim-byom-key` (`secret: true`); the same value is set on the Foundry connection's `credentials.key`.
- Value is derived deterministically at deploy time via `uniqueString(...)` and threaded as a Bicep `@secure()` parameter — no secret in source control.

## Consequences

- Foundry Responses runtime fast-paths through the `api-key` match; AAD-only callers fall through to the AAD validator. Both call paths continue to work.
- API stays `subscriptionRequired: false`. No APIM subscription objects to manage.
- The api-key value is shared between the Foundry connection and the APIM named value. Rotation = redeploy (both get the new `uniqueString` output).
- The backend never sees `api-key` or `Ocp-Apim-Subscription-Key` headers (stripped in policy).

## References

- `infra/policies/inbound.xml` — the `<choose>` block + header strips.
- `infra/modules/apim-policy.bicep` — `apim-byom-key` named value.
- `infra/main.bicep` — `uniqueString()`-derived key, threaded as secure param.
- PR #3 (`evmin/fix/byom-target-openai`, commit `ac43704`) — landed this design.
