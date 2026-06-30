#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

FOLLOW_LOGS=0
if [[ "${1:-}" == "-f" || "${1:-}" == "--follow" ]]; then
  FOLLOW_LOGS=1
fi

if [[ ! -f config/bitcoin.conf ]]; then
  echo "未找到 config/bitcoin.conf，先运行初始化..."
  "$ROOT_DIR/scripts/setup.sh"
fi

if docker volume inspect btc-testnet-data >/dev/null 2>&1; then
  docker run --rm -v btc-testnet-data:/data alpine rm -f /data/bitcoin.conf 2>/dev/null || true
fi

echo "启动 Bitcoin Signet 节点..."
docker compose up -d

echo
docker compose ps

if [[ "$FOLLOW_LOGS" -eq 1 ]]; then
  echo
  echo "跟踪日志（Ctrl+C 退出，不会停止节点）..."
  docker compose logs -f bitcoind
else
  echo
  echo "节点已在后台运行。常用命令："
  echo "  ./scripts/status.sh"
  echo "  ./scripts/show-rpc-info.sh"
  echo "  ./scripts/stop.sh"
  echo "  ./scripts/btc-cli.sh getblockchaininfo"
  if [[ -f .env ]]; then
    # shellcheck disable=SC1091
    source .env
    if [[ "${RPC_BIND_ADDR:-127.0.0.1}" != "127.0.0.1" ]]; then
      echo
      "$ROOT_DIR/scripts/show-rpc-info.sh"
    fi
  fi
fi
