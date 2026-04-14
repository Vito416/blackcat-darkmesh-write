#!/usr/bin/env node
import http from 'node:http'
import fs from 'node:fs'
import crypto from 'node:crypto'
import { fileURLToPath } from 'node:url'

const DEFAULT_HB_URL = 'https://push.forward.computer'
const DEFAULT_SCHEDULER = 'n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo'
const DEFAULT_PORT = 8789
const DEFAULT_TIMEOUT_MS = 45000
const DEFAULT_RETRIES = 4

const PRODUCTION_LIKE_MODES = new Set(['production', 'prod', 'staging', 'stage', 'preprod', 'pre-production'])
const UNSAFE_NO_TOKEN_OVERRIDE = 'WRITE_API_UNSAFE_ALLOW_NO_TOKEN'
let env = null
let ao = null
let aoConnectLibPromise = null

function clean(value) {
  if (!value) return ''
  const next = String(value).trim()
  return next === '' || next === 'undefined' || next === 'null' ? '' : next
}

function isTrue(value) {
  const next = clean(value).toLowerCase()
  return next === '1' || next === 'true' || next === 'yes' || next === 'on'
}

function positiveInt(value, fallback) {
  const parsed = Number.parseInt(String(value || ''), 10)
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback
  return parsed
}

async function loadAoConnectLib() {
  if (!aoConnectLibPromise) {
    aoConnectLibPromise = import('@permaweb/aoconnect')
  }
  return aoConnectLibPromise
}

function isProductionLike(rawEnv = process.env) {
  const explicit = clean(rawEnv.WRITE_API_PRODUCTION_LIKE)
  if (explicit) {
    return isTrue(explicit)
  }
  const mode = clean(rawEnv.WRITE_API_MODE || rawEnv.APP_ENV || rawEnv.NODE_ENV).toLowerCase()
  return PRODUCTION_LIKE_MODES.has(mode)
}

export function buildEnv(rawEnv = process.env) {
  const built = {
    host: clean(rawEnv.HOST) || '0.0.0.0',
    port: positiveInt(rawEnv.PORT, DEFAULT_PORT),
    hbUrl: clean(rawEnv.WRITE_HB_URL) || clean(rawEnv.HB_URL) || DEFAULT_HB_URL,
    scheduler: clean(rawEnv.WRITE_HB_SCHEDULER) || clean(rawEnv.HB_SCHEDULER) || DEFAULT_SCHEDULER,
    mode: clean(rawEnv.WRITE_AO_MODE) || clean(rawEnv.AO_MODE) || 'mainnet',
    writePid: clean(rawEnv.WRITE_PROCESS_ID) || clean(rawEnv.AO_PID) || '',
    walletPath: clean(rawEnv.WRITE_WALLET_PATH) || clean(rawEnv.AO_WALLET_PATH) || 'wallet.json',
    walletJson: clean(rawEnv.WRITE_WALLET_JSON),
    apiToken: clean(rawEnv.WRITE_API_TOKEN) || '',
    signerUrl: clean(rawEnv.WRITE_SIGNER_URL) || clean(rawEnv.WORKER_SIGN_URL) || '',
    signerToken: clean(rawEnv.WRITE_SIGNER_TOKEN) || clean(rawEnv.WORKER_AUTH_TOKEN) || '',
    defaultActor: clean(rawEnv.WRITE_GATEWAY_ACTOR) || 'gateway-template',
    defaultRole: clean(rawEnv.WRITE_GATEWAY_ROLE) || 'admin',
    tenantFallback: clean(rawEnv.WRITE_TENANT_FALLBACK) || '',
    allowOrigin: clean(rawEnv.WRITE_API_ALLOW_ORIGIN) || '*',
    timeoutMs: positiveInt(rawEnv.WRITE_RESULT_TIMEOUT_MS, DEFAULT_TIMEOUT_MS),
    retries: positiveInt(rawEnv.WRITE_RESULT_RETRIES, DEFAULT_RETRIES),
    acceptEmptyResult: isTrue(clean(rawEnv.WRITE_API_ACCEPT_EMPTY_RESULT) || '0'),
    debug: isTrue(rawEnv.WRITE_API_DEBUG),
    productionLike: isProductionLike(rawEnv),
    unsafeAllowNoToken: isTrue(rawEnv[UNSAFE_NO_TOKEN_OVERRIDE]),
  }
  if (built.productionLike && !built.apiToken && !built.unsafeAllowNoToken) {
    throw new Error(`write_api_token_required:${UNSAFE_NO_TOKEN_OVERRIDE}`)
  }
  return built
}

