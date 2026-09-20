#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
CONTAINER="${RETH_CONTAINER:-bsc-node-reth}"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/load-env.sh"
load_dotenv "${ROOT_DIR}/.env"
HTTP_PORT="${HTTP_PORT:-8545}"
HTTP_BIND="${HTTP_BIND_ADDR:-127.0.0.1}"
P2P_PORT="${P2P_PORT:-30303}"

echo "=== 容器 ==="
docker compose ps

echo
echo "=== 数据目录 ==="
if [[ -d data/reth/db ]]; then
  du -sh data/reth 2>/dev/null || true
  [[ -f data/reth/reth.toml ]] && grep -E 'distance|block_interval' data/reth/reth.toml | head -6
else
  echo "尚无 data/reth/db → bash scripts/snapshot.sh start"
fi

echo
echo "=== 端口 ==="
ss -tlnp 2>/dev/null | grep -E ":${HTTP_PORT}|:${P2P_PORT}" || echo "未监听 ${HTTP_PORT}/${P2P_PORT}"

echo
echo "=== RPC ==="
curl -sf -m 5 -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  "http://${HTTP_BIND}:${HTTP_PORT}/" && echo || echo "RPC 无响应"

echo
echo "=== 同步 ==="
curl -sf -m 5 -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
  "http://${HTTP_BIND}:${HTTP_PORT}/" && echo || true
curl -sf -m 5 -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  "http://${HTTP_BIND}:${HTTP_PORT}/" && echo || true

if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
  echo
  echo "=== 日志（最近）==="
  docker compose logs --tail 8 reth 2>/dev/null || true
fi
