#!/usr/bin/env node
import fs from 'fs'
import Arweave from 'arweave'
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

function preview(text, n = 180) {
  return String(text || '').replace(/\s+/g, ' ').slice(0, n)
}

function summarizeBody(text) {
  const out = {
    bodyPreview: preview(text),
    json: false,
    hasCommitments: false,
    commitmentDevices: [],
    committedKeysUnion: [],
    statusInBody: null
  }

  try {
    const parsed = JSON.parse(text)
    out.json = true
    out.statusInBody = parsed?.status ?? null
    if (parsed && typeof parsed === 'object' && parsed.commitments && typeof parsed.commitments === 'object') {
      out.hasCommitments = true
      const devices = new Set()
      const keys = new Set()
      for (const v of Object.values(parsed.commitments)) {
        if (v && typeof v === 'object') {
          if (v['commitment-device']) devices.add(v['commitment-device'])
          if (Array.isArray(v.committed)) {
            for (const c of v.committed) keys.add(c)
          }
        }
      }
      out.commitmentDevices = [...devices].sort()
      out.committedKeysUnion = [...keys].sort()
    }
  } catch {
    // not json
  }

  return out
}

async function run() {
  const pid = must(arg('pid'), 'pid')
  const url = arg('url', 'https://push.forward.computer')
  const scheduler = arg('scheduler', 'n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo')
  const moduleId = arg('module')
  const variant = arg('variant', 'ao.TN.1')
  const walletPath = arg('wallet', 'wallet.json')
  const outFile = arg(
    'out',
    `tmp/push-shape-report-${new Date().toISOString().replace(/[:.]/g, '-')}.json`
  )

  const jwk = JSON.parse(fs.readFileSync(walletPath, 'utf8'))
  const arweave = Arweave.init({ host: 'arweave.net', port: 443, protocol: 'https' })
  const walletAddr = await arweave.wallets.jwkToAddress(jwk)
  const ao = connect({
    MODE: 'mainnet',
    URL: url,
    SCHEDULER: scheduler,
    signer: createSigner(jwk)
  })

  const basePush = {
    path: `/${pid}~process@1.0/push`,
    target: pid,
    data: '',
    Action: 'Ping',
    Type: 'Message',
    Variant: variant,
    'Data-Protocol': 'ao'
  }

  const cases = [
    {
      name: 'control_direct_pid',
      params: {
        path: `/${pid}`,
        target: pid,
        data: '',
        Action: 'Ping',
        Type: 'Message',
        Variant: variant,
        'Data-Protocol': 'ao'
      }
    },
    { name: 'push_base', params: { ...basePush } },
    {
      name: 'push_with_transport_trio',
      params: {
        ...basePush,
        'signing-format': 'ans104',
        'accept-bundle': 'true',
        'require-codec': 'application/json'
      }
    },
    {
      name: 'push_with_transport_quartet',
      params: {
        ...basePush,
        'signing-format': 'ans104',
        'accept-bundle': 'true',
        'require-codec': 'application/json',
        'accept-codec': 'httpsig@1.0'
      }
    },
    {
      name: 'push_with_meta_fields',
      params: {
        ...basePush,
        Owner: walletAddr,
        Nonce: `nonce-${Date.now()}`,
        Timestamp: new Date().toISOString(),
        Status: '0'
      }
    },
    {
      name: 'push_with_meta_plus_transport',
      params: {
        ...basePush,
        Owner: walletAddr,
        Nonce: `nonce-${Date.now()}-t`,
        Timestamp: new Date().toISOString(),
        Status: '0',
        'signing-format': 'ans104',
        'accept-bundle': 'true',
        'require-codec': 'application/json'
      }
    },
    {
      name: 'push_with_module_if_provided',
      skip: !moduleId,
      params: {
        ...basePush,
        ...(moduleId ? { Module: moduleId } : {})
      }
    },
    {
      name: 'push_with_module_plus_transport_if_provided',
      skip: !moduleId,
      params: {
        ...basePush,
        ...(moduleId ? { Module: moduleId } : {}),
        'signing-format': 'ans104',
        'accept-bundle': 'true',
        'require-codec': 'application/json'
      }
    }
  ]

  const results = []
  for (const c of cases) {
    if (c.skip) continue
    const startedAt = new Date().toISOString()
    let status = null
    let ok = false
    let text = ''
    let headers = {}
    let error = null
    try {
      const res = await ao.request(c.params)
      status = res.status
      ok = res.ok
      res.headers.forEach((v, k) => {
        headers[k] = v
      })
      text = await res.text()
    } catch (e) {
      error = e?.message || String(e)
    }
    const summary = summarizeBody(text)
    results.push({
      case: c.name,
      startedAt,
      params: c.params,
      status,
      ok,
      error,
      headers,
      ...summary
    })
  }

  const report = {
    generatedAt: new Date().toISOString(),
    pid,
    module: moduleId || null,
    endpoint: url,
    scheduler,
    walletAddress: walletAddr,
    results
  }

  fs.writeFileSync(outFile, JSON.stringify(report, null, 2))

  for (const r of results) {
    const k = r.committedKeysUnion?.length ? `[${r.committedKeysUnion.join(',')}]` : '[]'
    console.log(
      `${r.case.padEnd(40)} status=${String(r.status).padEnd(4)} ok=${String(r.ok).padEnd(5)} commitments=${String(r.hasCommitments).padEnd(5)} keys=${k} preview="${preview(
        r.bodyPreview,
        90
      )}"`
    )
  }
  console.log(`\nSaved full report: ${outFile}`)
}

run().catch((err) => {
  console.error(err)
  process.exit(1)
})

