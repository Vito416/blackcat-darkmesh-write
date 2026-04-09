import fs from 'fs';
import crypto from 'crypto';
import fetch from 'node-fetch';
import { connect, createSigner } from '@permaweb/aoconnect';

// Basic HTTP-Signature helper (draft) – signs over (target + body sha256)
function buildSignatureHeader({ wallet, url, body }) {
  const signer = createSigner(wallet);
  const digest = crypto.createHash('sha256').update(body).digest('base64');
  // Minimal httpsig payload: (Digest + Target)
  const message = `digest: SHA-256=${digest}\ntarget: ${url}`;
  const signature = signer.sign(message); // signer from aoconnect returns hex string
  const pub = signer.publicKey; // base64url
  return {
    'Digest': `SHA-256=${digest}`,
    'Target': url,
    'Signature': `keyId=\"${pub}\",algorithm=\"ed25519\",headers=\"digest target\",signature=\"${signature}\"`
  };
}

async function main() {
  const wallet = JSON.parse(fs.readFileSync('wallet.json','utf8'));
  const HB = 'http://localhost:8734';
  const SCHED = 'n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo';
  const PID = '26hrLuQBsVFcsqHMLhP1LjifRh8WYMerYyd71A2ofjo';

  const ao = connect({ MODE:'mainnet', URL: HB, SCHEDULER: SCHED, signer: createSigner(wallet) });

  const bodyObj = {
    process: PID,
    tags: [
      { name: 'Action', value: 'Ping' },
      { name: 'Content-Type', value: 'application/json' },
      { name: 'Data-Protocol', value: 'ao' },
      { name: 'Type', value: 'Message' },
      { name: 'Variant', value: 'ao.TN.1' },
    ],
    data: ''
  };

  const body = JSON.stringify(bodyObj);
  const url = `${HB}/message`;
  console.log('sending to', url, 'body', body);
  const headers = {
    'Content-Type': 'application/json',
    'codec-device': 'httpsig@1.0',
    ...buildSignatureHeader({ wallet, url, body })
  };

  try {
    const resp = await fetch(url, { method: 'POST', headers, body });
    const text = await resp.text();
    console.log('status', resp.status);
    console.log('body', text.slice(0,400));
  } catch (e) {
    console.error('fetch error', e);
  }
}

main();
