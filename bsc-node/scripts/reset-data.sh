#!/usr/bin/env bash
# 重置数据目录（切换同步模式时使用）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

read -r -p "确认清空所有链数据？此操作不可恢复 [y/N] " ans
[[ "${ans}" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }

docker compose down 2>/dev/null || true
rm -rf data/node/* data/incr/*
echo "[reset] 数据已清空，可切换 BSC_SYNC_MODE 后重新 docker compose up -d"
