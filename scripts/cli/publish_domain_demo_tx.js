#!/usr/bin/env node
import fs from 'fs'
import path from 'path'
import Arweave from 'arweave'

function clean(value) {
  if (value === undefined || value === null) return undefined
  const out = String(value).trim()
  return out === '' ? undefined : out
}

function parseArgs(argv) {
  const args = {
    wallet: clean(process.env.WALLET_PATH || process.env.WALLET) || 'wallet.json',
    input:
      clean(process.env.DM_DEMO_HTML) ||
      path.resolve('scripts/demo/domain-quickstart-demo.html'),
    out: clean(process.env.DM_DEMO_OUT),
    appName: clean(process.env.DM_DEMO_APP_NAME) || 'darkmesh-domain-quickstart',
    variant: clean(process.env.DM_DEMO_VARIANT) || 'dm.quickstart.demo.v1',
    title: clean(process.env.DM_DEMO_TITLE) || 'Darkmesh Domain Quickstart Demo',
    dryRun: clean(process.env.DM_DEMO_SEND) !== '1'
  }

  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i]
    if (arg === '--wallet') args.wallet = clean(argv[++i]) || args.wallet
    else if (arg === '--input') args.input = clean(argv[++i]) || args.input
    else if (arg === '--out') args.out = clean(argv[++i]) || args.out
    else if (arg === '--app-name') args.appName = clean(argv[++i]) || args.appName
    else if (arg === '--variant') args.variant = clean(argv[++i]) || args.variant
    else if (arg === '--title') args.title = clean(argv[++i]) || args.title
    else if (arg === '--send') args.dryRun = false
    else if (arg === '--dry-run') args.dryRun = true
    else if (arg === '--confirm-publish') i += 1
    else if (arg === '-h' || arg === '--help') {
      console.log(
        'Usage: node scripts/cli/publish_domain_demo_tx.js [--wallet wallet.json] [--input scripts/demo/domain-quickstart-demo.html] [--out tmp/demo-tx.json] [--dry-run] [--send --confirm-publish DEMO]'
      )
      process.exit(0)
    } else {
      throw new Error(`Unknown arg: ${arg}`)
    }
  }

  if (!args.dryRun) {
    if (!argv.includes('--wallet')) throw new Error('Live publish requires explicit --wallet')
    if (clean(process.env.DM_DEMO_CONFIRM) !== 'DEMO' && !argv.includes('--confirm-publish')) {
      throw new Error('Live publish requires --confirm-publish DEMO')
    }
    const confirmIdx = argv.indexOf('--confirm-publish')
    if (confirmIdx !== -1 && argv[confirmIdx + 1] !== 'DEMO') {
      throw new Error('Live publish requires --confirm-publish DEMO')
    }
  }

  return args
}

async function main() {
  const args = parseArgs(process.argv)
  if (!fs.existsSync(args.wallet)) throw new Error(`Wallet not found: ${args.wallet}`)
  if (!fs.existsSync(args.input)) throw new Error(`Input HTML not found: ${args.input}`)

  const wallet = JSON.parse(fs.readFileSync(args.wallet, 'utf8'))
  let html = fs.readFileSync(args.input, 'utf8')
  const buildTime = new Date().toISOString()
  html = html.replaceAll('__DM_BUILD_TIME__', buildTime)

  const arweave = Arweave.init({
    host: 'arweave.net',
    port: 443,
    protocol: 'https'
  })

  const tx = await arweave.createTransaction({ data: html }, wallet)
  tx.addTag('Content-Type', 'text/html; charset=utf-8')
  tx.addTag('App-Name', args.appName)
  tx.addTag('Type', 'webpage')
  tx.addTag('Variant', args.variant)
  tx.addTag('Title', args.title)

  await arweave.transactions.sign(tx, wallet)

  let status = 'dry-run'
  if (!args.dryRun) {
    const res = await arweave.transactions.post(tx)
    status = String(res.status)
    if (![200, 202].includes(res.status)) {
      throw new Error(`Publish failed with HTTP ${res.status}`)
    }
  }

  const out = {
    tx: tx.id,
    status,
    buildTime,
    input: path.resolve(args.input),
    url: `https://arweave.net/${tx.id}`,
    dataUrl: `https://arweave.net/tx/${tx.id}/data`
  }

  console.log(JSON.stringify(out, null, 2))
  if (args.out) {
    fs.mkdirSync(path.dirname(args.out), { recursive: true })
    fs.writeFileSync(args.out, JSON.stringify(out, null, 2))
  }
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
