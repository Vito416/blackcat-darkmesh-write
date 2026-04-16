#!/usr/bin/env node
import fs from 'fs'
import { createData, ArweaveSigner } from 'arbundles'
import { locate } from '@permaweb/ao-scheduler-utils'
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

function clean(v) {
  if (v === undefined || v === null) return undefined
  const s = String(v).trim()
  if (!s || s === 'undefined' || s === 'null') return undefined
  return s
}

function loadJson(path) {
  return JSON.parse(fs.readFileSync(path, 'utf8'))
}

function loadSecrets(path) {
  if (!path || !fs.existsSync(path)) return {}
  return loadJson(path)
}

async function fetchWithTimeout(url, init = {}, timeoutMs = 25000) {
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), timeoutMs)
  try {
    return await fetch(url, { ...init, signal: ctl.signal })
  } finally {
    clearTimeout(timer)
  }
}

function baseCommand(action, payload, i) {
  return {
    action,
    requestId: `req-matrix-${Date.now()}-${i}`,
    actor: 'worker-test',
    tenant: 'blackcat',
    role: 'admin',
    // Worker /sign validates epoch seconds (parseInt), not ISO timestamps.
    timestamp: Math.floor(Date.now() / 1000),
    nonce: `nonce-${Math.random().toString(36).slice(2, 10)}`,
    signatureRef: 'worker-ed25519',
    payload
  }
}

function basicFixtures() {
  return [
    baseCommand('SaveDraftPage', {
      siteId: 'site-demo',
      pageId: 'home',
      locale: 'en',
      blocks: [{ type: 'text', value: 'Matrix draft content' }]
    }, 1),
    baseCommand('PublishPageVersion', {
      siteId: 'site-demo',
      pageId: 'home',
      versionId: 'v-matrix-1',
      manifestTx: 'tx-matrix-1'
    }, 2),
    baseCommand('UpsertRoute', {
      siteId: 'site-demo',
      path: '/matrix',
      target: 'page:home'
    }, 3),
    baseCommand('CreatePaymentIntent', {
      orderId: 'ord-matrix-1',
      amount: 1000,
      currency: 'USD'
    }, 4),
    baseCommand('ProviderWebhook', {
      provider: 'stripe',
      eventType: 'payment.succeeded',
      orderId: 'ord-matrix-1',
      paymentId: 'pay-matrix-1',
      amount: 1000,
      currency: 'USD',
      receivedAt: new Date().toISOString()
    }, 5),
    baseCommand('ProviderShippingWebhook', {
      provider: 'shippo',
      eventType: 'shipment.updated',
      shipmentId: 'shp-matrix-1',
      orderId: 'ord-matrix-1',
      status: 'in_transit',
      receivedAt: new Date().toISOString()
    }, 6)
  ]
}

function extendedFixtures() {
  return [
    ...basicFixtures(),
    baseCommand('CreateWebhook', {
      siteId: 'site-demo',
      url: 'https://example.invalid/webhook',
      events: ['OrderCreated', 'OrderUpdated']
    }, 7),
    baseCommand('RunWebhookRetries', {
      limit: 10
    }, 8),
    baseCommand('SchedulePublish', {
      siteId: 'site-demo',
      pageId: 'home',
      publishAt: new Date(Date.now() + 15 * 60 * 1000).toISOString()
    }, 9),
    baseCommand('RunScheduledPublishes', {
      limit: 10
    }, 10),
    baseCommand('SubmitForm', {
      formId: 'contact-form',
      submission: {
        email: 'user@example.invalid',
        message: 'hello from matrix'
      }
    }, 11),
    baseCommand('CreateOrder', {
      orderId: 'ord-matrix-2',
      siteId: 'site-demo',
      items: [{ sku: 'sku-1', qty: 1 }],
      currency: 'USD'
    }, 12),
    baseCommand('CreateShipment', {
      orderId: 'ord-matrix-2',
      shipmentId: 'shp-matrix-2',
      status: 'created',
      items: [{ sku: 'sku-1', qty: 1 }]
    }, 13),
    baseCommand('UpsertShipmentStatus', {
      shipmentId: 'shp-matrix-2',
      status: 'in_transit',
      trackingUrl: 'https://tracking.example.invalid/track/1'
    }, 14),
    baseCommand('UpsertReturnStatus', {
      returnId: 'ret-matrix-1',
      status: 'received'
    }, 15),
    baseCommand('RefundPayment', {
      paymentId: 'pay-matrix-1',
      amount: 500,
      reason: 'customer_request'
    }, 16),
    baseCommand('ConfirmPayment', {
      paymentId: 'pay-matrix-1',
      provider: 'stripe'
    }, 17)
  ]
}

