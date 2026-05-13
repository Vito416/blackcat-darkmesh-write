# Sample Commands

- `save-draft-page.json` — draft page command with `Action=SaveDraftPage`.
- `publish-page-version.json` — publish command with `Expected-Version` guard.
- `assign-role.json` — role assignment with tenant scope.

## Registry/resolver control templates

`scripts/cli/run_command.lua --template ...` only generates validated control-plane JSON. These actions are not write commands and must be sent explicitly to the registry or resolver AO process.

Generate a template JSON:

```bash
lua scripts/cli/run_command.lua --template RegisterHBNode > /tmp/RegisterHBNode.json
```

Dry-run the AO message shape before sending:

```bash
AO_REGISTRY_PID=<registry_pid> \
node scripts/cli/send_control_command.js /tmp/RegisterHBNode.json --target registry
```

Send live after signing with the operator secret/key expected by the target AO process:

```bash
AO_REGISTRY_PID=<registry_pid> \
node scripts/cli/send_control_command.js /tmp/RegisterHBNode.json \
  --target registry \
  --hmac-secret "$AUTH_SIGNATURE_SECRET" \
  --send
```

Resolver actions use `AO_RESOLVER_PID` and `--target resolver`. Running these templates through `lua scripts/cli/run_command.lua /tmp/RegisterHBNode.json` intentionally fails with `WRONG_TARGET`, so policy/resolver state cannot be accidentally mutated via the write process.

Available policy/resolver templates:

```bash
lua scripts/cli/run_command.lua --list-templates
```

One-liners for every registry/resolver control action:

```bash
lua scripts/cli/run_command.lua --template RegisterHBNode > /tmp/RegisterHBNode.json
lua scripts/cli/run_command.lua --template UpdateHBNodeStatus > /tmp/UpdateHBNodeStatus.json
lua scripts/cli/run_command.lua --template SetSiteServingPolicy > /tmp/SetSiteServingPolicy.json
lua scripts/cli/run_command.lua --template SetSiteFundingState > /tmp/SetSiteFundingState.json
lua scripts/cli/run_command.lua --template SetPolicyMode > /tmp/SetPolicyMode.json
lua scripts/cli/run_command.lua --template PublishPolicySnapshot > /tmp/PublishPolicySnapshot.json
lua scripts/cli/run_command.lua --template RevokePolicySnapshot > /tmp/RevokePolicySnapshot.json
lua scripts/cli/run_command.lua --template SetDnsProofState > /tmp/SetDnsProofState.json
lua scripts/cli/run_command.lua --template GetTemplateActionContract > /tmp/GetTemplateActionContract.json
lua scripts/cli/run_command.lua --template GetSiteRuntimeBundle > /tmp/GetSiteRuntimeBundle.json
lua scripts/cli/run_command.lua --template ResolveRouteForHost > /tmp/ResolveRouteForHost.json
lua scripts/cli/run_command.lua --template GetSiteServingPolicy > /tmp/GetSiteServingPolicy.json
lua scripts/cli/run_command.lua --template GetPolicySnapshot > /tmp/GetPolicySnapshot.json
lua scripts/cli/run_command.lua --template GetDnsProofState > /tmp/GetDnsProofState.json
lua scripts/cli/run_command.lua --template ResolveHostPolicyBundle > /tmp/ResolveHostPolicyBundle.json
lua scripts/cli/run_command.lua --template GetDomainLifecycleState > /tmp/GetDomainLifecycleState.json
lua scripts/cli/run_command.lua --template SetDomainLifecycleState > /tmp/SetDomainLifecycleState.json
lua scripts/cli/run_command.lua --template CreateSessionLifecycle > /tmp/CreateSessionLifecycle.json
lua scripts/cli/run_command.lua --template ReadSessionLifecycle > /tmp/ReadSessionLifecycle.json
lua scripts/cli/run_command.lua --template GetSessionLifecycle > /tmp/GetSessionLifecycle.json
lua scripts/cli/run_command.lua --template RotateSessionLifecycle > /tmp/RotateSessionLifecycle.json
lua scripts/cli/run_command.lua --template RevokeSessionLifecycle > /tmp/RevokeSessionLifecycle.json
lua scripts/cli/run_command.lua --template ListSessionsBySubject > /tmp/ListSessionsBySubject.json
lua scripts/cli/run_command.lua --template CheckPaymentWebhookIdempotency > /tmp/CheckPaymentWebhookIdempotency.json
lua scripts/cli/run_command.lua --template GetPaymentWebhookIdempotencyState > /tmp/GetPaymentWebhookIdempotencyState.json
lua scripts/cli/run_command.lua --template ResetPaymentWebhookIdempotencyState > /tmp/ResetPaymentWebhookIdempotencyState.json
lua scripts/cli/run_command.lua --template InvalidateResolverCache > /tmp/InvalidateResolverCache.json
lua scripts/cli/run_command.lua --template GetResolverCacheStats > /tmp/GetResolverCacheStats.json
```

## Template-runtime (gateway migration) read stubs

These stubs represent registry/resolver-targeted read workflows that replace
gateway `src` runtime lookups:

