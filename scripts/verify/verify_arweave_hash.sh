#!/usr/bin/env bash
set -euo pipefail
FILE="$1"
TXID="$2"
if [ -z "${FILE:-}" ] || [ -z "${TXID:-}" ]; then
  echo "usage: $0 <local-file> <txid>" >&2
  exit 1
fi
if [ ! -f "$FILE" ]; then
  echo "file not found: $FILE" >&2
  exit 1
fi

hash_stream() {
  local path_or_stream=$1
  if [ "$path_or_stream" = "-" ]; then
    # stdin
    sha256sum | awk '{print $1}'
  else
    sha256sum "$path_or_stream" | awk '{print $1}'
  fi
}

hash_gzip_or_plain() {
  local src=$1
  if file -b "$src" | grep -qi gzip; then
    gzip -cd "$src" | sha256sum | awk '{print $1}'
  else
    sha256sum "$src" | awk '{print $1}'
  fi
}

REMOTE_HASH=$(curl --connect-timeout 5 --max-time 15 --max-filesize 52428800 -sL "https://arweave.net/${TXID}" |
  { if file -b /dev/stdin 2>/dev/null | grep -qi gzip; then gzip -cd; else cat; fi; } |
  sha256sum | awk '{print $1}')

LOCAL_HASH=$(hash_gzip_or_plain "$FILE")
if [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
  echo "hash match: $LOCAL_HASH"
  exit 0
else
  echo "hash mismatch! local=$LOCAL_HASH remote=$REMOTE_HASH" >&2
  exit 2
fi
