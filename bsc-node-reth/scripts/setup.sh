#!/usr/bin/env bash
# 生成 data/reth/reth.toml（约 1.5 年 state 裁剪配置）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="${ROOT_DIR}/config/reth.toml.template"
DATA_RETH="${ROOT_DIR}/data/reth"
OUT="${DATA_RETH}/reth.toml"

usage() {
  cat <<'EOF'
用法: bash scripts/setup.sh [命令]

命令:
  init     写入 reth.toml（默认）
  repair   重新渲染 reth.toml 并重启容器

环境变量（或 .env）:
  PRUNE_HISTORY_DISTANCE   直接指定块数
  PRUNE_HISTORY_DAYS       与 BLOCK_TIME_SEC 一起计算块数
  BLOCK_TIME_SEC           默认 0.45
EOF
}

calc_distance() {
  # shellcheck disable=SC1091
  [[ -f "${ROOT_DIR}/.env" ]] && source "${ROOT_DIR}/.env" || true
  if [[ -n "${PRUNE_HISTORY_DISTANCE:-}" ]]; then
    echo "${PRUNE_HISTORY_DISTANCE}"
    return
  fi
  local days="${PRUNE_HISTORY_DAYS:-548}"
  local bt="${BLOCK_TIME_SEC:-0.45}"
  python3 - "${days}" "${bt}" <<'PY'
import math, sys
days, bt = float(sys.argv[1]), float(sys.argv[2])
print(int(math.ceil(days * 86400 / bt)))
PY
}

write_reth_toml() {
  local dist
  dist="$(calc_distance)"
  mkdir -p "${DATA_RETH}/logs"
  if [[ ! -f "${TEMPLATE}" ]]; then
    echo "[setup] 缺少 ${TEMPLATE}" >&2
    exit 1
  fi
  sed "s/__PRUNE_HISTORY_DISTANCE__/${dist}/g" "${TEMPLATE}" > "${OUT}"
  chmod 644 "${OUT}"
  echo "[setup] 已写入 ${OUT}（distance=${dist}）"
  echo "[setup] 约 $(
    python3 - "${dist}" "${BLOCK_TIME_SEC:-0.45}" <<'PY'
import sys
d, bt = int(sys.argv[1]), float(sys.argv[2])
print(f"{d * bt / 86400:.1f} 天" if bt else "?")
PY
  ) @ ${BLOCK_TIME_SEC:-0.45}s/块"
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
