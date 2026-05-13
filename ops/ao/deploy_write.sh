#!/usr/bin/env bash
set -euo pipefail
# Build and publish the Lua write AO WASM module.
# This replaces the old dist/ao-write.js TypeScript skeleton deploy path.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f package.json ]]; then
  echo "Run from blackcat-darkmesh-write repo root" >&2
  exit 1
fi

npm run build:ao

if [[ ! -f dist/write/process.lua || ! -f dist/write/config.yml ]]; then
  echo "Missing dist/write/process.lua or dist/write/config.yml." >&2
  echo "Generate the AO runtime package with the pinned runtime pipeline before publishing." >&2
  exit 1
fi

npm run build:ao-wasm
node scripts/publish-wasm.js
