#!/usr/bin/env bash
# Regenerate and drift-check the WeaveDB schema manifest derived from local JSON schemas.
# - UPDATE_SCHEMA_MANIFEST=1 will refresh the tracked manifest file in-place.
# - Default mode writes to a temp file and fails if the tracked manifest differs.

set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
OUT_PATH="$ROOT_DIR/schemas/manifest/weavedb-manifest.json"

tmp="$(mktemp)"
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT

python3 - "$ROOT_DIR" "$tmp" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
out = Path(sys.argv[2])

actions_path = root / "schemas" / "actions.schema.json"
envelope_path = root / "schemas" / "command-envelope.schema.json"

def sha256(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()

def load_json(path: Path):
    return json.loads(path.read_text())

actions_schema = load_json(actions_path)
envelope_schema = load_json(envelope_path)

actions_enum = actions_schema.get("properties", {}).get("Action", {}).get("enum", [])

required_by_action = {}
for name, spec in (actions_schema.get("properties") or {}).items():
    if name == "Action" or not isinstance(spec, dict):
        continue
    req = spec.get("required") or []
    required_by_action[name] = sorted(req)
required_by_action = {k: required_by_action[k] for k in sorted(required_by_action)}

manifest = {
    "format": "weavedb-schema-manifest",
    "component": "blackcat-darkmesh-write",
    "version": 1,
    "schemas": {
        "command-envelope": {
            "source": str(envelope_path.relative_to(root)),
            "sha256": sha256(envelope_path),
            "required": envelope_schema.get("required", []),
            "properties": sorted((envelope_schema.get("properties") or {}).keys()),
        },
        "actions": {
            "source": str(actions_path.relative_to(root)),
            "sha256": sha256(actions_path),
            "actions": sorted(actions_enum),
            "required": required_by_action,
        },
    },
}

out.write_text(json.dumps(manifest, separators=(",", ":"), sort_keys=True))
print(f"[schema-manifest] wrote {out}")
PY

if [ "${UPDATE_SCHEMA_MANIFEST:-0}" -eq 1 ]; then
  mkdir -p "$(dirname "$OUT_PATH")"
  mv "$tmp" "$OUT_PATH"
  echo "[schema-manifest] updated $OUT_PATH"
  exit 0
fi

if [ ! -f "$OUT_PATH" ]; then
  echo "[schema-manifest] missing $OUT_PATH; run UPDATE_SCHEMA_MANIFEST=1 scripts/verify/schema_manifest.sh" >&2
  exit 1
fi

if diff -u "$OUT_PATH" "$tmp" >/dev/null; then
  echo "[schema-manifest] ok"
else
  echo "[schema-manifest] drift detected; run UPDATE_SCHEMA_MANIFEST=1 scripts/verify/schema_manifest.sh" >&2
  diff -u "$OUT_PATH" "$tmp" >&2 || true
  exit 1
fi
