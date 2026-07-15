#!/usr/bin/env bash
# BSC Chapel 测试网启动脚本
set -euo pipefail

: "${BSC_SYNC_MODE:=snap}"
: "${HTTP_BIND_ADDR:?HTTP_BIND_ADDR is required (use Tailscale IP: tailscale ip -4)}"

NAT_MODE="${NAT_MODE:-any}"
case "${NAT_MODE}" in
  extip)
    : "${NAT_EXTIP:?NAT_EXTIP is required when NAT_MODE=extip}"
    NAT_SETTING="extip:${NAT_EXTIP}"
    ;;
  extip:*)
    NAT_SETTING="${NAT_MODE}"
    ;;
  *)
    NAT_SETTING="${NAT_MODE}"
    ;;
esac

HTTP_VHOSTS="${HTTP_VHOSTS:-localhost,127.0.0.1,${HTTP_BIND_ADDR}}"
WS_BIND_ADDR="${WS_BIND_ADDR:-${HTTP_BIND_ADDR}}"

CONFIG_PATH="/bsc/config/config.toml"
GENESIS_PATH="/bsc/config/genesis.json"
if [[ ! -f "${CONFIG_PATH}" ]]; then
  if [[ -f "/bsc/config/testnet/config.toml" ]]; then
    CONFIG_PATH="/bsc/config/testnet/config.toml"
    GENESIS_PATH="/bsc/config/testnet/genesis.json"
    echo "[bsc] 使用配置: ${CONFIG_PATH}（建议宿主机执行 bash scripts/setup.sh repair）"
  else
    echo "[bsc] 错误: 未找到 config.toml，请运行 bash scripts/setup.sh" >&2
    exit 1
  fi
fi

if [[ ! -f "${GENESIS_PATH}" ]]; then
  echo "[bsc] 错误: 未找到 genesis.json" >&2
  exit 1
fi

CHAIN_DATA="/bsc/node/geth/chaindata"
HAS_SNAPSHOT=false
[[ -f "${CHAIN_DATA}/CURRENT" ]] && HAS_SNAPSHOT=true

prepare_datadir() {
  case "${BSC_SYNC_MODE}" in
    incr)
      if ${HAS_SNAPSHOT}; then
        echo "[bsc] incr 模式：检测到已有 chaindata，继续增量同步"
        return
      fi
      echo "[bsc] incr 模式：清空 datadir，从远程下载 base snapshot..."
      rm -rf /bsc/node/geth /bsc/node/.bsc_genesis_initialized
      rm -rf /bsc/incr/*
      ;;
    snap)
      if ${HAS_SNAPSHOT}; then
        echo "[bsc] snap 模式：检测到已有 chaindata，继续同步"
        return
      fi
      [[ -d /bsc/node/geth ]] && rm -rf /bsc/node/geth
      echo "[bsc] snap 模式：初始化 Chapel testnet genesis..."
      geth --datadir /bsc/node --db.engine pebble --state.scheme path init "${GENESIS_PATH}"
      echo "[bsc] genesis 初始化完成，将从网络 snap 同步"
      ;;
    fast|pruned)
      if ! ${HAS_SNAPSHOT}; then
        echo "[bsc] 错误: ${BSC_SYNC_MODE} 模式需先导入 testnet 快照" >&2
        echo "[bsc]   fast   → 仅主网可用，测试网请用 snap 或 pruned" >&2
        echo "[bsc]   pruned → 见 README / bnb-chain/bsc-snapshots testnet" >&2
        exit 1
      fi
      echo "[bsc] ${BSC_SYNC_MODE} 模式：使用已导入的 snapshot"
      ;;
    *)
      echo "[bsc] 未知 BSC_SYNC_MODE=${BSC_SYNC_MODE}" >&2
      echo "[bsc] 支持: snap | incr | fast | pruned" >&2
      exit 1
      ;;
  esac
}

prepare_datadir

# Chapel testnet 官方 StaticNodes（config.toml 内亦有；作 bootnodes 兜底）
DEFAULT_BOOTNODES="enode://db1e2c76e34f85b75fdc2460aad25a64947acc4adabb60b4c95f50c03066a4884f44f2d4d4c1607190712a0315681d30caa8a1c7d850e7aa643e29a6c1692739@52.199.214.252:30311,enode://e5c4320eaa3357286cdde303df8b5b84f81013d86a72f91ecb2efc59b48a376bf16904d0a4e8ca44981c8d201bef439e1fb91c551d24aa39b65d930f03fc1823@52.51.80.128:30311,enode://75601809401e4dedf6477fa9b74170d932b76aba0d1de1c19b27ff0a424ede294b5fc235af64f41dd4003a43793f63f321082b4de6d6a0588b5c84215f909af9@3.209.122.123:30311,enode://665cf77ca26a8421cfe61a52ac312958308d4912e78ce8e0f61d6902e4494d4cc38f9b0dd1b23a427a7a5734e27e5d9729231426b06bb9c73b56a142f83f6b68@52.72.123.113:30311"

SYNC_MODE="full"
EXTRA_ARGS=()

case "${BSC_SYNC_MODE}" in
  snap)
    SYNC_MODE="snap"
    ;;
  fast)
    EXTRA_ARGS+=(
      --tries-verify-mode none
      --history.transactions 1152000
      --history.blocks 1152000
    )
    echo "[bsc] fast 模式: trace 窗口由 triesInMemory=${TRIES_IN_MEMORY:-8192} 控制"
    ;;
  incr)
    EXTRA_ARGS+=(
      --incr.use-remote
      --incr.remote-url "https://download.snapshots.bnbchain.world/incr-snapshot"
      --incr.datadir /bsc/incr
    )
    ;;
esac

COMMON_ARGS=(
  --config "${CONFIG_PATH}"
  --datadir /bsc/node
  --syncmode "${SYNC_MODE}"
  --db.engine pebble
  --state.scheme path
  --port "${P2P_PORT:-30311}"
  --nat "${NAT_SETTING}"
  --bootnodes "${BSC_BOOTNODES:-${DEFAULT_BOOTNODES}}"
  --maxpeers "${MAX_PEERS:-80}"
  --maxpendpeers "${MAX_PEND_PEERS:-100}"
  --cache "${CACHE_MB:-2048}"
  --triesInMemory "${TRIES_IN_MEMORY:-8192}"
  --history.state "${HISTORY_STATE:-8192}"
  --history.transactions 0
  --history.blocks 360000
  --history.logs.disable
  --http
  --http.addr "${HTTP_BIND_ADDR}"
  --http.port "${HTTP_PORT:-8575}"
  --http.vhosts "${HTTP_VHOSTS}"
  --http.api eth,net,web3,txpool,debug,parlia
  --http.corsdomain "*"
  --ws
  --ws.addr "${WS_BIND_ADDR}"
  --ws.port "${WS_PORT:-8576}"
  --ws.origins "*"
  --ws.api eth,net,web3,debug,parlia
  --metrics
  --metrics.addr 127.0.0.1
  --metrics.port "${METRICS_PORT:-16060}"
  --verbosity 3
)

echo "[bsc] Chapel testnet 启动: ${BSC_SYNC_MODE} (syncmode=${SYNC_MODE}, p2p=${P2P_PORT:-30311}, rpc=${HTTP_PORT:-8575})"
exec geth "${COMMON_ARGS[@]}" "${EXTRA_ARGS[@]}"
