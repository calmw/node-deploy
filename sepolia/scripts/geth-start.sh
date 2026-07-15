#!/bin/sh
# Geth 启动脚本（由 docker-compose 挂载调用）
set -eu

: "${HTTP_BIND_ADDR:?HTTP_BIND_ADDR is required}"

HTTP_VHOSTS="${HTTP_VHOSTS:-localhost,127.0.0.1,${HTTP_BIND_ADDR}}"
WS_BIND_ADDR="${WS_BIND_ADDR:-${HTTP_BIND_ADDR}}"
SYNC_MODE="${SEPOLIA_SYNC_MODE:-snapshot}"
CHAIN_MARKER="/data/sepolia/geth/chaindata/CURRENT"

has_snapshot() {
  [ -f "${CHAIN_MARKER}" ]
}

case "${SYNC_MODE}" in
  snap)
    GETH_SYNC=snap
    echo "[geth] snap 模式：从网络 snap 同步（首 sync 较慢）"
    ;;
  snapshot)
    if ! has_snapshot; then
      echo "[geth] 错误: snapshot 模式需先导入 Geth 快照" >&2
      echo "[geth]   bash scripts/snapshot.sh start" >&2
      echo "[geth]   或改用 SEPOLIA_SYNC_MODE=snap" >&2
      exit 1
    fi
    GETH_SYNC=snap
    echo "[geth] snapshot 模式：基于已导入快照继续同步"
    ;;
  *)
    echo "[geth] 未知 SEPOLIA_SYNC_MODE=${SYNC_MODE}" >&2
    echo "[geth] 支持: snapshot | snap" >&2
    exit 1
    ;;
esac

exec geth \
  --sepolia \
  --datadir=/data \
  --syncmode="${GETH_SYNC}" \
  --db.engine=pebble \
  --state.scheme=path \
  --port="${P2P_PORT:-30303}" \
  --maxpeers="${MAX_PEERS:-50}" \
  --cache="${CACHE_MB:-4096}" \
  --history.blocks="${HISTORY_BLOCKS:-360000}" \
  --history.transactions="${HISTORY_TRANSACTIONS:-0}" \
  --history.logs.disable \
  --http \
  --http.addr=0.0.0.0 \
  --http.port=8545 \
  --http.vhosts="${HTTP_VHOSTS}" \
  --http.api=eth,net,web3,txpool,debug \
  --http.corsdomain="*" \
  --ws \
  --ws.addr=0.0.0.0 \
  --ws.port=8546 \
  --ws.origins="*" \
  --ws.api=eth,net,web3,debug \
  --authrpc.addr=0.0.0.0 \
  --authrpc.port=8551 \
  --authrpc.vhosts="*" \
  --authrpc.jwtsecret=/config/jwtsecret \
  --metrics \
  --metrics.addr=127.0.0.1 \
  --metrics.port=6060 \
  --verbosity=3
