#!/usr/bin/env node
import fs from 'fs'
import { locate } from '@permaweb/ao-scheduler-utils'
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

async function fetchWithTimeout(url, init = {}, timeoutMs = 20000) {
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), timeoutMs)
  try {
    return await fetch(url, { ...init, signal: ctl.signal })
  } finally {
    clearTimeout(timer)
  }
}

function normalizeHeaders(res) {
  const out = {}
  res.headers.forEach((v, k) => {
    out[k] = v
  })
  return out
}

async function safeFetch(url, init = {}, timeoutMs = 20000) {
  try {
    const res = await fetchWithTimeout(url, init, timeoutMs)
    const text = await res.text().catch(() => '')
    return {
      ok: true,
      url,
      status: res.status,
      headers: normalizeHeaders(res),
      bodyPreview: text.slice(0, 500)
    }
  } catch (e) {
    return {
      ok: false,
      url,
      error: e?.message || String(e)
    }
  }
}

async function safeAoResult({ ao, pid, slot, timeoutMs = 25000 }) {
  const withTimeout = (promise) =>
    Promise.race([
      promise,
      new Promise((_, rej) =>
        setTimeout(() => rej(new Error(`timeout_${timeoutMs}ms`)), timeoutMs)
      )
    ])
  try {
    const out = await withTimeout(ao.result({ process: pid, message: String(slot) }))
    return {
      ok: true,
      slot,
      mode: 'aoconnect.result',
      output: out
    }
  } catch (e) {
    const primaryError = e?.message || String(e)
    try {
      const res = await withTimeout(
        ao.request({
          path: `/${pid}~process@1.0/compute=${slot}?accept-bundle=true&require-codec=application/json`,
          target: pid,
          data: '1984',
          'accept-bundle': 'true',
          'require-codec': 'application/json'
        })
      )
      const text = await res.text().catch(() => '')
      let parsed = null
      try {
        parsed = JSON.parse(text)
      } catch {
        parsed = null
      }
      const normalized = parsed?.results?.raw || parsed?.raw || parsed
      return {
        ok: res.ok,
        slot,
        mode: 'aoconnect.request_fallback',
        status: res.status,
        output: {
          atSlot: parsed?.['at-slot'] ?? null,
          status: parsed?.status ?? null,
          hasInlineResults: Boolean(parsed?.results),
          output: normalized?.Output ?? null,
          messagesCount: Array.isArray(normalized?.Messages) ? normalized.Messages.length : null,
          spawnsCount: Array.isArray(normalized?.Spawns) ? normalized.Spawns.length : null,
          assignmentsCount: Array.isArray(normalized?.Assignments)
            ? normalized.Assignments.length
            : null,
          hasError: normalized?.Error ? Object.keys(normalized.Error).length > 0 : false
        },
        bodyPreview: text.slice(0, 400),
        primaryError
      }
    } catch (fallbackError) {
      return {
        ok: false,
        slot,
        mode: 'failed',
        error: `${primaryError}; fallback=${fallbackError?.message || String(fallbackError)}`
      }
    }
  }
}

async function safeAoDryrun({ ao, pid, timeoutMs = 25000 }) {
  const timeout = new Promise((_, rej) =>
    setTimeout(() => rej(new Error(`timeout_${timeoutMs}ms`)), timeoutMs)
  )
  try {
    const out = await Promise.race([
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
      timeout
    ])
    return { ok: true, output: out }
  } catch (e) {
    return { ok: false, error: e?.message || String(e) }
  }
}

async function safeComputeProbe(baseUrl, pid, slot) {
  const url = `${baseUrl}/${pid}~process@1.0/compute=${slot}?accept-bundle=true&require-codec=application/json`
  try {
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
      throw lastError || new Error('compute_probe_failed')
    }
    let parsed = null
    try {
      parsed = JSON.parse(text)
    } catch {
      parsed = null
    }

    const out = {
      ok: true,
      url,
      status: res.status,
      headers: normalizeHeaders(res),
      bodyPreview: text.slice(0, 500),
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
  } catch (e) {
    return {
      ok: false,
      url,
      error: e?.message || String(e)
    }
  }
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
        sendEntry.aoconnectResultProbe = await safeAoResult({ ao, pid, slot })
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
    console.log(
      `slot/current(process) => ${step.probes.slotCurrentViaProcess.status || step.probes.slotCurrentViaProcess.error}`
    )
    console.log(
      `slot(current scheduler POST) => ${step.probes.slotCurrentViaScheduler.status || step.probes.slotCurrentViaScheduler.error}`
    )
    if (step.probes.aoconnectDryrunPing) {
      console.log(`aoconnect dryrun Ping => ${step.probes.aoconnectDryrunPing.ok ? 'ok' : step.probes.aoconnectDryrunPing.error}`)
    }
    for (const send of step.sends) {
      const c = send.computeProbe?.status || send.computeProbe?.error || 'na'
      const su = send.schedulerMessageProbe?.status || send.schedulerMessageProbe?.error || 'na'
      const ar = send.aoconnectResultProbe
        ? send.aoconnectResultProbe.ok
          ? `ok:${send.aoconnectResultProbe.mode || 'unknown'}`
          : send.aoconnectResultProbe.error
        : 'na'
      console.log(`${send.action}: compute=${c} scheduler-msg=${su} ao.result=${ar}`)
    }
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
