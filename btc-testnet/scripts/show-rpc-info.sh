#!/usr/bin/env bash
# 输出团队 RPC 连接信息（不含密码，密码由运维单独分发）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

[[ -f .env ]] && set -a && source .env && set +a

RPC_PORT="${RPC_PORT:-38332}"
RPC_BIND="${RPC_BIND_ADDR:-127.0.0.1}"
RPC_HOST="${RPC_HOST:-}"

if [[ -z "${RPC_HOST}" ]]; then
  if [[ "${RPC_BIND}" == "127.0.0.1" || "${RPC_BIND}" == "localhost" ]]; then
    RPC_HOST="127.0.0.1"
  elif [[ "${RPC_BIND}" == "0.0.0.0" ]]; then
    RPC_HOST="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    RPC_HOST="${RPC_HOST:-<服务器内网IP>}"
  else
    RPC_HOST="${RPC_BIND}"
  fi
fi

RPC_USER=""
if [[ -f config/bitcoin.conf ]]; then
  # shellcheck disable=SC1090
  source config/bitcoin.conf
  RPC_USER="${rpcuser:-btc_signet_rpc}"
fi

echo "=== Signet RPC（团队开发） ==="
echo "URL:   http://${RPC_HOST}:${RPC_PORT}/"
echo "User:  ${RPC_USER:-btc_signet_rpc}"
echo "Pass:  见 config/bitcoin.conf（勿提交 git；建议走公司密钥库分发）"
echo "Chain: signet"
echo
echo "开发机连通性测试："
echo "  bash scripts/btc-rpc-test.sh --url http://${RPC_HOST}:${RPC_PORT}/"
echo
if [[ "${RPC_BIND}" == "0.0.0.0" ]]; then
  echo "⚠ RPC 绑定 0.0.0.0：请确认云安全组/防火墙已限制 ${RPC_PORT}/tcp 仅公司 VPN 或办公网。"
elif [[ "${RPC_BIND}" == "127.0.0.1" ]]; then
  echo "ℹ RPC 仅本机可连。上云后请将 .env 的 RPC_BIND_ADDR 改为云服务器内网 IP，并配置 rpcallowip + 安全组。"
fi
