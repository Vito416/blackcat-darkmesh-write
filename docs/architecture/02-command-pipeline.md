# Command Pipeline

1) **Envelope intake**
   Accept signed command with tags: `Action`, `Request-Id`, `Actor`, `Tenant`, `Expected-Version`, `Nonce`, `Signature-Ref`, `Timestamp`.

2) **Validation**
   - Schema validation (JSON schemas in `schemas/`).
   - Policy checks (role, tenant scope, capability, action allowlist).
   - Temporal checks (timestamp drift, nonce freshness).

3) **Idempotency / anti-replay**
   - Look up `Request-Id` registry; if seen, return recorded outcome.
   - Enforce optimistic concurrency via `Expected-Version` when targeting mutable entities.

4) **Command execution**
   - Route to specific handler (page, route, catalog, profile, permission).
   - Produce deterministic status and any emitted events.

   **Policy/resolver admin family (registry target)**
   The write tooling also emits a policy command family for the AO registry process:
   - `RegisterHBNode`
   - `UpdateHBNodeStatus`
   - `SetSiteServingPolicy`
   - `SetSiteFundingState`
   - `SetPolicyMode`
   - `PublishPolicySnapshot`
   - `RevokePolicySnapshot`

   These commands use the same signed envelope fields, but their intended downstream
   target is the registry process (policy/resolver control-plane), not page/catalog handlers.

5) **Audit + events**
   - Append audit record with request, actor, decision, and hash of payload.
   - Emit domain event toward `blackcat-darkmesh-ao` processes for state materialization.

6) **Response**
   - Return status + correlation IDs; never return secrets or unvalidated payloads.

## Operator CLI templates for registry policy actions

The local command runner ships built-in templates for the registry policy family, but it does not execute them through write. Generate the JSON, then send it directly to the control-plane AO process:

```bash
lua scripts/cli/run_command.lua --list-templates
lua scripts/cli/run_command.lua --template SetPolicyMode > /tmp/SetPolicyMode.json

# dry-run/inspect normalized AO tags and payload
AO_REGISTRY_PID=<registry_pid> \
node scripts/cli/send_control_command.js /tmp/SetPolicyMode.json --target registry

# live send: sign with the same operator secret/key policy expected by registry AO
AO_REGISTRY_PID=<registry_pid> \
node scripts/cli/send_control_command.js /tmp/SetPolicyMode.json \
  --target registry \
  --hmac-secret "$AUTH_SIGNATURE_SECRET" \
  --send
```

Running `lua scripts/cli/run_command.lua /tmp/SetPolicyMode.json` intentionally returns `WRONG_TARGET`; write remains write-command authority only.

Template set currently includes:
- `RegisterHBNode`
- `UpdateHBNodeStatus`
- `SetSiteServingPolicy`
- `SetSiteFundingState`
- `SetPolicyMode`
- `PublishPolicySnapshot`
- `RevokePolicySnapshot`
- `SetDnsProofState`

## Template-runtime read stubs (registry/resolver target)

To support migration of gateway runtime actions into AO-managed control-plane,
the CLI also exposes registry/resolver read stubs with full envelope metadata:

- `GetTemplateActionContract`
- `GetSiteRuntimeBundle`
- `ResolveRouteForHost`

These commands are modeled as safe read-oriented stubs (no write-side state mutation)
and are intended for registry/resolver process handling during the migration wave.

## Registry/resolver lifecycle + dns-proof wave

Write CLI templates now include policy/lifecycle/dns-proof operations used during
gateway -> AO migration:

- `GetSiteServingPolicy`
- `GetPolicySnapshot`
- `GetDnsProofState`
- `ResolveHostPolicyBundle`
- `GetDomainLifecycleState`
- `SetDomainLifecycleState`
- `CreateSessionLifecycle`
- `ReadSessionLifecycle`
- `GetSessionLifecycle`
- `RotateSessionLifecycle`
- `RevokeSessionLifecycle`
- `ListSessionsBySubject`
- `CheckPaymentWebhookIdempotency`
- `GetPaymentWebhookIdempotencyState`
- `ResetPaymentWebhookIdempotencyState`
- `InvalidateResolverCache`
- `GetResolverCacheStats`

All templates keep the same signed envelope shape (`requestId`, `actor`, `tenant`, `nonce`, `timestamp`, `signatureRef`, `payload`) and are validated in contracts smoke before explicit registry/resolver dispatch.
