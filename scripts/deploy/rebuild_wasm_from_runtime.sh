#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist/write"
DOCKER_IMAGE="${DOCKER_IMAGE:-p3rmaw3b/ao:0.1.5}"

docker_bind_path() {
  local path="$1"
  if [[ -n "${WSL_DISTRO_NAME:-}" ]] && command -v wslpath >/dev/null 2>&1 && command -v docker.exe >/dev/null 2>&1; then
    wslpath -w "${path}"
  else
    printf '%s' "${path}"
  fi
}

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "docker daemon is not reachable; start Docker Desktop or a local Docker daemon" >&2
  exit 1
fi

if [[ ! -d "${DIST_DIR}" ]]; then
  echo "missing ${DIST_DIR} (generate the AO runtime package before rebuilding WASM)" >&2
  exit 1
fi

if [[ ! -f "${DIST_DIR}/process.lua" ]]; then
  echo "missing ${DIST_DIR}/process.lua (generate the AO runtime package before rebuilding WASM)" >&2
  exit 1
fi

if [[ ! -f "${DIST_DIR}/config.yml" ]]; then
  echo "missing ${DIST_DIR}/config.yml (generate the AO runtime package before rebuilding WASM)" >&2
  exit 1
fi

echo "Rebuilding WASM from ${DIST_DIR}/process.lua ..."
docker run \
  --platform linux/amd64 \
  -v "$(docker_bind_path "${DIST_DIR}"):/src" \
  "${DOCKER_IMAGE}" \
  ao-build-module

if [[ ! -f "${DIST_DIR}/process.wasm" ]]; then
  echo "ERROR: dist/write/process.wasm missing after Docker build" >&2
  exit 1
fi

if [[ "$(strings "${DIST_DIR}/process.wasm" | grep -Fc "function process.handle")" -eq 0 ]]; then
  echo "ERROR: Built WASM is missing process.handle runtime symbol" >&2
  exit 1
fi

echo "Done: ${DIST_DIR}/process.wasm"
