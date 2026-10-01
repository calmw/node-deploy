#!/usr/bin/env bash
# 生成 data/reth/reth.toml（静态数据 18 个月 / state 历史 17 个月裁剪配置）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="${ROOT_DIR}/config/reth.toml.template"
DATA_RETH="${ROOT_DIR}/data/reth"
OUT="${DATA_RETH}/reth.toml"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/load-env.sh"
load_dotenv "${ROOT_DIR}/.env"

BLOCK_TIME_SEC="${BLOCK_TIME_SEC:-0.45}"

usage() {
  cat <<'EOF'
用法: bash scripts/setup.sh [命令]

命令:
  init     写入 reth.toml（默认）
  repair   重新渲染 reth.toml 并重启容器

环境变量（或 .env）:
  PRUNE_STATIC_HISTORY_MONTHS    交易/回执等静态数据保留月数（默认 18）
  PRUNE_STATE_HISTORY_MONTHS     state 历史保留月数（默认 17）
  BLOCK_TIME_SEC                 出块间隔秒数（默认 0.45，BSC Fermi 后）
  PRUNE_STATIC_HISTORY_DISTANCE  直接指定静态数据块数（覆盖月数）
  PRUNE_STATE_HISTORY_DISTANCE   直接指定 state 历史块数（覆盖月数）
EOF
}

# 月按 365.25/12 天计，向上取整到块
months_to_blocks() {
  awk -v m="$1" -v bt="${BLOCK_TIME_SEC}" 'BEGIN {
    b = m * 365.25 / 12 * 86400 / bt
    printf "%d\n", (b == int(b)) ? b : int(b) + 1
  }'
}

blocks_to_days() {
  awk -v d="$1" -v bt="${BLOCK_TIME_SEC}" 'BEGIN { printf "%.1f\n", d * bt / 86400 }'
}

warn_legacy_env() {
  if [[ -n "${PRUNE_HISTORY_DISTANCE:-}${PRUNE_HISTORY_DAYS:-}" ]]; then
    echo "[setup] 警告: .env 中 PRUNE_HISTORY_DISTANCE / PRUNE_HISTORY_DAYS 已废弃并被忽略，" >&2
    echo "[setup]       请改用 PRUNE_STATIC_HISTORY_* / PRUNE_STATE_HISTORY_*（见 .env.example）" >&2
  fi
}

write_reth_toml() {
  warn_legacy_env
  local static_dist state_dist
  static_dist="${PRUNE_STATIC_HISTORY_DISTANCE:-$(months_to_blocks "${PRUNE_STATIC_HISTORY_MONTHS:-18}")}"
  state_dist="${PRUNE_STATE_HISTORY_DISTANCE:-$(months_to_blocks "${PRUNE_STATE_HISTORY_MONTHS:-17}")}"

  mkdir -p "${DATA_RETH}"
  if [[ ! -f "${TEMPLATE}" ]]; then
    echo "[setup] 缺少 ${TEMPLATE}" >&2
    exit 1
  fi
  sed -e "s/__PRUNE_STATIC_DISTANCE__/${static_dist}/g" \
      -e "s/__PRUNE_STATE_DISTANCE__/${state_dist}/g" \
      "${TEMPLATE}" > "${OUT}"
  chmod 644 "${OUT}"
  echo "[setup] 已写入 ${OUT} @ ${BLOCK_TIME_SEC}s/块"
  echo "[setup]   静态数据（交易/回执/索引/sender）distance=${static_dist}（约 $(blocks_to_days "${static_dist}") 天）"
  echo "[setup]   state 历史（账户/存储）        distance=${state_dist}（约 $(blocks_to_days "${state_dist}") 天）"
}

cmd_init() {
  write_reth_toml
  echo ""
  echo "[setup] 下一步:"
  echo "  cp .env.example .env && 编辑 Tailscale IP"
  echo "  bash scripts/deploy.sh --bg-download   # 推荐：后台下 Reth Full 快照"
  echo "  或 bash scripts/deploy.sh --skip-download  # 已有 data/reth/db"
}

cmd_repair() {
  echo "=== 最近日志 ==="
  docker compose -f "${ROOT_DIR}/docker-compose.yml" logs --tail 30 reth 2>&1 || true
  write_reth_toml
  docker compose -f "${ROOT_DIR}/docker-compose.yml" down 2>/dev/null || true
  docker compose -f "${ROOT_DIR}/docker-compose.yml" up -d
  sleep 5
  docker compose -f "${ROOT_DIR}/docker-compose.yml" ps
}

CMD="${1:-init}"
case "${CMD}" in
  init|"") cmd_init ;;
  repair) cmd_repair ;;
  -h|--help|help) usage ;;
  *)
    echo "未知命令: ${CMD}" >&2
    usage
    exit 1
    ;;
esac
