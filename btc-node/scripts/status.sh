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

echo
echo "=== 区块链同步 ==="
"$ROOT_DIR/scripts/btc-cli.sh" getblockchaininfo \
  | grep -E '"chain"|"blocks"|"headers"|"verificationprogress"|"initialblockdownload"'
