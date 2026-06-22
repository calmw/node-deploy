#!/usr/bin/env bash
# 清空 Base 节点链数据（切换 Pruned ↔ Archive 或重建节点时使用）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "⚠️  将停止容器并删除 Docker 卷 base-node-data（所有链数据）"
read -r -p "确认请输入 yes: " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
  echo "已取消"
  exit 0
fi

docker compose down -v 2>/dev/null || true
echo "链数据已清除。下一步："
echo "  1. 确认 config/network.env 中 Pruned / Archive 配置正确"
echo "  2. （可选）导入官方 pruned 快照到全新卷，见 README"
echo "  3. ./scripts/start.sh"
