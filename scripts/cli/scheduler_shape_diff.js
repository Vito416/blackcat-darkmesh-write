#!/usr/bin/env node
import fs from 'fs'
import crypto from 'crypto'
import { httpbis, createSigner } from 'http-message-signatures'

function arg(name, fallback) {
  const idx = process.argv.indexOf(`--${name}`)
  if (idx === -1) return fallback
  return process.argv[idx + 1]
}

function must(v, name) {
  if (!v) throw new Error(`Missing --${name}`)
  return v
}

function base64UrlNoPad(buf) {
  return Buffer.from(buf).toString('base64url').replace(/=+$/g, '')
}

function base64Std(buf) {
  return Buffer.from(buf).toString('base64')
}

function sha256DigestBase64(body) {
  const hash = crypto.createHash('sha256').update(body).digest('base64')
  return `sha-256=:${hash}:`
}

function headerValue(headers, name) {
  const target = name.toLowerCase()
  for (const [k, v] of Object.entries(headers)) {
    if (k.toLowerCase() === target) return v
  }
  return undefined
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
  return b64.length % 4 === 0 ? b64 : b64 + '='.repeat(4 - (b64.length % 4))
}

function summarizeBody(text) {
  const out = {
    preview: String(text || '').replace(/\s+/g, ' ').slice(0, 180),
    isJson: false,
    hasCommitments: false,
    committedKeys: []
  }
  try {
    const parsed = JSON.parse(text)
    out.isJson = true
    if (parsed && typeof parsed === 'object' && parsed.commitments && typeof parsed.commitments === 'object') {
      out.hasCommitments = true
      const keys = new Set()
      for (const v of Object.values(parsed.commitments)) {
        if (v && typeof v === 'object' && Array.isArray(v.committed)) {
          for (const k of v.committed) keys.add(k)
        }
      }
      out.committedKeys = [...keys].sort()
    }
  } catch {
    // not json
  }
  return out
}

async function signHeaders({ wallet, keyIdFormat, url, method, headers }) {
  const keyObj = crypto.createPrivateKey({ key: wallet, format: 'jwk' })
  const nBuf = Buffer.from(wallet.n, 'base64url')
  const keyIdBody = keyIdFormat === 'base64' ? base64Std(nBuf) : base64UrlNoPad(nBuf)
  const keyId = `publickey:${keyIdBody}`
  const signer = createSigner(keyObj, 'rsa-pss-sha512', keyId)

  const signed = await httpbis.signMessage(
    { key: signer, fields: Object.keys(headers).sort(), params: ['alg', 'keyid'] },
    { method, url, headers }
  )
  const sig = headerValue(signed.headers, 'signature')
  const sigInput = headerValue(signed.headers, 'signature-input')
  if (!sig || !sigInput) throw new Error('Missing signature headers after signing')
  const sigName = sigNameFromSignatureHeader(sig)
  const sigB64 = signatureBase64FromHeader(sig)
  return {
    ...headers,
    signature: `comm-${sigName}=:${sigB64}:`,
    'signature-input': sigInput.replace(/^sig=/, `comm-${sigName}=`)
  }
}

function buildBodies(pid, scheduler, moduleId, committedFileObj) {
  const plainLower = {
    target: pid,
    type: 'Message',
    action: 'Ping',
    'data-protocol': 'ao',
    variant: 'ao.TN.1',
    data: ''
  }
  const plainUpper = {
    Target: pid,
    Type: 'Message',
    Action: 'Ping',
    'Data-Protocol': 'ao',
    Variant: 'ao.TN.1',
    Data: ''
  }
  const tagsShape = {
    tags: [
      { name: 'Action', value: 'Ping' },
      { name: 'Content-Type', value: 'application/json' },
      { name: 'Data-Protocol', value: 'ao' },
      { name: 'Type', value: 'Message' },
      { name: 'Variant', value: 'ao.TN.1' }
    ],
    data: ''
  }

  const withScheduler = {
    ...plainLower,
    scheduler,
    authority: scheduler
  }
  const withModule = moduleId ? { ...plainLower, module: moduleId } : null

  const cases = [
    { name: 'plain_lower', body: plainLower },
    { name: 'plain_upper', body: plainUpper },
    { name: 'tags_data_shape', body: tagsShape },
    { name: 'plain_with_scheduler', body: withScheduler }
  ]

  if (withModule) cases.push({ name: 'plain_with_module', body: withModule })
  if (committedFileObj?.body) cases.push({ name: 'committed_body_only', body: committedFileObj.body })
  if (committedFileObj) cases.push({ name: 'committed_full_file', body: committedFileObj })

  return cases
}

