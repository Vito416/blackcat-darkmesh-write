import { defineConfig } from '@memetic-block/hyperengine'

export default defineConfig({
  processes: {
    write: {
      // use the pre-bundled single-file Lua (package.preload contains all deps)
      entry: 'dist/write-bundle.lua',
      type: 'process',
    },
  },
  // Enable AOS module build → produces dist/write/{process.lua,config.yml}
  aos: {
    // pinned commit of permaweb/aos (2.0.6 generation). Change if you need a newer runtime.
    commit: 'd5ff8f44df752b13a1e7bce3ded2a5d84b69287f',
    // wasm64 target + limits that match current mainnet expectations
    target: 64,
    stack_size: 3_145_728,           // 3 MiB
    initial_memory: 4_194_304,       // 4 MiB
    maximum_memory: 1_073_741_824,   // 1 GiB
    compute_limit: '9000000000000',  // default HB compute limit
    module_format: 'wasm64-unknown-emscripten-draft_2024_02_15',
    exclude: [],
  },
  // no Vite/templates — pure Lua process
  deploy: {
    enabled: false, // we publish manually via ao CLI / aoconnect
  },
})
