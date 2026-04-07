import fs from 'fs'
import crypto from 'crypto'
import { connect, createSigner } from '@permaweb/aoconnect'

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

  const msgId = await ao.message({
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
  })
  const result = await ao.result({ process: PID, message: msgId })
  console.log(JSON.stringify(result, null, 2))
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
