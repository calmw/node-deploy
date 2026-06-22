#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "已创建 .env"
fi

# shellcheck disable=SC1091
source .env

NETWORK="${NETWORK:-mainnet}"
case "${NETWORK}" in
  mainnet)
    TEMPLATE="config/env.mainnet.example"
    ;;
  sepolia)
    TEMPLATE="config/env.sepolia.example"
    ;;
  *)
    echo "未知 NETWORK=${NETWORK}，支持 mainnet | sepolia" >&2
    exit 1
    ;;
esac

if [[ ! -f config/network.env ]]; then
  cp "${TEMPLATE}" config/network.env
  echo "已创建 config/network.env（${NETWORK}）"
  echo
  echo "⚠️  请编辑 config/network.env，填写 L1 节点地址："
  echo "    BASE_NODE_L1_ETH_RPC"
  echo "    BASE_NODE_L1_BEACON"
else
  echo "config/network.env 已存在，跳过"
fi

if grep -qE '^BASE_NODE_L1_ETH_RPC=$' config/network.env 2>/dev/null \
  || grep -qE '^BASE_NODE_L1_ETH_RPC=\s*$' config/network.env 2>/dev/null; then
  echo
  echo "⚠️  BASE_NODE_L1_ETH_RPC 尚未配置，启动前请填写 L1 RPC 地址"
fi

echo
echo "初始化完成。下一步："
echo "  1. 编辑 config/network.env，填入 L1 RPC 与 Beacon"
echo "  2. ./scripts/start.sh"
echo "  3. ./scripts/start.sh -f   # 启动并跟踪日志"
