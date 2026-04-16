import test from 'node:test'
import assert from 'node:assert/strict'

import {
  WRITE_API_CORS_ALLOW_HEADERS,
  buildCommand,
  buildEnv,
  normalizeWriteResult,
  resolveTargetWritePid,
  resolveTraceId,
} from '../../scripts/http/checkout_api_server.mjs'

test('WRITE_API_ACCEPT_EMPTY_RESULT defaults fail-closed', () => {
  const env = buildEnv({ NODE_ENV: 'test' })
  assert.equal(env.acceptEmptyResult, false)
})

test('WRITE_API_ALLOW_PID_OVERRIDE defaults disabled', () => {
  const env = buildEnv({ NODE_ENV: 'test' })
  assert.equal(env.allowWritePidOverride, false)
})

test('production-like mode requires WRITE_API_TOKEN by default', () => {
  assert.throws(
    () => buildEnv({ NODE_ENV: 'production' }),
    /write_api_token_required:WRITE_API_UNSAFE_ALLOW_NO_TOKEN/,
  )
})

test('production-like mode allows explicit unsafe override', () => {
  const env = buildEnv({
    NODE_ENV: 'production',
    WRITE_API_UNSAFE_ALLOW_NO_TOKEN: '1',
  })
  assert.equal(env.productionLike, true)
  assert.equal(env.apiToken, '')
})

test('WRITE_API_ALLOW_PID_OVERRIDE requires WRITE_API_TOKEN', () => {
  assert.throws(
    () => buildEnv({ NODE_ENV: 'test', WRITE_API_ALLOW_PID_OVERRIDE: '1' }),
    /write_pid_override_requires_token:WRITE_API_ALLOW_PID_OVERRIDE:WRITE_API_TOKEN/,
  )
})

test('WRITE_PROCESS_ID must be valid when configured', () => {
  assert.throws(
    () => buildEnv({ NODE_ENV: 'test', WRITE_PROCESS_ID: 'bad pid with spaces' }),
    /invalid_write_process_id/,
  )
})

test('WRITE_API_REQUIRE_PID_OVERRIDE requires WRITE_API_ALLOW_PID_OVERRIDE', () => {
  assert.throws(
    () =>
      buildEnv({
        NODE_ENV: 'test',
        WRITE_API_TOKEN: 'secret-token',
        WRITE_API_REQUIRE_PID_OVERRIDE: '1',
      }),
    /write_pid_require_override_needs_flag:WRITE_API_REQUIRE_PID_OVERRIDE:WRITE_API_ALLOW_PID_OVERRIDE/,
  )
})

test('WRITE_API_SITE_WRITE_PID_MAP requires WRITE_API_ALLOW_PID_OVERRIDE', () => {
  assert.throws(
    () =>
      buildEnv({
        NODE_ENV: 'test',
        WRITE_API_TOKEN: 'secret-token',
        WRITE_API_SITE_WRITE_PID_MAP: JSON.stringify({ 'site-1': 'A'.repeat(43) }),
      }),
    /write_pid_site_map_requires_override:WRITE_API_SITE_WRITE_PID_MAP:WRITE_API_ALLOW_PID_OVERRIDE/,
  )
})

test('target write PID stays static when per-request override is disabled', () => {
  const basePid = 'A'.repeat(43)
  const result = resolveTargetWritePid(
    { headers: { 'x-write-process-id': 'B'.repeat(43) } },
    { writeProcessId: 'C'.repeat(43) },
    { writePid: basePid, allowWritePidOverride: false, apiToken: '' },
  )
  assert.equal(result.ok, true)
  assert.equal(result.pid, basePid)
  assert.equal(result.overridden, false)
})

test('target write PID override requires token-authenticated request', () => {
  const result = resolveTargetWritePid(
    { headers: { 'x-write-process-id': 'B'.repeat(43) } },
    {},
    { writePid: 'A'.repeat(43), allowWritePidOverride: true, apiToken: 'secret-token' },
  )
  assert.equal(result.ok, false)
  assert.equal(result.status, 401)
  assert.equal(result.error, 'unauthorized')
})

test('target write PID override accepts trusted header when enabled and authenticated', () => {
  const overridePid = 'B'.repeat(43)
  const result = resolveTargetWritePid(
    { headers: { 'x-write-process-id': overridePid, authorization: 'Bearer secret-token' } },
    {},
    { writePid: 'A'.repeat(43), allowWritePidOverride: true, apiToken: 'secret-token' },
  )
  assert.equal(result.ok, true)
  assert.equal(result.pid, overridePid)
  assert.equal(result.overridden, true)
  assert.equal(result.source, 'header')
})

