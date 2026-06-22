#!/usr/bin/env bash
# 快照下载：start | status | log | stop | download（前台）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/data/logs"
LOG_FILE="${LOG_DIR}/snapshot-download.log"
PID_FILE="${ROOT_DIR}/data/snapshot-download.pid"
DATA_DIR="${ROOT_DIR}/data/node"
ARCHIVE="${DATA_DIR}/snapshot.tar.zst"
CHAIN_MARKER="${DATA_DIR}/geth/chaindata/CURRENT"
META_FILE="${ROOT_DIR}/config/snapshot-meta.json"
DATA_JSON_URL="https://raw.githubusercontent.com/48Club/bsc-snapshots/main/data.json"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

usage() {
  cat <<'EOF'
用法: bash scripts/snapshot.sh <命令>

命令:
  start     后台下载+解压 FastNode 快照（约 420GB，可关终端）
  status    查看进度
  log       实时日志（Ctrl+C 退出）
  stop      停止后台任务
  download  前台下载+解压（需保持终端）

完成后: docker compose up -d
EOF
}

is_running() {
  [[ -f "${PID_FILE}" ]] || return 1
  kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

do_download_fast() {
  if [[ -f "${CHAIN_MARKER}" ]]; then
    log "[snapshot] 快照已存在: ${CHAIN_MARKER}"
    return 0
  fi

  if ! command -v zstd &>/dev/null; then
    echo "[snapshot] 错误: 需要 zstd，安装: sudo apt install -y zstd" >&2
    exit 1
  fi

  mkdir -p "${DATA_DIR}" "${ROOT_DIR}/config"

  log "[snapshot] 获取最新快照地址..."
  curl -fsSL -o "${META_FILE}" "${DATA_JSON_URL}"

  read -r SNAPSHOT_URL SNAPSHOT_MD5 _ < <(
    python3 - <<'PY' "${META_FILE}"
import json, sys
m = json.load(open(sys.argv[1]))["geth"]["none"]
print(m["link"], m["md5"], m["flags"])
PY
  )

  HTTP_CODE=$(curl -sI -o /dev/null -w "%{http_code}" "${SNAPSHOT_URL}" || echo "000")
  if [[ "${HTTP_CODE}" != "200" ]]; then
    echo "[snapshot] 错误: 快照 URL 不可访问 (HTTP ${HTTP_CODE})" >&2
    echo "[snapshot] URL: ${SNAPSHOT_URL}" >&2
    exit 1
  fi

  AVAIL_GB=$(df -BG "${ROOT_DIR}" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
  log "[snapshot] 可用磁盘: ${AVAIL_GB}GB | URL: ${SNAPSHOT_URL}"

  cd "${DATA_DIR}"
  if [[ ! -f "${ARCHIVE}" ]]; then
    log "[snapshot] 开始下载（支持断点续传）..."
    if command -v aria2c &>/dev/null; then
      aria2c -s8 -x8 -k1024M -o snapshot.tar.zst "${SNAPSHOT_URL}"
    else
      wget -c -O snapshot.tar.zst "${SNAPSHOT_URL}"
    fi
  else
    log "[snapshot] 发现未解压的 snapshot.tar.zst，跳过下载"
  fi

  log "[snapshot] 开始解压（1~3 小时）..."
  if command -v pv &>/dev/null; then
    pv snapshot.tar.zst | tar --use-compress-program="zstd -d --long=31" -xf -
  else
    tar --use-compress-program="zstd -d --long=31" -xf snapshot.tar.zst
  fi
  rm -f snapshot.tar.zst

  if [[ ! -f "${CHAIN_MARKER}" ]]; then
    echo "[snapshot] 错误: 解压后未找到 geth/chaindata/CURRENT" >&2
    exit 1
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R 1000:1000 "${ROOT_DIR}/data"
  fi
  log "[snapshot] ✓ 快照就绪"
}

cmd_start() {
  if [[ -f "${CHAIN_MARKER}" ]]; then
    echo "[snapshot] 快照已存在，无需下载"
    exit 0
  fi
  if is_running; then
    echo "[snapshot] 已在运行 (PID $(cat "${PID_FILE}"))"
    exit 0
  fi
  mkdir -p "${LOG_DIR}" "${DATA_DIR}"
  nohup bash "${BASH_SOURCE[0]}" download >> "${LOG_FILE}" 2>&1 &
  echo $! > "${PID_FILE}"
  sleep 1
  echo "[snapshot] 后台运行 (PID $(cat "${PID_FILE}"))，日志: ${LOG_FILE}"
}

cmd_status() {
  if [[ -f "${CHAIN_MARKER}" ]]; then
    echo "状态: ✓ 已完成 → docker compose up -d"
    return 0
  fi
  if is_running; then
    echo "状态: 运行中 (PID $(cat "${PID_FILE}"))"
  else
    echo "状态: 未启动 → bash scripts/snapshot.sh start"
    return 0
  fi
  [[ -f "${ARCHIVE}" ]] && echo "文件: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
  echo "--- 最近日志 ---"
  tail -8 "${LOG_FILE}" 2>/dev/null || true
}

cmd_log() {
  [[ -f "${LOG_FILE}" ]] || { echo "先运行: bash scripts/snapshot.sh start"; exit 1; }
  tail -f "${LOG_FILE}"
}

cmd_stop() {
  if is_running; then
    kill "$(cat "${PID_FILE}")" 2>/dev/null || true
    sleep 2
    kill -9 "$(cat "${PID_FILE}")" 2>/dev/null || true
  fi
  rm -f "${PID_FILE}"
  echo "[snapshot] 已停止（已下载部分保留，可断点续传）"
}

CMD="${1:-}"
case "${CMD}" in
  start)    cmd_start ;;
  status)   cmd_status ;;
  log)      cmd_log ;;
  stop)     cmd_stop ;;
  download) do_download_fast ;;
  -h|--help|help) usage ;;
  *)
    echo "未知命令: ${CMD}" >&2
    usage
    exit 1
    ;;
esac
