#!/usr/bin/env bash
# 家宽动态公网 IP：检测出口 IP 变化 → 更新 .env 的 NAT_MODE=extip / NAT_EXTIP → 重建容器
#
# 手动执行: bash scripts/update-extip.sh
# 定时执行（每 5 分钟）:
#   */5 * * * * cd /data3/bsc-node-reth && bash scripts/update-extip.sh >> data/logs/extip.log 2>&1
#
# 注意: 开启 Tailscale exit node 时查到的是出口节点 IP，不要同时使用。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

ENV_FILE="${ENV_FILE:-.env}"
IP_URLS=(${IP_URLS:-https://ip.3322.net https://api.ipify.org https://ifconfig.me})

log() { echo "$(date '+%F %T') [extip] $*"; }

[[ -f "${ENV_FILE}" ]] || { log "缺少 ${ENV_FILE}"; exit 1; }

ip=""
for url in "${IP_URLS[@]}"; do
  ip="$(curl -4 -fsS --max-time 10 "${url}" 2>/dev/null | tr -d '[:space:]')" || ip=""
  [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && break
  ip=""
done
[[ -n "${ip}" ]] || { log "获取公网 IP 失败，跳过"; exit 0; }

current_ip="$(sed -n 's/^NAT_EXTIP=//p' "${ENV_FILE}" | tail -n1)"
current_mode="$(sed -n 's/^NAT_MODE=//p' "${ENV_FILE}" | tail -n1)"

if [[ "${ip}" == "${current_ip}" && "${current_mode}" == "extip" ]]; then
  exit 0
fi

if grep -q '^NAT_MODE=' "${ENV_FILE}"; then
  sed -i.bak 's/^NAT_MODE=.*/NAT_MODE=extip/' "${ENV_FILE}"
else
  echo 'NAT_MODE=extip' >> "${ENV_FILE}"
fi
if grep -q '^NAT_EXTIP=' "${ENV_FILE}"; then
  sed -i.bak "s/^NAT_EXTIP=.*/NAT_EXTIP=${ip}/" "${ENV_FILE}"
else
  echo "NAT_EXTIP=${ip}" >> "${ENV_FILE}"
fi
rm -f "${ENV_FILE}.bak"

log "公网 IP ${current_ip:-<空>} → ${ip}，重建容器"
docker compose up -d