test('target write PID override rejects invalid override values', () => {
  const result = resolveTargetWritePid(
    { headers: { authorization: 'Bearer secret-token' } },
    { writeProcessId: 'bad pid with spaces' },
    { writePid: 'A'.repeat(43), allowWritePidOverride: true, apiToken: 'secret-token' },
  )
  assert.equal(result.ok, false)
  assert.equal(result.status, 400)
  assert.equal(result.error, 'invalid_write_process_id_override')
})

test('target write PID override can be required in dynamic mode', () => {
  const result = resolveTargetWritePid(
    { headers: {} },
    {},
    {
      writePid: 'A'.repeat(43),
      allowWritePidOverride: true,
      requireWritePidOverride: true,
      apiToken: 'secret-token',
    },
  )
  assert.equal(result.ok, false)
  assert.equal(result.status, 400)
  assert.equal(result.error, 'missing_write_process_id_override')
})

test('target write PID override enforces per-site PID route map', () => {
  const result = resolveTargetWritePid(
    { headers: { authorization: 'Bearer secret-token', 'x-write-process-id': 'B'.repeat(43) } },
    { siteId: 'site-1' },
    {
      writePid: 'A'.repeat(43),
      allowWritePidOverride: true,
      apiToken: 'secret-token',
      siteWritePidMap: { 'site-1': 'C'.repeat(43) },
    },
  )
  assert.equal(result.ok, false)
  assert.equal(result.status, 403)
  assert.equal(result.error, 'write_pid_route_mismatch')
})

test('target write PID override accepts mapped site route', () => {
  const overridePid = 'B'.repeat(43)
  const result = resolveTargetWritePid(
    { headers: { authorization: 'Bearer secret-token', 'x-write-process-id': overridePid } },
    { payload: { siteId: 'site-2' } },
    {
      writePid: 'A'.repeat(43),
      allowWritePidOverride: true,
      apiToken: 'secret-token',
      siteWritePidMap: { 'site-2': overridePid },
    },
  )
  assert.equal(result.ok, true)
  assert.equal(result.pid, overridePid)
  assert.equal(result.overridden, true)
})

test('target write PID override accepts canonical tenant keys in signed envelopes', () => {
  const overridePid = 'B'.repeat(43)
  const result = resolveTargetWritePid(
    { headers: { authorization: 'Bearer secret-token', 'x-write-process-id': overridePid } },
    {
      Tenant: 'tenant-canon',
      Payload: { orderId: 'ord-1' },
    },
    {
      writePid: 'A'.repeat(43),
      allowWritePidOverride: true,
      apiToken: 'secret-token',
      siteWritePidMap: { 'tenant-canon': overridePid },
    },
  )
  assert.equal(result.ok, true)
  assert.equal(result.pid, overridePid)
  assert.equal(result.overridden, true)
})

test('target write PID override rejects mismatched site scope values', () => {
  const result = resolveTargetWritePid(
    { headers: { authorization: 'Bearer secret-token', 'x-write-process-id': 'B'.repeat(43) } },
    { siteId: 'site-top', payload: { siteId: 'site-payload' } },
    {
      writePid: 'A'.repeat(43),
      allowWritePidOverride: true,
      apiToken: 'secret-token',
      siteWritePidMap: { 'site-top': 'B'.repeat(43) },
    },
  )
  assert.equal(result.ok, false)
  assert.equal(result.status, 400)
  assert.equal(result.error, 'write_pid_route_key_mismatch')
})

test('normalizeWriteResult returns clear contract for empty AO result payload', () => {
  const result = normalizeWriteResult(
    {},
    { requestId: 'rid-1', action: 'CreateOrder' },
    { acceptEmptyResult: false, debug: false },
  )
  assert.equal(result.status, 502)
  assert.deepEqual(result.body, {
    ok: false,
    error: 'empty_ao_result',
    code: 'EMPTY_AO_RESULT',
    message: 'AO transport succeeded but no write result envelope was returned',
    requestId: 'rid-1',
    action: 'CreateOrder',
  })
})

test('normalizeWriteResult returns clear contract for invalid AO output payload', () => {
  const result = normalizeWriteResult(
    { Output: 'not-json' },
    { requestId: 'rid-2', action: 'CreatePaymentIntent' },
    { acceptEmptyResult: false, debug: false },
  )
  assert.equal(result.status, 502)
  assert.equal(result.body.ok, false)
  assert.equal(result.body.error, 'invalid_ao_result_payload')
  assert.equal(result.body.code, 'INVALID_AO_RESULT')
  assert.equal(result.body.requestId, 'rid-2')
  assert.equal(result.body.action, 'CreatePaymentIntent')
  assert.equal(result.body.message, 'AO returned non-JSON write result payload')
})

