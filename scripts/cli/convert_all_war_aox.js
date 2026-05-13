#!/usr/bin/env node
import fs from 'fs'
import Arweave from 'arweave'
import { connect, createSigner } from '@permaweb/aoconnect'

function arg(name, fallback) {
  const idx = process.argv.indexOf(`--${name}`)
  if (idx === -1) return fallback
  return process.argv[idx + 1]
}

function hasArg(name) {
  return process.argv.includes(`--${name}`)
}

function asBool(value, fallback = false) {
  if (value === undefined || value === null) return fallback
  const v = String(value).trim().toLowerCase()
  if (v === '1' || v === 'true' || v === 'yes' || v === 'on') return true
  if (v === '0' || v === 'false' || v === 'no' || v === 'off') return false
  return fallback
}

function asInt(value, fallback) {
  const n = Number(value)
  return Number.isFinite(n) ? Math.trunc(n) : fallback
}

function ensure(val, name) {
  if (val === undefined || val === null || String(val).trim() === '') {
    throw new Error(`Missing --${name}`)
  }
  return String(val).trim()
}

function findTagValue(msg, name) {
  const tags = Array.isArray(msg?.Tags) ? msg.Tags : []
  const hit = tags.find((t) => t?.name === name)
  return hit?.value
}

function formatUnits(v, denom = 12) {
  const n = BigInt(v)
  const negative = n < 0n
  const abs = negative ? -n : n
  const base = 10n ** BigInt(denom)
  const whole = abs / base
  const frac = (abs % base).toString().padStart(denom, '0').replace(/0+$/, '')
  return `${negative ? '-' : ''}${whole.toString()}${frac ? '.' + frac : ''}`
}

function makeTimedFetch(timeoutMs) {
  return async (input, init = {}) => {
    const ctrl = new AbortController()
    const timeout = setTimeout(() => ctrl.abort(), timeoutMs)
    try {
      return await fetch(input, { ...init, signal: ctrl.signal })
    } finally {
      clearTimeout(timeout)
    }
  }
}

