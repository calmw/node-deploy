#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
CONTAINER="${BSC_CONTAINER:-bsc-testnet-node}"

# shellcheck disable=SC1091
[[ -f .env ]] && source .env || true
HTTP_PORT="${HTTP_PORT:-8575}"
HTTP_BIND="${HTTP_BIND_ADDR:-127.0.0.1}"
P2P_PORT="${P2P_PORT:-30311}"

echo "=== 容器 ==="
docker compose ps

echo
echo "=== 端口监听（host 网络）==="
ss -tlnp 2>/dev/null | grep -E ":${HTTP_PORT}|:${P2P_PORT}" || echo "未看到 ${HTTP_BIND}:${HTTP_PORT} 或 *:${P2P_PORT}"

echo
echo "=== RPC ==="
if curl -sf -m 3 -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  "http://${HTTP_BIND}:${HTTP_PORT}/" 2>/dev/null; then
  echo
else
  echo "RPC 无响应 → docker compose logs --tail 40 bsc"
fi

if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
  attach() {
    docker exec "${CONTAINER}" geth attach --datadir /bsc/node --exec "$1" 2>/dev/null
  }
  echo
  echo "=== 链状态 ==="
  if CHAIN_ID="$(attach 'eth.chainId()')"; then
    echo "chainId=${CHAIN_ID}"
    echo "block=$(attach 'eth.blockNumber')"
    echo "peers=$(attach 'net.peerCount')"
    echo "syncing=$(attach 'JSON.stringify(eth.syncing)')"
  else
    echo "geth attach 失败 → docker compose logs --tail 40 bsc"
  fi
fi