async function signWithWorker(cmd, signUrl, token) {
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
    30000
  )
  const text = await res.text().catch(() => '')
  if (!res.ok) {
    throw new Error(`worker_sign_failed:${res.status}:${text.slice(0, 180)}`)
  }
  const json = JSON.parse(text)
  return {
    ...cmd,
    signature: json.signature,
    signatureRef: json.signatureRef || cmd.signatureRef
  }
}

async function sendSchedulerDirect({ baseUrl, pid, jwk, cmd, variant }) {
  const signer = new ArweaveSigner(jwk)
  const tags = [
    { name: 'Action', value: 'Write-Command' },
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
  const data = JSON.stringify(cmd)
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
  const bodyText = await res.text().catch(() => '')
  const headers = {}
  res.headers.forEach((v, k) => {
    headers[k] = v
  })
  return {
    action: cmd.action,
    requestId: cmd.requestId,
    status: res.status,
    ok: res.ok,
    slot: headers.slot || null,
    process: headers.process || null,
    messageId: item.id,
    endpoint,
    bodyPreview: bodyText.slice(0, 280)
  }
}

async function probeSchedulerMessage(schedulerUrl, pid, messageId) {
  const url = `${schedulerUrl}/${messageId}?process-id=${pid}`
  const res = await fetchWithTimeout(url, { method: 'GET' }, 20000)
  const text = await res.text().catch(() => '')
  return {
    url,
    status: res.status,
    ok: res.ok,
    bodyPreview: text.slice(0, 400)
  }
}

async function main() {
  const pid = must(arg('pid'), 'pid')
  const walletPath = arg('wallet', 'wallet.json')
  const secretsPath = arg('secrets', 'tmp/test-secrets.json')
  const urls = String(arg('urls', 'https://push.forward.computer,https://push-1.forward.computer'))
    .split(',')
    .map((s) => s.trim().replace(/\/$/, ''))
    .filter(Boolean)
  const signUrl =
    clean(arg('sign-url', process.env.WORKER_SIGN_URL)) ||
    'https://blackcat-inbox-production.vitek-pasek.workers.dev/sign'
  const variant = arg('variant', 'ao.TN.1')
  const profile = arg('profile', 'basic')
  const executionMode = resolveExecutionMode(process.argv, process.env)
  const out = arg(
    'out',
    `tmp/business-matrix-scheduler-direct-${new Date().toISOString().replace(/[:.]/g, '-')}.json`
  )

  const jwk = loadJson(walletPath)
  const secrets = loadSecrets(secretsPath)
  const token =
    clean(arg('worker-auth-token', process.env.WORKER_AUTH_TOKEN)) ||
    clean(secrets.WORKER_AUTH_TOKEN)
  if (!token) throw new Error('WORKER_AUTH_TOKEN missing (env/--worker-auth-token/--secrets)')

  const scheduler = await locate(pid)
  const schedulerUrl = String(scheduler.url || 'https://schedule.forward.computer').replace(/\/$/, '')

  const report = {
    generatedAt: new Date().toISOString(),
    pid,
    urls,
    schedulerUrl,
    variant,
    profile,
    signUrl,
    execution: {
      mode: executionMode,
      enforced: executionMode === 'strict'
    },
    tests: []
  }

  const fixtures = profile === 'extended' ? extendedFixtures() : basicFixtures()
  for (const baseUrl of urls) {
    const baseReport = {
      baseUrl,
      results: [],
      assertions: []
    }
    for (const fixture of fixtures) {
      const signed = await signWithWorker(fixture, signUrl, token)
      const sendRes = await sendSchedulerDirect({ baseUrl, pid, jwk, cmd: signed, variant })
      const schedulerProbe = await probeSchedulerMessage(schedulerUrl, pid, sendRes.messageId)
      const slot = Number(sendRes.slot || '')
      let computeProbe = null
      if (Number.isFinite(slot)) {
        try {
          computeProbe = await probeCompute(baseUrl, pid, slot, fetchWithTimeout)
        } catch (err) {
          computeProbe = {
            url: `${baseUrl}/${pid}~process@1.0/compute=${slot}`,
            status: 'error',
            ok: false,
            error: err?.message || String(err)
          }
        }
      }
      const assertion = buildExecutionAssertion({
        mode: executionMode,
        transportOk: sendRes.ok === true,
        schedulerMessageOk: schedulerProbe.ok === true,
        computeProbe,
        requireSchedulerMessage: true
      })
      const annotatedAssertion = {
        baseUrl,
        action: fixture.action,
        requestId: fixture.requestId,
        ...assertion
      }
      baseReport.results.push({
        action: fixture.action,
        requestId: fixture.requestId,
        send: sendRes,
        schedulerMessage: schedulerProbe,
        compute: computeProbe,
        assertion: annotatedAssertion
      })
      baseReport.assertions.push(annotatedAssertion)
    }
    baseReport.summary = {
      mode: executionMode,
      enforced: executionMode === 'strict',
      assertions: summarizeAssertions(baseReport.assertions),
      failedAssertions: baseReport.assertions
        .filter((assertion) => assertion.passed === false)
        .map((assertion) => ({
          action: assertion.action,
          requestId: assertion.requestId,
          failures: assertion.failures || []
        }))
    }
    report.tests.push(baseReport)
  }

  const allAssertions = report.tests.flatMap((test) => test.assertions || [])
  report.summary = {
    mode: executionMode,
    enforced: executionMode === 'strict',
    assertions: summarizeAssertions(allAssertions),
    tests: report.tests.length,
    actions: allAssertions.length,
    failedAssertions: report.tests.flatMap((test) => test.summary.failedAssertions || [])
  }

  fs.writeFileSync(out, JSON.stringify(report, null, 2))
  console.log(`saved=${out}`)
  for (const t of report.tests) {
    console.log(`\n[${t.baseUrl}]`)
    for (const row of t.results) {
      const assertionLabel = row.assertion ? ` assert=${formatAssertionStatus(row.assertion)}` : ''
      console.log(
        `${row.action}: send=${row.send.status} slot=${row.send.slot || ''} scheduler_msg=${row.schedulerMessage.status}${assertionLabel}`
      )
    }
    console.log(
      `assertions: mode=${t.summary.mode} passed=${t.summary.assertions.passed} failed=${t.summary.assertions.failed} runtime_ok=${t.summary.assertions.runtimeOk} transport_ok=${t.summary.assertions.transportOk} scheduler_ok=${t.summary.assertions.schedulerOk}`
    )
  }

  console.log(
    `assertion_summary: mode=${report.summary.mode} enforced=${report.summary.enforced ? 'yes' : 'no'} passed=${report.summary.assertions.passed} failed=${report.summary.assertions.failed} runtime_ok=${report.summary.assertions.runtimeOk} transport_ok=${report.summary.assertions.transportOk} scheduler_ok=${report.summary.assertions.schedulerOk}`
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
