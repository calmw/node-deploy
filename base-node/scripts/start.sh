#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

FOLLOW_LOGS=0
if [[ "${1:-}" == "-f" || "${1:-}" == "--follow" ]]; then
  FOLLOW_LOGS=1
fi

if [[ ! -f config/network.env ]]; then
  echo "未找到 config/network.env，先运行初始化..."
  "$ROOT_DIR/scripts/setup.sh"
fi

if grep -qE '^BASE_NODE_L1_ETH_RPC=$' config/network.env \
  || grep -qE '^BASE_NODE_L1_ETH_RPC=\s*$' config/network.env; then
  echo "错误: 请先在 config/network.env 中配置 BASE_NODE_L1_ETH_RPC" >&2
  exit 1
fi

if grep -qE '^BASE_NODE_L1_BEACON=$' config/network.env \
  || grep -qE '^BASE_NODE_L1_BEACON=\s*$' config/network.env; then
  echo "错误: 请先在 config/network.env 中配置 BASE_NODE_L1_BEACON" >&2
  exit 1
fi

echo "拉取 Base 节点镜像..."
docker compose pull

echo "启动 Base 节点（execution + consensus）..."
docker compose up -d

echo
docker compose ps

if [[ "$FOLLOW_LOGS" -eq 1 ]]; then
  echo
  echo "跟踪日志（Ctrl+C 退出，不会停止节点）..."
  docker compose logs -f
else
  echo
  echo "节点已在后台运行。常用命令："
  echo "  ./scripts/status.sh           # 查看状态与同步进度"
  echo "  ./scripts/stop.sh             # 停止节点"
  echo "  ./scripts/base-rpc.sh ...     # JSON-RPC 调用"
  echo "  docker compose logs -f        # 跟踪全部日志"
  echo "  docker compose logs -f execution   # 仅 execution 层"
  echo "  docker compose logs -f consensus   # 仅 consensus 层"
fi
