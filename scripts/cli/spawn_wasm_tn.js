// Spawn WASM process with Variant=ao.TN.1 via ao.request (control-plane parity path).
// Usage:
//   AO_MODULE=<txid> HB_URL=https://write.darkmesh.fun HB_SCHEDULER=_wCF... node scripts/cli/spawn_wasm_tn.js
// Optional:
//   AO_WAIT_MODULE=1|0 AO_SPAWN_PATH=/push AO_NAME=blackcat-write

import fs from 'fs'
import { connect, createSigner } from '@permaweb/aoconnect'

const EXT_DEFAULTS = {
  moduleFormat: 'wasm64-unknown-emscripten-draft_2024_02_15',
  memoryLimit: '1-gb',
  computeLimit: '9000000000000',
  aosVersion: '2.0.6'
}
const DEFAULT_PUBLIC_SCHEDULER = 'n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo'

function clean(value) {
  if (value === undefined || value === null) return undefined
  const out = String(value).trim()
  return out === '' ? undefined : out
}

function parseBoolFlag(value, defaultValue) {
  const v = clean(value)
  if (v === undefined) return defaultValue
  if (v === '1' || v.toLowerCase() === 'true') return true
  if (v === '0' || v.toLowerCase() === 'false') return false
  return defaultValue
}

function normalizeSpawnPath(value) {
  const v = clean(value)
  if (!v) return undefined
  return v.startsWith('/') ? v : `/${v}`
}

function resolveSpawnPaths({ url, explicitPath }) {
  const manual = normalizeSpawnPath(explicitPath)
  if (manual) return [manual]
  try {
    const parsed = new URL(url)
    const pathname = (parsed.pathname || '/').replace(/\/+$/, '') || '/'
    if (pathname.includes('~process@1.0')) return ['/push']
  } catch {
    // no-op
  }
  return ['/push', '/~process@1.0/push']
}

function resolveModuleProbeBaseUrl(url) {
  const raw = clean(url) || ''
  const fallback = raw
    .replace(/\/+$/, '')
    .replace(/\/~process@1\.0$/, '')
    .replace(/\/push$/, '')

  try {
    const parsed = new URL(raw)
    let pathname = (parsed.pathname || '/').replace(/\/+$/, '') || '/'
    if (pathname.endsWith('/~process@1.0')) {
      pathname = pathname.replace(/\/~process@1\.0$/, '') || '/'
    }
    if (pathname.endsWith('/push')) {
      pathname = pathname.replace(/\/push$/, '') || '/'
    }
    parsed.pathname = pathname
    return parsed.toString().replace(/\/$/, '')
  } catch {
    return fallback || raw
  }
}


function resolveSchedulerLocation(url) {
  try {
    const parsed = new URL(url)
    let pathname = (parsed.pathname || '/').replace(/\/+$/, '') || '/'
    if (pathname.endsWith('/~process@1.0')) {
      pathname = pathname.replace(/\/~process@1\.0$/, '') || '/'
    }
    if (pathname.endsWith('/push')) {
      pathname = pathname.replace(/\/push$/, '') || '/'
    }
    parsed.pathname = pathname
    parsed.search = ''
    parsed.hash = ''
    return parsed.toString().replace(/\/$/, '')
  } catch {
    return undefined
  }
}

async function fetchSchedulerAddressFromMeta(location) {
  const normalized = clean(location)
  if (!normalized) return null
  const endpoint = `${normalized.replace(/\/$/, '')}/~meta@1.0/info/address`
  const res = await fetch(endpoint, { method: 'GET' }).catch(() => null)
  if (!res || !res.ok) return null
  const body = clean(await res.text().catch(() => ''))
  if (!body) return null
  if (!/^[A-Za-z0-9_-]{43,64}$/.test(body)) return null
  return body
}

