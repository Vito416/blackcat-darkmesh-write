#!/usr/bin/env node
/**
 * Generic AO message sender (HTTPSIG/structured) for push-1 or any HB.
 *
 * Usage:
 *   node send-msg.js --pid <processId> --action Ping --data "" \
 *     --url https://push-1.forward.computer --variant ao.TN.1 \
 *     --type Message --content-type application/json
 *
 * Defaults:
 *   url: https://push-1.forward.computer
 *   pid: 26hrLuQBsVFcsqHMLhP1LjifRh8WYMerYyd71A2ofjo
 *   action: Ping
 *   data: ""
 *   variant: ao.TN.1
 *   type: Message
 *   content-type: application/json
 */

import fetch from 'node-fetch';

function parseArgs() {
  const args = process.argv.slice(2);
  const out = {};
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
      console.error('Refusing to use defaults. Pass --pid and --url (or --allow-defaults to override).');
      process.exit(1);
    }
  }
  const pid = args.pid || '26hrLuQBsVFcsqHMLhP1LjifRh8WYMerYyd71A2ofjo';
  const base = (args.url || 'https://push-1.forward.computer').replace(/\/$/, '');
  const url = `${base}/${pid}`;

  const action = args.action || 'Ping';
  const rawData = args.data;
  const data = rawData !== undefined ? rawData : '';
  const variant = args.variant || 'ao.TN.1';
  const type = args.type || 'Message';
  const contentType = args['content-type'] || 'application/json';

  // presets for common actions
  const baseTags = [
    { name: 'Content-Type', value: contentType },
    { name: 'Data-Protocol', value: 'ao' },
    { name: 'Type', value: type },
    { name: 'Variant', value: variant },
  ];

  let tags;
  let finalData = data;
  const now = Date.now().toString();

  if (args.preset === 'savedraft') {
    tags = [
      { name: 'Action', value: 'SaveDraftPage' },
      { name: 'Request-Id', value: args['request-id'] || 'req-demo-uuid' },
      { name: 'Actor', value: args.actor || 'demo-actor' },
      { name: 'Tenant', value: args.tenant || 'demo-tenant' },
      { name: 'Timestamp', value: args.timestamp || now },
      ...baseTags,
    ];
    finalData = finalData || JSON.stringify({ content: 'demo draft', updatedAt: now });
  } else if (args.preset === 'notify') {
    tags = [
      { name: 'Action', value: 'Notify' },
      { name: 'Event', value: args.event || 'demo-event' },
      { name: 'Tenant', value: args.tenant || 'demo-tenant' },
      { name: 'Actor', value: args.actor || 'demo-actor' },
      { name: 'Timestamp', value: args.timestamp || now },
      { name: 'Content-Type', value: 'application/json' },
      { name: 'Data-Protocol', value: 'ao' },
      { name: 'Type', value: type },
      { name: 'Variant', value: variant },
    ];
    finalData = rawData !== undefined ? data : JSON.stringify({ message: 'demo notify' });
  } else if (args.preset === 'writecmd') {
    tags = [
      { name: 'Action', value: 'Write-Command' },
      { name: 'Request-Id', value: args['request-id'] || 'req-demo' },
      { name: 'Actor', value: args.actor || 'demo-actor' },
      { name: 'Tenant', value: args.tenant || 'demo-tenant' },
      { name: 'Timestamp', value: args.timestamp || now },
      { name: 'Role', value: args.role || 'editor' },
      ...(args.signature ? [{ name: 'Signature', value: args.signature }] : []),
      ...(args['signature-ref'] ? [{ name: 'Signature-Ref', value: args['signature-ref'] }] : []),
      ...baseTags,
    ];
    finalData = rawData !== undefined ? data : JSON.stringify({ content: 'demo' });
  } else {
    tags = [
      { name: 'Action', value: action },
      ...baseTags,
    ];
  }

  const body = { tags, data: finalData };

  console.log('POST', url);
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
