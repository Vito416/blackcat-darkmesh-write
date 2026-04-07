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

function cleanEnv(v) {
  if (v === undefined || v === null) return undefined
  const s = String(v).trim()
  if (!s || s === 'undefined' || s === 'null') return undefined
  return s
}

async function fetchWithTimeout(url, init = {}, timeoutMs = 20000) {
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), timeoutMs)
  try {
    return await fetch(url, { ...init, signal: ctl.signal })
  } finally {
    clearTimeout(timer)
  }
}

function loadSecrets(path) {
  if (!path || !fs.existsSync(path)) return {}
  return JSON.parse(fs.readFileSync(path, 'utf8'))
}

function writeCommandBase() {
  return {
    action: 'SaveDraftPage',
    requestId: `req-live-${Date.now()}`,
    actor: 'worker-test',
    tenant: 'blackcat',
    role: 'admin',
    timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    nonce: `nonce-${Math.random().toString(36).slice(2, 10)}`,
    signatureRef: 'worker-ed25519',
    payload: {
      siteId: 'site-demo',
      pageId: 'page-demo',
      locale: 'en',
      blocks: [{ type: 'text', value: 'hello from scheduler direct deep test' }]
    }
  }
}

async function signWriteCommand(cmd, signUrl, token) {
  const res = await fetchWithTimeout(
    signUrl,
    {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${token}`
      },
      body: JSON.stringify(cmd)
    },
    25000
  )
  const text = await res.text()
  if (!res.ok) {
    throw new Error(`worker_sign_failed:${res.status}:${text.slice(0, 240)}`)
  }
  const json = JSON.parse(text)
  return {
    ...cmd,
    signature: json.signature,
    signatureRef: json.signatureRef || cmd.signatureRef
  }
}

async function sendSchedulerMessage({ baseUrl, pid, jwk, action, data, variant }) {
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
  const endpoint = `${baseUrl}/~scheduler@1.0/schedule?target=${pid}`
  const res = await fetchWithTimeout(
    endpoint,
    {
      method: 'POST',
      headers: {
        'content-type': 'application/ans104',
        'codec-device': 'ans104@1.0'
      },
      body: item.getRaw()
    },
    30000
  )
  const text = await res.text().catch(() => '')
  const headers = {}
  res.headers.forEach((v, k) => {
    headers[k] = v
  })
  let parsedBody = null
  try {
    parsedBody = JSON.parse(text)
  } catch {
    parsedBody = null
  }
  return {
    endpoint,
    action,
    dataItemId: item.id,
    txDataLength: Buffer.byteLength(data),
    status: res.status,
    ok: res.ok,
    headers,
    bodyPreview: text.slice(0, 800),
    parsedAction: parsedBody?.body?.action || null,
    parsedSlot: parsedBody?.slot || null
  }
}

async function probeCompute(baseUrl, pid, slot) {
  const url = `${baseUrl}/${pid}~process@1.0/compute=${slot}?accept-bundle=true&require-codec=application/json`
  let res = null
  let text = ''
  let lastError = null
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      res = await fetchWithTimeout(url, { method: 'GET' }, 30000)
      text = await res.text().catch(() => '')
      break
    } catch (e) {
      lastError = e
      if (attempt < 3) {
        await new Promise((r) => setTimeout(r, 3000))
      }
    }
  }

  if (!res) {
    return {
      url,
      status: 'error',
      ok: false,
      error: lastError?.message || String(lastError)
    }
  }
  let parsed = null
  try {
    parsed = JSON.parse(text)
  } catch {
    parsed = null
  }

  // Some nodes may return a results link instead of inline results.
  let resultsLinkProbe = null
  if (parsed && !parsed.results && parsed['results+link']) {
    const linkUrl = `${baseUrl}/${parsed['results+link']}?process-id=${pid}&accept-bundle=true&require-codec=application/json`
    try {
      const linkRes = await fetchWithTimeout(linkUrl, { method: 'GET' }, 15000)
      const linkText = await linkRes.text().catch(() => '')
      let linkParsed = null
      try {
        linkParsed = JSON.parse(linkText)
      } catch {
        linkParsed = null
      }
      if (linkParsed && !parsed.results) {
        if (linkParsed.raw) parsed.results = { raw: linkParsed.raw }
        else parsed.results = linkParsed
      }
      resultsLinkProbe = {
        url: linkUrl,
        status: linkRes.status,
        ok: linkRes.ok
      }
    } catch (e) {
      resultsLinkProbe = {
        url: linkUrl,
        status: 'error',
        error: e?.message || String(e)
      }
    }
  }

  const raw = parsed?.results?.raw || parsed?.raw || null
  return {
    url,
    status: res.status,
    ok: res.ok,
    bodyPreview: text.slice(0, 240),
    parsed: parsed
      ? {
          atSlot: parsed['at-slot'] ?? null,
          status: parsed.status ?? null,
          hasResults: Boolean(parsed.results || parsed.raw),
          output: raw?.Output ?? null,
          messagesCount: Array.isArray(raw?.Messages) ? raw.Messages.length : null,
          spawnsCount: Array.isArray(raw?.Spawns) ? raw.Spawns.length : null,
          assignmentsCount: Array.isArray(raw?.Assignments) ? raw.Assignments.length : null,
          hasError: raw?.Error ? Object.keys(raw.Error).length > 0 : false
        }
      : null,
    resultsLinkProbe
  }
}

async function probeSlotCurrent(baseUrl, pid) {
  const url = `${baseUrl}/${pid}/slot/current`
  const res = await fetchWithTimeout(url, { method: 'GET' }, 12000)
  const text = await res.text().catch(() => '')
  return {
    url,
    status: res.status,
    ok: res.ok,
    body: text.trim().slice(0, 200)
  }
}

async function main() {
  const pid = must(arg('pid'), 'pid')
  const walletPath = arg('wallet', 'wallet.json')
  const urls = String(arg('urls', 'https://push.forward.computer,https://push-1.forward.computer'))
    .split(',')
    .map((u) => u.trim().replace(/\/$/, ''))
    .filter(Boolean)
  const variant = arg('variant', 'ao.TN.1')
  const secretsPath = arg('secrets')
  const out = arg(
    'out',
    `tmp/deep-test-scheduler-direct-${new Date().toISOString().replace(/[:.]/g, '-')}.json`
  )

  const jwk = JSON.parse(fs.readFileSync(walletPath, 'utf8'))
  const secrets = loadSecrets(secretsPath)
  const signUrl = cleanEnv(arg('sign-url', process.env.WORKER_SIGN_URL)) ||
    'https://blackcat-inbox-production.vitek-pasek.workers.dev/sign'
  const token =
    cleanEnv(arg('worker-auth-token', process.env.WORKER_AUTH_TOKEN)) ||
    cleanEnv(secrets.WORKER_AUTH_TOKEN)

  if (!token) throw new Error('WORKER_AUTH_TOKEN is required (env, --worker-auth-token, or --secrets)')

  const signedCmd = await signWriteCommand(writeCommandBase(), signUrl, token)
  fs.writeFileSync('tmp/writecmd-signed-live.json', JSON.stringify(signedCmd, null, 2))

  const report = {
    generatedAt: new Date().toISOString(),
    pid,
    urls,
    variant,
    signUrl,
    steps: []
  }

  for (const baseUrl of urls) {
    const step = {
      baseUrl,
      sends: [],
      slotCurrent: null,
      computeChecks: []
    }
    step.sends.push(
      await sendSchedulerMessage({
        baseUrl,
        pid,
        jwk,
        action: 'Ping',
        data: '',
        variant
      })
    )
    step.sends.push(
      await sendSchedulerMessage({
        baseUrl,
        pid,
        jwk,
        action: 'GetOpsHealth',
        data: '',
        variant
      })
    )
    step.sends.push(
      await sendSchedulerMessage({
        baseUrl,
        pid,
        jwk,
        action: 'Write-Command',
        data: JSON.stringify(signedCmd),
        variant
      })
    )

    step.slotCurrent = await probeSlotCurrent(baseUrl, pid)

    for (const send of step.sends) {
      const slot = Number(send.headers.slot || send.parsedSlot || '')
      if (!Number.isFinite(slot)) continue
      try {
        step.computeChecks.push(await probeCompute(baseUrl, pid, slot))
      } catch (e) {
        step.computeChecks.push({
          url: `${baseUrl}/${pid}~process@1.0/compute=${slot}`,
          status: 'error',
          error: e?.message || String(e)
        })
      }
    }
    report.steps.push(step)
  }

  fs.writeFileSync(out, JSON.stringify(report, null, 2))

  console.log(`saved=${out}`)
  for (const step of report.steps) {
    console.log(`\n[${step.baseUrl}]`)
    for (const send of step.sends) {
      console.log(
        `${send.action}: status=${send.status} slot=${send.headers.slot || send.parsedSlot || ''} action_echo=${send.parsedAction || ''}`
      )
    }
    console.log(
      `slot/current: status=${step.slotCurrent.status} body=${step.slotCurrent.body}`
    )
    for (const cmp of step.computeChecks) {
      const p = cmp.parsed || {}
      console.log(
        `compute: status=${cmp.status} slot=${p.atSlot ?? ''} output=${p.output ?? ''} messages=${p.messagesCount ?? ''} error=${p.hasError === true ? 'yes' : p.hasError === false ? 'no' : ''}`
      )
    }
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
