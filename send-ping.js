import fs from 'fs';
import { connect, createDataItemSigner } from '@permaweb/aoconnect';

const wallet = JSON.parse(fs.readFileSync('wallet.json','utf8'));
const signer = createDataItemSigner(wallet);
const HB = 'https://push-1.forward.computer';
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
    const res = await ao.result({ process: PID, message: msgId, timeout: 20000 });
    console.log(JSON.stringify(res, null, 2));
  } catch (err) {
    console.error('ERROR', err);
  }
})();
