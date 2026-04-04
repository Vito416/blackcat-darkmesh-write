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
req WRITE_AUTH_TOKEN
req WRITE_SIG_PUBLIC
req REQUIRE_SECRETS
if [[ "${REQUIRE_SECRETS}" != "1" ]]; then
  echo "REQUIRE_SECRETS must be 1 for prod" >&2
  exit 1
fi

echo "preflight: OK"
