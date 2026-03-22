/**
 * Minimal AO handler skeleton for shared -write process (v1).
 * Goal: keep interface stable while we port logic from Lua incrementally.
 *
 * Message shape (expected):
 * {
 *   Action: string,
 *   payload: any,
 *   tenant?: string,
 *   actor?: string,
 *   nonce?: string,
 *   ts?: number,
 *   signature?: string, // optional, HMAC in worker
 * }
 *
 * State shape: plain JS object; persisted by AO runtime between invocations.
 */

type State = Record<string, unknown>;

type Message = {
  Action?: string;
  payload?: any;
  tenant?: string;
  actor?: string;
  nonce?: string;
  ts?: number;
  signature?: string;
};

type Reply =
  | { status: 'OK'; result?: any }
  | { status: 'ERROR'; code?: string; message?: string };

function ok(result?: any): Reply {
  return { status: 'OK', result };
}

function err(code: string, message: string): Reply {
  return { status: 'ERROR', code, message };
}

// TODO: plug in real validation (nonce/ts/HMAC) ported from Lua.
function basicValidate(msg: Message): Reply | null {
  if (!msg.Action) return err('BAD_REQUEST', 'Action missing');
  if (!msg.nonce) return err('BAD_REQUEST', 'nonce required');
  if (!msg.ts) return err('BAD_REQUEST', 'ts required');
  return null;
}

// Route minimal actions; extend as we port logic.
function handleAction(state: State, msg: Message): Reply {
  switch (msg.Action) {
    case 'Health':
      return ok({ now: Date.now(), pid: state.pid ?? 'unknown' });
    case 'SaveDraftPage':
      // placeholder: store last draft per tenant/page
      {
        const tenant = msg.tenant || 'default';
        const payload = msg.payload ?? {};
        const key = `${tenant}:${payload.pageId ?? 'page'}`;
        state.drafts = state.drafts || {};
        (state.drafts as Record<string, unknown>)[key] = payload;
        return ok({ saved: key });
      }
    default:
      return err('NOT_IMPLEMENTED', `Action ${msg.Action} not implemented`);
  }
}

/**
 * AO entrypoint. Exports a default function(state, msg) => { state, result }
 */
export default function handle(state: State = {}, msg: Message) {
  const v = basicValidate(msg);
  if (v) return { state, result: v };

  const result = handleAction(state, msg);
  return { state, result };
}

