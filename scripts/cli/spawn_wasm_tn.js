// Spawn a WASM process with Variant=ao.TN.1 (bypasses aoconnect's hardcoded ao.N.1)
// Usage:
//   AO_MODULE=<txid> AO_URL=https://push-1.forward.computer AO_SCHEDULER=n_XZ... node scripts/cli/spawn_wasm_tn.js
// Requires wallet.json funded and dist/write/process.wasm already uploaded.

import fs from 'fs'
import { connect, createSigner } from '@permaweb/aoconnect'

function cleanEnv(val) {
  if (!val) return undefined
  const v = String(val).trim()
  if (!v || v === 'undefined' || v === 'null') return undefined
  return v
}

const MODULE_TX = cleanEnv(process.env.AO_MODULE) || 'F47cEULJhjxolLnvRYO2zGK4cMGToydkxVmA7R7Qe_c'
const URL =
  cleanEnv(process.env.HB_URL) ||
  cleanEnv(process.env.HYPERBEAM_URL) ||
  cleanEnv(process.env.AO_URL) ||
  'https://push-1.forward.computer'
const SCHED =
  cleanEnv(process.env.HB_SCHEDULER) ||
  cleanEnv(process.env.HYPERBEAM_SCHEDULER) ||
  cleanEnv(process.env.AO_SCHEDULER) ||
  'n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo'
const WRITE_SIG_TYPE = cleanEnv(process.env.WRITE_SIG_TYPE)
const WRITE_SIG_PUBLIC = cleanEnv(process.env.WRITE_SIG_PUBLIC)
const WRITE_SIG_PUBLICS = cleanEnv(process.env.WRITE_SIG_PUBLICS)

const signer = createSigner(JSON.parse(fs.readFileSync('wallet.json', 'utf-8')))
// mainnet mode now works because we patched aoconnect to keep Variant=ao.TN.1
const ao = connect({ MODE: 'mainnet', URL, SCHEDULER: SCHED, signer })

function optionalTag(name, value) {
  return value ? [{ name, value }] : []
}

async function main() {
  const pid = await ao.spawn({
    module: MODULE_TX,
    scheduler: SCHED,
    data: '1984',
    tags: [
      { name: 'Variant', value: 'ao.TN.1' },
      { name: 'Name', value: 'blackcat-write' },
      { name: 'Content-Type', value: 'application/wasm' },
      { name: 'Data-Protocol', value: 'ao' },
      { name: 'Input-Encoding', value: 'JSON-1' },
      { name: 'Output-Encoding', value: 'JSON-1' },
      { name: 'signing-format', value: 'ans104' },
      { name: 'accept-bundle', value: 'true' },
      { name: 'accept-codec', value: 'httpsig@1.0' },
      ...optionalTag('WRITE_SIG_TYPE', WRITE_SIG_TYPE),
      ...optionalTag('WRITE_SIG_PUBLIC', WRITE_SIG_PUBLIC),
      ...optionalTag('WRITE_SIG_PUBLICS', WRITE_SIG_PUBLICS)
    ]
  })

  console.log('PID', pid)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
