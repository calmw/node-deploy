#!/usr/bin/env bash
# BSC Reth：源码镜像 + genesis 同步（默认）或快照
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

DO_BUILD=false
DO_PUSH=false
SKIP_DOCKER=false
USE_SNAPSHOT=false
SKIP_DOWNLOAD=false
BG_DOWNLOAD=false
BUILD_REF=""
REGISTRY_ARG=""

usage() {
  cat <<'EOF'
用法: bash scripts/deploy.sh [选项]

默认（.env RETH_SYNC_MODE=genesis）:
  · 不下载快照，空 datadir 从 block 0 同步
  · 1.5 年 state 见 data/reth/reth.toml
  · debug RPC 见 RETH_DEBUG

选项:
  --build              先 build-from-source.sh --update-env
  --push               构建后 push（需 --registry 或 .env RETH_REGISTRY）
  --registry <name>    如 ghcr.io/you/bsc-reth
  --ref <tag>          reth-bsc 版本，如 v0.1.2
  --with-snapshot      快照模式
  --bg-download        后台下载快照（仅 --with-snapshot）
  --skip-download      已有 data/reth/db
  --skip-docker        不启动容器
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) DO_BUILD=true; shift ;;
    --push) DO_PUSH=true; shift ;;
    --with-snapshot) USE_SNAPSHOT=true; shift ;;
    --skip-download) SKIP_DOWNLOAD=true; shift ;;
    --bg-download) BG_DOWNLOAD=true; shift ;;
    --skip-docker) SKIP_DOCKER=true; shift ;;
    --registry) REGISTRY_ARG="$2"; shift 2 ;;
    --ref) BUILD_REF="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

echo "============================================"
echo " BSC Reth 部署（1.5 年裁剪 + debug）"
echo " 目录: ${ROOT_DIR}"
echo "============================================"

for cmd in docker python3; do
  command -v "${cmd}" &>/dev/null || { echo "缺少: ${cmd}" >&2; exit 1; }
done
docker compose version &>/dev/null || { echo "缺少: docker compose" >&2; exit 1; }

if ${DO_BUILD}; then
  BUILD_ARGS=(--update-env)
  [[ -n "${BUILD_REF}" ]] && BUILD_ARGS+=(--ref "${BUILD_REF}")
  ${DO_PUSH} && BUILD_ARGS+=(--push)
  [[ -n "${REGISTRY_ARG}" ]] && BUILD_ARGS+=(--registry "${REGISTRY_ARG}")
  echo "[1] 源码构建镜像..."
  bash scripts/build-from-source.sh "${BUILD_ARGS[@]}"
else
  echo "[1] 跳过构建（未指定 --build）"
fi

echo "[2] setup.sh → reth.toml"
bash scripts/setup.sh init

echo "[3] .env"
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

if ${USE_SNAPSHOT}; then
  if grep -q '^RETH_SYNC_MODE=' .env; then
    sed -i.bak 's/^RETH_SYNC_MODE=.*/RETH_SYNC_MODE=snapshot/' .env
  else
    echo "RETH_SYNC_MODE=snapshot" >> .env
  fi
  # shellcheck disable=SC1091
  source .env
fi

SYNC="${RETH_SYNC_MODE:-genesis}"
has_reth_data() {
  [[ -d data/reth/db ]]
}

echo "[4] 同步方式: ${SYNC}"
if [[ "${SYNC}" == "snapshot" ]]; then
  if ${SKIP_DOWNLOAD}; then
    has_reth_data || { echo "错误: 无 data/reth/db" >&2; exit 1; }
    echo "  跳过快照下载"
  elif has_reth_data; then
    echo "  已有 db/"
  elif ${BG_DOWNLOAD}; then
    bash scripts/snapshot.sh start
    SKIP_DOCKER=true
  else
    bash scripts/snapshot.sh download
  fi
else
  echo "  genesis：不下载快照"
  if has_reth_data; then
    echo "  已有 data/reth/db/，将从现有进度继续"
  else
    echo "  空 datadir → 首次启动将从 block 0 同步（耗时长）"
  fi
fi

bash scripts/setup.sh init

if ${SKIP_DOCKER}; then
  echo "[5] 跳过 docker compose up"
  exit 0
fi

echo "[5] 启动容器"
if [[ "${RETH_COMPOSE_PULL:-false}" == "true" ]]; then
  docker compose pull
else
  echo "  RETH_COMPOSE_PULL=false，使用本地/已构建镜像"
fi
docker compose up -d
sleep 3
docker compose ps

echo ""
echo "验证:"
echo "  bash scripts/status.sh"
echo "  docker compose logs -f --tail 30 reth"
