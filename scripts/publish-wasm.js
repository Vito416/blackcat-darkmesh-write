// Publish dist/write/process.wasm to Arweave with correct WASM tags (ao.TN.1)
// Usage: node scripts/publish-wasm.js
// Requires: wallet.json funded, dist/write/process.wasm built

import fs from 'fs'
import Arweave from 'arweave'

const wallet = JSON.parse(fs.readFileSync('wallet.json', 'utf8'))
const data = fs.readFileSync('dist/write/process.wasm')

const TAGS = [
  ['Content-Type', 'application/wasm'],
  ['Module-Format', 'wasm64-unknown-emscripten-draft_2024_02_15'],
  ['Variant', 'ao.TN.1'],
  ['Data-Protocol', 'ao'],
  ['Input-Encoding', 'JSON-1'],
  ['Output-Encoding', 'JSON-1'],
  ['Memory-Limit', '1-gb'],
  ['Compute-Limit', '9000000000000'],
  ['AOS-Version', '2.0.6'],
  ['Type', 'Module'],
  ['Name', 'blackcat-write'],
  ['signing-format', 'ans104'],
  ['accept-bundle', 'true'],
  ['accept-codec', 'httpsig@1.0']
]

async function main() {
  const arweave = Arweave.init({
    host: 'arweave.net',
    port: 443,
    protocol: 'https'
  })

  const tx = await arweave.createTransaction({ data }, wallet)
  TAGS.forEach(([name, value]) => tx.addTag(name, value))

  await arweave.transactions.sign(tx, wallet)
  const res = await arweave.transactions.post(tx)

  console.log('TX', tx.id, 'status', res.status)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
