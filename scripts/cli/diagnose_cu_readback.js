#!/usr/bin/env node
import fs from 'fs'
import { locate } from '@permaweb/ao-scheduler-utils'
import { connect, createSigner } from '@permaweb/aoconnect'
import {
  readResponseWithRetry,
  runWithRetry,
  withTimeout
} from './retry_helpers.js'

function arg(name, fallback) {
  const idx = process.argv.indexOf(`--${name}`)
  if (idx === -1) return fallback
  return process.argv[idx + 1]
}

function must(v, name) {
  if (!v) throw new Error(`Missing --${name}`)
  return v
}

async function safeFetch(url, init = {}, timeoutMs = 20000) {
  const outcome = await readResponseWithRetry({
    url,
    label: 'safe_fetch',
    attempts: 4,
    timeoutMs,
    baseDelayMs: 500,
    maxDelayMs: 4000,
    bodyPreviewLimit: 500,
    request: () => fetch(url, init)
  })
  return {
    ok: outcome.ok,
    url,
    status: outcome.status,
    headers: outcome.headers,
    bodyPreview: outcome.bodyPreview,
    attempts: outcome.attempts,
    retryCount: outcome.retryCount,
    errorClass: outcome.errorClass,
    error: outcome.ok ? null : outcome.error || outcome.errorClass
  }
}

async function safeAoResult({ ao, baseUrl, pid, slot, timeoutMs = 25000 }) {
  const primary = await runWithRetry(
    () => withTimeout(ao.result({ process: pid, message: String(slot) }), timeoutMs, 'ao.result'),
    {
      label: 'ao.result',
      attempts: 4,
      baseDelayMs: 500,
      maxDelayMs: 4000
    }
  )
  if (primary.ok) {
    return {
      ok: true,
      slot,
      mode: 'aoconnect.result',
      attempts: primary.attempts,
      retryCount: primary.retryCount,
      errorClass: primary.errorClass,
      output: primary.value
    }
  }

  const computeUrl = `${baseUrl}/${pid}~process@1.0/compute=${slot}?accept-bundle=true&require-codec=application/json`
  const fallback = await readResponseWithRetry({
    url: computeUrl,
    label: 'ao.request_fallback',
    attempts: 4,
    timeoutMs,
    baseDelayMs: 500,
    maxDelayMs: 4000,
    bodyPreviewLimit: 400,
    parseJson: true,
    request: () =>
      withTimeout(
        ao.request({
          path: `/${pid}~process@1.0/compute=${slot}?accept-bundle=true&require-codec=application/json`,
          target: pid,
          data: '1984',
          'accept-bundle': 'true',
          'require-codec': 'application/json'
        }),
        timeoutMs,
        'ao.request'
      )
  })
  if (!fallback.ok) {
    return {
      ok: false,
      slot,
      mode: 'failed',
      attempts: fallback.attempts,
      retryCount: fallback.retryCount,
      errorClass: fallback.errorClass,
      error: `${primary.errorClass}:${primary.error}; fallback=${fallback.errorClass}:${fallback.error || fallback.errorClass}`,
      primaryAttempts: primary.attempts,
      primaryErrorClass: primary.errorClass,
      fallbackAttempts: fallback.attempts,
      fallbackErrorClass: fallback.errorClass
    }
  }

  const parsed = fallback.parsed || null
  const normalized = parsed?.results?.raw || parsed?.raw || parsed
  return {
    ok: fallback.ok,
    slot,
    mode: 'aoconnect.request_fallback',
    status: fallback.status,
    attempts: fallback.attempts,
    retryCount: fallback.retryCount,
    errorClass: fallback.errorClass,
    output: {
      atSlot: parsed?.['at-slot'] ?? null,
      status: parsed?.status ?? null,
      hasInlineResults: Boolean(parsed?.results),
      output: normalized?.Output ?? null,
      messagesCount: Array.isArray(normalized?.Messages) ? normalized.Messages.length : null,
      spawnsCount: Array.isArray(normalized?.Spawns) ? normalized.Spawns.length : null,
      assignmentsCount: Array.isArray(normalized?.Assignments) ? normalized.Assignments.length : null,
      hasError: normalized?.Error ? Object.keys(normalized.Error).length > 0 : false
    },
    bodyPreview: fallback.bodyPreview,
    primaryErrorClass: primary.errorClass,
    primaryAttempts: primary.attempts
  }
}

