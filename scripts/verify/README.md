# Verify scripts

This directory holds verification and smoke-check helpers for the write layer.

Current tools:

- `preflight.sh` — validates JSON schemas and checks Lua sources for syntax errors (`lua5.4` or `luac` required).
- `auth_scope_matrix.lua` — fail-closed auth scope + strict role-policy checks.
- `persistence_failure_modes.lua` — deterministic WAL/idempotency persistence failure checks.

Usage:

```bash
scripts/verify/preflight.sh
```

Run this locally before opening a PR to catch obvious issues early.
