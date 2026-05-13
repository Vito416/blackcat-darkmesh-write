#!/usr/bin/env node
// Send registry/resolver control-plane commands directly to their AO process.
// This intentionally does not route policy/resolver commands through write.

import fs from 'node:fs'
import crypto from 'node:crypto'

const DEFAULT_URL = 'https://push.forward.computer'
const DEFAULT_SCHEDULER = 'n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo'

const RESOLVER_ACTIONS = new Set([
  'ResolveRouteForHost',
  'InvalidateResolverCache',
  'GetResolverCacheStats'
])

const PUBLIC_READ_ACTIONS = new Set([
  'GetTemplateActionContract',
  'GetSiteRuntimeBundle',
  'ResolveRouteForHost',
  'GetSiteServingPolicy',
  'GetPolicySnapshot',
  'GetDnsProofState',
  'ResolveHostPolicyBundle',
  'GetDomainLifecycleState',
  'GetPaymentWebhookIdempotencyState',
  'GetResolverCacheStats'
])

function arg(name, fallback) {
  const idx = process.argv.indexOf(`--${name}`)
  if (idx === -1) return fallback
  return process.argv[idx + 1]
}

function hasFlag(name) {
  return process.argv.includes(`--${name}`)
}

function positionalFile(argv = process.argv) {
  const valueFlags = new Set([
    'target',
    'pid',
    'hmac-secret',
    'wallet',
    'out',
    'url',
    'scheduler'
  ])
  for (let i = 2; i < argv.length; i += 1) {
    const token = argv[i]
    if (!token || token.startsWith('--')) {
      const name = token?.slice(2)
      if (valueFlags.has(name)) i += 1
      continue
    }
    return token
  }
  return undefined
}

function clean(value) {
  if (value === undefined || value === null) return undefined
  const out = String(value).trim()
  return out === '' ? undefined : out
}

function ensure(value, name) {
  const out = clean(value)
  if (!out) throw new Error(`Missing ${name}`)
  return out
}

function parseJsonFile(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'))
}

function pick(obj, keys) {
  for (const key of keys) {
    const val = obj?.[key]
    if (val !== undefined && val !== null && String(val) !== '') return val
  }
  return undefined
}

function setIf(out, key, value) {
  if (value !== undefined && value !== null && value !== '') out[key] = value
}

function markConsumed(consumed, ...keys) {
  for (const key of keys) consumed.add(key)
}

function camelToControlField(key) {
  const withDashes = key
    .replace(/([a-z0-9])([A-Z])/g, '$1-$2')
    .replace(/_/g, '-')
  return withDashes
    .split('-')
    .filter(Boolean)
    .map((part) => {
      const lower = part.toLowerCase()
      if (lower === 'id') return 'Id'
      if (lower === 'ttl') return 'Ttl'
      if (lower === 'txt') return 'TXT'
      if (lower === 'dns') return 'DNS'
      if (lower === 'hb') return 'HB'
      return part.charAt(0).toUpperCase() + part.slice(1)
    })
    .join('-')
}

function normalizeTimestamp(value) {
  const raw = clean(value)
  if (!raw) return Math.floor(Date.now() / 1000)
  if (/^\d+$/.test(raw)) return Number(raw)
  const ms = Date.parse(raw)
  if (!Number.isFinite(ms)) throw new Error(`Invalid timestamp: ${raw}`)
  return Math.floor(ms / 1000)
}

function addBaseFields(cmd, out) {
  const action = ensure(cmd.action || cmd.Action, 'command action')
  out.Action = action
  out['Request-Id'] = ensure(cmd.requestId || cmd['Request-Id'], 'command requestId')
  setIf(out, 'Nonce', cmd.nonce || cmd.Nonce)
  out.ts = normalizeTimestamp(cmd.timestamp || cmd.Timestamp || cmd.ts)
  setIf(out, 'Timestamp', cmd.timestamp || cmd.Timestamp)
  setIf(out, 'Actor-Role', cmd.role || cmd.actorRole || cmd['Actor-Role'])
  setIf(out, 'Schema-Version', cmd.schemaVersion || cmd['Schema-Version'] || '1')
  setIf(out, 'Signature', cmd.signature || cmd.Signature)
  return action
}

