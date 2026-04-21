#!/usr/bin/env node
import fs from 'fs'
import { connect, createSigner } from '@permaweb/aoconnect'

function arg(name, fallback) {
  const idx = process.argv.indexOf(`--${name}`)
  if (idx === -1) return fallback
  return process.argv[idx + 1]
}

function must(v, name) {
  if (!v) throw new Error(`Missing --${name}`)
  return v
}

function isPrintableUtf8(buf) {
  const s = Buffer.from(buf).toString('utf8')
  const replaced = s.replace(/[\x20-\x7E\r\n\t]/g, '')
  return replaced.length < Math.max(16, s.length * 0.02)
}

async function readBody(body) {
  if (body == null) return { kind: 'none', size: 0, text: '' }
  if (typeof body === 'string') {
    return { kind: 'string', size: Buffer.byteLength(body), text: body }
  }
  if (Buffer.isBuffer(body)) {
    return isPrintableUtf8(body)
      ? { kind: 'buffer-utf8', size: body.length, text: body.toString('utf8') }
      : { kind: 'buffer-b64', size: body.length, base64: body.toString('base64') }
  }
  if (body instanceof Uint8Array) {
    const b = Buffer.from(body)
    return isPrintableUtf8(b)
      ? { kind: 'uint8array-utf8', size: b.length, text: b.toString('utf8') }
      : { kind: 'uint8array-b64', size: b.length, base64: b.toString('base64') }
  }
  if (body instanceof ArrayBuffer) {
    const b = Buffer.from(new Uint8Array(body))
    return isPrintableUtf8(b)
      ? { kind: 'arraybuffer-utf8', size: b.length, text: b.toString('utf8') }
      : { kind: 'arraybuffer-b64', size: b.length, base64: b.toString('base64') }
  }
  if (typeof Blob !== 'undefined' && body instanceof Blob) {
    const ab = await body.arrayBuffer()
    const b = Buffer.from(new Uint8Array(ab))
    return isPrintableUtf8(b)
      ? { kind: 'blob-utf8', size: b.length, text: b.toString('utf8') }
      : { kind: 'blob-b64', size: b.length, base64: b.toString('base64') }
  }

  return { kind: typeof body, size: 0, text: String(body) }
}

async function main() {
  const pid = must(arg('pid'), 'pid')
  const url = arg('url', 'http://127.0.0.1:8734')
  const scheduler = arg('scheduler', 'n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo')
  const walletPath = arg('wallet', 'wallet.json')
  const action = arg('action', 'Ping')
  const data = arg('data', '')
  const outFile = arg(
    'out',
    `tmp/aomessage-wire-${new Date().toISOString().replace(/[:.]/g, '-')}.json`
  )

  const jwk = JSON.parse(fs.readFileSync(walletPath, 'utf8'))
  const origFetch = globalThis.fetch
  if (!origFetch) throw new Error('global fetch is unavailable')

  let captured = null

  globalThis.fetch = async (input, init = {}) => {
    const reqUrl = typeof input === 'string' ? input : String(input?.url || input)
    const target = reqUrl.includes('process@1.0/push') || reqUrl.includes('/~scheduler@1.0/schedule')
    if (target) {
      const headersObj = {}
      const h = new Headers(init.headers || {})
      h.forEach((v, k) => {
        headersObj[k] = v
      })
      const reqBody = await readBody(init.body)
      const startedAt = new Date().toISOString()
      const res = await origFetch(input, init)
      const txt = await res.clone().text().catch(() => '')
      const responseHeaders = {}
      res.headers.forEach((v, k) => {
        responseHeaders[k] = v
      })
      captured = {
        startedAt,
        request: {
          url: reqUrl,
          method: init.method || 'GET',
          headers: headersObj,
          body: reqBody
        },
        response: {
          status: res.status,
          ok: res.ok,
          headers: responseHeaders,
          bodyPreview: txt.slice(0, 2000)
        }
      }
      return res
    }
    return origFetch(input, init)
  }

  try {
    const ao = connect({
      MODE: 'mainnet',
      URL: url,
      SCHEDULER: scheduler,
      signer: createSigner(jwk)
    })

    let messageId = null
    let sendError = null
    try {
      messageId = await ao.message({
        process: pid,
        tags: [
          { name: 'Action', value: action },
          { name: 'Variant', value: 'ao.TN.1' },
          { name: 'Type', value: 'Message' },
          { name: 'Data-Protocol', value: 'ao' },
          { name: 'Content-Type', value: 'application/json' },
          { name: 'Input-Encoding', value: 'JSON-1' },
          { name: 'Output-Encoding', value: 'JSON-1' }
        ],
        data
      })
    } catch (e) {
      sendError = e?.message || String(e)
    }

    const out = {
      generatedAt: new Date().toISOString(),
      endpoint: url,
      scheduler,
      pid,
      action,
      messageId,
      sendError,
      captured
    }

    fs.writeFileSync(outFile, JSON.stringify(out, null, 2))
    console.log(`Saved: ${outFile}`)
    if (captured) {
      console.log(
        `Captured ${captured.request.method} ${captured.request.url} -> ${captured.response.status}`
      )
    } else {
      console.log('No matching wire request captured.')
    }
  } finally {
    globalThis.fetch = origFetch
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})

