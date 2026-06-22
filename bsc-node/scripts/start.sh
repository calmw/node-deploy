#!/usr/bin/env bash
# BSC 节点启动脚本（由 docker-compose 挂载调用）
set -euo pipefail

: "${BSC_SYNC_MODE:=fast}"
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
  if [[ -f "/bsc/config/mainnet/config.toml" ]]; then
    CONFIG_PATH="/bsc/config/mainnet/config.toml"
    GENESIS_PATH="/bsc/config/mainnet/genesis.json"
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
      # incr 从远程下载 base snapshot，绝对不能 geth init
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
      echo "[bsc] snap 模式：初始化 genesis..."
      geth --datadir /bsc/node --db.engine pebble --state.scheme path init "${GENESIS_PATH}"
      echo "[bsc] genesis 初始化完成，将从网络 snap 同步"
      ;;
    fast|pruned)
      if ! ${HAS_SNAPSHOT}; then
        echo "[bsc] 错误: ${BSC_SYNC_MODE} 模式需先导入 snapshot" >&2
        echo "[bsc]   fast   → bash scripts/snapshot.sh start" >&2
        echo "[bsc]   pruned → 见 README 官方快照说明" >&2
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

# BSC mainnet 官方 bootnodes（与 params/bootnodes.go 一致，FRP 场景下加强 outbound 发现）
DEFAULT_BOOTNODES="enode://433c8bfdf53a3e2268ccb1b829e47f629793291cbddf0c76ae626da802f90532251fc558e2e0d10d6725e759088439bf1cd4714716b03a259a35d4b2e4acfa7f@52.69.102.73:30311,enode://571bee8fb902a625942f10a770ccf727ae2ba1bab2a2b64e121594a99c9437317f6166a395670a00b7d93647eacafe598b6bbcef15b40b6d1a10243865a3e80f@35.73.84.120:30311,enode://fac42fb0ba082b7d1eebded216db42161163d42e4f52c9e47716946d64468a62da4ba0b1cac0df5e8bf1e5284861d757339751c33d51dfef318be5168803d0b5@18.203.152.54:30311,enode://3063d1c9e1b824cfbb7c7b6abafa34faec6bb4e7e06941d218d760acdd7963b274278c5c3e63914bd6d1b58504c59ec5522c56f883baceb8538674b92da48a96@34.250.32.100:30311,enode://ad78c64a4ade83692488aa42e4c94084516e555d3f340d9802c2bf106a3df8868bc46eae083d2de4018f40e8d9a9952c32a0943cd68855a9bc9fd07aac982a6d@34.204.214.24:30311,enode://5db798deb67df75d073f8e2953dad283148133acb520625ea804c9c4ad09a35f13592a762d8f89056248f3889f6dcc33490c145774ea4ff2966982294909b37a@107.20.191.97:30311"

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
    echo "[bsc] fast 模式: trace 窗口由 triesInMemory=${TRIES_IN_MEMORY:-15000} 控制（history.state 不生效）"
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
  --port "${P2P_PORT:-30303}"
  --nat "${NAT_SETTING}"
  --bootnodes "${BSC_BOOTNODES:-${DEFAULT_BOOTNODES}}"
  --maxpeers "${MAX_PEERS:-80}"
  --maxpendpeers "${MAX_PEND_PEERS:-100}"
  --cache "${CACHE_MB:-4096}"
  --triesInMemory "${TRIES_IN_MEMORY:-15000}"
  --history.state "${HISTORY_STATE:-15000}"
  --history.transactions 0
  --history.blocks 360000
  --history.logs.disable
  --http
  --http.addr "${HTTP_BIND_ADDR}"
  --http.port "${HTTP_PORT:-8545}"
  --http.vhosts "${HTTP_VHOSTS}"
  --http.api eth,net,web3,txpool,debug,parlia
  --http.corsdomain "*"
  --ws
  --ws.addr "${WS_BIND_ADDR}"
  --ws.port "${WS_PORT:-8546}"
  --ws.origins "*"
  --ws.api eth,net,web3,debug,parlia
  --metrics
  --metrics.addr 127.0.0.1
  --metrics.port 6060
  --verbosity 3
)

echo "[bsc] 启动模式: ${BSC_SYNC_MODE} (syncmode=${SYNC_MODE}, nat=${NAT_SETTING})"
exec geth "${COMMON_ARGS[@]}" "${EXTRA_ARGS[@]}"
