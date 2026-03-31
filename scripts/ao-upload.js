import { readFile } from 'fs/promises';
import { resolve } from 'path';
import Arweave from 'arweave';

const walletPath = resolve(process.env.WALLET || process.env.WALLET_PATH || 'wallet.json');
const bundlePath = resolve('dist/write-bundle.lua');

async function main() {
  const [walletRaw, bundle] = await Promise.all([
    readFile(walletPath, 'utf8'),
    readFile(bundlePath)
  ]);
  const wallet = JSON.parse(walletRaw);

  const arweave = Arweave.init({ host: 'arweave.net', port: 443, protocol: 'https' });
  const tx = await arweave.createTransaction({ data: bundle }, wallet);

  tx.addTag('Content-Type', 'text/lua');
  tx.addTag('Data-Protocol', 'ao');
  tx.addTag('Type', 'Module');
  tx.addTag('Module-Format', 'lua');
  tx.addTag('App-Name', 'blackcat-write');

  await arweave.transactions.sign(tx, wallet);
  const res = await arweave.transactions.post(tx);
  if (![200, 202].includes(res.status)) {
    throw new Error(`Upload failed with status ${res.status}`);
  }
  console.log('Module TX:', tx.id);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
