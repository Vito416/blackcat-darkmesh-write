#!/usr/bin/env bash
set -euo pipefail
# Minimal deploy helper for shared -write AO process.
# Requirements:
# - ao CLI available in PATH (e.g. npm i -g @permaweb/ao-cli or use npx)
# - wallet JWK path in AO_WALLET (testnet/mainnet as desired)
# - built bundle at dist/ao-write.js (run: npm install && npm run build:ao)

if ! command -v ao >/dev/null 2>&1; then
  echo "ao CLI not found. Install with: npm i -g @permaweb/ao-cli" >&2
  exit 1
fi

WALLET="${AO_WALLET:-}"
if [ -z "$WALLET" ]; then
  echo "Set AO_WALLET to your JWK path" >&2
  exit 1
fi

MODULE="dist/ao-write.js"
if [ ! -f "$MODULE" ]; then
  echo "Bundle not found: $MODULE (run npm run build:ao)" >&2
  exit 1
fi

echo "Deploying AO write process with wallet $WALLET ..."
PID=$(ao deploy --module "$MODULE" --wallet "$WALLET")
echo "Deployed PID: $PID"
echo "Export this to your gateway/env: AO_WRITE_PID_CURRENT=$PID"
