#!/usr/bin/env bash
# 部署目录不是 git 仓库时，从 GitHub 拉最新 bsc-node-reth 文件（不覆盖 data/、.env、.build）
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${NODE_DEPLOY_REPO:-https://github.com/calmw/node-deploy.git}"
REF="${NODE_DEPLOY_REF:-main}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "[sync] 克隆 ${REPO} (${REF}) → 同步到 ${ROOT_DIR}"
git clone --depth 1 --branch "${REF}" "${REPO}" "${TMP}/repo"
rsync -a --delete \
  --exclude 'data/' \
  --exclude '.env' \
  --exclude '.build/' \
  "${TMP}/repo/bsc-node-reth/" "${ROOT_DIR}/"
chmod +x "${ROOT_DIR}"/scripts/*.sh 2>/dev/null || true
echo "[sync] 完成。请检查 .env（未覆盖）；可 bash scripts/repair-env.sh 仅当 .env 损坏时。"
