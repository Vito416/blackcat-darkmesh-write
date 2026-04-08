import fs from 'fs'
import crypto from 'crypto'
import { connect, createSigner } from '@permaweb/aoconnect'
import { createData, ArweaveSigner } from 'arbundles'
import {
  readResponseWithRetry,
  runWithRetry,
  withTimeout
} from './retry_helpers.js'

function cleanEnv(val) {
  if (!val) return undefined
  const v = String(val).trim()
  if (!v || v === 'undefined' || v === 'null') return undefined
  return v
}

const PID = cleanEnv(process.env.AO_PID) || 'QFCAzUYXtgZI29S4NFD9T-p-cj21rmvCa5DINux-2XE'
const HYPERBEAM_URL =
  cleanEnv(process.env.HB_URL) ||
  cleanEnv(process.env.HYPERBEAM_URL) ||
  cleanEnv(process.env.AO_URL) ||
  'https://push-1.forward.computer'
const HYPERBEAM_SCHEDULER =
  cleanEnv(process.env.HB_SCHEDULER) ||
  cleanEnv(process.env.HYPERBEAM_SCHEDULER) ||
  cleanEnv(process.env.AO_SCHEDULER) ||
  'n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo'
const RAW_DATA_OVERRIDE = cleanEnv(process.env.AO_DATA)
const STATUS_TAG = cleanEnv(process.env.AO_STATUS)
const AO_VARIANT = cleanEnv(process.env.AO_VARIANT) || 'ao.TN.1'
const AO_CONTENT_TYPE = cleanEnv(process.env.AO_CONTENT_TYPE) || 'application/json'
const AO_INPUT_ENCODING = cleanEnv(process.env.AO_INPUT_ENCODING) || 'JSON-1'
const AO_OUTPUT_ENCODING = cleanEnv(process.env.AO_OUTPUT_ENCODING) || 'JSON-1'
const AO_INGRESS_MODE = cleanEnv(process.env.AO_INGRESS_MODE) || 'auto' // auto | push | scheduler

const PRIV_PEM = process.env.WORKER_ED25519_PRIV || 'tmp/worker-ed25519-priv.pem'
const WORKER_SIGN_URL = cleanEnv(process.env.WORKER_SIGN_URL)
const WORKER_AUTH_TOKEN = cleanEnv(process.env.WORKER_AUTH_TOKEN)
const SIGNATURE_REF = cleanEnv(process.env.SIGNATURE_REF) || 'worker-ed25519-test'

function stableStringify(value) {
  if (value === null || value === undefined) return 'null'
  if (Array.isArray(value)) {
    return `[${value.map(stableStringify).join(',')}]`
  }
  if (typeof value === 'object') {
    const keys = Object.keys(value).sort()
    return `{${keys
      .map((k) => `${JSON.stringify(k)}:${stableStringify(value[k])}`)
      .join(',')}}`
  }
  return JSON.stringify(value)
}

function canonicalDetachedMessage(cmd) {
  const parts = [
    cmd.action || '',
    cmd.tenant || '',
    cmd.actor || '',
    cmd.timestamp || '',
    cmd.nonce || '',
    stableStringify(cmd.payload || {}),
    cmd.requestId || ''
  ]
  return parts.join('|')
}

function signEd25519Hex(message, pemPath) {
  const pem = fs.readFileSync(pemPath)
  const sig = crypto.sign(null, Buffer.from(message), pem)
  return Buffer.from(sig).toString('hex')
}

async function sendViaSchedulerDirect({ baseUrl, pid, jwk, data, variant }) {
  const signer = new ArweaveSigner(jwk)
  const tags = [
    { name: 'Action', value: 'Write-Command' },
    { name: 'Content-Type', value: 'application/json' },
    { name: 'Input-Encoding', value: 'JSON-1' },
    { name: 'Output-Encoding', value: 'JSON-1' },
    { name: 'signing-format', value: 'ans104' },
    { name: 'accept-bundle', value: 'true' },
    { name: 'require-codec', value: 'application/json' },
    { name: 'Data-Protocol', value: 'ao' },
    { name: 'Type', value: 'Message' },
    { name: 'Variant', value: variant }
  ]
  const item = createData(data, signer, { target: pid, tags })
  await item.sign(signer)
  const endpoint = `${baseUrl.replace(/\/$/, '')}/~scheduler@1.0/schedule?target=${pid}`
  const res = await fetch(endpoint, {
    method: 'POST',
    headers: {
      'content-type': 'application/ans104',
      'codec-device': 'ans104@1.0'
    },
    body: item.getRaw()
  })
  const text = await res.text().catch(() => '')
  let parsed = null
  try {
    parsed = JSON.parse(text)
  } catch {
    parsed = null
  }
  const slot = Number(res.headers.get('slot') || parsed?.slot || '')
  if (!res.ok) {
    throw new Error(`scheduler_send_failed:${res.status}:${text.slice(0, 220)}`)
  }
  if (!Number.isFinite(slot)) {
    throw new Error(`scheduler_send_no_slot:${text.slice(0, 220)}`)
  }
  return {
    ingressMode: 'scheduler',
    slot,
    dataItemId: item.id,
    status: res.status,
    endpoint,
    bodyPreview: text.slice(0, 400)
  }
}

