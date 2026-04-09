import fs from 'fs';
import { connect, createSigner } from '@permaweb/aoconnect';

const wallet = JSON.parse(fs.readFileSync('wallet.json','utf8'));
// Use HTTPSIG signer (structured), not ANS-104 bundle, to avoid invalid bundle errors.
const signer = createSigner(wallet);
const HB = 'http://localhost:8734';
const SCHED = 'n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo';
const PID = '26hrLuQBsVFcsqHMLhP1LjifRh8WYMerYyd71A2ofjo';

const ao = connect({ MODE:'mainnet', URL: HB, SCHEDULER: SCHED });

(async () => {
  try {
    const msgId = await ao.message({
      process: PID,
      signer,
      tags: [
        { name: 'Action', value: 'Ping' },
        { name: 'Content-Type', value: 'application/json' },
      ],
      data: ''
    });
    console.log('msgId', msgId);
    const res = await ao.result({ process: PID, message: msgId, timeout: 10000 });
    console.log(JSON.stringify(res, null, 2));
  } catch (err) {
    console.error('ERROR name', err?.name);
    console.error('ERROR message', err?.message);
    console.error('ERROR stack', err?.stack);
    console.error('ERROR response', err?.response);
    console.error('ERROR cause', err?.cause);
  }
})();
