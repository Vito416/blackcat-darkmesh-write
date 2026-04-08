const RETRYABLE_ERROR_CODES = new Set([
  'ECONNRESET',
  'ETIMEDOUT',
  'EPIPE',
  'ECONNREFUSED',
  'ENOTFOUND',
  'EAI_AGAIN',
  'ECONNABORTED',
  'UND_ERR_SOCKET',
  'UND_ERR_CONNECT_TIMEOUT',
  'UND_ERR_HEADERS_TIMEOUT',
  'UND_ERR_BODY_TIMEOUT',
  'UND_ERR_ABORTED'
])

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

export async function withTimeout(promise, ms, label) {
  let timer
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(
          () => reject(new Error(`timeout_${label || 'op'}_${ms}ms`)),
          ms
        )
      })
    ])
  } finally {
    clearTimeout(timer)
  }
}

export function normalizeHeaders(res) {
  const out = {}
  if (!res?.headers?.forEach) return out
  res.headers.forEach((value, key) => {
    out[key] = value
  })
  return out
}

export function classifyRetryError(err) {
  const message = String(err?.message || err || '')
  const name = String(err?.name || 'Error')
  const code = String(err?.code || '')
  const status = Number(err?.status)

  if (Number.isFinite(status) && status >= 500) {
    return { errorClass: `http_${status}`, retryable: true }
  }

  if (err?.retryable === true) {
    return {
      errorClass: String(err?.errorClass || code || name || 'retryable'),
      retryable: true
    }
  }

  if (err?.retryable === false) {
    return {
      errorClass: String(err?.errorClass || code || name || 'error'),
      retryable: false
    }
  }

  if (name === 'AbortError' || /aborted/i.test(message)) {
    return { errorClass: 'aborted', retryable: true }
  }

  if (/timeout/i.test(message)) {
    return { errorClass: 'timeout', retryable: true }
  }

  if (RETRYABLE_ERROR_CODES.has(code)) {
    return { errorClass: code.toLowerCase(), retryable: true }
  }

  if (/fetch failed/i.test(message)) {
    return { errorClass: 'fetch_failed', retryable: true }
  }

  return {
    errorClass: code ? code.toLowerCase() : name.toLowerCase(),
    retryable: false
  }
}

export function backoffDelayMs(attempt, baseDelayMs = 300, maxDelayMs = 4000, factor = 2) {
  const base = Math.min(maxDelayMs, baseDelayMs * factor ** Math.max(0, attempt - 1))
  const jitter = Math.max(50, Math.round(base * 0.2))
  return Math.max(0, Math.round(base - jitter + Math.random() * jitter * 2))
}

export function isTruncatedResponse(response, text) {
  const header = response?.headers?.get?.('content-length')
  if (!header) return false
  const expected = Number(header)
  if (!Number.isFinite(expected) || expected <= 0) return false
  return Buffer.byteLength(text || '', 'utf8') < expected
}

