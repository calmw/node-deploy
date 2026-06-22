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
  repair    修复已解压但目录不对的数据（如 geth.fast/geth/...）

完成后: docker compose up -d
EOF
}

is_running() {
  [[ -f "${PID_FILE}" ]] || return 1
  kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

is_extract_running() {
  pgrep -f "${DATA_DIR}/snapshot.tar.zst" >/dev/null 2>&1 \
    || pgrep -f "zstd -d --long=31" >/dev/null 2>&1 \
    || pgrep -f "tar --use-compress-program.*snapshot.tar.zst" >/dev/null 2>&1
}

find_chaindata_dir() {
  local found=""
  found="$(find "${DATA_DIR}" -path '*/geth/chaindata/CURRENT' -type f 2>/dev/null | head -1 || true)"
  if [[ -n "${found}" ]]; then
    dirname "$(dirname "${found}")"  # .../geth
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

  local expected_geth="${DATA_DIR}/geth"
  if [[ "$(readlink -f "${geth_src}")" == "$(readlink -f "${expected_geth}")" ]]; then
    return 0
  fi

  log "[snapshot] 检测到非标准目录 ${geth_src}，移动到 ${expected_geth} ..."
  if [[ -d "${expected_geth}" ]]; then
    log "[snapshot] 备份已有 ${expected_geth} → ${expected_geth}.bak"
    mv "${expected_geth}" "${expected_geth}.bak.$(date +%s)"
  fi

  local parent_dir grandparent
  parent_dir="$(dirname "${geth_src}")"
  grandparent="$(basename "${parent_dir}")"
  if [[ "${parent_dir}" == "${DATA_DIR}" ]]; then
    : # already data/node/geth
  elif [[ "${grandparent}" == "geth.fast" && -d "${DATA_DIR}/geth.fast/geth" ]]; then
    mv "${DATA_DIR}/geth.fast/geth" "${expected_geth}"
    rm -rf "${DATA_DIR}/geth.fast"
  elif [[ "${grandparent}" == "fast" && -d "${DATA_DIR}/fast/geth" ]]; then
    mv "${DATA_DIR}/fast/geth" "${expected_geth}"
    rm -rf "${DATA_DIR}/fast"
  else
    mv "${geth_src}" "${expected_geth}"
    rmdir "${parent_dir}" 2>/dev/null || true
    rmdir "$(dirname "${parent_dir}")" 2>/dev/null || true
  fi

  [[ -f "${CHAIN_MARKER}" ]]
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

  if ! fix_snapshot_layout; then
    echo "[snapshot] 错误: 解压后未找到 geth/chaindata/CURRENT" >&2
    echo "[snapshot] 请检查: find ${DATA_DIR} -name CURRENT" >&2
    echo "[snapshot] 压缩包已保留: ${ARCHIVE}（修复目录后可重新解压或 bash scripts/snapshot.sh repair）" >&2
    exit 1
  fi

  rm -f snapshot.tar.zst

  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R 1000:1000 "${ROOT_DIR}/data"
  fi
  log "[snapshot] ✓ 快照就绪: ${CHAIN_MARKER}"
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

cmd_repair() {
  echo "=== 查找 chaindata/CURRENT ==="
  find "${DATA_DIR}" -path '*/geth/chaindata/CURRENT' -type f 2>/dev/null || echo "(未找到)"
  echo
  if fix_snapshot_layout; then
    if [[ "$(id -u)" -eq 0 ]]; then
      chown -R 1000:1000 "${ROOT_DIR}/data"
    fi
    echo "✓ 修复成功 → docker compose up -d"
    du -sh "${DATA_DIR}/geth" 2>/dev/null || true
  else
    echo "✗ 未找到可修复的 chaindata，需重新下载: bash scripts/snapshot.sh start" >&2
    exit 1
  fi
}

cmd_status() {
  if [[ -f "${CHAIN_MARKER}" ]]; then
    echo "状态: ✓ 已完成 → docker compose up -d"
    du -sh "${DATA_DIR}/geth" 2>/dev/null || true
    return 0
  fi

  if is_running; then
    echo "状态: 运行中 (PID $(cat "${PID_FILE}"))"
  elif is_extract_running; then
    echo "状态: 解压中（无 PID 文件，可能是前台任务或父进程已退出）"
    echo "  查看: ps aux | grep -E 'tar|zstd|snapshot'"
  elif [[ -f "${ARCHIVE}" ]]; then
    echo "状态: 下载已完成，待解压 → bash scripts/snapshot.sh start"
    echo "  （会跳过下载，直接从 snapshot.tar.zst 解压，约 1~3 小时）"
  elif [[ -d "${DATA_DIR}/geth.fast" || -d "${DATA_DIR}/fast" || -d "${DATA_DIR}/geth" ]]; then
    echo "状态: 解压不完整或目录不对 → bash scripts/snapshot.sh repair"
    find "${DATA_DIR}" -path '*/geth/chaindata/CURRENT' -type f 2>/dev/null | head -3 || true
  else
    echo "状态: 未启动 → bash scripts/snapshot.sh start"
  fi

  [[ -f "${ARCHIVE}" ]] && echo "文件: ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
  if [[ -d "${DATA_DIR}/geth" ]]; then
    echo "chaindata: 部分存在 ($(du -sh "${DATA_DIR}/geth" 2>/dev/null | cut -f1 || echo '?'))"
  fi
  du -sh "${DATA_DIR}" 2>/dev/null || true
  echo "--- 最近日志 ---"
  tail -15 "${LOG_FILE}" 2>/dev/null || echo "(无日志 ${LOG_FILE})"
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
  repair)   cmd_repair ;;
  -h|--help|help) usage ;;
  *)
    echo "未知命令: ${CMD}" >&2
    usage
    exit 1
    ;;
esac
