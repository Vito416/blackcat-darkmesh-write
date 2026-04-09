import fs from 'fs';
import fetch from 'node-fetch';

const PID = '26hrLuQBsVFcsqHMLhP1LjifRh8WYMerYyd71A2ofjo';
const URL = `https://push-1.forward.computer/${PID}`;

const body = {
  tags: [
    { name: 'Action', value: 'Ping' },
    { name: 'Content-Type', value: 'application/json' },
    { name: 'Data-Protocol', value: 'ao' },
    { name: 'Type', value: 'Message' },
    { name: 'Variant', value: 'ao.TN.1' },
  ],
  data: ''
};

async function main() {
  console.log('POST', URL);
  const resp = await fetch(URL, {
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

main().catch(err => {
  console.error(err);
  process.exit(1);
});