async function safeAoDryrun({ ao, pid, timeoutMs = 25000 }) {
  const outcome = await runWithRetry(
    () =>
      withTimeout(
        ao.dryrun({
          process: pid,
          tags: [
            { name: 'Action', value: 'Ping' },
            { name: 'Type', value: 'Message' },
            { name: 'Variant', value: 'ao.TN.1' },
            { name: 'Data-Protocol', value: 'ao' },
            { name: 'Content-Type', value: 'application/json' },
            { name: 'Input-Encoding', value: 'JSON-1' },
            { name: 'Output-Encoding', value: 'JSON-1' }
          ],
          data: ''
        }),
        timeoutMs,
        'ao.dryrun'
      ),
    {
      label: 'ao.dryrun',
      attempts: 4,
      baseDelayMs: 500,
      maxDelayMs: 4000
    }
  )
  if (outcome.ok) {
    return {
      ok: true,
      attempts: outcome.attempts,
      retryCount: outcome.retryCount,
      errorClass: outcome.errorClass,
      output: outcome.value
    }
  }
  return {
    ok: false,
    attempts: outcome.attempts,
    retryCount: outcome.retryCount,
    errorClass: outcome.errorClass,
    error: outcome.error
  }
}

async function safeComputeProbe(baseUrl, pid, slot) {
  const url = `${baseUrl}/${pid}~process@1.0/compute=${slot}?accept-bundle=true&require-codec=application/json`
  const outcome = await readResponseWithRetry({
    url,
    label: 'compute_probe',
    attempts: 4,
    timeoutMs: 30000,
    baseDelayMs: 750,
    maxDelayMs: 6000,
    bodyPreviewLimit: 500,
    parseJson: true,
    request: () => fetch(url, { method: 'GET' })
  })

  if (!outcome.ok) {
    return {
      ok: false,
      url,
      status: outcome.status,
      error: outcome.error || outcome.errorClass,
      errorClass: outcome.errorClass,
      attempts: outcome.attempts,
      retryCount: outcome.retryCount,
      bodyPreview: outcome.bodyPreview
    }
  }

  const parsed = outcome.parsed || null
  const out = {
    ok: true,
    url,
    status: outcome.status,
    headers: outcome.headers,
    bodyPreview: outcome.bodyPreview,
    attempts: outcome.attempts,
    retryCount: outcome.retryCount,
    errorClass: outcome.errorClass,
    parsedSummary: parsed
      ? {
          atSlot: parsed['at-slot'] ?? null,
          status: parsed.status ?? null,
          hasInlineResults: Boolean(parsed.results),
          hasRaw: Boolean(parsed?.results?.raw || parsed?.raw),
          resultsLink: parsed['results+link'] || null
        }
      : null
  }

  if (parsed && !parsed.results && parsed['results+link']) {
    out.resultsLinkProbe = await safeFetch(
      `${baseUrl}/${parsed['results+link']}?process-id=${pid}&accept-bundle=true&require-codec=application/json`,
      { method: 'GET' },
      15000
    )
  }
  return out
}

function formatFetchOutcome(item) {
  if (!item) return 'na'
  const status = item.status ?? (item.ok ? 'ok' : 'err')
  const attempts = item.attempts ? `x${item.attempts}` : ''
  const errorClass = item.errorClass ? `/${item.errorClass}` : ''
  return `${status}${errorClass}${attempts}`
}

function formatReadbackOutcome(item) {
  if (!item) return 'na'
  if (item.ok) {
    const mode = item.mode || 'ok'
    const attempts = item.attempts ? `x${item.attempts}` : ''
    const errorClass = item.errorClass ? `/${item.errorClass}` : ''
    return `${mode}${errorClass}${attempts}`
  }
  const attempts = item.attempts ? `x${item.attempts}` : ''
  const errorClass = item.errorClass ? item.errorClass : 'unknown'
  return `error:${errorClass}${attempts}`
}