function mapPayload(action, payload = {}) {
  const out = {}
  const consumed = new Set()
  const siteId = pick(payload, ['siteId', 'Site-Id'])
  const host = pick(payload, ['host', 'domain', 'Host', 'Domain'])
  setIf(out, 'Site-Id', siteId)
  setIf(out, 'Host', host)
  markConsumed(consumed, 'siteId', 'Site-Id', 'host', 'domain', 'Host', 'Domain')

  if (action === 'RegisterHBNode' || action === 'UpdateHBNodeStatus') {
    setIf(out, 'Node-Id', pick(payload, ['nodeId', 'hbNodeId', 'node', 'wallet', 'Node-Id']))
    setIf(out, 'Url', pick(payload, ['url', 'endpoint', 'baseUrl', 'Url']))
    markConsumed(consumed, 'nodeId', 'hbNodeId', 'node', 'wallet', 'Node-Id', 'url', 'endpoint', 'baseUrl', 'Url')
  }

  if (action === 'SetPolicyMode') {
    setIf(out, 'Mode', pick(payload, ['mode', 'Mode']))
    markConsumed(consumed, 'mode', 'Mode')
  }

  if (action === 'SetSiteServingPolicy') {
    setIf(out, 'Serving-State', pick(payload, ['servingState', 'servingPolicy', 'policy', 'mode']))
    markConsumed(consumed, 'servingState', 'servingPolicy', 'policy', 'mode')
  }

  if (action === 'SetSiteFundingState') {
    setIf(out, 'Funding-State', pick(payload, ['fundingState', 'state', 'status']))
    markConsumed(consumed, 'fundingState', 'state', 'status')
  }

  if (action === 'SetDnsProofState') {
    setIf(out, 'Status', pick(payload, ['proofState', 'state', 'status']))
    setIf(out, 'TXT-Value', pick(payload, ['txtValue', 'dnsTxt', 'TXT-Value']))
    markConsumed(consumed, 'proofState', 'state', 'status', 'txtValue', 'dnsTxt', 'TXT-Value')
  }

  if (action === 'SetDomainLifecycleState') {
    setIf(out, 'State', pick(payload, ['lifecycleState', 'state', 'status', 'State']))
    markConsumed(consumed, 'lifecycleState', 'state', 'status', 'State')
  }

  if (action === 'PublishPolicySnapshot' || action === 'RevokePolicySnapshot') {
    setIf(out, 'Snapshot-Id', pick(payload, ['snapshotId', 'id', 'Snapshot-Id']))
    if (payload.snapshot !== undefined) out.Snapshot = payload.snapshot
    else if (payload.snapshotHash !== undefined) out.Snapshot = { snapshotHash: payload.snapshotHash }
    markConsumed(consumed, 'snapshotId', 'id', 'Snapshot-Id', 'snapshot', 'snapshotHash', 'hash', 'tx')
  }

  if (action === 'GetPolicySnapshot') {
    setIf(out, 'Snapshot-Id', pick(payload, ['snapshotId', 'id', 'Snapshot-Id']))
    markConsumed(consumed, 'snapshotId', 'id', 'Snapshot-Id')
  }

  if (action === 'GetTemplateActionContract') {
    setIf(out, 'Action-Names', pick(payload, ['actionName', 'action', 'op', 'operation']))
    markConsumed(consumed, 'actionName', 'action', 'op', 'operation', 'templateId', 'templateKey', 'template')
  }

  if (action === 'ResolveRouteForHost') {
    setIf(out, 'Path', pick(payload, ['path', 'route', 'uri']))
    setIf(out, 'Method', pick(payload, ['method', 'Method']) || 'GET')
    markConsumed(consumed, 'path', 'route', 'uri', 'method', 'Method')
  }

  if (action === 'InvalidateResolverCache' || action === 'GetResolverCacheStats') {
    setIf(out, 'Scope', pick(payload, ['scope']))
    markConsumed(consumed, 'scope')
  }

  for (const [key, value] of Object.entries(payload)) {
    if (value === undefined || value === null) continue
    if (consumed.has(key)) continue
    const mapped = {
      actorRole: 'Actor-Role',
      cacheTtlSec: 'Cache-Ttl-Sec',
      capabilityTier: 'Capability-Tier',
      checkedAt: 'Checked-At',
      claims: 'Claims',
      context: 'Context',
      country: 'Country',
      dnsProofRequired: 'DNS-Proof-Required',
      eventId: 'Event-Id',
      expiresAt: 'Expires-At',
      fingerprint: 'Fingerprint',
      fundingState: 'Funding-State',
      hbAllowList: 'HB-Allow-List',
      hbDenyList: 'HB-Deny-List',
      includeEntries: 'Include-Entries',
      keyMaxBytes: 'Key-Max-Bytes',
      lifecycleState: 'Lifecycle-State',
      labels: 'Labels',
      limit: 'Limit',
      maxKeys: 'Max-Keys',
      metadata: 'Metadata',
      newSessionId: 'New-Session-Id',
      note: 'Note',
      payerRef: 'Payer-Ref',
      plan: 'Plan',
      policy: 'Policy',
      policyRef: 'Policy-Ref',
      proofRef: 'Proof-Ref',
      provider: 'Provider',
      reason: 'Reason',
      region: 'Region',
      scoreWeight: 'Score-Weight',
      sessionId: 'Session-Id',
      source: 'Source',
      status: 'Status',
      subject: 'Subject',
      tier: 'Tier',
      tokenTtlSec: 'Token-Ttl-Sec',
      verified: 'Verified'
    }[key] || camelToControlField(key)
    if (out[mapped] === undefined) out[mapped] = value
  }

  return out
}