- `GetTemplateActionContract` — returns action contract metadata for a site/template context.
- `GetSiteRuntimeBundle` — fetches runtime bundle descriptor for host/site.
- `ResolveRouteForHost` — host + path lookup for route resolution.
- `GetSiteServingPolicy` — read the active serving/funding policy view.
- `GetPolicySnapshot` — read currently active policy snapshot metadata.
- `GetDnsProofState` — read DNS proof state for host/site.
- `ResolveHostPolicyBundle` — read consolidated host policy decision input bundle.
- `GetDomainLifecycleState` — read lifecycle state for domain/site.
- `SetDomainLifecycleState` — admin lifecycle mutation (suspend/activate/retire).
- `CreateSessionLifecycle` / `ReadSessionLifecycle` / `GetSessionLifecycle` — session lifecycle creation and reads.
- `RotateSessionLifecycle` / `RevokeSessionLifecycle` — session lifecycle mutation actions.
- `ListSessionsBySubject` — list active or full lifecycle sessions for a subject.
- `CheckPaymentWebhookIdempotency` — canonical webhook dedupe/duplicate/conflict decision write.
- `GetPaymentWebhookIdempotencyState` — inspect provider-level webhook idempotency ledger snapshots.
- `ResetPaymentWebhookIdempotencyState` — clear provider/site webhook idempotency ledger state.

All templates include full envelope fields (`requestId`, `actor`, `tenant`, `nonce`, `timestamp`, `signatureRef`) so `send_control_command.js` can normalize/sign them for the target AO process.

## Resolver maintenance quick run sequence

```bash
# 1) Inspect cache stats (summary scope)
lua scripts/cli/run_command.lua --template GetResolverCacheStats > /tmp/GetResolverCacheStats.json
AO_RESOLVER_PID=<resolver_pid> node scripts/cli/send_control_command.js /tmp/GetResolverCacheStats.json --target resolver --send

# 2) Invalidate a host-scoped resolver cache entry
lua scripts/cli/run_command.lua --template InvalidateResolverCache > /tmp/InvalidateResolverCache.json
AO_RESOLVER_PID=<resolver_pid> node scripts/cli/send_control_command.js /tmp/InvalidateResolverCache.json --target resolver --hmac-secret "$AUTH_SIGNATURE_SECRET" --send
```

## End-to-end sample payloads (new registry/resolver templates)

`GetSiteServingPolicy`
```json
{
  "action": "GetSiteServingPolicy",
  "requestId": "req-get-site-serving-policy-001",
  "actor": "operator",
  "tenant": "darkmesh",
  "role": "registry-admin",
  "signatureRef": "operator-key",
  "nonce": "nonce-get-site-serving-policy-001",
  "timestamp": "2026-04-22T00:00:00Z",
  "payload": { "siteId": "site-jdwt" }
}
```

`GetPolicySnapshot`
```json
{
  "action": "GetPolicySnapshot",
  "requestId": "req-get-policy-snapshot-001",
  "actor": "operator",
  "tenant": "darkmesh",
  "role": "registry-admin",
  "signatureRef": "operator-key",
  "nonce": "nonce-get-policy-snapshot-001",
  "timestamp": "2026-04-22T00:00:00Z",
  "payload": { "snapshotId": "snapshot-2026-04-22" }
}
```

`GetDnsProofState`
```json
{
  "action": "GetDnsProofState",
  "requestId": "req-get-dns-proof-state-001",
  "actor": "operator",
  "tenant": "darkmesh",
  "role": "registry-admin",
  "signatureRef": "operator-key",
  "nonce": "nonce-get-dns-proof-state-001",
  "timestamp": "2026-04-22T00:00:00Z",
  "payload": { "host": "jdwt.fun" }
}
```

`ResolveHostPolicyBundle`
```json
{
  "action": "ResolveHostPolicyBundle",
  "requestId": "req-resolve-host-policy-bundle-001",
  "actor": "operator",
  "tenant": "darkmesh",
  "role": "registry-admin",
  "signatureRef": "operator-key",
  "nonce": "nonce-resolve-host-policy-bundle-001",
  "timestamp": "2026-04-22T00:00:00Z",
  "payload": { "host": "jdwt.fun" }
}
```

`GetDomainLifecycleState`
```json
{
  "action": "GetDomainLifecycleState",
  "requestId": "req-get-domain-lifecycle-state-001",
  "actor": "operator",
  "tenant": "darkmesh",
  "role": "registry-admin",
  "signatureRef": "operator-key",
  "nonce": "nonce-get-domain-lifecycle-state-001",
  "timestamp": "2026-04-22T00:00:00Z",
  "payload": { "domain": "jdwt.fun" }
}
```

`SetDomainLifecycleState`
```json
{
  "action": "SetDomainLifecycleState",
  "requestId": "req-set-domain-lifecycle-state-001",
  "actor": "operator",
  "tenant": "darkmesh",
  "role": "registry-admin",
  "signatureRef": "operator-key",
  "nonce": "nonce-set-domain-lifecycle-state-001",
  "timestamp": "2026-04-22T00:00:00Z",
  "payload": { "domain": "jdwt.fun", "lifecycleState": "active" }
}
```

`InvalidateResolverCache`
```json
{
  "action": "InvalidateResolverCache",
  "requestId": "req-invalidate-resolver-cache-001",
  "actor": "operator",
  "tenant": "darkmesh",
  "role": "registry-admin",
  "signatureRef": "operator-key",
  "nonce": "nonce-invalidate-resolver-cache-001",
  "timestamp": "2026-04-22T00:00:00Z",
  "payload": { "scope": "host", "host": "jdwt.fun" }
}
```

`GetResolverCacheStats`
```json
{
  "action": "GetResolverCacheStats",
  "requestId": "req-get-resolver-cache-stats-001",
  "actor": "operator",
  "tenant": "darkmesh",
  "role": "registry-admin",
  "signatureRef": "operator-key",
  "nonce": "nonce-get-resolver-cache-stats-001",
  "timestamp": "2026-04-22T00:00:00Z",
  "payload": { "scope": "summary" }
}
```
