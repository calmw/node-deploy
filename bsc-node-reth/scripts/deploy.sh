#!/usr/bin/env bash
# BSC Fast Node 一键部署（48Club 快照 ~415GB + Docker）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

SKIP_DOWNLOAD=false
SKIP_DOCKER=false
BG_DOWNLOAD=false

usage() {
  cat <<'EOF'
用法: bash scripts/deploy.sh [选项]

一键部署 BSC Fast Node（默认模式，约 415GB 快照）

选项:
  --skip-download   跳过快照下载（已有 data/node/geth/chaindata 时使用）
  --bg-download     后台下载快照（可关闭终端，用 snapshot.sh status 查看）
  --skip-docker     只准备配置和快照，不启动容器
  -h, --help        显示帮助

示例:
  bash scripts/deploy.sh                  # 完整部署（前台下载快照）
  bash scripts/deploy.sh --bg-download    # 后台下载快照，不阻塞终端
  bash scripts/deploy.sh --skip-download  # 快照已存在，直接启动
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
echo " BSC Fast Node 一键部署"
echo " 目录: ${ROOT_DIR}"
echo "============================================"
echo ""

# ── 1. 检查依赖 ──────────────────────────────
echo "[1/5] 检查依赖..."
MISSING=()
for cmd in docker curl unzip; do
  command -v "${cmd}" &>/dev/null || MISSING+=("${cmd}")
done
if ! docker compose version &>/dev/null; then
  MISSING+=("docker compose")
fi
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "缺少依赖: ${MISSING[*]}" >&2
  echo "请先安装: docker、docker compose plugin、curl、unzip" >&2
  exit 1
fi

if ! ${SKIP_DOWNLOAD}; then
  if ! command -v zstd &>/dev/null; then
    echo "缺少 zstd（解压快照需要），安装: sudo apt install -y zstd" >&2
    exit 1
  fi
  AVAIL_GB=$(df -BG "${ROOT_DIR}" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
  if [[ "${AVAIL_GB}" -lt 500 ]]; then
    echo "警告: 可用磁盘 ${AVAIL_GB}GB < 500GB，fast 模式建议至少 500GB" >&2
    read -r -p "是否继续？[y/N] " ans
    [[ "${ans}" =~ ^[Yy]$ ]] || exit 1
  fi
fi
echo "  ✓ 依赖 OK"

# ── 2. 初始化配置 ────────────────────────────
echo ""
echo "[2/5] 初始化 BSC 配置..."
bash scripts/setup.sh

# ── 3. 环境变量 ──────────────────────────────
echo ""
echo "[3/5] 配置 .env..."
if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "  已创建 .env（从 .env.example 复制）"
else
  echo "  使用已有 .env"
fi

# 确保 fast 模式
if grep -q '^BSC_SYNC_MODE=' .env; then
  sed -i 's/^BSC_SYNC_MODE=.*/BSC_SYNC_MODE=fast/' .env
else
  echo "BSC_SYNC_MODE=fast" >> .env
fi

# 自动填入 Tailscale IP
if command -v tailscale &>/dev/null; then
  TS_IP="$(tailscale ip -4 2>/dev/null || true)"
  if [[ -n "${TS_IP}" ]]; then
    sed -i "s/^HTTP_BIND_ADDR=.*/HTTP_BIND_ADDR=${TS_IP}/" .env
    sed -i "s/^WS_BIND_ADDR=.*/WS_BIND_ADDR=${TS_IP}/" .env
    sed -i "s|^HTTP_VHOSTS=.*|HTTP_VHOSTS=localhost,127.0.0.1,${TS_IP}|" .env
    echo "  已自动设置 Tailscale IP: ${TS_IP}"
  fi
fi

# shellcheck disable=SC1091
set -a
source .env
set +a
NAT_EXTIP="${NAT_EXTIP:-}"
echo "  BSC_SYNC_MODE=${BSC_SYNC_MODE}"
echo "  NAT_MODE=${NAT_MODE:-any}"
if [[ -n "${NAT_EXTIP}" ]]; then
  echo "  NAT_EXTIP=${NAT_EXTIP}"
else
  echo "  NAT_EXTIP=（未设置，NAT_MODE=any 时无需配置）"
fi
echo "  HTTP_BIND_ADDR=${HTTP_BIND_ADDR}"

# ── 4. 下载快照 ──────────────────────────────
echo ""
CHAIN_MARKER="${ROOT_DIR}/data/node/geth/chaindata/CURRENT"
if ${SKIP_DOWNLOAD}; then
  echo "[4/5] 跳过快照下载（--skip-download）"
  if [[ ! -f "${CHAIN_MARKER}" ]]; then
    echo "错误: 未找到 data/node/geth/chaindata/CURRENT，请先下载快照或去掉 --skip-download" >&2
    exit 1
  fi
  echo "  ✓ 快照已存在"
elif [[ -f "${CHAIN_MARKER}" ]]; then
  echo "[4/5] 检测到已有快照，跳过下载"
  echo "  ✓ ${CHAIN_MARKER}"
else
  echo "[4/5] 下载 48Club FastNode 快照（约 420GB）..."
  if ${BG_DOWNLOAD}; then
    bash scripts/snapshot.sh start
    echo ""
    echo "快照在后台下载中，终端可关闭。"
    echo "  查看进度: bash scripts/snapshot.sh status"
    echo "  查看日志: bash scripts/snapshot.sh log"
    echo "  完成后执行: docker compose up -d"
    SKIP_DOCKER=true
  else
    bash scripts/snapshot.sh download
  fi
fi

# ── 5. 启动节点 ──────────────────────────────
echo ""
if ${SKIP_DOCKER}; then
  echo "[5/5] 跳过 Docker 启动（--skip-docker）"
else
  echo "[5/5] 拉取镜像并启动容器..."
  docker compose pull
  docker compose up -d
  sleep 3
  docker compose ps
fi

echo ""
echo "============================================"
echo " 部署完成！"
echo "============================================"
echo ""
echo "后续步骤:"
if [[ -n "${NAT_EXTIP}" ]]; then
  echo "  1. 确认 frpc 已穿透 TCP/UDP 30303 → 云服务器 ${NAT_EXTIP}"
else
  echo "  1. 家用直连：路由器放行 TCP+UDP 30303（可选）；peer 少时执行 bash scripts/refresh-static-nodes.sh"
fi
echo "  2. 查看日志: docker compose logs -f"
echo "  3. 查同步状态:"
echo "       docker exec bsc-node geth attach --datadir /bsc/node --exec eth.syncing"
echo "  4. 查区块高度:"
echo "       curl -s -X POST -H 'Content-Type: application/json' \\"
echo "         --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}' \\"
echo "         http://${HTTP_BIND_ADDR}:8545"
echo "  5. 查地址余额:"
echo "       curl -s -X POST -H 'Content-Type: application/json' \\"
echo "         --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"0x地址\",\"latest\"],\"id\":1}' \\"
echo "         http://${HTTP_BIND_ADDR}:8545"
echo ""
