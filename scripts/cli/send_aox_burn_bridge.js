#!/usr/bin/env node
import fs from 'fs'
import { createData, ArweaveSigner } from 'arbundles'

function arg(name, fallback) {
  const idx = process.argv.indexOf(`--${name}`)
  if (idx === -1) return fallback
  return process.argv[idx + 1]
}

function hasArg(name) {
  return process.argv.includes(`--${name}`)
}

function asBool(value, fallback = false) {
  if (value === undefined || value === null) return fallback
  const v = String(value).trim().toLowerCase()
  if (v === '1' || v === 'true' || v === 'yes' || v === 'on') return true
  if (v === '0' || v === 'false' || v === 'no' || v === 'off') return false
  return fallback
}

function ensure(val, name) {
  if (val === undefined || val === null || String(val).trim() === '') {
    throw new Error(`Missing --${name}`)
  }
  return String(val).trim()
}

async function main() {
  const send = asBool(arg('send', '0'), false)
  const dryRun = asBool(arg('dry-run', send ? '0' : '1'), !send)
  if (!dryRun) {
    for (const required of ['pid', 'wallet', 'quantity', 'recipient']) {
      if (!hasArg(required)) {
        throw new Error(`Live send requires explicit --${required}`)
      }
    }
    if (arg('confirm-send') !== 'BURN') {
      throw new Error('Live send requires --confirm-send BURN')
    }
  }

  const pid = ensure(arg('pid', 'xU9zFkq3X2ZQ6olwNVvr1vUWIjc3kXTWr7xKQD6dh10'), 'pid')
  const walletPath = ensure(arg('wallet', 'wallet.json'), 'wallet')
  const urlBase = ensure(arg('url', 'https://push.forward.computer'), 'url').replace(/\/$/, '')
  const action = ensure(arg('action', 'Burn'), 'action')
  const quantity = ensure(arg('quantity', '10053479999996'), 'quantity')
  const recipient = ensure(
    arg('recipient', 'Im52vSBuUry80UZRUvlkvDqraD4-GAQx6AQ-GQfRP8E'),
    'recipient'
  )
  const variant = ensure(arg('variant', 'ao.TN.1'), 'variant')
  const sdkTag = arg('sdk', 'aoconnect')
  const contentType = ensure(arg('content-type', 'text/plain'), 'content-type')
  const data = arg('data', '.') // default 1 byte payload
  const outFile = arg('out')
  const includeQuantityTag = asBool(arg('include-quantity-tag', '1'), true)

  const jwk = JSON.parse(fs.readFileSync(walletPath, 'utf8'))
  const signer = new ArweaveSigner(jwk)

  const tags = [
    { name: 'Action', value: action },
    ...(includeQuantityTag ? [{ name: 'Quantity', value: quantity }] : []),
    { name: 'Recipient', value: recipient },
    { name: 'Data-Protocol', value: 'ao' },
    { name: 'Variant', value: variant },
    { name: 'Type', value: 'Message' },
    { name: 'Content-Type', value: contentType },
    ...(sdkTag ? [{ name: 'SDK', value: sdkTag }] : [])
  ]

  const item = createData(data, signer, {
    target: pid,
    tags
  })
  await item.sign(signer)

  const endpoint = `${urlBase}/~scheduler@1.0/schedule?target=${pid}`

  if (dryRun) {
    const preview = {
      generatedAt: new Date().toISOString(),
      dryRun: true,
      willSend: false,
      endpoint,
      tx: {
        dataItemId: item.id,
        target: pid,
        dataLength: Buffer.byteLength(data),
        quantity,
        recipient,
        tags
      }
    }
    if (outFile) {
      fs.writeFileSync(outFile, JSON.stringify(preview, null, 2))
    }
    console.log(JSON.stringify(preview, null, 2))
    return
  }

  const res = await fetch(endpoint, {
    method: 'POST',
    headers: {
      'content-type': 'application/ans104',
      'codec-device': 'ans104@1.0'
    },
    body: item.getRaw()
  })

  const body = await res.text().catch(() => '')
  let parsed = null
  try {
    parsed = JSON.parse(body)
  } catch {
    parsed = null
  }

  const headers = {}
  res.headers.forEach((v, k) => {
    headers[k] = v
  })

  const result = {
    generatedAt: new Date().toISOString(),
    endpoint,
    status: res.status,
    ok: res.ok,
    slot: Number(headers.slot || parsed?.slot || ''),
    process: headers.process || parsed?.process || pid,
    tx: {
      dataItemId: item.id,
      target: pid,
      dataLength: Buffer.byteLength(data),
      quantity,
      recipient,
      tags
    },
    headers,
    body
  }

  if (outFile) {
    fs.writeFileSync(outFile, JSON.stringify(result, null, 2))
  }

  console.log(JSON.stringify(result, null, 2))

  if (!res.ok) {
    process.exitCode = 1
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