async function main() {
  const pid = must(arg('pid'), 'pid')
  const scheduler = arg('scheduler', 'n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo')
  const moduleId = arg('module', null)
  const urls = String(arg('urls', 'http://127.0.0.1:8734'))
    .split(',')
    .map((x) => x.trim())
    .filter(Boolean)
  const walletPath = arg('wallet', 'wallet.json')
  const committedPath = arg('committed-file', 'tmp/committed_ping.json')
  const outFile = arg(
    'out',
    `tmp/scheduler-shape-report-${new Date().toISOString().replace(/[:.]/g, '-')}.json`
  )

  const wallet = JSON.parse(fs.readFileSync(walletPath, 'utf8'))
  const committedFileObj = fs.existsSync(committedPath)
    ? JSON.parse(fs.readFileSync(committedPath, 'utf8'))
    : null
  const bodies = buildBodies(pid, scheduler, moduleId, committedFileObj)

  const headerProfiles = [
    {
      name: 'default_headers',
      build: (bodyStr) => ({
        'accept-bundle': 'true',
        'accept-codec': 'httpsig@1.0',
        'codec-device': 'httpsig@1.0',
        'content-type': 'application/json',
        'content-digest': sha256DigestBase64(bodyStr),
        'content-length': String(Buffer.byteLength(bodyStr))
      })
    },
    {
      name: 'transport_headers',
      build: (bodyStr) => ({
        'accept-bundle': 'true',
        'accept-codec': 'httpsig@1.0',
        'codec-device': 'httpsig@1.0',
        'signing-format': 'ans104',
        'require-codec': 'application/json',
        'content-type': 'application/json',
        'content-digest': sha256DigestBase64(bodyStr),
        'content-length': String(Buffer.byteLength(bodyStr))
      })
    }
  ]

  const keyIdFormats = ['base64', 'base64url']
  const results = []

  for (const base of urls) {
    const cleanBase = base.replace(/\/$/, '')
    const path = `/~scheduler@1.0/schedule?target=${pid}`
    const requestUrl = `${cleanBase}${path}`

    for (const keyIdFormat of keyIdFormats) {
      for (const hp of headerProfiles) {
        for (const c of bodies) {
          const bodyStr = JSON.stringify(c.body)
          const headers = hp.build(bodyStr)
          let status = null
          let ok = false
          let responseBody = ''
          let responseHeaders = {}
          let error = null

          try {
            const signedHeaders = await signHeaders({
              wallet,
              keyIdFormat,
              url: requestUrl,
              method: 'POST',
              headers
            })
            const res = await fetch(requestUrl, {
              method: 'POST',
              headers: signedHeaders,
              body: bodyStr
            })
            status = res.status
            ok = res.ok
            res.headers.forEach((v, k) => {
              responseHeaders[k] = v
            })
            responseBody = await res.text()
          } catch (e) {
            error = e?.message || String(e)
          }

          const summary = summarizeBody(responseBody)
          results.push({
            endpoint: cleanBase,
            path,
            keyIdFormat,
            headerProfile: hp.name,
            bodyCase: c.name,
            status,
            ok,
            error,
            responseHeaders,
            ...summary
          })
        }
      }
    }
  }

  const report = {
    generatedAt: new Date().toISOString(),
    pid,
    scheduler,
    module: moduleId,
    urls,
    cases: bodies.map((b) => b.name),
    results
  }
  fs.writeFileSync(outFile, JSON.stringify(report, null, 2))

  for (const r of results) {
    const keys = r.committedKeys.length ? `[${r.committedKeys.join(',')}]` : '[]'
    console.log(
      `${r.endpoint} ${r.keyIdFormat} ${r.headerProfile} ${r.bodyCase} => ${r.status} commitments=${r.hasCommitments} keys=${keys} preview="${r.preview}"`
    )
  }
  console.log(`\nSaved report: ${outFile}`)
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})