async function main() {
  const send = asBool(arg('send', '0'), false)
  const dryRun = asBool(arg('dry-run', send ? '0' : '1'), !send)
  if (!dryRun) {
    for (const required of ['pid', 'wallet']) {
      if (!hasArg(required)) {
        throw new Error(`Live burn-all requires explicit --${required}`)
      }
    }
    if (arg('confirm-burn-all') !== 'BURN_ALL') {
      throw new Error('Live burn-all requires --confirm-burn-all BURN_ALL')
    }
  }

  const pid = ensure(arg('pid', 'xU9zFkq3X2ZQ6olwNVvr1vUWIjc3kXTWr7xKQD6dh10'), 'pid')
  const walletPath = ensure(arg('wallet', 'wallet.json'), 'wallet')
  const retries = asInt(arg('retries', '1'), 1)
  const retryDelayMs = asInt(arg('retry-delay-ms', '30000'), 30000)
  const timeoutMs = asInt(arg('timeout-ms', '20000'), 20000)
  const outFile = arg('out')

  const wallet = JSON.parse(fs.readFileSync(walletPath, 'utf8'))
  const signer = createSigner(wallet)
  const fetchWithTimeout = makeTimedFetch(timeoutMs)
  const ao = connect({
    MODE: 'legacy',
    signer,
    fetch: fetchWithTimeout
  })

  const arweave = Arweave.init({ host: 'arweave.net', port: 443, protocol: 'https' })
  const address = await arweave.wallets.jwkToAddress(wallet)

  const balanceTags = [
    { name: 'Action', value: 'Balance' },
    { name: 'Recipient', value: address },
    { name: 'Data-Protocol', value: 'ao' },
    { name: 'Type', value: 'Message' },
    { name: 'Variant', value: 'ao.TN.1' },
    { name: 'Content-Type', value: 'text/plain' }
  ]
  const infoTags = [
    { name: 'Action', value: 'Info' },
    { name: 'Data-Protocol', value: 'ao' },
    { name: 'Type', value: 'Message' },
    { name: 'Variant', value: 'ao.TN.1' },
    { name: 'Content-Type', value: 'text/plain' }
  ]

  const info = await ao.dryrun({ process: pid, tags: infoTags, data: '.' })
  const infoMsg = info?.Messages?.[0] || {}
  const burnFee = BigInt(findTagValue(infoMsg, 'BurnFee') || '0')
  const minBurnAmt = BigInt(findTagValue(infoMsg, 'MinBurnAmt') || '0')
  const denomination = Number(findTagValue(infoMsg, 'Denomination') || '12')

  const beforeRes = await ao.dryrun({ process: pid, tags: balanceTags, data: '.' })
  const beforeMsg = beforeRes?.Messages?.[0] || {}
  const beforeRaw = findTagValue(beforeMsg, 'Balance') || beforeMsg?.Data || '0'
  if (!/^\d+$/.test(String(beforeRaw))) {
    throw new Error('Unable to parse balance from AO dryrun')
  }
  const beforeBalance = BigInt(beforeRaw)

  const quantity = beforeBalance
  const expectedBridgeQuantity = beforeBalance - burnFee
  const attempts = []
  let sent = null
  let result = null

  if (!dryRun && beforeBalance > 0n) {
    for (let i = 1; i <= Math.max(1, retries); i++) {
      try {
        const messageId = await ao.message({
          process: pid,
          signer,
          tags: [
            { name: 'Action', value: 'Burn' },
            { name: 'Quantity', value: quantity.toString() },
            { name: 'Recipient', value: address },
            { name: 'Data-Protocol', value: 'ao' },
            { name: 'Variant', value: 'ao.TN.1' },
            { name: 'Type', value: 'Message' },
            { name: 'Content-Type', value: 'text/plain' },
            { name: 'SDK', value: 'aoconnect' }
          ],
          data: '.'
        })
        sent = { attempt: i, messageId }
        attempts.push({ attempt: i, ok: true, messageId })
        break
      } catch (e) {
        const error = e?.message || String(e)
        attempts.push({ attempt: i, ok: false, error })
        if (!/Rate limit exceeded/i.test(error)) break
        if (i < retries) {
          await new Promise((resolve) => setTimeout(resolve, retryDelayMs))
        }
      }
    }

    if (sent?.messageId) {
      for (let i = 0; i < 30; i++) {
        try {
          result = await ao.result({ process: pid, message: sent.messageId })
          break
        } catch {
          await new Promise((resolve) => setTimeout(resolve, 2000))
        }
      }
    }
  }

  const afterRes = await ao.dryrun({ process: pid, tags: balanceTags, data: '.' })
  const afterMsg = afterRes?.Messages?.[0] || {}
  const afterRaw = findTagValue(afterMsg, 'Balance') || afterMsg?.Data || '0'
  const afterBalance = /^\d+$/.test(String(afterRaw)) ? BigInt(afterRaw) : null

  const output = {
    generatedAt: new Date().toISOString(),
    pid,
    address,
    dryRun,
    send: !dryRun,
    retries,
    retryDelayMs,
    beforeBalance: beforeBalance.toString(),
    beforeBalanceFormatted: formatUnits(beforeBalance, denomination),
    burnQuantity: quantity.toString(),
    burnQuantityFormatted: formatUnits(quantity, denomination),
    burnFee: burnFee.toString(),
    burnFeeFormatted: formatUnits(burnFee, denomination),
    minBurnAmt: minBurnAmt.toString(),
    minBurnAmtFormatted: formatUnits(minBurnAmt, denomination),
    expectedBridgeQuantity: expectedBridgeQuantity.toString(),
    expectedBridgeQuantityFormatted: formatUnits(expectedBridgeQuantity, denomination),
    sent,
    attempts,
    resultReceived: Boolean(result),
    result,
    afterBalance: afterBalance === null ? null : afterBalance.toString(),
    afterBalanceFormatted: afterBalance === null ? null : formatUnits(afterBalance, denomination)
  }

  if (outFile) {
    fs.writeFileSync(outFile, JSON.stringify(output, null, 2))
  }
  console.log(JSON.stringify(output, null, 2))
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
