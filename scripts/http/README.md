# Write checkout endpoint adapter

This adapter exposes gateway-compatible write endpoints:

- `POST /api/checkout/order`
- `POST /api/checkout/payment-intent`
- `GET /healthz`

## Run

```bash
WRITE_PROCESS_ID=<write_pid> \
WRITE_WALLET_PATH=wallet.json \
WRITE_HB_URL=https://push.forward.computer \
WRITE_HB_SCHEDULER=n_XZJhUnmldNFo4dhajoPZWhBXuJk-OcQr5JQ49c4Zo \
WRITE_SIGNER_URL=https://<worker-host>/sign \
WRITE_SIGNER_TOKEN=<worker_bearer_token> \
node scripts/http/checkout_api_server.mjs
```

## Request examples

Signed envelope (already signed):

```bash
curl -sS -X POST http://127.0.0.1:8789/api/checkout/order \
  -H 'content-type: application/json' \
  --data @signed-order-command.json
```

Unsigned payload (adapter calls worker signer):

```bash
curl -sS -X POST http://127.0.0.1:8789/api/checkout/order \
  -H 'content-type: application/json' \
  --data '{"siteId":"site-main","items":[{"sku":"sku-1","qty":1,"price":100}]}'
```

## Notes

- If `signature`/`signatureRef` is missing, signer env is required.
- Adapter forwards as AO `Write-Command` and returns normalized write response.
- If AO transport succeeds but runtime envelope is empty, adapter can return
  `202 { status: "OK", code: "ACCEPTED_ASYNC" }` (`WRITE_API_ACCEPT_EMPTY_RESULT=1`, default).
- Optional API auth token:
  - set `WRITE_API_TOKEN`
  - send `Authorization: Bearer <token>` or `X-API-Token`.