function loadWallet(config = env) {
  if (!config) {
    throw new Error('env_not_initialized')
  }
  if (config.walletJson) {
    return JSON.parse(config.walletJson)
  }
  if (!config.walletPath || !fs.existsSync(config.walletPath)) {
    throw new Error(`wallet_missing:${config.walletPath}`)
  }
  return JSON.parse(fs.readFileSync(config.walletPath, 'utf8'))
}

function nowIso() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
}

function json(res, status, body) {
  res.statusCode = status
  res.setHeader('content-type', 'application/json; charset=utf-8')
  res.setHeader('cache-control', 'no-store')
  res.setHeader('x-content-type-options', 'nosniff')
  res.setHeader('x-frame-options', 'DENY')
  res.setHeader('referrer-policy', 'no-referrer')
  res.setHeader('access-control-allow-origin', env.allowOrigin)
  res.setHeader('access-control-allow-methods', 'GET,POST,OPTIONS')
  res.setHeader('access-control-allow-headers', 'content-type,authorization,x-api-token,x-request-id')
  res.end(JSON.stringify(body))
}

function requireAuth(req) {
  if (!env.apiToken) return true
  const authHeader = clean(req.headers.authorization)
  const tokenHeader = clean(req.headers['x-api-token'])
  const bearer = authHeader.toLowerCase().startsWith('bearer ') ? authHeader.slice(7).trim() : ''
  return bearer === env.apiToken || tokenHeader === env.apiToken
}

function readJsonBody(req, maxBytes = 256 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let total = 0
    req.on('data', (chunk) => {
      total += chunk.length
      if (total > maxBytes) {
        reject(new Error('payload_too_large'))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      try {
        const raw = Buffer.concat(chunks).toString('utf8')
        const parsed = raw ? JSON.parse(raw) : {}
        if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
          reject(new Error('invalid_json'))
          return
        }
        resolve(parsed)
      } catch {
        reject(new Error('invalid_json'))
      }
    })
    req.on('error', reject)
  })
}

function firstString(...values) {
  for (const value of values) {
    const trimmed = clean(value)
    if (trimmed) return trimmed
  }
  return ''
}

function commandRequestId(req, body) {
  return (
    firstString(req.headers['x-request-id'], body.requestId, body['request-id']) ||
    `gw-write-${Date.now()}-${crypto.randomBytes(4).toString('hex')}`
  )
}

function commandNonce(body) {
  return firstString(body.nonce) || `nonce-${crypto.randomBytes(8).toString('hex')}`
}

function buildPayload(body) {
  if (body.payload && typeof body.payload === 'object' && !Array.isArray(body.payload)) {
    return { ...body.payload }
  }
  const payload = { ...body }
  delete payload.action
  delete payload.requestId
  delete payload['request-id']
  delete payload.actor
  delete payload.tenant
  delete payload.role
  delete payload.timestamp
  delete payload.nonce
  delete payload.signatureRef
  delete payload.signature
  delete payload.siteId
  delete payload.templateAction
  return payload
}

function inferExpectedAction(pathname) {
  if (pathname === '/api/checkout/order') return 'CreateOrder'
  if (pathname === '/api/checkout/payment-intent') return 'CreatePaymentIntent'
  return ''
}

