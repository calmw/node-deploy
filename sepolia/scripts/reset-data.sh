#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

read -r -p "确认清空 data/geth 与 data/lighthouse？[y/N] " ans
[[ "${ans}" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }

docker compose down 2>/dev/null || true
rm -rf data/geth/* data/lighthouse/*
echo "[reset] 数据已清空，可重新 bash scripts/deploy.sh"
