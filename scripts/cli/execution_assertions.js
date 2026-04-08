function hasArg(argv, name) {
  return argv.includes(`--${name}`)
}

function argValue(argv, name, fallback) {
  const idx = argv.indexOf(`--${name}`)
  if (idx === -1) return fallback
  return argv[idx + 1] ?? fallback
}

function cleanMode(value, fallback = 'info') {
  const mode = String(value || fallback).trim().toLowerCase()
  if (mode === 'strict') return 'strict'
  if (mode === 'info' || mode === 'informational') return 'info'
  return fallback
}

function isMeaningfulValue(value) {
  if (value === undefined || value === null) return false
  if (typeof value === 'string') return value.trim().length > 0
  if (Array.isArray(value)) return value.length > 0
  if (typeof value === 'object') return Object.keys(value).length > 0
  return true
}

function probeSignals(parsed) {
  const signals = []
  if (isMeaningfulValue(parsed?.output)) signals.push('output')
  if (Number(parsed?.messagesCount || 0) > 0) signals.push('messages')
  if (Number(parsed?.spawnsCount || 0) > 0) signals.push('spawns')
  if (Number(parsed?.assignmentsCount || 0) > 0) signals.push('assignments')
  return signals
}

function hasNumericAtSlot(value) {
  if (typeof value === 'number') return Number.isFinite(value)
  if (typeof value === 'string') return value.trim() !== '' && Number.isFinite(Number(value))
  return false
}

export function resolveExecutionMode(argv = process.argv, env = process.env) {
  const rawMode = argValue(argv, 'execution-mode', env.EXECUTION_MODE || 'info')
  const envStrict = String(env.ASSERT_EXECUTION || '').trim()
  const strictRequested = hasArg(argv, 'assert-execution') || envStrict === '1' || envStrict.toLowerCase() === 'true'
  return cleanMode(strictRequested ? 'strict' : rawMode, 'info')
}

export async function probeCompute(baseUrl, pid, slot, fetchWithTimeout) {
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
  const parsedSummary = parsed
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
    : null

  return {
    url,
    status: res.status,
    ok: res.ok,
    bodyPreview: text.slice(0, 240),
    parsed: parsedSummary,
    resultsLinkProbe
  }
}

export function assessRuntimeEffect(probe) {
  if (!probe) {
    return {
      ok: false,
      reason: 'missing_compute_probe',
      signals: [],
      evidence: null
    }
  }

  if (!probe.ok || probe.status !== 200) {
    return {
      ok: false,
      reason: 'compute_not_ok',
      signals: [],
      evidence: {
        status: probe.status,
        ok: probe.ok,
        bodyPreview: probe.bodyPreview || ''
      }
    }
  }

  const parsed = probe.parsed || {}
  const signals = probeSignals(parsed)
  const hasResults = parsed.hasResults === true || hasNumericAtSlot(parsed.atSlot)
  const hasError = parsed.hasError === true
  const strength = signals.length > 0 ? 'signal' : hasResults ? 'compute' : null
  const ok = hasError ? false : signals.length > 0 || hasResults
  let reason = null
  if (hasError) reason = 'runtime_error'
  else if (!ok) reason = 'empty_runtime_payload'

  return {
    ok,
    reason,
    strength,
    signals,
    evidence: {
      status: probe.status,
      ok: probe.ok,
      atSlot: parsed.atSlot ?? null,
      hasResults,
      output: parsed.output ?? null,
      messagesCount: parsed.messagesCount ?? null,
      spawnsCount: parsed.spawnsCount ?? null,
      assignmentsCount: parsed.assignmentsCount ?? null,
      hasError
    }
  }
}

export function buildExecutionAssertion({
  mode = 'info',
  transportOk,
  schedulerMessageOk,
  computeProbe,
  requireSchedulerMessage = false
}) {
  const normalizedMode = cleanMode(mode, 'info')
  const runtime = assessRuntimeEffect(computeProbe)
  const transportPassed = transportOk === true
  const schedulerPassed = requireSchedulerMessage ? schedulerMessageOk === true : true
  const runtimePassed = runtime.ok === true
  const passed = transportPassed && schedulerPassed && runtimePassed
  const failures = []

  if (!transportPassed) failures.push('transport')
  if (requireSchedulerMessage && !schedulerPassed) failures.push('scheduler_message')
  if (!runtimePassed) failures.push(runtime.reason || 'runtime_effect')

  return {
    mode: normalizedMode,
    enforced: normalizedMode === 'strict',
    passed,
    transportOk: transportPassed,
    schedulerMessageOk: requireSchedulerMessage ? schedulerPassed : null,
    runtimeEffectOk: runtimePassed,
    runtimeEffect: runtime,
    failures
  }
}

export function summarizeAssertions(assertions) {
  const rows = Array.isArray(assertions) ? assertions.filter(Boolean) : []
  const total = rows.length
  const passed = rows.filter((row) => row.passed === true).length
  const failed = rows.filter((row) => row.passed === false).length
  const enforcedFailed = rows.filter((row) => row.enforced === true && row.passed === false).length
  const runtimeOk = rows.filter((row) => row.runtimeEffectOk === true).length
  const transportOk = rows.filter((row) => row.transportOk === true).length
  const schedulerOk = rows.filter((row) => row.schedulerMessageOk === true).length

  return {
    total,
    passed,
    failed,
    enforcedFailed,
    transportOk,
    schedulerOk,
    runtimeOk
  }
}

export function formatAssertionStatus(assertion) {
  if (!assertion) return 'n/a'
  if (assertion.passed) return 'pass'
  const reason = Array.isArray(assertion.failures) && assertion.failures.length > 0 ? assertion.failures.join('+') : 'failed'
  return `fail(${reason})`
}
