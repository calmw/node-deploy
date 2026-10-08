#!/usr/bin/env bash
# 多连接分块下载官方快照，边下边解压，不保存整个压缩包（峰值临时占用 ≈ PARALLEL × CHUNK_MB）。
# 用法: sudo bash scripts/snapshot-stream.sh <快照URL> <解压目录>
# 环境变量: PARALLEL（并发连接数，默认 16）、CHUNK_MB（分块大小，默认 256）、
#           TAR_ARGS（额外 tar 参数，如官方包需 "--strip-components=2 --exclude=reth.toml"）
# 注意: zstd/tar 流不能从中间续传，进程中断后只能清空解压目录从头再来。
set -euo pipefail

URL="${1:?用法: snapshot-stream.sh <快照URL> <解压目录>}"
DEST="${2:?用法: snapshot-stream.sh <快照URL> <解压目录>}"
PARALLEL="${PARALLEL:-16}"
CHUNK=$(( ${CHUNK_MB:-256} * 1024 * 1024 ))
WORK="${DEST}/.snapshot-stream"
read -ra EXTRA_TAR_ARGS <<<"${TAR_ARGS:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }

SIZE=$(curl -sfIL --max-time 30 "${URL}" | tr -d '\r' \
  | awk 'tolower($1)=="content-length:" {n=$2} END {print n}')
[[ "${SIZE}" =~ ^[0-9]+$ ]] || { log "取不到文件大小: ${URL}"; exit 1; }
TOTAL=$(( (SIZE + CHUNK - 1) / CHUNK ))

mkdir -p "${DEST}"
rm -rf "${WORK}"
mkdir -p "${WORK}"

fetch() {
  local i=$1
  local start=$(( i * CHUNK ))
  local end=$(( start + CHUNK - 1 ))
  (( end < SIZE )) || end=$(( SIZE - 1 ))
  local want=$(( end - start + 1 ))
  local part="${WORK}/${i}.part"
  until curl -sf --connect-timeout 20 --speed-time 60 --speed-limit 10240 \
          -r "${start}-${end}" -o "${part}" "${URL}" \
        && [[ $(wc -c <"${part}") -eq ${want} ]]; do
    sleep 5
  done
  mv "${part}" "${WORK}/${i}"
}

produce() {
  trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
  local next=0 i started
  started=$(date +%s)
  for (( i = 0; i < TOTAL; i++ )); do
    while (( next < TOTAL && next < i + PARALLEL )); do
      fetch "${next}" >/dev/null 2>&1 &
      next=$(( next + 1 ))
    done
    until [[ -f "${WORK}/${i}" ]]; do sleep 1; done
    cat "${WORK}/${i}"
    rm -f "${WORK}/${i}"
    if (( (i + 1) % 40 == 0 || i + 1 == TOTAL )); then
      local done_b=$(( (i + 1) * CHUNK )) elapsed=$(( $(date +%s) - started ))
      (( done_b < SIZE )) || done_b=${SIZE}
      log "$(( i + 1 ))/${TOTAL} 块，$(( done_b * 100 / SIZE ))%，平均 $(( done_b / (elapsed + 1) / 1048576 )) MiB/s"
    fi
  done
  wait
}

log "开始: ${URL}"
log "大小 $(( SIZE / 1073741824 )) GiB，${TOTAL} 块 × $(( CHUNK / 1048576 )) MiB，并发 ${PARALLEL}，解压到 ${DEST}"
produce | zstd -dc --long=31 | tar -xf - -C "${DEST}" ${EXTRA_TAR_ARGS[@]+"${EXTRA_TAR_ARGS[@]}"}
rmdir "${WORK}"
log "完成"
