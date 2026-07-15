#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# shellcheck disable=SC1091
[[ -f .env ]] && source .env || true
HTTP_BIND="${HTTP_BIND_ADDR:-127.0.0.1}"
HTTP_PORT="${HTTP_PORT:-8545}"
BEACON_BIND="${BEACON_BIND_ADDR:-127.0.0.1}"
BEACON_PORT="${BEACON_PORT:-5052}"
RPC_URL="http://${HTTP_BIND}:${HTTP_PORT}"
CHAIN_MARKER="${ROOT_DIR}/data/geth/sepolia/geth/chaindata/CURRENT"

echo "=== Geth 快照 ==="
if [[ -f "${CHAIN_MARKER}" ]]; then
  echo "✓ 快照已就绪"
  du -sh data/geth/sepolia 2>/dev/null || du -sh data/geth 2>/dev/null || true
else
  bash scripts/snapshot.sh status || true
  echo
  echo "提示: 快照完成前容器不会启动。完成后执行: docker compose up -d"
fi

echo
echo "=== 容器 ==="
docker compose ps

GETH_UP=false
LH_UP=false
docker compose ps --status running 2>/dev/null | grep -q sepolia-geth && GETH_UP=true
docker compose ps --status running 2>/dev/null | grep -q sepolia-lighthouse && LH_UP=true

echo
echo "=== Geth 同步 ==="
if ${GETH_UP}; then
  SYNCING="$(curl -sf -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
    "${RPC_URL}" 2>/dev/null || echo '{}')"
  if echo "${SYNCING}" | grep -q '"result":false'; then
    HEIGHT="$(curl -sf -X POST -H 'Content-Type: application/json' \
      --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
      "${RPC_URL}" | grep -oE '"result":"0x[0-9a-f]+"' | grep -oE '0x[0-9a-f]+' || echo 0x0)"
    printf "已同步，区块高度: %s (%d)\n" "${HEIGHT}" "$((HEIGHT))"
  else
    echo "同步中..."
    echo "${SYNCING}" | head -c 500
    echo
  fi
  PEERS="$(curl -sf -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
    "${RPC_URL}" | grep -oE '0x[0-9a-f]+' | tail -1 || echo 0x0)"
  printf "execution peers: %d\n" "$((PEERS))"
elif [[ -f "${CHAIN_MARKER}" ]]; then
  echo "geth 未运行 → docker compose up -d"
else
  echo "geth 未运行（等待快照）"
fi

echo
echo "=== Lighthouse ==="
if ${LH_UP}; then
  SYNC="$(curl -sf "http://${BEACON_BIND}:${BEACON_PORT}/eth/v1/node/syncing" 2>/dev/null || true)"
  if [[ -n "${SYNC}" ]]; then
    echo "${SYNC}" | python3 -c "
import json,sys
d=json.load(sys.stdin).get('data',{})
if d.get('is_syncing'):
    h=d.get('head_slot','?')
    d2=d.get('sync_distance','?')
    print(f'同步中 head_slot={h} distance={d2}')
else:
    print('已同步')
" 2>/dev/null || echo "${SYNC}" | head -c 300
  else
    echo "Beacon API 尚未就绪"
  fi
elif [[ -f "${CHAIN_MARKER}" ]]; then
  echo "lighthouse 未运行 → docker compose up -d"
else
  echo "lighthouse 未运行（等待快照）"
fi

echo
echo "=== 磁盘 ==="
du -sh data/geth data/lighthouse 2>/dev/null || true

if ${GETH_UP}; then
  PRESYNC="$(docker compose logs --tail=30 geth 2>&1 | grep -E 'Syncing|Imported new chain|state download' | tail -3 || true)"
  if [[ -n "${PRESYNC}" ]]; then
    echo
    echo "=== 最近 Geth 日志 ==="
    echo "${PRESYNC}"
  fi
fi
