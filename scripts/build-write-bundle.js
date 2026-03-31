import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { join } from 'path';

const sharedDir = 'ao/shared';
const entryFile = 'ao/write/process.lua';
const outFile = 'dist/write-bundle.lua';

const sharedList = [
  'analytics.lua','audit.lua','auth.lua','bridge.lua','crypto.lua','export.lua',
  'gopay.lua','idempotency.lua','jwt.lua','metrics.lua','outbox_verifier.lua',
  'paypal.lua','persist.lua','psp_webhooks.lua','schema.lua','storage.lua',
  'stripe.lua','tax.lua','validation.lua'
];

const files = [
  ...sharedList.map(f => [`ao.shared.${f.replace('.lua','')}`, readFileSync(join(sharedDir,f),'utf8')]),
  ['ao.shared.write.process', readFileSync(entryFile,'utf8')],
];

const chunks = files.map(([name, src]) => `
package.preload["${name}"] = function()
  local loaded, err = load([=[${src.replace(/\]/g, '\\]')}]=], "${name}")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end
`);

const entry = `-- bundled write process\n${chunks.join('\n')}\nreturn require("ao.shared.write.process")\n`;

mkdirSync('dist', { recursive: true });
writeFileSync(outFile, entry);
console.log('Bundled ->', outFile, 'bytes:', entry.length);
