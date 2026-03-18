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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILE="$ROOT/ops/env.prod.example"

echo "Linting $FILE"
check_eq "$FILE" WRITE_REQUIRE_SIGNATURE 1
check_eq "$FILE" WRITE_REQUIRE_NONCE 1
check_nonempty "$FILE" OUTBOX_HMAC_SECRET
check_nonempty "$FILE" WRITE_SIG_PUBLIC

if [[ $fail -ne 0 ]]; then
  exit 1
fi
green "secrets lint OK"
