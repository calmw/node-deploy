#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

FOLLOW_LOGS=0
if [[ "${1:-}" == "-f" || "${1:-}" == "--follow" ]]; then
  FOLLOW_LOGS=1
fi

if [[ ! -f config/bitcoin.conf ]]; then
  echo "未找到 config/bitcoin.conf，先运行初始化..."
  "$ROOT_DIR/scripts/setup.sh"
fi

# 清理数据卷内残留的 bitcoin.conf（旧版 -conf 挂载方案会在 v31 触发启动失败）
if docker volume inspect btc-node-data >/dev/null 2>&1; then
  docker run --rm -v btc-node-data:/data alpine rm -f /data/bitcoin.conf 2>/dev/null || true
fi

echo "启动 BTC 主网节点..."
docker compose up -d

echo
docker compose ps

if [[ "$FOLLOW_LOGS" -eq 1 ]]; then
  echo
  echo "跟踪日志（Ctrl+C 退出，不会停止节点）..."
  docker compose logs -f bitcoind
else
  echo
  echo "节点已在后台运行。常用命令："
  echo "  ./scripts/status.sh      # 查看状态与同步进度"
  echo "  ./scripts/stop.sh        # 停止节点"
  echo "  docker compose logs -f bitcoind"
fi
