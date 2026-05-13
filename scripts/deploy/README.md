# Deploy scripts

These helpers package and publish the write AO process. Source of truth is the Lua process under `ao/write/process.lua`; the old TypeScript AO skeleton is no longer part of the deploy path.

## Build order

```bash
npm run build:ao
# generate/refresh dist/write/process.lua + dist/write/config.yml with the pinned AO runtime pipeline
npm run build:ao-wasm
node scripts/publish-wasm.js
```

- `npm run build:ao` creates `dist/write-bundle.lua` from the Lua source and shared modules.
- `npm run build:ao-wasm` calls `rebuild_wasm_from_runtime.sh`; it requires `dist/write/process.lua` and `dist/write/config.yml` to already exist.
- `publish-wasm.js` uploads `dist/write/process.wasm` with AO module tags.

## WASM rebuild helper

```bash
scripts/deploy/rebuild_wasm_from_runtime.sh
```

The helper rebuilds `dist/write/process.wasm` with the pinned `p3rmaw3b/ao:0.1.5` Docker image and verifies the runtime symbol. It is WSL-aware and translates Docker Desktop bind-mount paths automatically.