function sortedKeys(obj) {
  return Object.keys(obj).sort((a, b) => String(a).localeCompare(String(b)))
}

function canonicalValue(value) {
  if (Array.isArray(value)) {
    return `{${value.map((v, i) => `${i + 1}=${canonicalValue(v)}`).join(',')}}`
  }
  if (value && typeof value === 'object') {
    return `{${sortedKeys(value).map((k) => `${k}=${canonicalValue(value[k])}`).join(',')}}`
  }
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  if (typeof value === 'number') return Number.isFinite(value) ? String(value) : ''
  if (typeof value === 'string') return value
  return ''
}

function canonicalPayload(msg) {
  const cleaned = {}
  for (const [key, value] of Object.entries(msg)) {
    if (key === 'Signature' || key === 'signature' || key === 'Signature-Ref') continue
    cleaned[key] = value
  }
  return canonicalValue(cleaned)
}

function signHmac(msg, secret) {
  return crypto.createHmac('sha256', secret).update(canonicalPayload(msg)).digest('hex')
}

function resolveTargetPid(action, target, explicitPid) {
  if (explicitPid) return explicitPid
  if (target === 'registry') return clean(process.env.AO_REGISTRY_PID) || clean(process.env.AO_CONTROL_PID)
  if (target === 'resolver') return clean(process.env.AO_RESOLVER_PID) || clean(process.env.AO_CONTROL_PID)
  if (RESOLVER_ACTIONS.has(action)) {
    return clean(process.env.AO_RESOLVER_PID) || clean(process.env.AO_CONTROL_PID)
  }
  return clean(process.env.AO_REGISTRY_PID) || clean(process.env.AO_CONTROL_PID)
}

