#!/usr/bin/env bash
set -euo pipefail

req() {
  local name="$1"
  local val="${!name-}"
  if [[ -z "$val" ]]; then
    echo "missing env: $name" >&2
    exit 1
  fi
  if [[ "$val" =~ (changeme|placeholder|example|sample|setme) ]]; then
    echo "refusing placeholder value for $name" >&2
    exit 1
  fi
}

# Required for prod
req WRITE_REQUIRE_SIGNATURE
if [[ "${WRITE_REQUIRE_SIGNATURE}" != "1" ]]; then
  echo "WRITE_REQUIRE_SIGNATURE must be 1 for prod" >&2
  exit 1
fi
req OUTBOX_HMAC_SECRET
if [[ ${#OUTBOX_HMAC_SECRET} -lt 32 ]]; then
  echo "OUTBOX_HMAC_SECRET must be >=32 chars" >&2
  exit 1
fi

if [[ "${WRITE_SIG_TYPE:-ed25519}" == "hmac" ]]; then
  req WRITE_SIG_SECRET
else
  req WRITE_SIG_PUBLIC
fi

if [[ "${WRITE_ALLOW_ANON:-0}" != "0" ]]; then
  echo "WRITE_ALLOW_ANON must be 0 for prod" >&2
  exit 1
fi

echo "preflight: OK"