async function main() {
  const pid = must(arg('pid'), 'pid')
  const reportPath = arg('report', 'tmp/deep-test-scheduler-direct-latest.json')
  const walletPath = arg('wallet', 'wallet.json')
  const schedulerUrlArg = arg('scheduler-url')
  const out = arg(
    'out',
    `tmp/cu-readback-diagnostic-${new Date().toISOString().replace(/[:.]/g, '-')}.json`
  )

  if (!fs.existsSync(reportPath)) {
    throw new Error(`Report file not found: ${reportPath}`)
  }

  const runReport = JSON.parse(fs.readFileSync(reportPath, 'utf8'))
  const defaultSchedulerAddress = 'n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo'
  let schedulerMeta = null
  try {
    schedulerMeta = await locate(pid)
  } catch {
    schedulerMeta = {}
  }
  const schedulerUrl = (
    schedulerUrlArg ||
    schedulerMeta.url ||
    process.env.HB_SCHEDULER_URL ||
    process.env.HYPERBEAM_SCHEDULER_URL ||
    'https://schedule.forward.computer'
  ).replace(/\/$/, '')
  const schedulerAddress =
    schedulerMeta.address || process.env.HB_SCHEDULER || process.env.AO_SCHEDULER || defaultSchedulerAddress
  const pushUrls = (runReport.steps || []).map((s) => String(s.baseUrl || '').replace(/\/$/, '')).filter(Boolean)
  const jwk = JSON.parse(fs.readFileSync(walletPath, 'utf8'))

  const results = {
    generatedAt: new Date().toISOString(),
    pid,
    schedulerUrl,
    schedulerAddress: schedulerAddress || null,
    reportPath,
    steps: []
  }

  for (const step of runReport.steps || []) {
    const baseUrl = String(step.baseUrl || '').replace(/\/$/, '')
    if (!baseUrl) continue
    const entry = {
      baseUrl,
      probes: {},
      sends: []
    }

    entry.probes.slotCurrentViaProcess = await safeFetch(
      `${baseUrl}/${pid}/slot/current`,
      { method: 'GET' },
      15000
    )
    entry.probes.slotCurrentViaScheduler = await safeFetch(
      `${baseUrl}/~scheduler@1.0/slot?target=${pid}`,
      { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' },
      15000
    )

    for (const send of step.sends || []) {
      const slot = Number(send?.headers?.slot || send?.parsedSlot || '')
      const messageId = send?.dataItemId || null
      const sendEntry = {
        action: send?.action || null,
        slot: Number.isFinite(slot) ? slot : null,
        messageId,
        computeProbe: null,
        schedulerMessageProbe: null,
        aoconnectResultProbe: null
      }

      if (Number.isFinite(slot)) {
        sendEntry.computeProbe = await safeComputeProbe(baseUrl, pid, slot)
      }

      if (schedulerUrl && messageId) {
        sendEntry.schedulerMessageProbe = await safeFetch(
          `${schedulerUrl}/${messageId}?process-id=${pid}`,
          { method: 'GET' },
          15000
        )
      }

      // ao.result/dryrun are probed only on the primary push URL to avoid duplicate load.
      if (Number.isFinite(slot) && baseUrl === pushUrls[0]) {
        const ao = connect({
          MODE: 'mainnet',
          URL: baseUrl,
          SCHEDULER: schedulerAddress,
          signer: createSigner(jwk)
        })
        sendEntry.aoconnectResultProbe = await safeAoResult({ ao, baseUrl, pid, slot })
      }

      entry.sends.push(sendEntry)
    }

    if (baseUrl === pushUrls[0]) {
      const ao = connect({
        MODE: 'mainnet',
        URL: baseUrl,
        SCHEDULER: schedulerAddress,
        signer: createSigner(jwk)
      })
      entry.probes.aoconnectDryrunPing = await safeAoDryrun({ ao, pid })
    }

    results.steps.push(entry)
  }

  fs.writeFileSync(out, JSON.stringify(results, null, 2))

  console.log(`saved=${out}`)
  for (const step of results.steps) {
    console.log(`\n[${step.baseUrl}]`)
    console.log(`slot/current(process) => ${formatFetchOutcome(step.probes.slotCurrentViaProcess)}`)
    console.log(
      `slot(current scheduler POST) => ${formatFetchOutcome(step.probes.slotCurrentViaScheduler)}`
    )
    if (step.probes.aoconnectDryrunPing) {
      console.log(`aoconnect dryrun Ping => ${formatReadbackOutcome(step.probes.aoconnectDryrunPing)}`)
    }
    for (const send of step.sends) {
      const c = formatFetchOutcome(send.computeProbe)
      const su = formatFetchOutcome(send.schedulerMessageProbe)
      const ar = formatReadbackOutcome(send.aoconnectResultProbe)
      console.log(`${send.action}: compute=${c} scheduler-msg=${su} ao.result=${ar}`)
    }
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