function validateRouteAction(bodyAction, expectedAction) {
  if (!bodyAction) return { ok: true }
  const normalized = String(bodyAction).trim()
  if (!normalized) return { ok: true }
  if (normalized === expectedAction) return { ok: true }
  if (normalized === 'checkout.create-order' && expectedAction === 'CreateOrder') return { ok: true }
  if (normalized === 'checkout.create-payment-intent' && expectedAction === 'CreatePaymentIntent') {
    return { ok: true }
  }
  return { ok: false, error: 'action_route_mismatch', detail: { expectedAction, providedAction: normalized } }
}

function buildCommand(req, body, expectedAction) {
  const payload = buildPayload(body)
  const siteId = firstString(body.siteId, payload.siteId)
  if (siteId && !payload.siteId) payload.siteId = siteId

  const actionCheck = validateRouteAction(body.action, expectedAction)
  if (!actionCheck.ok) return actionCheck

  const tenant = firstString(body.tenant, payload.siteId, env.tenantFallback)
  if (!tenant) {
    return { ok: false, error: 'tenant_required', detail: 'tenant or payload.siteId is required' }
  }

  const command = {
    action: expectedAction,
    requestId: commandRequestId(req, body),
    actor: firstString(body.actor, env.defaultActor),
    tenant,
    role: firstString(body.role, env.defaultRole),
    timestamp: firstString(body.timestamp, nowIso()),
    nonce: commandNonce(body),
    payload,
  }

  const signatureRef = firstString(body.signatureRef)
  const signature = firstString(body.signature)
  if (signatureRef) command.signatureRef = signatureRef
  if (signature) command.signature = signature

  return { ok: true, command }
}

