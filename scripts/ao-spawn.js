// Legacy wrapper kept for backward compatibility.
// Prefer: scripts/cli/spawn_wasm_tn.js
//
// Supported legacy env mapping:
// - MODULE_TX -> AO_MODULE
// - URL -> HB_URL
// - SCHEDULER -> HB_SCHEDULER
// - WALLET/WALLET_PATH pass through

import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const moduleTx = process.env.MODULE_TX || process.env.AO_MODULE
if (!moduleTx) {
  console.error('MODULE_TX (or AO_MODULE) env is required.')
  process.exit(1)
}

const env = {
  ...process.env,
  AO_MODULE: moduleTx
}
if (!env.HB_URL && process.env.URL) env.HB_URL = process.env.URL
if (!env.HB_SCHEDULER && process.env.SCHEDULER) env.HB_SCHEDULER = process.env.SCHEDULER
if (!env.AO_NAME) env.AO_NAME = 'blackcat-write'

const targetPath = fileURLToPath(new URL('./cli/spawn_wasm_tn.js', import.meta.url))
const child = spawnSync(process.execPath, [targetPath, ...process.argv.slice(2)], {
  stdio: 'inherit',
  env
})

process.exit(child.status ?? 1)
