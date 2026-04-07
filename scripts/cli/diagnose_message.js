import fs from 'fs'
import crypto from 'crypto'
import Arweave from 'arweave'
import { connect, createSigner } from '@permaweb/aoconnect'

function cleanEnv(val) {
  if (!val) return undefined
  const v = String(val).trim()
  if (!v || v === 'undefined' || v === 'null') return undefined
  return v
}

const PID = cleanEnv(process.env.AO_PID)
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

const PRIV_PEM = process.env.WORKER_ED25519_PRIV || 'tmp/worker-ed25519-priv.pem'
const WORKER_SIGN_URL = cleanEnv(process.env.WORKER_SIGN_URL)
const WORKER_AUTH_TOKEN = cleanEnv(process.env.WORKER_AUTH_TOKEN)
const SIGNATURE_REF = cleanEnv(process.env.SIGNATURE_REF) || 'worker-ed25519'

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

async function buildSignedCommand() {
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
      const body = await resp.text()
      throw new Error(`worker_sign_failed:${resp.status}:${body}`)
    }
    const signed = await resp.json()
    cmd.signature = signed.signature
    cmd.signatureRef = signed.signatureRef || cmd.signatureRef
  } else {
    const message = canonicalDetachedMessage(cmd)
    cmd.signature = signEd25519Hex(message, PRIV_PEM)
  }

  return cmd
}

async function main() {
  if (!PID) throw new Error('AO_PID is required')
  const jwk = JSON.parse(fs.readFileSync('wallet.json', 'utf-8'))
  const arweave = Arweave.init({ host: 'arweave.net', port: 443, protocol: 'https' })
  const walletAddr = await arweave.wallets.jwkToAddress(jwk)
  const ao = connect({
    MODE: 'mainnet', // aoconnect patched to keep Variant=ao.TN.1
    URL: HYPERBEAM_URL,
    SCHEDULER: HYPERBEAM_SCHEDULER,
    signer: createSigner(jwk)
  })

  const actionOverride = cleanEnv(process.env.AO_ACTION)
  const rawDataOverride = cleanEnv(process.env.AO_DATA)
  const cmd = await buildSignedCommand()
  const data =
    rawDataOverride !== undefined ? rawDataOverride : JSON.stringify(cmd)

  const variant = cleanEnv(process.env.AO_VARIANT) || 'ao.TN.1'
  const contentType = cleanEnv(process.env.AO_CONTENT_TYPE)
  const inputEnc = cleanEnv(process.env.AO_INPUT_ENCODING)
  const outputEnc = cleanEnv(process.env.AO_OUTPUT_ENCODING)
  const moduleId = cleanEnv(process.env.AO_MODULE) || cleanEnv(process.env.HB_MODULE)
  const owner = cleanEnv(process.env.AO_OWNER) || walletAddr
  const nonceTag = cleanEnv(process.env.AO_NONCE) || cmd.nonce || `nonce-${Math.random().toString(36).slice(2, 10)}`
  const tsTag = cleanEnv(process.env.AO_TIMESTAMP) || cmd.timestamp || new Date().toISOString()
  const params = {
    path: `/${PID}~process@1.0/push`,
    target: PID,
    data,
    Action: actionOverride || 'Write-Command',
    Type: 'Message',
    Variant: variant,
    'Data-Protocol': 'ao',
    ...(contentType ? { 'Content-Type': contentType } : {}),
    ...(inputEnc ? { 'Input-Encoding': inputEnc } : {}),
    ...(outputEnc ? { 'Output-Encoding': outputEnc } : {}),
    Status: '0',
    ...(owner ? { Owner: owner } : {}),
    ...(moduleId ? { Module: moduleId } : {}),
    Nonce: nonceTag,
    Timestamp: tsTag,
    'Content-Length': Buffer.byteLength(data).toString(),
    SDK: 'aoconnect',
    'signing-format': 'ans104',
    'accept-bundle': 'true',
    'require-codec': 'application/json'
  }

  const response = await ao.request(params)
  const bodyText = await response.text().catch(() => '')
  const headers = {}
  response.headers.forEach((v, k) => (headers[k] = v))
  console.log(
    JSON.stringify(
      {
        status: response.status,
        ok: response.ok,
        url: response.url,
        headers,
        body: bodyText
      },
      null,
      2
    )
  )
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
