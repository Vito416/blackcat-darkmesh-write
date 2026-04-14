import test from 'node:test'
import assert from 'node:assert/strict'

import {
  WRITE_API_CORS_ALLOW_HEADERS,
  buildEnv,
  normalizeWriteResult,
  resolveTraceId,
} from '../../scripts/http/checkout_api_server.mjs'

test('WRITE_API_ACCEPT_EMPTY_RESULT defaults fail-closed', () => {
  const env = buildEnv({ NODE_ENV: 'test' })
  assert.equal(env.acceptEmptyResult, false)
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
