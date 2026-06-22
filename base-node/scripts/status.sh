#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
[[ -f .env ]] && source .env

HTTP_PORT="${HTTP_PORT:-8545}"
RPC_URL="http://127.0.0.1:${HTTP_PORT}"

echo "=== 容器状态 ==="
docker compose ps

if ! docker compose ps --status running 2>/dev/null | grep -q base-execution; then
  echo
  echo "Base 节点未在运行。启动：./scripts/start.sh"
  exit 0
fi

echo
echo "=== 区块链同步（execution RPC :${HTTP_PORT}）==="

rpc_call() {
  local method="$1"
  shift
  local params="${1:-[]}"
  curl -sf -X POST \
    -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":${params},\"id\":1}" \
    "${RPC_URL}" 2>/dev/null || echo ""
}

if ! rpc_call eth_blockNumber >/dev/null; then
  echo "RPC 暂不可用，execution 可能仍在启动中"
  echo "查看日志: docker compose logs --tail=30 execution"
  exit 0
fi

BLOCK_HEX="$(rpc_call eth_blockNumber | grep -oE '"result":"0x[0-9a-f]+"' | sed 's/.*"0x/0x/' | tr -d '"')"
if [[ -n "${BLOCK_HEX}" ]]; then
  BLOCK_DEC=$((BLOCK_HEX))
  echo "当前区块高度: ${BLOCK_DEC} (${BLOCK_HEX})"
fi

SYNCING="$(rpc_call eth_syncing)"
if echo "${SYNCING}" | grep -q '"result":false'; then
  echo "同步状态: 已完成"
elif echo "${SYNCING}" | grep -q '"result":{'; then
  echo "同步状态: 进行中"
  echo "${SYNCING}" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin).get('result') or {}
    for k in ('currentBlock', 'highestBlock', 'startingBlock'):
        v = d.get(k)
        if v:
            print(f'  {k}: {int(v, 16)}')
except Exception:
    pass
" 2>/dev/null || echo "${SYNCING}"
else
  echo "同步状态: 未知（RPC 响应异常）"
fi

CHAIN_ID="$(rpc_call eth_chainId | grep -oE '"result":"0x[0-9a-f]+"' | sed 's/.*"0x/0x/' | tr -d '"')"
if [[ -n "${CHAIN_ID}" ]]; then
  echo "Chain ID: $((CHAIN_ID)) (${CHAIN_ID})"
fi
