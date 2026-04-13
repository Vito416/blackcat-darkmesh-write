// Spawn WASM process with full tag set (Variant=ao.TN.1) using ao.request directly.
// Usage:
//   AO_MODULE=<txid> AO_URL=https://push-1.forward.computer AO_SCHEDULER=n_XZ... node scripts/cli/spawn_wasm_raw.js
// Requires wallet.json (funded) and published wasm module.

import fs from 'fs'
import { connect, createSigner } from '@permaweb/aoconnect'

const MODULE_TX = process.env.AO_MODULE || 'F47cEULJhjxolLnvRYO2zGK4cMGToydkxVmA7R7Qe_c'
const URL =
  process.env.HB_URL ||
  process.env.HYPERBEAM_URL ||
  process.env.AO_URL ||
  'https://push-1.forward.computer'
const SCHED =
  process.env.HB_SCHEDULER ||
  process.env.HYPERBEAM_SCHEDULER ||
  process.env.AO_SCHEDULER ||
  'n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo'
const WRITE_SIG_TYPE = process.env.WRITE_SIG_TYPE || ''
const WRITE_SIG_PUBLIC = process.env.WRITE_SIG_PUBLIC || ''
const WRITE_SIG_PUBLICS = process.env.WRITE_SIG_PUBLICS || ''

const signer = createSigner(JSON.parse(fs.readFileSync('wallet.json', 'utf8')))
const ao = connect({ MODE: 'mainnet', URL, SCHEDULER: SCHED, signer })

async function main() {
  const params = {
    path: '/push',
    device: 'process@1.0',
    'scheduler-device': 'scheduler@1.0',
    'push-device': 'push@1.0',
    'execution-device': 'genesis-wasm@1.0',
    Authority: SCHED,
    Scheduler: SCHED,
    Module: MODULE_TX,
    // Critical tags
    Type: 'Process',
    Variant: 'ao.TN.1',
    'Data-Protocol': 'ao',
    'Content-Type': 'application/wasm',
    'Module-Format': 'wasm64-unknown-emscripten-draft_2024_02_15',
    'Input-Encoding': 'JSON-1',
    'Output-Encoding': 'JSON-1',
    'Memory-Limit': '1-gb',
    'Compute-Limit': '9000000000000',
    'AOS-Version': '2.0.6',
    Name: 'blackcat-write',
    'accept-bundle': 'true',
    'accept-codec': 'httpsig@1.0',
    'signing-format': 'ans104',
    data: '1984'
  }
  if (WRITE_SIG_TYPE) params.WRITE_SIG_TYPE = WRITE_SIG_TYPE
  if (WRITE_SIG_PUBLIC) params.WRITE_SIG_PUBLIC = WRITE_SIG_PUBLIC
  if (WRITE_SIG_PUBLICS) params.WRITE_SIG_PUBLICS = WRITE_SIG_PUBLICS

  const res = await ao.request(params)
  const pid = res.headers.get('process')
  console.log('status', res.status)
  console.log('PID', pid)
  const body = await res.text().catch(() => '')
  if (body) console.log('body', body)
  if (!pid) process.exit(1)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
