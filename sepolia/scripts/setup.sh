#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

CONFIG_DIR="${ROOT_DIR}/config"
JWT_FILE="${CONFIG_DIR}/jwtsecret"

mkdir -p "${CONFIG_DIR}" "${ROOT_DIR}/data/geth" "${ROOT_DIR}/data/lighthouse" "${ROOT_DIR}/data/logs"

if [[ ! -f "${JWT_FILE}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32 > "${JWT_FILE}"
  else
    head -c 32 /dev/urandom | xxd -p -c 32 > "${JWT_FILE}"
  fi
  chmod 600 "${JWT_FILE}"
  echo "[setup] 已生成 JWT: config/jwtsecret"
else
  echo "[setup] JWT 已存在，跳过"
fi

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "[setup] 已创建 .env"
else
  echo "[setup] .env 已存在，跳过"
fi

chmod +x "${ROOT_DIR}"/scripts/*.sh 2>/dev/null || true

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R 1000:1000 "${ROOT_DIR}/data" 2>/dev/null || true
  chown 1000:1000 "${JWT_FILE}" 2>/dev/null || true
fi

echo
echo "[setup] 完成。下一步："
echo "  bash scripts/deploy.sh --bg-download   # 推荐：后台下载快照"
echo "  bash scripts/deploy.sh --skip-download # 已有 data/geth/sepolia/geth/chaindata 时"