function buildTags(msg) {
  const tags = [
    { name: 'Action', value: String(msg.Action) },
    { name: 'Request-Id', value: String(msg['Request-Id']) },
    { name: 'Data-Protocol', value: 'ao' },
    { name: 'Variant', value: 'ao.TN.1' },
    { name: 'Type', value: 'Message' },
    { name: 'Content-Type', value: 'application/json' }
  ]
  if (msg['Actor-Role']) tags.push({ name: 'Actor-Role', value: String(msg['Actor-Role']) })
  return tags
}

async function main() {
  if (hasFlag('help') || hasFlag('h')) {
    console.log('Usage: node scripts/cli/send_control_command.js <command.json> --target registry|resolver --pid <AO_PID> --send [--hmac-secret secret] [--wallet wallet.json]')
    process.exit(0)
  }

  const file = positionalFile()
  const input = ensure(file, 'command JSON path')
  const cmd = parseJsonFile(input)
  const normalized = {}
  const action = addBaseFields(cmd, normalized)
  Object.assign(normalized, mapPayload(action, cmd.payload || cmd.Payload || {}))

  const hmacSecret = clean(arg('hmac-secret', process.env.AO_CONTROL_HMAC_SECRET || process.env.AUTH_SIGNATURE_SECRET))
  if (hmacSecret && !normalized.Signature) normalized.Signature = signHmac(normalized, hmacSecret)

  const target = clean(arg('target', RESOLVER_ACTIONS.has(action) ? 'resolver' : 'registry'))
  const pid = resolveTargetPid(action, target, clean(arg('pid')))
  const send = hasFlag('send')
  const allowUnsigned = hasFlag('allow-unsigned')
  const outFile = clean(arg('out'))
  const url = clean(arg('url', process.env.HB_URL || process.env.HYPERBEAM_URL || process.env.AO_URL)) || DEFAULT_URL
  const scheduler = clean(arg('scheduler', process.env.HB_SCHEDULER || process.env.HYPERBEAM_SCHEDULER || process.env.AO_SCHEDULER)) || DEFAULT_SCHEDULER

  if (send && !pid) throw new Error('Missing target PID. Use --pid or AO_CONTROL_PID/AO_REGISTRY_PID/AO_RESOLVER_PID.')
  if (send && !normalized.Signature && !allowUnsigned && !PUBLIC_READ_ACTIONS.has(action)) {
    throw new Error('Refusing unsigned control mutation. Provide command.signature, --hmac-secret/AO_CONTROL_HMAC_SECRET, or --allow-unsigned for non-prod.')
  }

  const preview = {
    generatedAt: new Date().toISOString(),
    dryRun: !send,
    target,
    pid: pid || null,
    url,
    scheduler,
    action,
    normalized,
    tags: buildTags(normalized)
  }

  if (!send) {
    if (outFile) fs.writeFileSync(outFile, JSON.stringify(preview, null, 2))
    console.log(JSON.stringify(preview, null, 2))
    return
  }

  const walletPath = ensure(clean(arg('wallet', process.env.WALLET_PATH || process.env.WALLET || 'wallet.json')), '--wallet')
  const wallet = JSON.parse(fs.readFileSync(walletPath, 'utf8'))
  const { connect, createSigner } = await import('@permaweb/aoconnect')
  const signer = createSigner(wallet)
  const ao = connect({ MODE: 'mainnet', URL: url, SCHEDULER: scheduler, signer })
  const messageId = await ao.message({
    process: pid,
    signer,
    tags: buildTags(normalized),
    data: JSON.stringify(normalized)
  })

  let result = null
  for (let i = 0; i < 20; i += 1) {
    try {
      result = await ao.result({ process: pid, message: messageId })
      break
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 1500))
    }
  }

  const output = { ...preview, dryRun: false, messageId, resultReceived: Boolean(result), result }
  if (outFile) fs.writeFileSync(outFile, JSON.stringify(output, null, 2))
  console.log(JSON.stringify(output, null, 2))
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
