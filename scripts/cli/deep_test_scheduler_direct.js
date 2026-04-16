#!/usr/bin/env node
import fs from 'fs'
import { createData, ArweaveSigner } from 'arbundles'
import {
  buildExecutionAssertion,
  formatAssertionStatus,
  probeCompute,
  resolveExecutionMode,
  summarizeAssertions
} from './execution_assertions.js'

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

function commandPayload(action) {
  if (action === 'SaveDraftPage') {
    return {
      siteId: 'site-demo',
      pageId: 'page-demo',
      locale: 'en',
      blocks: [{ type: 'text', value: 'hello from scheduler direct deep test' }]
    }
  }
  if (action === 'RuntimeSignal') {
    return {
      marker: `runtime-signal-${Date.now()}`
    }
  }
  return {}
}

function writeCommandBase(action, index) {
  return {
    action,
    requestId: `req-live-${Date.now()}-${index}`,
    actor: 'worker-test',
    tenant: 'blackcat',
    role: 'admin',
    // Worker /sign validates epoch seconds (parseInt), not ISO timestamps.
    timestamp: Math.floor(Date.now() / 1000),
    nonce: `nonce-${Math.random().toString(36).slice(2, 10)}`,
    signatureRef: 'worker-ed25519',
    payload: commandPayload(action)
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

async function sendSchedulerMessage({ baseUrl, pid, jwk, action, commandAction, requestId, data, variant }) {
  const signer = new ArweaveSigner(jwk)
  const tags = [
    { name: 'Action', value: action },
    { name: 'Reply-To', value: pid },
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
    envelopeAction: action,
    action: commandAction || action,
    requestId: requestId || null,
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
  const executionMode = resolveExecutionMode(process.argv, process.env)
  const token =
    cleanEnv(arg('worker-auth-token', process.env.WORKER_AUTH_TOKEN)) ||
    cleanEnv(secrets.WORKER_AUTH_TOKEN)

  if (!token) throw new Error('WORKER_AUTH_TOKEN is required (env, --worker-auth-token, or --secrets)')

  const commandActions = ['Ping', 'GetOpsHealth', 'RuntimeSignal']
  const signedCommands = []
  for (let i = 0; i < commandActions.length; i += 1) {
    const action = commandActions[i]
    const signed = await signWriteCommand(writeCommandBase(action, i + 1), signUrl, token)
    signedCommands.push(signed)
  }
  fs.writeFileSync('tmp/writecmd-signed-live.json', JSON.stringify(signedCommands, null, 2))

  const report = {
    generatedAt: new Date().toISOString(),
    pid,
    urls,
    variant,
    signUrl,
    commandActions,
    execution: {
      mode: executionMode,
      enforced: executionMode === 'strict'
    },
    steps: []
  }

  for (const baseUrl of urls) {
    const step = {
      baseUrl,
      sends: [],
      slotCurrent: null,
      computeChecks: [],
      assertions: []
    }
    for (const cmd of signedCommands) {
      step.sends.push(
        await sendSchedulerMessage({
          baseUrl,
          pid,
          jwk,
          action: 'Write-Command',
          commandAction: cmd.action,
          requestId: cmd.requestId,
          data: JSON.stringify(cmd),
          variant
        })
      )
    }

    step.slotCurrent = await probeSlotCurrent(baseUrl, pid)

    for (const send of step.sends) {
      const slot = Number(send.headers.slot || send.parsedSlot || '')
      if (!Number.isFinite(slot)) continue
      try {
        const compute = await probeCompute(baseUrl, pid, slot, fetchWithTimeout)
        step.computeChecks.push(compute)
        send.compute = compute
      } catch (e) {
        const failedCompute = {
          url: `${baseUrl}/${pid}~process@1.0/compute=${slot}`,
          status: 'error',
          error: e?.message || String(e)
        }
        step.computeChecks.push(failedCompute)
        send.compute = failedCompute
      }
    }

    for (const send of step.sends) {
      send.assertion = {
        action: send.action,
        requestId: send.requestId || null,
        ...buildExecutionAssertion({
          mode: executionMode,
          transportOk: send.ok === true,
          computeProbe: send.compute
        })
      }
      step.assertions.push(send.assertion)
    }
    step.summary = {
      mode: executionMode,
      enforced: executionMode === 'strict',
      assertions: summarizeAssertions(step.assertions),
      failedAssertions: step.assertions
        .filter((assertion) => assertion.passed === false)
        .map((assertion) => ({
          action: assertion.action || 'unknown',
          requestId: assertion.requestId || null,
          failures: assertion.failures || []
        }))
    }
    report.steps.push(step)
  }

  const allAssertions = report.steps.flatMap((step) => step.assertions || [])
  report.summary = {
    mode: executionMode,
    enforced: executionMode === 'strict',
    assertions: summarizeAssertions(allAssertions),
    steps: report.steps.length,
    actionAssertions: allAssertions.length,
    failedAssertions: report.steps.flatMap((step) => step.summary.failedAssertions || [])
  }

  fs.writeFileSync(out, JSON.stringify(report, null, 2))

  console.log(`saved=${out}`)
  for (const step of report.steps) {
    console.log(`\n[${step.baseUrl}]`)
    for (const send of step.sends) {
      const assertionLabel = send.assertion ? ` assert=${formatAssertionStatus(send.assertion)}` : ''
      console.log(
        `${send.action}: status=${send.status} slot=${send.headers.slot || send.parsedSlot || ''} envelope=${send.envelopeAction || ''} action_echo=${send.parsedAction || ''}${assertionLabel}`
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
    console.log(
      `assertions: mode=${step.summary.mode} passed=${step.summary.assertions.passed} failed=${step.summary.assertions.failed} runtime_ok=${step.summary.assertions.runtimeOk} transport_ok=${step.summary.assertions.transportOk}`
    )
  }

  console.log(
    `assertion_summary: mode=${report.summary.mode} enforced=${report.summary.enforced ? 'yes' : 'no'} passed=${report.summary.assertions.passed} failed=${report.summary.assertions.failed} runtime_ok=${report.summary.assertions.runtimeOk} transport_ok=${report.summary.assertions.transportOk}`
  )

  if (executionMode === 'strict' && report.summary.assertions.failed > 0) {
    throw new Error(`execution_assertions_failed:${report.summary.assertions.failed}`)
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
