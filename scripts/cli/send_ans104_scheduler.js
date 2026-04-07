#!/usr/bin/env node
import fs from 'fs'
import { createData, ArweaveSigner } from 'arbundles'

function arg(name, fallback) {
  const idx = process.argv.indexOf(`--${name}`)
  if (idx === -1) return fallback
  return process.argv[idx + 1]
}

function must(v, name) {
  if (!v) throw new Error(`Missing --${name}`)
  return v
}

async function main() {
  const pid = must(arg('pid'), 'pid')
  const urlBase = arg('url', 'https://push.forward.computer').replace(/\/$/, '')
  const walletPath = arg('wallet', 'wallet.json')
  const action = arg('action', 'Ping')
  const variant = arg('variant', 'ao.TN.1')
  const dataFile = arg('data-file')
  const data = dataFile ? fs.readFileSync(dataFile, 'utf8') : arg('data', '')
  const outFile = arg(
    'out',
    `tmp/scheduler-send-${action.toLowerCase()}-${new Date().toISOString().replace(/[:.]/g, '-')}.json`
  )

  const jwk = JSON.parse(fs.readFileSync(walletPath, 'utf8'))
  const signer = new ArweaveSigner(jwk)

  const tags = [
    { name: 'Action', value: action },
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
  const body = item.getRaw()
  const endpoint = `${urlBase}/~scheduler@1.0/schedule?target=${pid}`

  const res = await fetch(endpoint, {
    method: 'POST',
    headers: {
      'content-type': 'application/ans104',
      'codec-device': 'ans104@1.0'
    },
    body
  })
  const text = await res.text().catch(() => '')
  const headers = {}
  res.headers.forEach((v, k) => {
    headers[k] = v
  })

  const out = {
    generatedAt: new Date().toISOString(),
    endpoint,
    status: res.status,
    ok: res.ok,
    tx: {
      dataItemId: item.id,
      target: pid,
      tags,
      dataLength: Buffer.byteLength(data)
    },
    headers,
    body: text
  }
  fs.writeFileSync(outFile, JSON.stringify(out, null, 2))

  console.log(`status=${res.status}`)
  console.log(`slot=${headers.slot || ''}`)
  console.log(`process=${headers.process || ''}`)
  console.log(`saved=${outFile}`)
  console.log(text.slice(0, 400))
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
