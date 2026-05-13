// Compatibility wrapper for older automation.
// It now delegates to spawn_wasm_tn.js, which includes robust path fallback
// and normalized module readiness probe behavior.

import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const targetPath = fileURLToPath(new URL('./spawn_wasm_tn.js', import.meta.url))
const child = spawnSync(process.execPath, [targetPath, ...process.argv.slice(2)], {
  stdio: 'inherit',
  env: process.env
})

process.exit(child.status ?? 1)
