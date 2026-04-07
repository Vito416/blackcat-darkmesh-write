#!/usr/bin/env node
import fs from 'fs'
import path from 'path'

function arg(name, fallback) {
  const idx = process.argv.indexOf(`--${name}`)
  if (idx === -1) return fallback
  return process.argv[idx + 1]
}

function must(v, name) {
  if (!v) throw new Error(`Missing --${name}`)
  return v
}

function readJsonMaybe(filePath) {
  if (!filePath || !fs.existsSync(filePath)) return null
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'))
  } catch {
    return null
  }
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true })
}

function copyIfExists(src, destDir) {
  if (!src || !fs.existsSync(src)) return null
  const base = path.basename(src)
  const dest = path.join(destDir, base)
  fs.copyFileSync(src, dest)
  return dest
}

function tsForFile() {
  return new Date().toISOString().replace(/[:.]/g, '-')
}

function formatSendRow(send) {
  return `| ${send.action || ''} | ${send.slot ?? ''} | ${send.messageId || ''} | ${send.schedulerMsg || ''} | ${send.compute || ''} | ${send.aoResult || ''} |`
}

function main() {
  const deepReportPath = must(arg('deep-report', 'tmp/deep-test-scheduler-direct-latest.json'), 'deep-report')
  const cuReportPath = arg('cu-report', 'tmp/cu-readback-diagnostic-latest.json')
  const pidArg = arg('pid')
  const outDir = arg('out-dir', `tmp/hb-escalation-${tsForFile()}`)

  const deep = readJsonMaybe(deepReportPath)
  if (!deep) throw new Error(`Invalid deep report JSON: ${deepReportPath}`)
  const cu = readJsonMaybe(cuReportPath)

  const pid = pidArg || deep.pid
  if (!pid) throw new Error('PID is missing in report and --pid was not provided')

  ensureDir(outDir)

  const copied = {
    deepReport: copyIfExists(deepReportPath, outDir),
    cuReport: copyIfExists(cuReportPath, outDir),
    wireCapture: copyIfExists('tmp/aomessage-wire-latest.json', outDir),
    schedulerDirect: copyIfExists('tmp/scheduler-direct-push.json', outDir),
    schedulerDirectMirror: copyIfExists('tmp/scheduler-direct-push1.json', outDir)
  }

  const matrix = []
  for (const step of cu?.steps || []) {
    for (const send of step.sends || []) {
      matrix.push({
        baseUrl: step.baseUrl,
        action: send.action,
        slot: send.slot,
        messageId: send.messageId,
        schedulerMsg: send.schedulerMessageProbe?.status ?? send.schedulerMsg ?? null,
        compute: send.computeProbe?.status ?? send.compute ?? null,
        aoResult: send.aoconnectResultProbe?.error || (send.aoconnectResultProbe?.ok ? 'ok' : null)
      })
    }
  }

  const summary = {
    generatedAt: new Date().toISOString(),
    pid,
    schedulerUrl: cu?.schedulerUrl || 'https://schedule.forward.computer',
    reports: copied,
    matrix
  }
  fs.writeFileSync(path.join(outDir, 'summary.json'), JSON.stringify(summary, null, 2))

  const reproSh = `#!/usr/bin/env bash
set -euo pipefail

PID="${pid}"
PUSH="https://push.forward.computer"
PUSH1="https://push-1.forward.computer"
SCHED="https://schedule.forward.computer"

echo "PID: $PID"
echo
echo "[1] Scheduler slot (push.forward):"
curl -sS "$PUSH/~scheduler@1.0/slot/current?target=$PID"
echo
echo
echo "[2] Process slot/current (push.forward):"
curl -i -sS "$PUSH/$PID/slot/current" | sed -n '1,40p'
echo
echo "[3] Process slot/current (push-1):"
curl -i -sS "$PUSH1/$PID/slot/current" | sed -n '1,40p'
echo
echo "[4] Compute probe (replace <slot>):"
echo "curl -i -sS \\"$PUSH/$PID~process@1.0/compute=<slot>\\" | sed -n '1,40p'"
echo "curl -i -sS \\"$PUSH1/$PID~process@1.0/compute=<slot>\\" | sed -n '1,40p'"
echo
echo "[5] Scheduler message probe (replace <msgId>):"
echo "curl -i -sS \\"$SCHED/<msgId>?process-id=$PID\\" | sed -n '1,60p'"
`
  fs.writeFileSync(path.join(outDir, 'repro.sh'), reproSh)
  fs.chmodSync(path.join(outDir, 'repro.sh'), 0o755)

  const rows = matrix.map(formatSendRow).join('\n')
  const reportMd = `# HyperBEAM Escalation Bundle

Generated: ${summary.generatedAt}

- PID: \`${pid}\`
- Scheduler URL: \`${summary.schedulerUrl}\`

## Evidence Matrix

| Endpoint | Action | Slot | Message ID | Scheduler Fetch | Compute | aoconnect result |
|---|---|---:|---|---:|---:|---|
${rows || '| (none) |  |  |  |  |  |  |'}

## Repro Files

- \`${path.basename(copied.deepReport || '')}\`
- \`${path.basename(copied.cuReport || '')}\`
- \`${path.basename(copied.wireCapture || '')}\`
- \`${path.basename(copied.schedulerDirect || '')}\`
- \`${path.basename(copied.schedulerDirectMirror || '')}\`

## Quick Repro

\`\`\`bash
./repro.sh
\`\`\`
`
  fs.writeFileSync(path.join(outDir, 'REPORT.md'), reportMd)

  console.log(`saved=${outDir}`)
  console.log(`summary=${path.join(outDir, 'summary.json')}`)
  console.log(`report=${path.join(outDir, 'REPORT.md')}`)
}

main()