async function fetchResultViaComputeRequest(pid, slotOrMessage) {
  const endpoint = `${HYPERBEAM_URL.replace(/\/$/, '')}/${pid}~process@1.0/compute=${slotOrMessage}?accept-bundle=true&require-codec=application/json`
  const outcome = await readResponseWithRetry({
    url: endpoint,
    label: 'compute_fetch',
    attempts: 4,
    timeoutMs: 45000,
    baseDelayMs: 750,
    maxDelayMs: 6000,
    bodyPreviewLimit: 800,
    parseJson: true,
    request: () => fetch(endpoint, { method: 'GET' })
  })
  const parsed = outcome.parsed || null
  return {
    ok: outcome.ok,
    status: outcome.status,
    parsed,
    normalized: parsed?.results?.raw || parsed?.raw || parsed,
    bodyPreview: outcome.bodyPreview,
    attempts: outcome.attempts,
    retryCount: outcome.retryCount,
    errorClass: outcome.errorClass,
    error: outcome.ok ? null : outcome.error || outcome.errorClass
  }
}

async function resolveResult({ ao, pid, slotOrMessage }) {
  const primary = await runWithRetry(
    () => withTimeout(ao.result({ process: pid, message: slotOrMessage }), 45000, 'ao.result'),
    {
      label: 'ao.result',
      attempts: 4,
      baseDelayMs: 750,
      maxDelayMs: 6000
    }
  )

  if (primary.ok) {
    return {
      resultMode: 'aoconnect.result',
      result: primary.value,
      attempts: primary.attempts,
      retryCount: primary.retryCount,
      errorClass: primary.errorClass
    }
  }

  const fallback = await fetchResultViaComputeRequest(pid, slotOrMessage)
  if (!fallback.ok) {
    throw new Error(
      `result_fetch_failed: primary=${primary.errorClass}:${primary.error}; primary_attempts=${primary.attempts}; fallback=${fallback.errorClass}:${fallback.error || fallback.errorClass}; fallback_attempts=${fallback.attempts}; fallback_status=${fallback.status ?? 'na'}; fallback_preview=${fallback.bodyPreview || ''}`
    )
  }

  return {
    resultMode: 'aoconnect.request_fallback',
    status: fallback.status,
    result: fallback.normalized,
    raw: fallback.parsed,
    attempts: fallback.attempts,
    retryCount: fallback.retryCount,
    errorClass: fallback.errorClass,
    primaryAttempts: primary.attempts,
    primaryErrorClass: primary.errorClass,
    primaryError: primary.error
  }
}

