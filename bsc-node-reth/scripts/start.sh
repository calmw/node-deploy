#!/usr/bin/env bash
# BSC Reth 节点启动（custom prune，勿 --full）
set -euo pipefail

: "${HTTP_BIND_ADDR:?HTTP_BIND_ADDR is required (Tailscale: tailscale ip -4)}"

DATADIR="${RETH_DATADIR:-/data}"
CONFIG="${DATADIR}/reth.toml"

if [[ ! -f "${CONFIG}" ]]; then
  echo "[reth] 错误: 未找到 ${CONFIG}，请先 bash scripts/setup.sh" >&2
  exit 1
fi

# 官方文档推荐 trusted peers（加速出块同步）
DEFAULT_TRUSTED_PEERS="enode://551c8009f1d5bbfb1d64983eeb4591e51ad488565b96cdde7e40a207cfd6c8efa5b5a7fa88ed4e71229c988979e4c720891287ddd7d00ba114408a3ceb972ccb@34.245.203.3:30311,enode://c637c90d6b9d1d0038788b163a749a7a86fed2e7d0d13e5dc920ab144bb432ed1e3e00b54c1a93cecba479037601ba9a5937a88fe0be949c651043473c0d1e5b@34.244.120.206:30311,enode://bac6a548c7884270d53c3694c93ea43fa87ac1c7219f9f25c9d57f6a2fec9d75441bc4bad1e81d78c049a1c4daf3b1404e2bbb5cd9bf60c0f3a723bbaea110bc@3.255.117.110:30311,enode://94e56c84a5a32e2ef744af500d0ddd769c317d3c3dd42d50f5ea95f5f3718a5f81bc5ce32a7a3ea127bc0f10d3f88f4526a67f5b06c1d85f9cdfc6eb46b2b375@3.255.231.219:30311"

TRUSTED="${RETH_TRUSTED_PEERS:-${DEFAULT_TRUSTED_PEERS}}"
WS_BIND="${WS_BIND_ADDR:-${HTTP_BIND_ADDR}}"

NAT_ARGS=()
case "${NAT_MODE:-any}" in
  extip)
    : "${NAT_EXTIP:?NAT_EXTIP required when NAT_MODE=extip}"
    NAT_ARGS=(--nat "extip:${NAT_EXTIP}")
    ;;
  none)
    NAT_ARGS=(--nat none)
    ;;
  *)
    NAT_ARGS=(--nat any)
    ;;
esac

HTTP_API="${HTTP_API:-eth,net,web3,txpool,debug,trace,admin,rpc,reth,ots}"
WS_API="${WS_API:-eth,net,web3,txpool,debug,trace}"

ARGS=(
  node
  --chain=bsc
  --datadir="${DATADIR}"
  --port "${P2P_PORT:-30303}"
  --max-peers "${MAX_PEERS:-100}"
  "${NAT_ARGS[@]}"
  --trusted-peers "${TRUSTED}"
  --enable-prefetch
  --optimize.enable-execution-cache
  --http
  --http.addr "${HTTP_BIND_ADDR}"
  --http.port "${HTTP_PORT:-8545}"
  --http.api "${HTTP_API}"
  --ws
  --ws.addr "${WS_BIND}"
  --ws.port "${WS_PORT:-8546}"
  --ws.api "${WS_API}"
  --metrics "127.0.0.1:${METRICS_PORT:-6060}"
  --log.file.directory "${DATADIR}/logs"
)

echo "[reth] bsc mainnet | datadir=${DATADIR} | prune=reth.toml | p2p=${P2P_PORT:-30303} | rpc=${HTTP_BIND_ADDR}:${HTTP_PORT:-8545}"
echo "[reth] 未使用 --full；历史窗口见 reth.toml 中 distance"

# 镜像入口一般为 reth-bsc；兼容不同 ENTRYPOINT
if command -v bsc-reth >/dev/null 2>&1; then
  exec bsc-reth "${ARGS[@]}"
fi
if command -v reth-bsc >/dev/null 2>&1; then
  exec reth-bsc "${ARGS[@]}"
fi
echo "[reth] 错误: 容器内未找到 reth-bsc / bsc-reth 可执行文件" >&2
exit 1