test('normalizeWriteResult keeps explicit async-accept path only when enabled', () => {
  const result = normalizeWriteResult(
    {},
    { requestId: 'rid-3', action: 'CreateOrder' },
    { acceptEmptyResult: true, debug: false },
  )
  assert.equal(result.status, 202)
  assert.equal(result.body.status, 'OK')
  assert.equal(result.body.code, 'ACCEPTED_ASYNC')
  assert.equal(result.body.requestId, 'rid-3')
})

test('normalizeWriteResult returns clear contract for AO runtime error payload', () => {
  const result = normalizeWriteResult(
    { Error: { message: 'runtime boom' } },
    { requestId: 'rid-4', action: 'CreateOrder' },
    { acceptEmptyResult: false, debug: false },
  )
  assert.equal(result.status, 502)
  assert.equal(result.body.error, 'ao_runtime_error')
  assert.equal(result.body.code, 'AO_RUNTIME_ERROR')
  assert.equal(result.body.requestId, 'rid-4')
  assert.equal(result.body.action, 'CreateOrder')
  assert.equal(result.body.details.runtimeError.message, 'runtime boom')
})

test('trace id sanitizer accepts safe IDs and rejects invalid values', () => {
  assert.equal(resolveTraceId('trace-abc_123.DEF'), 'trace-abc_123.DEF')
  assert.equal(resolveTraceId('short'), '')
  assert.equal(resolveTraceId('trace with space'), '')
  assert.equal(resolveTraceId('trace\nnewline'), '')
})

test('CORS allow-headers include x-trace-id', () => {
  assert.match(WRITE_API_CORS_ALLOW_HEADERS, /\bx-trace-id\b/)
})

test('CORS allow-headers include write PID override header', () => {
  assert.match(WRITE_API_CORS_ALLOW_HEADERS, /\bx-write-process-id\b/)
})

test('buildCommand defaults timestamp to epoch seconds when missing', () => {
  const built = buildCommand({ headers: {} }, { payload: { siteId: 'site-1' } }, 'CreateOrder')
  assert.equal(built.ok, true)
  assert.match(built.command.timestamp, /^[0-9]{10,}$/)
})

test('buildCommand resolves tenant from payload.tenant', () => {
  const built = buildCommand(
    { headers: {} },
    { payload: { tenant: 'tenant-payload', siteId: 'site-1' } },
    'CreateOrder',
  )
  assert.equal(built.ok, true)
  assert.equal(built.command.tenant, 'tenant-payload')
})

test('buildCommand rejects mismatched site scope values', () => {
  const built = buildCommand(
    { headers: {} },
    { siteId: 'site-top', payload: { siteId: 'site-payload' } },
    'CreateOrder',
  )
  assert.equal(built.ok, false)
  assert.equal(built.error, 'site_id_mismatch')
})

test('buildCommand preserves signed identity envelope fields', () => {
  const iso = '2026-04-16T00:00:00Z'
  const built = buildCommand(
    { headers: { 'x-request-id': 'header-rid' } },
    {
      Action: 'CreateOrder',
      'Request-Id': 'signed-rid',
      Actor: 'signed-actor',
      Tenant: 'signed-tenant',
      'Actor-Role': 'editor',
      timestamp: iso,
      Nonce: 'signed-nonce',
      payload: { siteId: 'site-1', items: [{ sku: 'sku-1', qty: 1 }] },
      signature: 'signed-sig',
      'Signature-Ref': 'signed-ref',
    },
    'CreateOrder',
    {
      defaultActor: 'gateway-default-actor',
      defaultRole: 'gateway-default-role',
      tenantFallback: 'gateway-default-tenant',
    },
  )
  assert.equal(built.ok, true)
  assert.equal(built.command.requestId, 'signed-rid')
  assert.equal(built.command.actor, 'signed-actor')
  assert.equal(built.command.tenant, 'signed-tenant')
  assert.equal(built.command.role, 'editor')
  assert.equal(built.command.timestamp, iso)
  assert.equal(built.command.nonce, 'signed-nonce')
  assert.equal(built.command.signature, 'signed-sig')
  assert.equal(built.command.signatureRef, 'signed-ref')
})

test('buildCommand normalizes ISO timestamp to epoch seconds', () => {
  const iso = '2026-04-15T20:00:00Z'
  const built = buildCommand(
    { headers: {} },
    { timestamp: iso, payload: { siteId: 'site-1' } },
    'CreateOrder',
  )
  assert.equal(built.ok, true)
  assert.equal(built.command.timestamp, String(Math.floor(Date.parse(iso) / 1000)))
})

test('buildCommand rejects malformed timestamp', () => {
  const built = buildCommand(
    { headers: {} },
    { timestamp: 'not-a-timestamp', payload: { siteId: 'site-1' } },
    'CreateOrder',
  )
  assert.equal(built.ok, false)
  assert.equal(built.error, 'invalid_timestamp')
})
