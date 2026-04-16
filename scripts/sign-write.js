#!/usr/bin/env node
// Sign a write command using ed25519 keys from env (WRITE_SIG_PRIV_HEX seed, 64 hex chars).
// Usage:
//   node scripts/sign-write.js --file cmd.json
//   echo '{...}' | node scripts/sign-write.js
// Env:
//   WRITE_SIG_PRIV_HEX (required, 64 hex chars seed)
//   WRITE_SIG_REF (optional, default "write-ed25519-test")

import { readFileSync } from 'fs';
import { stdin, stdout, exit, argv } from 'process';
import nacl from 'tweetnacl';

function canonicalPayload(payload) {
  if (payload === null || payload === undefined) return 'null';
  if (Array.isArray(payload)) return `[${payload.map(canonicalPayload).join(',')}]`;
  if (typeof payload === 'object') {
    const keys = Object.keys(payload).sort();
    return `{${keys.map((k) => JSON.stringify(k) + ':' + canonicalPayload(payload[k])).join(',')}}`;
  }
  return JSON.stringify(payload);
}

function canonicalDetachedMessage(cmd) {
  return [
    cmd.action || cmd.Action || '',
    cmd.tenant || cmd.Tenant || cmd['Tenant-Id'] || '',
    cmd.actor || cmd.Actor || '',
    cmd.ts || cmd.timestamp || cmd['X-Timestamp'] || '',
    cmd.nonce || cmd.Nonce || cmd['X-Nonce'] || '',
    cmd.role || cmd.Role || cmd['Actor-Role'] || '',
    canonicalPayload(cmd.payload || cmd.Payload || {}),
    cmd.requestId || cmd['Request-Id'] || '',
  ].join('|');
}

function readInput() {
  const idx = argv.indexOf('--file');
  if (idx !== -1 && argv[idx + 1]) {
    return readFileSync(argv[idx + 1], 'utf8');
  }
  return readFileSync(0, 'utf8'); // stdin
}

function main() {
  const privHex = process.env.WRITE_SIG_PRIV_HEX;
  const sigRef = process.env.WRITE_SIG_REF || 'write-ed25519-test';
  if (!privHex || privHex.length !== 64) {
    console.error('WRITE_SIG_PRIV_HEX (64 hex chars) required');
    exit(1);
  }
  const seed = Buffer.from(privHex, 'hex');
  const keyPair = nacl.sign.keyPair.fromSeed(seed);

  const input = readInput();
  let cmd;
  try {
    cmd = JSON.parse(input || '{}');
  } catch (_e) {
    console.error('invalid json input');
    exit(1);
  }
  const message = Buffer.from(canonicalDetachedMessage(cmd));
  const sig = nacl.sign.detached(message, keyPair.secretKey);
  const sigHex = Buffer.from(sig).toString('hex');
  stdout.write(JSON.stringify({ signature: sigHex, signatureRef: sigRef, cmd }, null, 2) + '\n');
}

main();
