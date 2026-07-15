#!/usr/bin/env bash
# ethPandaOps Sepolia Geth 快照下载
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/data/logs"
LOG_FILE="${LOG_DIR}/snapshot-download.log"
PID_FILE="${ROOT_DIR}/data/snapshot-download.pid"
DATA_DIR="${ROOT_DIR}/data/geth"
ARCHIVE="${DATA_DIR}/snapshot.tar.zst"
CHAIN_MARKER="${DATA_DIR}/sepolia/geth/chaindata/CURRENT"
META_FILE="${ROOT_DIR}/config/snapshot-meta.json"
LATEST_URL="https://snapshots.ethpandaops.io/sepolia/geth/latest"

# 默认 curl 流式（边下边解压，不占双倍磁盘）；海外带宽好时可设 SNAPSHOT_USE_ARIA2=1
: "${SNAPSHOT_USE_ARIA2:=0}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

usage() {
  cat <<'EOF'
用法: bash scripts/snapshot.sh <命令>

命令:
  start     后台下载+解压
  status    查看进度与目录占用明细
  log       实时日志
  stop      停止后台任务
  clean     删除未完成的 snapshot.tar.zst / 部分 chaindata（交互确认）
  download  前台下载+解压
  repair    修复解压后目录层级不对

环境变量:
  SNAPSHOT_USE_ARIA2=1   用 aria2c 先下压缩包再解压（需额外 ~687GB 磁盘）

完成后: docker compose up -d
EOF
}

