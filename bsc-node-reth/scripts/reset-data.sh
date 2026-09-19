#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

read -r -p "确认清空 data/reth 全部 Reth 数据？不可恢复 [y/N] " ans
[[ "${ans}" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }

docker compose down 2>/dev/null || true
bash scripts/snapshot.sh stop 2>/dev/null || true
rm -rf data/reth/* data/logs/reth-snapshot-download.log
echo "[reset] 已清空。重新部署: bash scripts/deploy.sh --bg-download"
