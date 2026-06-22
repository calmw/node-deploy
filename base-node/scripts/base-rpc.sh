#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
[[ -f .env ]] && source .env

HTTP_PORT="${HTTP_PORT:-8545}"
RPC_URL="http://127.0.0.1:${HTTP_PORT}"

if [[ $# -eq 0 ]]; then
  echo "用法: $0 <method> [params_json]" >&2
  echo "示例:" >&2
  echo "  $0 eth_blockNumber" >&2
  echo "  $0 eth_getBlockByNumber '[\"latest\", false]'" >&2
  exit 1
fi

METHOD="$1"
PARAMS="${2:-[]}"

exec curl -s -X POST \
  -H "Content-Type: application/json" \
  --data "{\"jsonrpc\":\"2.0\",\"method\":\"${METHOD}\",\"params\":${PARAMS},\"id\":1}" \
  "${RPC_URL}"
