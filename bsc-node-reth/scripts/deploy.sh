#!/usr/bin/env bash
# BSC Reth 主网：reth.toml ~1.5 年裁剪 + 可选 Full 快照
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

SKIP_DOWNLOAD=false
SKIP_DOCKER=false
BG_DOWNLOAD=false

usage() {
  cat <<'EOF'
用法: bash scripts/deploy.sh [选项]

  --skip-download   已有 data/reth/db，跳过快照
  --bg-download     后台下载 Reth Full 快照（约 3.23 TiB）
  --skip-docker     只写配置，不启动容器
  -h, --help
EOF
}

for arg in "$@"; do
  case "${arg}" in
    --skip-download) SKIP_DOWNLOAD=true ;;
    --bg-download) BG_DOWNLOAD=true ;;
    --skip-docker) SKIP_DOCKER=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: ${arg}"; usage; exit 1 ;;
  esac
done

echo "============================================"
echo " BSC Reth 主网（custom prune ~1.5 年 state）"
echo " 目录: ${ROOT_DIR}"
echo "============================================"

MISSING=()
for cmd in docker curl python3; do
  command -v "${cmd}" &>/dev/null || MISSING+=("${cmd}")
done
docker compose version &>/dev/null || MISSING+=("docker compose")
[[ ${#MISSING[@]} -gt 0 ]] && { echo "缺少: ${MISSING[*]}" >&2; exit 1; }

echo "[1/4] setup.sh → reth.toml"
bash scripts/setup.sh init

echo "[2/4] .env"
[[ -f .env ]] || cp .env.example .env
if command -v tailscale &>/dev/null; then
  TS_IP="$(tailscale ip -4 2>/dev/null || true)"
  if [[ -n "${TS_IP}" ]]; then
    sed -i.bak "s/^HTTP_BIND_ADDR=.*/HTTP_BIND_ADDR=${TS_IP}/" .env
    sed -i.bak "s/^WS_BIND_ADDR=.*/WS_BIND_ADDR=${TS_IP}/" .env
    rm -f .env.bak
    echo "  Tailscale IP: ${TS_IP}"
  fi
fi
# shellcheck disable=SC1091
source .env

has_reth_data() {
  [[ -d data/reth/db ]] && [[ -d data/reth/static_files ]]
}

echo "[3/4] 快照"
if ${SKIP_DOWNLOAD}; then
  has_reth_data || { echo "错误: 无 data/reth/db，去掉 --skip-download" >&2; exit 1; }
  echo "  跳过快照"
elif has_reth_data; then
  echo "  已有 Reth 数据"
else
  if ${BG_DOWNLOAD}; then
    bash scripts/snapshot.sh start
    SKIP_DOCKER=true
  else
    bash scripts/snapshot.sh download
  fi
fi

echo "[4/4] 确保 reth.toml 在 datadir"
bash scripts/setup.sh init

if ${SKIP_DOCKER}; then
  echo "跳过 Docker。快照完成后: docker compose up -d"
else
  docker compose pull
  docker compose up -d
  sleep 3
  docker compose ps
fi

echo ""
echo "验证:"
echo "  bash scripts/status.sh"
echo "  curl -s -X POST -H 'Content-Type: application/json' \\"
echo "    --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_chainId\",\"params\":[],\"id\":1}' \\"
echo "    http://${HTTP_BIND_ADDR:-127.0.0.1}:${HTTP_PORT:-8545}"
