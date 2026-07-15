#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

SKIP_DOWNLOAD=false
SKIP_DOCKER=false
BG_DOWNLOAD=false

usage() {
  cat <<'EOF'
用法: bash scripts/deploy.sh [选项]

一键部署 Ethereum L1 Sepolia（Geth + Lighthouse）

选项:
  --skip-download   跳过快照（已有 chaindata 时）
  --bg-download     后台下载快照
  --skip-docker     只准备配置/快照，不启动容器
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
echo " Ethereum L1 Sepolia 部署"
echo " 目录: ${ROOT_DIR}"
echo "============================================"

echo "[1/5] 检查依赖..."
MISSING=()
for cmd in docker curl; do
  command -v "${cmd}" &>/dev/null || MISSING+=("${cmd}")
done
docker compose version &>/dev/null || MISSING+=("docker compose")
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "缺少: ${MISSING[*]}" >&2
  exit 1
fi

# shellcheck disable=SC1091
[[ -f .env ]] && source .env || true
SYNC_MODE="${SEPOLIA_SYNC_MODE:-snapshot}"

if [[ "${SYNC_MODE}" == "snapshot" ]] && ! ${SKIP_DOWNLOAD}; then
  if ! command -v zstd >/dev/null 2>&1; then
    echo "snapshot 模式需要 zstd: sudo apt install -y zstd" >&2
    exit 1
  fi
  AVAIL_GB=$(df -BG "${ROOT_DIR}" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
  if [[ "${AVAIL_GB}" -lt 350 ]]; then
    echo "警告: 可用磁盘 ${AVAIL_GB}GB < 350GB，snapshot 模式建议 ≥350GB" >&2
    read -r -p "是否继续？[y/N] " ans
    [[ "${ans}" =~ ^[Yy]$ ]] || exit 1
  fi
fi

echo "[2/5] 初始化..."
bash scripts/setup.sh

echo "[3/5] 配置 .env..."
# shellcheck disable=SC1091
source .env
if command -v tailscale &>/dev/null; then
  TS_IP="$(tailscale ip -4 2>/dev/null || true)"
  if [[ -n "${TS_IP}" ]]; then
    sed -i.bak "s/^HTTP_BIND_ADDR=.*/HTTP_BIND_ADDR=${TS_IP}/" .env
    sed -i.bak "s/^WS_BIND_ADDR=.*/WS_BIND_ADDR=${TS_IP}/" .env
    sed -i.bak "s/^BEACON_BIND_ADDR=.*/BEACON_BIND_ADDR=${TS_IP}/" .env
    sed -i.bak "s|^HTTP_VHOSTS=.*|HTTP_VHOSTS=localhost,127.0.0.1,${TS_IP}|" .env
    rm -f .env.bak
    echo "  Tailscale IP: ${TS_IP}"
  fi
fi
# shellcheck disable=SC1091
source .env
echo "  SEPOLIA_SYNC_MODE=${SEPOLIA_SYNC_MODE:-snapshot}"
echo "  HTTP_BIND_ADDR=${HTTP_BIND_ADDR}"

CHAIN_MARKER="${ROOT_DIR}/data/geth/sepolia/geth/chaindata/CURRENT"
echo "[4/5] 快照..."
if [[ "${SYNC_MODE}" == "snap" ]] || ${SKIP_DOWNLOAD}; then
  if [[ "${SYNC_MODE}" == "snapshot" && ! -f "${CHAIN_MARKER}" ]]; then
    echo "错误: snapshot 模式但无 chaindata，去掉 --skip-download 或改 SEPOLIA_SYNC_MODE=snap" >&2
    exit 1
  fi
  echo "  跳过快照"
elif [[ -f "${CHAIN_MARKER}" ]]; then
  echo "  ✓ 已有快照"
elif ${BG_DOWNLOAD}; then
  bash scripts/snapshot.sh start
  SKIP_DOCKER=true
else
  bash scripts/snapshot.sh download
fi

echo "[5/5] 启动容器..."
if ${SKIP_DOCKER}; then
  echo "  跳过 Docker 启动（快照仍在后台下载，容器此时不会运行）"
  echo ""
  echo "  查看快照: bash scripts/snapshot.sh status"
  echo "  实时日志: bash scripts/snapshot.sh log"
  echo "  快照就绪后: docker compose up -d && bash scripts/status.sh"
else
  docker compose pull
  docker compose up -d
  sleep 5
  docker compose ps
fi

echo
echo "============================================"
echo " 部署完成"
echo "============================================"
echo "  状态: bash scripts/status.sh"
echo "  日志: docker compose logs -f geth"
echo "  RPC:  http://${HTTP_BIND_ADDR}:${HTTP_PORT:-8545}"
echo "  Beacon: http://${BEACON_BIND_ADDR:-127.0.0.1}:${BEACON_PORT:-5052}"