function parsePidFromBody(body) {
  if (!body) return null
  const jsonStart = body.indexOf('{')
  if (jsonStart >= 0) {
    try {
      const parsed = JSON.parse(body.slice(jsonStart))
      return (
        parsed?.process ||
        parsed?.Process ||
        parsed?.pid ||
        parsed?.PID ||
        parsed?.['process-id'] ||
        parsed?.processId ||
        null
      )
    } catch {
      // no-op
    }
  }
  const m =
    body.match(/process(?:-id)?["'\s:=]+([A-Za-z0-9_-]{43,64})/i) ||
    body.match(/pid["'\s:=]+([A-Za-z0-9_-]{43,64})/i)
  return m ? m[1] : null
}

function parseArgs(argv) {
  const envDataFile = clean(process.env.AO_SPAWN_DATA_FILE)
  let dataFromFile = undefined
  if (envDataFile) {
    if (!fs.existsSync(envDataFile)) {
      throw new Error(`AO_SPAWN_DATA_FILE not found: ${envDataFile}`)
    }
    dataFromFile = fs.readFileSync(envDataFile, 'utf8')
  }
  const args = {
    module: clean(process.env.AO_MODULE),
    name: clean(process.env.AO_NAME) || 'blackcat-write',
    wallet: clean(process.env.WALLET) || clean(process.env.WALLET_PATH) || 'wallet.json',
    url:
      clean(process.env.HB_URL) ||
      clean(process.env.HYPERBEAM_URL) ||
      clean(process.env.AO_URL) ||
      'http://127.0.0.1:8734',
    scheduler:
      clean(process.env.HB_SCHEDULER) ||
      clean(process.env.HYPERBEAM_SCHEDULER) ||
      clean(process.env.AO_SCHEDULER),
    schedulerLocation:
      clean(process.env.HB_SCHEDULER_LOCATION) ||
      clean(process.env.HYPERBEAM_SCHEDULER_LOCATION) ||
      clean(process.env.AO_SCHEDULER_LOCATION),
    variant: clean(process.env.AO_VARIANT) || 'ao.TN.1',
    enforceSchedulerParity: parseBoolFlag(process.env.AO_ENFORCE_SCHEDULER_PARITY, true),
    spawnPath: clean(process.env.AO_SPAWN_PATH),
    waitModule: parseBoolFlag(process.env.AO_WAIT_MODULE, true),
    waitModuleTimeoutMs: Number(clean(process.env.AO_WAIT_MODULE_TIMEOUT_MS) || '300000'),
    waitModuleIntervalMs: Number(clean(process.env.AO_WAIT_MODULE_INTERVAL_MS) || '5000'),
    data: dataFromFile ?? clean(process.env.AO_SPAWN_DATA) ?? '1984',
    dataFile: envDataFile,
    out: clean(process.env.AO_PID_OUT),
    writeSigType: clean(process.env.WRITE_SIG_TYPE),
    writeSigPublic: clean(process.env.WRITE_SIG_PUBLIC),
    writeSigPublics: clean(process.env.WRITE_SIG_PUBLICS),
    writeSigSecret: clean(process.env.WRITE_SIG_SECRET)
  }

  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i]
    if (arg === '--module') args.module = clean(argv[++i]) || args.module
    else if (arg === '--name') args.name = clean(argv[++i]) || args.name
    else if (arg === '--wallet') args.wallet = clean(argv[++i]) || args.wallet
    else if (arg === '--url') args.url = clean(argv[++i]) || args.url
    else if (arg === '--scheduler') args.scheduler = clean(argv[++i]) || args.scheduler
    else if (arg === '--scheduler-location') {
      args.schedulerLocation = clean(argv[++i]) || args.schedulerLocation
    }
    else if (arg === '--enforce-scheduler-parity') {
      args.enforceSchedulerParity = parseBoolFlag(argv[++i], args.enforceSchedulerParity)
    }
    else if (arg === '--variant') args.variant = clean(argv[++i]) || args.variant
    else if (arg === '--spawn-path') args.spawnPath = clean(argv[++i]) || args.spawnPath
    else if (arg === '--wait-module') args.waitModule = parseBoolFlag(argv[++i], args.waitModule)
    else if (arg === '--wait-module-timeout-ms') {
      args.waitModuleTimeoutMs = Number(clean(argv[++i]) || args.waitModuleTimeoutMs)
    }
    else if (arg === '--wait-module-interval-ms') {
      args.waitModuleIntervalMs = Number(clean(argv[++i]) || args.waitModuleIntervalMs)
    }
    else if (arg === '--data') args.data = clean(argv[++i]) || args.data
    else if (arg === '--data-file') {
      const p = clean(argv[++i])
      if (!p) throw new Error('--data-file requires a path')
      if (!fs.existsSync(p)) throw new Error(`Data file not found: ${p}`)
      args.dataFile = p
      args.data = fs.readFileSync(p, 'utf8')
    }
    else if (arg === '--out') args.out = clean(argv[++i]) || args.out
    else if (arg === '-h' || arg === '--help') {
      console.log(
        'Usage: node scripts/cli/spawn_wasm_tn.js --module <TX> --url https://write.darkmesh.fun [--data-file path/to/process.lua] [--spawn-path /push] [--scheduler-location https://write.darkmesh.fun] [--enforce-scheduler-parity 1]'
      )
      process.exit(0)
    } else {
      throw new Error(`Unknown arg: ${arg}`)
    }
  }

  if (!args.module) throw new Error('Missing AO module tx. Provide --module or AO_MODULE.')
  return args
}

async function sleep(ms) {
  return new Promise((resolveFn) => setTimeout(resolveFn, ms))
}

async function waitForModuleReady({ url, moduleTx, timeoutMs, intervalMs }) {
  const probeBaseUrl = resolveModuleProbeBaseUrl(url)
  const endpoint = `${probeBaseUrl.replace(/\/$/, '')}/${moduleTx}~module@1.0?accept-bundle=true`
  const deadline = Date.now() + timeoutMs
  let lastStatus = null
  while (Date.now() < deadline) {
    const res = await fetch(endpoint, { method: 'GET' }).catch(() => null)
    const status = res?.status ?? 0
    if (status === 200) {
      return { ok: true, endpoint, status }
    }
    lastStatus = status
    await sleep(intervalMs)
  }
  return { ok: false, endpoint, status: lastStatus ?? 0 }
}

async function main() {
  const args = parseArgs(process.argv)
  const walletPath = args.wallet
  if (!fs.existsSync(walletPath)) throw new Error(`Wallet not found: ${walletPath}`)

  const wallet = JSON.parse(fs.readFileSync(walletPath, 'utf8'))
  const signer = createSigner(wallet)
  const ao = connect({
    MODE: 'mainnet',
    URL: args.url,
    SCHEDULER: args.scheduler || DEFAULT_PUBLIC_SCHEDULER,
    signer
  })

  const schedulerLocation = args.schedulerLocation || resolveSchedulerLocation(args.url)
  const schedulerFromMeta = await fetchSchedulerAddressFromMeta(schedulerLocation)
  const scheduler = args.scheduler || schedulerFromMeta || DEFAULT_PUBLIC_SCHEDULER

  if (
    args.enforceSchedulerParity &&
    schedulerFromMeta &&
    scheduler !== schedulerFromMeta
  ) {
    throw new Error(
      `scheduler_url_parity_mismatch: scheduler=${scheduler} but ${schedulerLocation}/~meta@1.0/info/address=${schedulerFromMeta}`
    )
  }

  if (args.waitModule) {
    const readiness = await waitForModuleReady({
      url: args.url,
      moduleTx: args.module,
      timeoutMs: args.waitModuleTimeoutMs,
      intervalMs: args.waitModuleIntervalMs
    })
    if (!readiness.ok) {
      throw new Error(
        `module_not_ready: status=${readiness.status} endpoint=${readiness.endpoint} (disable with --wait-module 0)`
      )
    }
  }

  const baseParams = {
    device: 'process@1.0',
    'scheduler-device': 'scheduler@1.0',
    'push-device': 'push@1.0',
    'execution-device': 'genesis-wasm@1.0',
    Authority: scheduler,
    Scheduler: scheduler,
    'Scheduler-Location': schedulerLocation,
    Module: args.module,
    Type: 'Process',
    Variant: args.variant,
    'Data-Protocol': 'ao',
    'Content-Type': 'application/wasm',
    'Module-Format': EXT_DEFAULTS.moduleFormat,
    'Input-Encoding': 'JSON-1',
    'Output-Encoding': 'JSON-1',
    'Memory-Limit': EXT_DEFAULTS.memoryLimit,
    'Compute-Limit': EXT_DEFAULTS.computeLimit,
    'AOS-Version': EXT_DEFAULTS.aosVersion,
    Name: args.name,
    'accept-bundle': 'true',
    'accept-codec': 'httpsig@1.0',
    'signing-format': 'ans104',
    data: args.data
  }
  if (args.writeSigType) baseParams.WRITE_SIG_TYPE = args.writeSigType
  if (args.writeSigPublic) baseParams.WRITE_SIG_PUBLIC = args.writeSigPublic
  if (args.writeSigPublics) baseParams.WRITE_SIG_PUBLICS = args.writeSigPublics
  if (args.writeSigSecret) baseParams.WRITE_SIG_SECRET = args.writeSigSecret

  const trySpawn = async (path) => {
    const res = await ao.request({ ...baseParams, path })
    const body = await res.text().catch(() => '')
    const pidFromHeader = res?.headers?.get('process') || res?.headers?.get('Process')
    const pid = pidFromHeader || parsePidFromBody(body)
    return { path, res, body, pid, pidFromHeader }
  }

  let attempt = null
  const spawnPaths = resolveSpawnPaths({ url: args.url, explicitPath: args.spawnPath })
  for (const path of spawnPaths) {
    const candidate = await trySpawn(path)
    attempt = candidate
    if (candidate.res.ok && candidate.pid) break
  }

  if (!attempt || !attempt.res.ok || !attempt.pid) {
    throw new Error(
      `spawn_failed: path=${attempt?.path || 'na'} status=${attempt?.res?.status || 'na'} pid=${attempt?.pid || 'missing'} body=${(attempt?.body || '').slice(0, 400)}`
    )
  }

  const out = {
    pid: attempt.pid,
    module: args.module,
    name: args.name,
    url: args.url,
    scheduler,
    schedulerInput: args.scheduler || null,
    schedulerFromMeta: schedulerFromMeta || null,
    schedulerLocation,
    spawnPath: attempt.path,
    variant: args.variant,
    status: attempt.res.status,
    pidFromHeader: attempt.pidFromHeader || null
  }
  console.log(JSON.stringify(out, null, 2))
  if (args.out) fs.writeFileSync(args.out, JSON.stringify(out, null, 2))
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