is_running() {
  [[ -f "${PID_FILE}" ]] || return 1
  kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

is_extract_running() {
  pgrep -f "${DATA_DIR}/snapshot.tar.zst" >/dev/null 2>&1 \
    || pgrep -f "zstd -d.*${ARCHIVE}" >/dev/null 2>&1 \
    || pgrep -f "snapshots.ethpandaops.io/sepolia/geth" >/dev/null 2>&1 \
    || pgrep -f "aria2c.*snapshot.tar.zst" >/dev/null 2>&1
}

find_chaindata_dir() {
  local found=""
  found="$(find "${DATA_DIR}" -path '*/geth/chaindata/CURRENT' -type f 2>/dev/null | head -1 || true)"
  if [[ -n "${found}" ]]; then
    dirname "$(dirname "${found}")"
    return 0
  fi
  return 1
}

fix_snapshot_layout() {
  if [[ -f "${CHAIN_MARKER}" ]]; then
    return 0
  fi

  local geth_src=""
  if ! geth_src="$(find_chaindata_dir)"; then
    return 1
  fi

  local expected="${DATA_DIR}/sepolia/geth"
  if [[ "$(readlink -f "${geth_src}")" == "$(readlink -f "${expected}")" ]]; then
    return 0
  fi

  log "[snapshot] 调整目录: ${geth_src} → ${expected}"
  mkdir -p "${DATA_DIR}/sepolia"
  if [[ -d "${expected}" ]]; then
    mv "${expected}" "${expected}.bak.$(date +%s)"
  fi
  mv "${geth_src}" "${expected}"
  [[ -f "${CHAIN_MARKER}" ]]
}

fetch_block_number() {
  curl -fsSL "${LATEST_URL}"
}

fetch_snapshot_url() {
  local block="$1"
  echo "https://snapshots.ethpandaops.io/sepolia/geth/${block}/snapshot.tar.zst"
}

print_disk_breakdown() {
  echo "  目录明细:"
  for p in "${ARCHIVE}" "${ARCHIVE}.aria2" "${DATA_DIR}/sepolia"; do
    [[ -e "${p}" ]] || continue
    du -sh "${p}" 2>/dev/null | awk -v p="${p}" '{print "    "$1"  "p}'
  done
  find "${DATA_DIR}" -maxdepth 2 -mindepth 1 -type d 2>/dev/null | while read -r d; do
    [[ "${d}" == "${DATA_DIR}/sepolia" ]] && continue
    du -sh "${d}" 2>/dev/null | awk -v p="${d}" '{print "    "$1"  "p}'
  done
}

parse_aria2_progress() {
  [[ -f "${LOG_FILE}" ]] || return 0
  grep -oE '\[[^]]+[0-9]+(\.[0-9]+)?[KMG]?i?B/[0-9]+(\.[0-9]+)?[KMG]?i?B\([0-9]+%\)[^]]*DL:[^]]+\]' "${LOG_FILE}" 2>/dev/null | tail -1 || true
}

do_download() {
  if [[ -f "${CHAIN_MARKER}" ]]; then
    log "[snapshot] 快照已存在: ${CHAIN_MARKER}"
    return 0
  fi

  mkdir -p "${DATA_DIR}" "${LOG_DIR}"
  local block url
  block="$(fetch_block_number)"
  url="$(fetch_snapshot_url "${block}")"
  log "[snapshot] 最新块高: ${block}"
  log "[snapshot] URL: ${url}"

  mkdir -p "$(dirname "${META_FILE}")"
  cat > "${META_FILE}" <<EOF
{"block": "${block}", "url": "${url}", "fetched_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF

  if [[ "${SNAPSHOT_USE_ARIA2}" == "1" ]] && command -v aria2c >/dev/null 2>&1; then
    log "[snapshot] aria2c 下载（SNAPSHOT_USE_ARIA2=1）..."
    # 无预分配，避免 ls 显示 687G 但 du 只有几 MB 的误导
    aria2c -c -x 16 -s 16 -k 1M --file-allocation=none \
      -d "$(dirname "${ARCHIVE}")" -o "$(basename "${ARCHIVE}")" "${url}"
    log "[snapshot] 解压中（流式，完成后删压缩包）..."
    if command -v zstd >/dev/null 2>&1; then
      zstd -d --long=31 -f "${ARCHIVE}" --stdout | tar -xf - -C "${DATA_DIR}"
    else
      tar -I zstd -xf "${ARCHIVE}" -C "${DATA_DIR}"
    fi
    rm -f "${ARCHIVE}" "${ARCHIVE}.aria2"
  else
    log "[snapshot] curl 流式下载+解压（推荐，不占双倍磁盘）..."
    rm -f "${ARCHIVE}" "${ARCHIVE}.aria2"
    curl -fsSL --retry 10 --retry-delay 15 --retry-all-errors "${url}" \
      | tar -I zstd -xf - -C "${DATA_DIR}"
    fix_snapshot_layout || true
    log "[snapshot] 完成"
    return 0
  fi

  rm -f "${ARCHIVE}" "${ARCHIVE}.aria2"
  fix_snapshot_layout
  log "[snapshot] 完成: ${CHAIN_MARKER}"
}

run_background() {
  mkdir -p "${LOG_DIR}"
  nohup env SNAPSHOT_USE_ARIA2="${SNAPSHOT_USE_ARIA2}" \
    bash "${ROOT_DIR}/scripts/snapshot.sh" download >> "${LOG_FILE}" 2>&1 &
  echo $! > "${PID_FILE}"
  log "[snapshot] 后台任务 PID=$(cat "${PID_FILE}"), 日志: ${LOG_FILE}"
}

cmd_clean() {
  if is_running || is_extract_running; then
    echo "[snapshot] 请先 bash scripts/snapshot.sh stop" >&2
    exit 1
  fi
  if [[ -f "${CHAIN_MARKER}" ]]; then
    echo "[snapshot] 快照已就绪，无需 clean" >&2
    exit 1
  fi
  echo "将删除未完成的下载/解压数据（不含 config/）："
  print_disk_breakdown
  read -r -p "确认？[y/N] " ans
  [[ "${ans}" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }
  rm -f "${ARCHIVE}" "${ARCHIVE}.aria2"
  rm -rf "${DATA_DIR}/sepolia" "${DATA_DIR}/geth" 2>/dev/null || true
  find "${DATA_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  rm -f "${PID_FILE}"
  log "[snapshot] 已清理，重新下载: bash scripts/snapshot.sh start"
}

cmd_status() {
  if [[ -f "${CHAIN_MARKER}" ]]; then
    echo "[snapshot] ✓ 快照就绪"
    echo "  ${CHAIN_MARKER}"
    du -sh "${DATA_DIR}/sepolia" 2>/dev/null || true
    echo "  下一步: docker compose up -d"
    return 0
  fi

  echo "[snapshot] data/geth 合计: $(du -sh "${DATA_DIR}" 2>/dev/null | awk '{print $1}' || echo '?')"
  print_disk_breakdown

  local prog
  prog="$(parse_aria2_progress)"
  if [[ -n "${prog}" ]]; then
    echo "  aria2: ${prog}"
    if echo "${prog}" | grep -qE 'DL:[0-9]+KiB'; then
      echo "  ⚠ 速度过慢（<1MiB/s），687GB 需极长时间。建议 stop → clean → 换网络或用 curl 流式重试"
    fi
  fi

  if pgrep -f "aria2c.*snapshot.tar.zst" >/dev/null 2>&1; then
    echo "[snapshot] 阶段: aria2c 下载"
  elif pgrep -f "snapshots.ethpandaops.io/sepolia/geth" >/dev/null 2>&1; then
    echo "[snapshot] 阶段: curl 流式下载+解压"
  elif pgrep -f "zstd -d.*${ARCHIVE}" >/dev/null 2>&1; then
    echo "[snapshot] 阶段: 解压"
  fi

  if is_running || is_extract_running; then
    [[ -f "${PID_FILE}" ]] && echo "  PID: $(cat "${PID_FILE}")"
    echo "  实时: bash scripts/snapshot.sh log"
    return 0
  fi

  if [[ -f "${LOG_FILE}" ]]; then
    echo "[snapshot] ✗ 无运行中任务"
    tail -5 "${LOG_FILE}" | sed 's/^/    /'
    echo "  清理重试: bash scripts/snapshot.sh clean && bash scripts/snapshot.sh start"
    return 1
  fi

  echo "[snapshot] 未开始 → bash scripts/snapshot.sh start"
}

CMD="${1:-}"
case "${CMD}" in
  start)
    [[ -f "${CHAIN_MARKER}" ]] && { log "[snapshot] 已存在，跳过"; exit 0; }
    is_running && { log "[snapshot] 已在运行"; exit 0; }
    run_background
    ;;
  download)
    do_download
    fix_snapshot_layout || true
    if [[ "$(id -u)" -eq 0 ]]; then
      chown -R 1000:1000 "${DATA_DIR}" 2>/dev/null || true
    fi
    rm -f "${PID_FILE}"
    ;;
  status) cmd_status ;;
  log)    tail -f "${LOG_FILE}" ;;
  stop)
    if is_running; then kill "$(cat "${PID_FILE}")" 2>/dev/null || true; fi
    pkill -f "aria2c.*snapshot.tar.zst" 2>/dev/null || true
    pkill -f "snapshots.ethpandaops.io/sepolia/geth" 2>/dev/null || true
    rm -f "${PID_FILE}"
    log "[snapshot] 已停止"
    ;;
  clean) cmd_clean ;;
  repair)
    fix_snapshot_layout && log "[snapshot] 目录 OK: ${CHAIN_MARKER}" \
      || { log "[snapshot] 未找到 chaindata"; exit 1; }
    ;;
  -h|--help|help) usage ;;
  *)
    echo "未知命令: ${CMD}" >&2
    usage
    exit 1
    ;;
esac