export async function readResponseWithRetry({
  request,
  url,
  label = 'request',
  attempts = 3,
  timeoutMs = 30000,
  baseDelayMs = 500,
  maxDelayMs = 4000,
  bodyPreviewLimit = 800,
  parseJson = false,
  validateParsed = null
}) {
  let lastFailure = null

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await withTimeout(Promise.resolve().then(request), timeoutMs, label)
      if (!response || typeof response.text !== 'function') {
        throw Object.assign(new Error(`${label}_invalid_response`), {
          retryable: false,
          errorClass: 'invalid_response'
        })
      }

      const headers = normalizeHeaders(response)
      const status = Number(response.status)
      const text = await response.text().catch((err) => {
        throw Object.assign(
          new Error(`${label}_body_read_failed:${err?.message || String(err)}`),
          {
            retryable: true,
            errorClass: 'body_read_failed',
            status,
            headers
          }
        )
      })
      const bodyPreview = text.slice(0, bodyPreviewLimit)

      if (Number.isFinite(status) && status >= 500) {
        throw Object.assign(new Error(`${label}_http_${status}`), {
          retryable: true,
          errorClass: `http_${status}`,
          status,
          headers,
          bodyPreview
        })
      }

      if (isTruncatedResponse(response, text)) {
        throw Object.assign(new Error(`${label}_truncated_response`), {
          retryable: true,
          errorClass: 'truncated_response',
          status,
          headers,
          bodyPreview
        })
      }

      let parsed = null
      if (parseJson) {
        try {
          parsed = text ? JSON.parse(text) : null
        } catch (err) {
          throw Object.assign(
            new Error(`${label}_invalid_json:${err?.message || String(err)}`),
            {
              retryable: true,
              errorClass: 'invalid_json',
              status,
              headers,
              bodyPreview
            }
          )
        }
      }

      if (validateParsed) {
        const validation = validateParsed(parsed, {
          attempt,
          response,
          status,
          text,
          headers
        })
        if (validation) {
          if (validation.retryable === false) {
            return {
              ok: response.ok,
              url: url || response.url || null,
              status,
              headers,
              bodyPreview,
              text,
              parsed,
              attempts: attempt,
              retryCount: attempt - 1,
              errorClass: validation.errorClass || null
            }
          }

          throw Object.assign(
            new Error(validation.message || `${label}_validation_failed`),
            {
              retryable: true,
              errorClass: validation.errorClass || 'validation_failed',
              status,
              headers,
              bodyPreview
            }
          )
        }
      }

      return {
        ok: response.ok,
        url: url || response.url || null,
        status,
        headers,
        bodyPreview,
        text,
        parsed,
        attempts: attempt,
        retryCount: attempt - 1,
        errorClass: response.ok ? null : `http_${status}`,
        error: response.ok ? null : `http_${status}`
      }
    } catch (err) {
      const info = classifyRetryError(err)
      lastFailure = {
        ok: false,
        url: url || null,
        status: Number.isFinite(Number(err?.status)) ? Number(err.status) : null,
        bodyPreview: err?.bodyPreview || null,
        error: err?.message || String(err),
        errorClass: err?.errorClass || info.errorClass || 'error',
        attempts: attempt,
        retryCount: attempt - 1,
        retryable: info.retryable
      }

      if (attempt < attempts && info.retryable) {
        await sleep(backoffDelayMs(attempt, baseDelayMs, maxDelayMs))
        continue
      }

      return lastFailure
    }
  }

  return lastFailure || {
    ok: false,
    url: url || null,
    status: null,
    bodyPreview: null,
    error: 'retry_exhausted',
    errorClass: 'retry_exhausted',
    attempts,
    retryCount: Math.max(0, attempts - 1),
    retryable: false
  }
}

export async function runWithRetry(fn, {
  label = 'operation',
  attempts = 3,
  baseDelayMs = 500,
  maxDelayMs = 4000
} = {}) {
  let lastFailure = null

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const value = await Promise.resolve().then(() => fn({ attempt }))
      return {
        ok: true,
        label,
        value,
        attempts: attempt,
        retryCount: attempt - 1,
        errorClass: null
      }
    } catch (err) {
      const info = classifyRetryError(err)
      lastFailure = {
        ok: false,
        label,
        error: err?.message || String(err),
        errorClass: err?.errorClass || info.errorClass || 'error',
        attempts: attempt,
        retryCount: attempt - 1,
        retryable: info.retryable
      }

      if (attempt < attempts && info.retryable) {
        await sleep(backoffDelayMs(attempt, baseDelayMs, maxDelayMs))
        continue
      }

      return lastFailure
    }
  }

  return lastFailure || {
    ok: false,
    label,
    error: 'retry_exhausted',
    errorClass: 'retry_exhausted',
    attempts,
    retryCount: Math.max(0, attempts - 1),
    retryable: false
  }
}
