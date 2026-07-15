#!/usr/bin/env bash
# BSC Chapel 测试网一键部署
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

SKIP_DOWNLOAD=false
SKIP_DOCKER=false
BG_DOWNLOAD=false

usage() {
  cat <<'EOF'
用法: bash scripts/deploy.sh [选项]

一键部署 BSC Chapel 测试网（默认 snap，无需快照）

选项:
  --skip-download   跳过快照（snap 模式可忽略）
  --bg-download     后台下载 pruned 快照（仅 BSC_SYNC_MODE=pruned 时）
  --skip-docker     只准备配置，不启动容器
  -h, --help
EOF
}

for arg in "$@"; do
  case "${arg}" in
    --skip-download) SKIP_DOWNLOAD=true ;;
    --bg-download) BG_DOWNLOAD=true ;;
    --skip-docker) SKIP_DOCKER=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: ${arg}" >&2; usage; exit 1 ;;
  esac
done

echo "============================================"
echo " BSC Chapel 测试网部署"
echo " 目录: ${ROOT_DIR}"
echo "============================================"

echo "[1/4] 检查依赖..."
for cmd in docker curl unzip; do
  command -v "${cmd}" &>/dev/null || { echo "缺少: ${cmd}" >&2; exit 1; }
done
docker compose version &>/dev/null || { echo "缺少 docker compose" >&2; exit 1; }

echo "[2/4] 初始化 Chapel testnet 配置..."
bash scripts/setup.sh

echo "[3/4] 配置 .env..."
[[ -f .env ]] || cp .env.example .env
if ! grep -q '^BSC_SYNC_MODE=' .env; then
  echo "BSC_SYNC_MODE=snap" >> .env
fi

if command -v tailscale &>/dev/null; then
  TS_IP="$(tailscale ip -4 2>/dev/null || true)"
  if [[ -n "${TS_IP}" ]]; then
    sed -i.bak "s/^HTTP_BIND_ADDR=.*/HTTP_BIND_ADDR=${TS_IP}/" .env
    sed -i.bak "s/^WS_BIND_ADDR=.*/WS_BIND_ADDR=${TS_IP}/" .env
    sed -i.bak "s|^HTTP_VHOSTS=.*|HTTP_VHOSTS=localhost,127.0.0.1,${TS_IP}|" .env
    rm -f .env.bak
    echo "  Tailscale IP: ${TS_IP}"
  fi
fi

# shellcheck disable=SC1091
source .env
echo "  BSC_SYNC_MODE=${BSC_SYNC_MODE:-snap}"
echo "  HTTP_PORT=${HTTP_PORT:-8575}  P2P_PORT=${P2P_PORT:-30311}"

CHAIN_MARKER="${ROOT_DIR}/data/node/geth/chaindata/CURRENT"
echo "[4/4] 快照..."
if [[ "${BSC_SYNC_MODE:-snap}" == "snap" ]]; then
  echo "  snap 模式，无需快照"
elif ${SKIP_DOWNLOAD}; then
  [[ -f "${CHAIN_MARKER}" ]] || { echo "错误: 无 chaindata" >&2; exit 1; }
else
  echo "  pruned/fast 模式请手动导入 testnet 快照，见 README"
  [[ -f "${CHAIN_MARKER}" ]] || SKIP_DOCKER=true
fi

if ${SKIP_DOCKER}; then
  echo "  跳过 Docker 启动"
else
  docker compose pull
  docker compose up -d
  docker compose ps
fi

HTTP_PORT="${HTTP_PORT:-8575}"
echo ""
echo "RPC: http://${HTTP_BIND_ADDR:-127.0.0.1}:${HTTP_PORT}"
echo "同步: docker exec bsc-testnet-node geth attach --datadir /bsc/node --exec eth.syncing"
