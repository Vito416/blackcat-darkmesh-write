#!/usr/bin/env bash
set -euo pipefail
red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
fail=0

check_eq() {
  local file=$1 key=$2 val=$3
  local got
  got="$(grep -E "^${key}=" "$file" | tail -n1 | cut -d= -f2- || true)"
  if [[ "$got" != "$val" ]]; then
    red "FAIL ${file}: ${key} expected ${val}, got '${got:-<missing>}'"
    fail=1
  fi
}

check_nonempty() {
  local file=$1 key=$2
  local got
  got="$(grep -E "^${key}=" "$file" | tail -n1 | cut -d= -f2- || true)"
  if [[ -z "$got" ]]; then
    red "FAIL ${file}: ${key} is empty/missing"
    fail=1
  fi
}

check_hmac_secret() {
  local file=$1 key=$2
  local got
  got="$(grep -E "^${key}=" "$file" | tail -n1 | cut -d= -f2- || true)"
  if [[ -z "$got" ]]; then
    red "FAIL ${file}: ${key} is empty/missing"
    fail=1
    return
  fi
  if [[ "$got" == "change-me-32-bytes-hex" ]]; then
    red "FAIL ${file}: ${key} still set to placeholder"
    fail=1
  fi
  if [[ ${#got} -lt 32 ]]; then
    red "FAIL ${file}: ${key} too short (<32 chars)"
    fail=1
  fi
  if ! [[ "$got" =~ ^[0-9a-fA-F]+$ ]]; then
    red "FAIL ${file}: ${key} must be hex to avoid HMAC drift"
    fail=1
  fi
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILE="$ROOT/ops/env.prod.example"
AO_FILE="$ROOT/../blackcat-darkmesh-ao/ops/env.prod.example"

echo "Linting $FILE"
check_eq "$FILE" WRITE_REQUIRE_SIGNATURE 1
check_eq "$FILE" WRITE_REQUIRE_NONCE 1
check_hmac_secret "$FILE" OUTBOX_HMAC_SECRET
check_nonempty "$FILE" WRITE_SIG_PUBLIC

if [[ -f "$AO_FILE" ]]; then
  echo "Cross-checking OUTBOX_HMAC_SECRET with $AO_FILE"
  ao_secret="$(grep -E '^OUTBOX_HMAC_SECRET=' "$AO_FILE" | tail -n1 | cut -d= -f2- || true)"
  write_secret="$(grep -E '^OUTBOX_HMAC_SECRET=' "$FILE" | tail -n1 | cut -d= -f2- || true)"
  if [[ -z "$ao_secret" || -z "$write_secret" ]]; then
    red "FAIL cross-repo: OUTBOX_HMAC_SECRET missing in one of the files"
    fail=1
  elif [[ "$ao_secret" != "$write_secret" ]]; then
    red "FAIL cross-repo: OUTBOX_HMAC_SECRET mismatch (write=$write_secret, ao=$ao_secret)"
    fail=1
  fi
fi

if [[ $fail -ne 0 ]]; then
  exit 1
fi
green "secrets lint OK"