async function maybeSignCommand(command) {
  if (command.signature && command.signatureRef) return command
  if (!env.signerUrl) {
    throw new Error('signature_required_no_signer')
  }
  if (!env.signerToken) {
    throw new Error('signer_token_missing')
  }
  const response = await fetch(env.signerUrl, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${env.signerToken}`,
    },
    body: JSON.stringify(command),
  })
  const text = await response.text().catch(() => '')
  if (!response.ok) {
    throw new Error(`signer_failed:${response.status}:${text.slice(0, 180)}`)
  }
  let parsed = null
  try {
    parsed = text ? JSON.parse(text) : null
  } catch {
    parsed = null
  }
  const signature = firstString(parsed?.signature)
  const signatureRef = firstString(parsed?.signatureRef)
  if (!signature || !signatureRef) {
    throw new Error('signer_invalid_response')
  }
  return {
    ...command,
    signature,
    signatureRef,
  }
}

async function withRetry(label, fn, attempts) {
  let lastError = null
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      return await fn(attempt + 1)
    } catch (error) {
      lastError = error
      if (attempt + 1 >= attempts) break
      await new Promise((resolve) => setTimeout(resolve, 600 * (attempt + 1)))
    }
  }
  throw new Error(`${label}_failed:${lastError instanceof Error ? lastError.message : String(lastError)}`)
}

function timeoutPromise(label, ms) {
  return new Promise((_, reject) => {
    const timer = setTimeout(() => reject(new Error(`timeout_${label}_${ms}ms`)), ms)
    timer.unref?.()
  })
}

async function withTimeout(label, promiseFactory, ms) {
  return Promise.race([promiseFactory(), timeoutPromise(label, ms)])
}

function writeMessageTags() {
  return [
    { name: 'Action', value: 'Write-Command' },
    { name: 'Variant', value: 'ao.TN.1' },
    { name: 'Content-Type', value: 'application/json' },
    { name: 'Input-Encoding', value: 'JSON-1' },
    { name: 'Output-Encoding', value: 'JSON-1' },
    { name: 'Data-Protocol', value: 'ao' },
    { name: 'Type', value: 'Message' },
  ]
}

async function sendWriteCommand(command) {
  if (!env.writePid) throw new Error('WRITE_PROCESS_ID missing')

  const data = JSON.stringify(command)
  const slotOrMessage = await withRetry(
    'ao_message',
    () =>
      withTimeout(
        'ao_message',
        () =>
          ao.message({
            process: env.writePid,
            tags: writeMessageTags(),
            data,
          }),
        env.timeoutMs,
      ),
    env.retries,
  )

  const primary = await withRetry(
    'ao_result',
    () =>
      withTimeout(
        'ao_result',
        () => ao.result({ process: env.writePid, message: String(slotOrMessage) }),
        env.timeoutMs,
      ),
    env.retries,
  ).catch(() => null)

  if (primary) {
    return {
      transport: 'aoconnect.result',
      slotOrMessage: String(slotOrMessage),
      raw: primary,
    }
  }

  const computeEndpoint =
    `${env.hbUrl.replace(/\/$/, '')}/${env.writePid}~process@1.0/compute=${slotOrMessage}` +
    '?accept-bundle=true&require-codec=application/json'

  const fallback = await withRetry(
    'compute_fetch',
    async () => {
      const response = await fetch(computeEndpoint, { method: 'GET' })
      const text = await response.text().catch(() => '')
      if (!response.ok) {
        throw new Error(`http_${response.status}:${text.slice(0, 180)}`)
      }
      try {
        return text ? JSON.parse(text) : {}
      } catch {
        throw new Error('invalid_json')
      }
    },
    env.retries,
  )

  return {
    transport: 'compute_fallback',
    slotOrMessage: String(slotOrMessage),
    raw: fallback,
  }
}

export function normalizeWriteResult(rawResult, context = {}, runtimeEnv = env) {
  const cfg = runtimeEnv || { acceptEmptyResult: false, debug: false }
  const failResult = (error, code, message, details) => ({
    status: 502,
    body: {
      ok: false,
      error,
      code,
      message,
      requestId: context.requestId || null,
      action: context.action || null,
      ...(details ? { details } : {}),
      ...(cfg.debug ? { raw: rawResult } : {}),
    },
  })

  const normalized = rawResult?.results?.raw || rawResult?.raw || rawResult || {}
  const output = normalized?.Output ?? normalized?.output ?? null

  let envelope = null
  if (typeof output === 'string') {
    if (output.trim() !== '') {
      try {
        envelope = JSON.parse(output)
      } catch {
        return failResult(
          'invalid_ao_result_payload',
          'INVALID_AO_RESULT',
          'AO returned non-JSON write result payload',
          { outputPreview: output.slice(0, 180) },
        )
      }
    }
  } else if (output && typeof output === 'object') {
    envelope = output
  } else if (normalized && typeof normalized === 'object' && typeof normalized.status === 'string') {
    envelope = normalized
  }

  if (!envelope) {
    const maybeError = normalized?.Error
    const hasRuntimeError =
      maybeError &&
      typeof maybeError === 'object' &&
      Object.keys(maybeError).length > 0
    if (!hasRuntimeError && cfg.acceptEmptyResult) {
      return {
        status: 202,
        body: {
          status: 'OK',
          code: 'ACCEPTED_ASYNC',
          message: 'command accepted; result envelope unavailable',
          requestId: context.requestId || null,
          action: context.action || null,
        },
      }
    }
    if (hasRuntimeError) {
      return failResult(
        'ao_runtime_error',
        'AO_RUNTIME_ERROR',
        'AO compute returned runtime error payload',
        { runtimeError: maybeError },
      )
    }
    return failResult(
      'empty_ao_result',
      'EMPTY_AO_RESULT',
      'AO transport succeeded but no write result envelope was returned',
    )
  }

  if (typeof envelope !== 'object' || Array.isArray(envelope) || !envelope) {
    return failResult(
      'invalid_ao_result_payload',
      'INVALID_AO_RESULT',
      'AO result envelope is not an object',
    )
  }

  const statusText = String(envelope.status || '').toUpperCase()
  if (!statusText) {
    return failResult(
      'invalid_ao_result_payload',
      'INVALID_AO_RESULT',
      'AO result envelope missing status field',
      { envelope },
    )
  }
  if (statusText === 'OK') {
    return { status: 200, body: envelope }
  }

  const code = firstString(envelope.code).toUpperCase()
  const status =
    code === 'INVALID_INPUT' || code === 'PAYLOAD_TOO_LARGE'
      ? 400
      : code === 'UNAUTHORIZED'
        ? 401
        : code === 'FORBIDDEN'
          ? 403
          : code === 'NOT_FOUND'
            ? 404
            : code === 'CONFLICT'
              ? 409
              : code === 'RATE_LIMITED'
                ? 429
                : 422
  return { status, body: envelope }
}

async function handleCheckout(req, res, pathname) {
  const expectedAction = inferExpectedAction(pathname)
  if (!expectedAction) {
    json(res, 404, { ok: false, error: 'not_found' })
    return
  }

  let body = {}
  try {
    body = await readJsonBody(req)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    if (message === 'payload_too_large') {
      json(res, 413, { ok: false, error: 'payload_too_large' })
      return
    }
    json(res, 400, { ok: false, error: 'invalid_json' })
    return
  }

  const built = buildCommand(req, body, expectedAction)
  if (!built.ok) {
    json(res, 400, { ok: false, error: built.error, detail: built.detail || null })
    return
  }

  try {
    const signed = await maybeSignCommand(built.command)
    const transport = await sendWriteCommand(signed)
    const normalized = normalizeWriteResult(transport.raw, {
      requestId: signed.requestId,
      action: signed.action,
    })

    if (env.debug) {
      normalized.body.transport = {
        mode: transport.transport,
        slotOrMessage: transport.slotOrMessage,
      }
      normalized.body.command = {
        action: signed.action,
        requestId: signed.requestId,
        tenant: signed.tenant,
        actor: signed.actor,
      }
    }

    json(res, normalized.status, normalized.body)
  } catch (error) {
    json(res, 502, {
      ok: false,
      error: 'write_command_failed',
      message: error instanceof Error ? error.message : String(error),
    })
  }
}

export function createServer() {
  return http.createServer(async (req, res) => {
    const method = (req.method || 'GET').toUpperCase()
    const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`)

    if (method === 'OPTIONS') {
      res.statusCode = 204
      res.setHeader('access-control-allow-origin', env.allowOrigin)
      res.setHeader('access-control-allow-methods', 'GET,POST,OPTIONS')
      res.setHeader('access-control-allow-headers', 'content-type,authorization,x-api-token,x-request-id')
      res.end('')
      return
    }

    if (url.pathname === '/healthz' && method === 'GET') {
      json(res, 200, {
        ok: true,
        service: 'write-checkout-api',
        writePidConfigured: Boolean(env.writePid),
        signerConfigured: Boolean(env.signerUrl),
        hbUrl: env.hbUrl,
        scheduler: env.scheduler,
        now: nowIso(),
      })
      return
    }

    if (!requireAuth(req)) {
      json(res, 401, { ok: false, error: 'unauthorized' })
      return
    }

    if (method !== 'POST') {
      json(res, 405, { ok: false, error: 'method_not_allowed' })
      return
    }

    if (url.pathname === '/api/checkout/order' || url.pathname === '/api/checkout/payment-intent') {
      await handleCheckout(req, res, url.pathname)
      return
    }

    json(res, 404, { ok: false, error: 'not_found' })
  })
}

export async function startServer(rawEnv = process.env) {
  env = buildEnv(rawEnv)
  const wallet = loadWallet(env)
  const { connect, createSigner } = await loadAoConnectLib()
  ao = connect({
    MODE: env.mode,
    URL: env.hbUrl,
    SCHEDULER: env.scheduler,
    signer: createSigner(wallet),
  })

  const server = createServer()
  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(env.port, env.host, () => resolve())
  })

  console.log(
    JSON.stringify({
      event: 'write_checkout_api_started',
      host: env.host,
      port: env.port,
      writePidConfigured: Boolean(env.writePid),
      signerConfigured: Boolean(env.signerUrl),
      hbUrl: env.hbUrl,
      scheduler: env.scheduler,
      productionLike: env.productionLike,
      requiresAuth: Boolean(env.apiToken),
      startedAt: nowIso(),
    }),
  )

  return server
}

function isMainModule() {
  if (!process.argv[1]) return false
  try {
    return fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url))
  } catch {
    return false
  }
}

if (isMainModule()) {
  startServer().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error))
    process.exit(1)
  })
}