async function main() {
  // Quick sanity check so we don't fail with cryptic "Invalid URL"
  try {
    new URL(HYPERBEAM_URL)
  } catch (e) {
    throw new Error(`AO_URL invalid: ${HYPERBEAM_URL}`)
  }
  const jwk = JSON.parse(fs.readFileSync('wallet.json', 'utf-8'))
  const ao = connect({
    MODE: 'mainnet', // patched aoconnect keeps Variant=ao.TN.1 now
    URL: HYPERBEAM_URL,
    SCHEDULER: HYPERBEAM_SCHEDULER,
    signer: createSigner(jwk)
  })

  const nowIso = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
  const cmd = {
    action: 'SaveDraftPage',
    requestId: `req-${Date.now()}`,
    actor: 'worker-test',
    tenant: 'blackcat',
    role: 'admin',
    timestamp: nowIso,
    nonce: `nonce-${Math.random().toString(36).slice(2, 10)}`,
    signatureRef: SIGNATURE_REF,
    payload: {
      siteId: 'site-demo',
      pageId: 'page-demo',
      locale: 'en',
      blocks: [{ type: 'text', value: 'hello from worker test' }]
    }
  }

  if (WORKER_SIGN_URL) {
    if (!WORKER_AUTH_TOKEN) {
      throw new Error('WORKER_AUTH_TOKEN required for WORKER_SIGN_URL')
    }
    const resp = await fetch(WORKER_SIGN_URL, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${WORKER_AUTH_TOKEN}`
      },
      body: JSON.stringify(cmd)
    })
    if (!resp.ok) {
      throw new Error(`worker_sign_failed:${resp.status}`)
    }
    const signed = await resp.json()
    cmd.signature = signed.signature
    cmd.signatureRef = signed.signatureRef || cmd.signatureRef
  } else {
    const message = canonicalDetachedMessage(cmd)
    cmd.signature = signEd25519Hex(message, PRIV_PEM)
  }

  const data = RAW_DATA_OVERRIDE !== undefined ? RAW_DATA_OVERRIDE : JSON.stringify(cmd)

  const sendViaPush = () =>
    withTimeout(
      ao.message({
        process: PID,
        tags: [
          { name: 'Action', value: 'Write-Command' },
          { name: 'Variant', value: AO_VARIANT },
          { name: 'Content-Type', value: AO_CONTENT_TYPE },
          { name: 'Input-Encoding', value: AO_INPUT_ENCODING },
          { name: 'Output-Encoding', value: AO_OUTPUT_ENCODING },
          { name: 'Data-Protocol', value: 'ao' },
          ...(STATUS_TAG ? [{ name: 'Status', value: STATUS_TAG }] : [])
        ],
        data
      }),
      30000,
      'ao.message'
    )

  let sendMeta = null
  if (AO_INGRESS_MODE === 'push') {
    const slot = await sendViaPush()
    sendMeta = { ingressMode: 'push', slot: Number(slot), messageIdOrSlot: slot }
  } else if (AO_INGRESS_MODE === 'scheduler') {
    sendMeta = await sendViaSchedulerDirect({
      baseUrl: HYPERBEAM_URL,
      pid: PID,
      jwk,
      data,
      variant: AO_VARIANT
    })
  } else {
    try {
      const schedulerMeta = await sendViaSchedulerDirect({
        baseUrl: HYPERBEAM_URL,
        pid: PID,
        jwk,
        data,
        variant: AO_VARIANT
      })
      sendMeta = schedulerMeta
    } catch (schedulerErr) {
      const slot = await sendViaPush()
      sendMeta = {
        ingressMode: 'push',
        slot: Number(slot),
        messageIdOrSlot: slot,
        schedulerError: schedulerErr?.message || String(schedulerErr)
      }
    }
  }

  let slotOrMessage = String(
    Number.isFinite(sendMeta?.slot) ? sendMeta.slot : sendMeta?.messageIdOrSlot
  )

  try {
    const resolved = await resolveResult({ ao, pid: PID, slotOrMessage })
    console.log(
      JSON.stringify(
        {
          ...resolved,
          sendMeta,
          messageIdOrSlot: slotOrMessage
        },
        null,
        2
      )
    )
    return
  } catch (err) {
    // Auto mode safety: if /push ingress accepted but readback stalls/fails,
    // retry through scheduler-direct to force a numeric slot we can read back.
    if (AO_INGRESS_MODE === 'auto' && sendMeta?.ingressMode === 'push') {
      const schedulerMeta = await sendViaSchedulerDirect({
        baseUrl: HYPERBEAM_URL,
        pid: PID,
        jwk,
        data,
        variant: AO_VARIANT
      })
      slotOrMessage = String(
        Number.isFinite(schedulerMeta?.slot)
          ? schedulerMeta.slot
          : schedulerMeta?.messageIdOrSlot
      )
      const resolved = await resolveResult({ ao, pid: PID, slotOrMessage })
      console.log(
        JSON.stringify(
          {
            ...resolved,
            sendMeta: {
              ...schedulerMeta,
              autoRetryFromPushError: err?.message || String(err),
              previousPushMeta: sendMeta
            },
            messageIdOrSlot: slotOrMessage
          },
          null,
          2
        )
      )
      return
    }
    throw err
  }
}

main()
  .then(() => {
    // Keep CLI deterministic: close even if downstream libs leave open handles.
    process.exit(0)
  })
  .catch((err) => {
    console.error(err)
    process.exit(1)
  })
