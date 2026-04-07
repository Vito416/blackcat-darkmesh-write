import fs from 'fs'
import crypto from 'crypto'
import { httpbis, createSigner } from 'http-message-signatures'

function arg(flag, fallback) {
  const idx = process.argv.indexOf(flag)
  return idx >= 0 ? process.argv[idx + 1] : fallback
}

function must(val, name) {
  if (!val) throw new Error(`Missing ${name}`)
  return val
}

function base64Url(buf) {
  return Buffer.from(buf).toString('base64url')
}

function base64UrlNoPad(buf) {
  return Buffer.from(buf).toString('base64url').replace(/=+$/g, '')
}

function sha256DigestBase64(body) {
  const hash = crypto.createHash('sha256').update(body).digest('base64')
  return `sha-256=:${hash}:`
}

function sigNameFromSignatureHeader(sigHeader) {
  const match = String(sigHeader).match(/sig=:(.+):/)
  if (!match) throw new Error('Unable to parse signature header')
  const b64 = match[1]
  const pad = b64.length % 4 === 0 ? b64 : b64 + '='.repeat(4 - (b64.length % 4))
  const sigBytes = Buffer.from(pad, 'base64')
  const digest = crypto.createHash('sha256').update(sigBytes).digest()
  return base64UrlNoPad(digest).toLowerCase()
}

function signatureBase64FromHeader(sigHeader) {
  const match = String(sigHeader).match(/sig=:(.+):/)
  if (!match) throw new Error('Unable to parse signature header')
  const b64 = match[1]
  const pad = b64.length % 4 === 0 ? b64 : b64 + '='.repeat(4 - (b64.length % 4))
  Buffer.from(pad, 'base64')
  return pad
}

function loadWallet(path) {
  return JSON.parse(fs.readFileSync(path, 'utf8'))
}

function headerValue(headers, name) {
  const target = name.toLowerCase()
  for (const [key, value] of Object.entries(headers)) {
    if (key.toLowerCase() === target) return value
  }
  return undefined
}

function defaultMessage(action, data, variant) {
  return {
    tags: [
      { name: 'Action', value: action },
      { name: 'Content-Type', value: 'application/json' },
      { name: 'Data-Protocol', value: 'ao' },
      { name: 'Type', value: 'Message' },
      { name: 'Variant', value: variant }
    ],
    data: data ?? ''
  }
}

async function signRequest({ url, method, headers }) {
  const walletPath = arg('--wallet', 'wallet.json')
  const wallet = loadWallet(walletPath)
  const keyObj = crypto.createPrivateKey({ key: wallet, format: 'jwk' })
  const keyId = `publickey:${base64UrlNoPad(Buffer.from(wallet.n, 'base64url'))}`
  const signer = createSigner(keyObj, 'rsa-pss-sha512', keyId)

  return httpbis.signMessage(
    {
      key: signer,
      fields: Object.keys(headers).sort(),
      params: ['alg', 'keyid']
    },
    {
      method,
      url,
      headers
    }
  )
}

async function main() {
  const pid = must(arg('--pid'), '--pid')
  const urlBase = arg('--url', 'http://localhost:8734')
  const direct = process.argv.includes('--direct')
  const action = arg('--action', 'Ping')
  const variant = arg('--variant', 'ao.TN.1')
  const data = arg('--data', '')
  const messageFile = arg('--message-file')
  const rawBody = messageFile
    ? fs.readFileSync(messageFile, 'utf8')
    : JSON.stringify(defaultMessage(action, data, variant))

  const url = direct
    ? `${urlBase.replace(/\/$/, '')}/${pid}`
    : `${urlBase.replace(/\/$/, '')}/${pid}~process@1.0/push`
  const headers = {
    'accept-bundle': 'true',
    'accept-codec': 'httpsig@1.0',
    'codec-device': 'httpsig@1.0',
    'content-type': 'application/json',
    'content-digest': sha256DigestBase64(rawBody),
    'content-length': String(Buffer.byteLength(rawBody))
  }

  const signed = await signRequest({ url, method: 'POST', headers })
  const sig = headerValue(signed.headers, 'signature')
  const sigInput = headerValue(signed.headers, 'signature-input')
  if (!sig || !sigInput) {
    throw new Error('Missing signature headers from http-message-signatures')
  }
  const outHeaders = { ...headers }
  const sigName = sigNameFromSignatureHeader(sig)
  const sigB64 = signatureBase64FromHeader(sig)
  const commSigEntry = `comm-${sigName}=:${sigB64}:`
  const commSigInputEntry = sigInput.replace(/^sig=/, `comm-${sigName}=`)
  outHeaders.signature = commSigEntry
  outHeaders['signature-input'] = commSigInputEntry
  if (process.argv.includes('--debug')) {
    console.log('request-headers', outHeaders)
    console.log('request-body', rawBody)
  }
  if (process.argv.includes('--print-curl')) {
    const headerLines = Object.entries(outHeaders)
      .map(([k, v]) => `-H ${JSON.stringify(`${k}: ${v}`)}`)
      .join(' \\\n  ')
    console.log('curl -sS -X POST \\')
    console.log(`  ${headerLines} \\`)
    console.log(`  ${JSON.stringify(url)} \\`)
    console.log(`  -d ${JSON.stringify(rawBody)}`)
  }

  const res = await fetch(url, {
    method: 'POST',
    headers: outHeaders,
    body: rawBody
  })
  const text = await res.text()
  console.log(`status=${res.status}`)
  console.log(text)
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
