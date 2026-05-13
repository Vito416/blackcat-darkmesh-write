#!/usr/bin/env node
import fs from 'node:fs'
import path from 'node:path'
import { randomUUID, createPrivateKey, sign as rsaSign, constants as cryptoConstants } from 'node:crypto'
import Arweave from 'arweave'

function clean(value) {
  if (value === undefined || value === null) return undefined
  const out = String(value).trim()
  return out === '' ? undefined : out
}

function parseArgs(argv) {
  const args = {
    wallet: clean(process.env.WALLET_PATH || process.env.WALLET) || 'wallet.json',
    template: clean(process.env.DM1_TEMPLATE),
    domain: clean(process.env.DM1_DOMAIN),
    siteTx: clean(process.env.DM1_SITE_TX),
    out: clean(process.env.DM1_OUT),
    seq: clean(process.env.DM1_SEQ),
    validDays: clean(process.env.DM1_VALID_DAYS) || '365',
    dryRun: clean(process.env.DM1_SEND) !== '1'
  }

  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i]
    if (arg === '--wallet') args.wallet = clean(argv[++i]) || args.wallet
    else if (arg === '--template') args.template = clean(argv[++i]) || args.template
    else if (arg === '--domain') args.domain = clean(argv[++i]) || args.domain
    else if (arg === '--site-tx') args.siteTx = clean(argv[++i]) || args.siteTx
    else if (arg === '--out') args.out = clean(argv[++i]) || args.out
    else if (arg === '--seq') args.seq = clean(argv[++i]) || args.seq
    else if (arg === '--valid-days') args.validDays = clean(argv[++i]) || args.validDays
    else if (arg === '--send') args.dryRun = false
    else if (arg === '--dry-run') args.dryRun = true
    else if (arg === '--confirm-publish') i += 1
    else if (arg === '-h' || arg === '--help') {
      console.log(
        'Usage: node scripts/cli/publish_dm1_config_tx.js --template <cfg.json> --domain <domain> --site-tx <txid> --out <cfg-out.json> [--wallet wallet.json] [--seq 5] [--valid-days 365] [--dry-run] [--send --confirm-publish DM1]'
      )
      process.exit(0)
    } else {
      throw new Error(`Unknown arg: ${arg}`)
    }
  }

  if (!args.template) throw new Error('--template is required')
  if (!args.domain) throw new Error('--domain is required')
  if (!args.siteTx) throw new Error('--site-tx is required')
  if (!args.out) throw new Error('--out is required')

  if (!args.dryRun) {
    if (!argv.includes('--wallet')) throw new Error('Live DM1 publish requires explicit --wallet')
    const confirmIdx = argv.indexOf('--confirm-publish')
    if (clean(process.env.DM1_CONFIRM) !== 'DM1' && confirmIdx === -1) {
      throw new Error('Live DM1 publish requires --confirm-publish DM1')
    }
    if (confirmIdx !== -1 && argv[confirmIdx + 1] !== 'DM1') {
      throw new Error('Live DM1 publish requires --confirm-publish DM1')
    }
  }

  return args
}

function canonicalSigPayload(config) {
  return JSON.stringify({
    domain: config.domain,
    nonce: config.nonce,
    owner: config.owner,
    sigAlg: config.sigAlg,
    v: config.v,
    validFrom: config.validFrom,
    validTo: config.validTo
  })
}

async function main() {
  const args = parseArgs(process.argv)
  if (!fs.existsSync(args.wallet)) throw new Error(`Wallet not found: ${args.wallet}`)
  if (!fs.existsSync(args.template)) throw new Error(`Template not found: ${args.template}`)

  const wallet = JSON.parse(fs.readFileSync(args.wallet, 'utf8'))
  const template = JSON.parse(fs.readFileSync(args.template, 'utf8'))
  const arweave = Arweave.init({ host: 'arweave.net', port: 443, protocol: 'https' })
  const owner = await arweave.wallets.jwkToAddress(wallet)
  const now = Math.floor(Date.now() / 1000)
  const validDays = Number.parseInt(args.validDays, 10)
  if (!Number.isFinite(validDays) || validDays <= 0) {
    throw new Error(`Invalid --valid-days value: ${args.validDays}`)
  }

  const config = {
    ...template,
    v: 'dm1',
    domain: args.domain,
    validFrom: now,
    validTo: now + validDays * 24 * 60 * 60,
    sigAlg: 'rsa-pss-sha256',
    nonce: randomUUID(),
    owner,
    kid: owner,
    'x-targetType': 'tx',
    'x-siteTx': args.siteTx
  }

  delete config.sig

  const payload = canonicalSigPayload(config)
  const privateKey = createPrivateKey({ key: wallet, format: 'jwk' })
  const signature = rsaSign('sha256', Buffer.from(payload, 'utf8'), {
    key: privateKey,
    padding: cryptoConstants.RSA_PKCS1_PSS_PADDING,
    saltLength: 32
  }).toString('base64')
  config.sig = signature

  fs.mkdirSync(path.dirname(args.out), { recursive: true })
  fs.writeFileSync(args.out, JSON.stringify(config, null, 2) + '\n')

  const tx = await arweave.createTransaction(
    { data: JSON.stringify(config, null, 2) + '\n' },
    wallet
  )
  tx.addTag('Content-Type', 'application/json')
  tx.addTag('App-Name', 'darkmesh-dm1-config')
  tx.addTag('Type', 'config')
  tx.addTag('Variant', 'dm1')
  tx.addTag('Domain', args.domain)
  tx.addTag('Owner', owner)
  tx.addTag('Target-Type', 'tx')
  tx.addTag('Target-TX', args.siteTx)

  await arweave.transactions.sign(tx, wallet)

  let status = 'dry-run'
  if (!args.dryRun) {
    const res = await arweave.transactions.post(tx)
    status = String(res.status)
    if (![200, 202].includes(res.status)) {
      throw new Error(`Publish failed with HTTP ${res.status}`)
    }
  }

  const seq = args.seq ? String(args.seq) : ''
  const txt = [
    'v=dm1',
    `cfg=${tx.id}`,
    `kid=${owner}`,
    'ttl=3600',
    seq ? `seq=${seq}` : null
  ]
    .filter(Boolean)
    .join(';')

  const out = {
    domain: args.domain,
    cfgTx: tx.id,
    txt,
    status,
    targetTx: args.siteTx,
    configPath: path.resolve(args.out),
    sigPayload: payload
  }

  console.log(JSON.stringify(out, null, 2))
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
