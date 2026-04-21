import { readFile } from 'fs/promises';
import { resolve } from 'path';
import { connect, createSigner } from '@permaweb/aoconnect';

const walletPath = resolve(process.env.WALLET || process.env.WALLET_PATH || 'wallet.json');
const moduleTx = process.env.MODULE_TX;
const scheduler = process.env.SCHEDULER || 'n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo';
const url = process.env.URL || 'http://127.0.0.1:8734';
const authority = process.env.AUTHORITY || scheduler;

if (!moduleTx) {
  console.error('MODULE_TX env is required (Arweave TX of write-bundle.lua).');
  process.exit(1);
}

async function main() {
  const wallet = JSON.parse(await readFile(walletPath, 'utf8'));

  const ao = connect({ MODE: 'mainnet', URL: url, SCHEDULER: scheduler, signer: createSigner(wallet) });

  const pid = await ao.spawn({
    module: moduleTx,
    tags: [ { name: 'Authority', value: authority } ],
    data: '-- boot: noop for write bundle'
  });

  console.log('Spawned process ID:', pid);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
