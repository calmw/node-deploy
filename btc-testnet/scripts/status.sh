#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "=== 容器状态 ==="
docker compose ps

if ! docker compose ps --status running 2>/dev/null | grep -q bitcoind; then
  echo
  echo "bitcoind 未在运行。启动：./scripts/start.sh"
  exit 0
fi

CLI="${ROOT_DIR}/scripts/btc-cli.sh"

echo
echo "=== Signet 同步（RPC）==="
INFO="$("${CLI}" -rpcwait getblockchaininfo 2>/dev/null || true)"
if [[ -z "${INFO}" ]]; then
  echo "RPC 尚未就绪，请稍后再试"
  exit 0
fi

echo "${INFO}" | grep -E '"chain"|"blocks"|"headers"|"verificationprogress"|"initialblockdownload"|"pruned"|"size_on_disk"'

HEADERS="$(echo "${INFO}" | grep -oE '"headers": [0-9]+' | grep -oE '[0-9]+' || echo 0)"
IBD="$(echo "${INFO}" | grep -oE '"initialblockdownload": (true|false)' | grep -oE 'true|false' || echo true)"

echo
echo "=== 网络 ==="
CONN="$("${CLI}" getconnectioncount 2>/dev/null || echo "?")"
echo "connections: ${CONN}"

MAX_PEER="$("${CLI}" getpeerinfo 2>/dev/null | python3 -c "import json,sys; p=json.load(sys.stdin); print(max([x.get('startingheight',0) for x in p], default=0))" 2>/dev/null || echo 0)"
[[ -n "${MAX_PEER}" && "${MAX_PEER}" != "0" ]] && echo "peer 最高高度: ${MAX_PEER}"

PRESYNC="$(docker compose logs --tail=500 bitcoind 2>&1 | grep 'Pre-synchronizing blockheaders' | tail -1 || true)"
if [[ -n "${PRESYNC}" ]]; then
  echo
  echo "=== header 预同步（日志）==="
  echo "${PRESYNC#*bitcoind-signet  | }"
fi

if [[ "${IBD}" == "true" && "${HEADERS}" == "0" ]]; then
  echo
  if [[ -n "${PRESYNC}" ]]; then
    echo "提示: Core 31 预同步时 RPC 的 headers/blocks 可能仍为 0，以日志为准。"
  elif [[ "${CONN}" == "0" ]]; then
    echo "提示: 无 peer，检查出站网络与 config/bitcoin.conf（onlynet=ipv4、addnode）。"
  elif [[ "${MAX_PEER}" -gt 0 ]]; then
    echo "提示: 有 peer 但无预同步日志，稍等或查看：docker compose logs --tail=100 bitcoind"
  fi
  echo "  docker compose logs --tail=500 bitcoind | grep 'Pre-synchronizing'"
fi
