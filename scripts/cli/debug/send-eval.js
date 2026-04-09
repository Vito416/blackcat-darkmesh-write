#!/usr/bin/env node
/**
 * Eval helper: sends Action=Eval with Lua code in "data" to the given PID.
 *
 * Usage:
 *   node scripts/cli/debug/send-eval.js --pid <PID> --code "return 'pong'"
 *   node scripts/cli/debug/send-eval.js --pid <PID> --file path/to/code.lua
 *   # optional: --url https://push-1.forward.computer --variant ao.TN.1
 */

import fs from 'fs';
import fetch from 'node-fetch';

function parseArgs() {
  const out = {};
  const args = process.argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const val = args[i + 1] && !args[i + 1].startsWith('--') ? args[++i] : true;
      out[key] = val;
    }
  }
  return out;
}

async function main() {
  const args = parseArgs();
  if (!args.pid || !args.url) {
    if (!args['allow-defaults']) {
      console.error('Pass --pid and --url (or --allow-defaults to use the demo defaults).');
      process.exit(1);
    }
  }
  const pid = args.pid || '26hrLuQBsVFcsqHMLhP1LjifRh8WYMerYyd71A2ofjo';
  const base = (args.url || 'https://push-1.forward.computer').replace(/\/$/, '');
  const direct = args.direct === true || args.direct === '1' || args.direct === 'true';
  // Important: /<PID> is process fetch; /<PID>~process@1.0/push is message ingress.
  const url = direct ? `${base}/${pid}` : `${base}/${pid}~process@1.0/push`;
  const variant = args.variant || 'ao.TN.1';

  let code = args.code || '';
  if (args.file) {
    const resolved = fs.realpathSync(args.file);
    const repoRoot = fs.realpathSync('.');
    if (!resolved.startsWith(repoRoot)) {
      throw new Error('Refusing to read files outside the repository root');
    }
    code = fs.readFileSync(resolved, 'utf8');
  }

  const body = {
    tags: [
      { name: 'Action', value: 'Eval' },
      { name: 'Content-Type', value: 'text/lua' },
      { name: 'Data-Protocol', value: 'ao' },
      { name: 'Type', value: 'Message' },
      { name: 'Variant', value: variant },
    ],
    data: code,
  };

  console.log('POST', url, direct ? '(direct process path)' : '(push path)');
  const resp = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'codec-device': 'httpsig@1.0',
    },
    body: JSON.stringify(body),
  });
  const text = await resp.text();
  console.log('status', resp.status);
  console.log('body', text.slice(0, 400));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
