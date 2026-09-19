#!/usr/bin/env bash
# BSC Reth 官方 Full 快照（单文件 .tar.zst，约 3.23 TiB）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/data/logs"
LOG_FILE="${LOG_DIR}/reth-snapshot-download.log"
PID_FILE="${ROOT_DIR}/data/reth-snapshot-download.pid"
DATA_DIR="${ROOT_DIR}/data/reth"
ARCHIVE="${DATA_DIR}/snapshot.tar.zst"

# shellcheck disable=SC1091
[[ -f "${ROOT_DIR}/.env" ]] && source "${ROOT_DIR}/.env" || true
SNAPSHOT_URL="${RETH_SNAPSHOT_URL:-https://pub-c5400abe5bed4adbaf8cd47467747e74.r2.dev/20260902_mainnet_reth_mdbx_full_node_v2.tar.zst}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

usage() {
  cat <<'EOF'
用法: bash scripts/snapshot.sh <命令>

命令:
  start     后台下载并解压到 data/reth/
  status    查看进度
  log       实时日志
  stop      停止后台任务
  download  前台下载+解压

前置: 可用磁盘建议 ≥ 3.5TB（4TB 盘请确保无其他大文件）
完成后: bash scripts/setup.sh && docker compose up -d

快照说明: 官方 Full 快照为 Reth --full 形态导出；导入后靠 reth.toml 的
distance 在运行中滚动保留约 1 年。快照内更早的历史 state 可能仍不足 1 年，
节点追块并运行满窗口后，查询范围才稳定为「链头往前 ~365 天」。
EOF
}

has_reth_data() {
  [[ -d "${DATA_DIR}/db" ]] && [[ -d "${DATA_DIR}/static_files" ]]
}

is_running() {
  [[ -f "${PID_FILE}" ]] || return 1
  kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

do_extract() {
  if ! command -v zstd >/dev/null; then
    echo "[snapshot] 需要 zstd: sudo apt install -y zstd" >&2
    exit 1
  fi
  mkdir -p "${DATA_DIR}"
  log "[snapshot] 解压到 ${DATA_DIR} ..."
  cd "${DATA_DIR}"
  if command -v pv >/dev/null; then
    pv snapshot.tar.zst | zstd -d --long=31 | tar -xf -
  else
    zstd -d --long=31 snapshot.tar.zst | tar -xf -
  fi
  rm -f snapshot.tar.zst
  if has_reth_data; then
    log "[snapshot] ✓ db/ + static_files/ 就绪"
  else
    echo "[snapshot] 错误: 解压后未找到 db/ 或 static_files/" >&2
    exit 1
  fi
}

do_download() {
  if has_reth_data; then
    log "[snapshot] 已有 Reth 数据，跳过"
    return 0
  fi
  if ! command -v zstd >/dev/null; then
    echo "[snapshot] 需要 zstd" >&2
    exit 1
  fi
  mkdir -p "${DATA_DIR}" "${LOG_DIR}"
  AVAIL_GB=$(df -BG "${ROOT_DIR}" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
  if [[ "${AVAIL_GB}" -lt 3500 ]]; then
    echo "[snapshot] 警告: 可用 ${AVAIL_GB}GB < 3500GB，4TB 盘可能不足" >&2
    read -r -p "继续？[y/N] " ans
    [[ "${ans}" =~ ^[Yy]$ ]] || exit 1
  fi
  log "[snapshot] URL: ${SNAPSHOT_URL}"
  cd "${DATA_DIR}"
  if [[ -f snapshot.tar.zst ]]; then
    log "[snapshot] 发现未解压的 snapshot.tar.zst，跳过下载"
  else
    log "[snapshot] 开始下载（支持断点）..."
    if command -v aria2c >/dev/null; then
      aria2c -c -x8 -s8 -o snapshot.tar.zst "${SNAPSHOT_URL}"
    else
      wget -c -O snapshot.tar.zst "${SNAPSHOT_URL}"
    fi
  fi
  do_extract
}

run_bg() {
  mkdir -p "${LOG_DIR}"
  if is_running; then
    echo "[snapshot] 已在运行 PID $(cat "${PID_FILE}")"
    exit 0
  fi
  nohup bash "${ROOT_DIR}/scripts/snapshot.sh" download >>"${LOG_FILE}" 2>&1 &
  echo $! >"${PID_FILE}"
  echo "[snapshot] 后台 PID $(cat "${PID_FILE}")，日志: ${LOG_FILE}"
}

case "${1:-}" in
  start) run_bg ;;
  download) do_download ;;
  status)
    if has_reth_data; then
      echo "状态: ✓ data/reth/db + static_files 已就绪"
      du -sh "${DATA_DIR}" 2>/dev/null || true
    elif [[ -f "${ARCHIVE}" ]]; then
      echo "状态: 已下载待解压 → bash scripts/snapshot.sh download"
      ls -lh "${ARCHIVE}"
    elif is_running; then
      echo "状态: 下载/解压中 PID $(cat "${PID_FILE}")"
      tail -3 "${LOG_FILE}" 2>/dev/null || true
    else
      echo "状态: 未开始 → bash scripts/snapshot.sh start"
    fi
    ;;
  log)
    [[ -f "${LOG_FILE}" ]] || { echo "先 bash scripts/snapshot.sh start"; exit 1; }
    tail -f "${LOG_FILE}"
    ;;
  stop)
    if is_running; then
      kill "$(cat "${PID_FILE}")" 2>/dev/null || true
      rm -f "${PID_FILE}"
      echo "[snapshot] 已停止（已下载部分保留）"
    else
      echo "[snapshot] 无后台任务"
    fi
    ;;
  -h|--help|help|"") usage ;;
  *)
    echo "未知命令: $1" >&2
    usage
    exit 1
    ;;
esac
