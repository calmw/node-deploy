#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p config
if [[ -d config/bitcoin.conf ]]; then
  echo "警告: config/bitcoin.conf 是目录（未 setup 就 compose up 会导致），正在删除..."
  rm -rf config/bitcoin.conf
fi

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "已创建 .env"
fi

if [[ ! -f config/bitcoin.conf ]]; then
  cp config/bitcoin.conf.example config/bitcoin.conf
  if command -v openssl >/dev/null 2>&1; then
    PASS="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
    if [[ "$(uname)" == "Darwin" ]]; then
      sed -i '' "s/CHANGE_ME_TO_A_STRONG_PASSWORD/${PASS}/" config/bitcoin.conf
    else
      sed -i "s/CHANGE_ME_TO_A_STRONG_PASSWORD/${PASS}/" config/bitcoin.conf
    fi
    echo "已生成随机 RPC 密码并写入 config/bitcoin.conf"
  else
    echo "请手动编辑 config/bitcoin.conf 中的 rpcpassword"
  fi
else
  echo "config/bitcoin.conf 已存在，跳过"
fi

chmod +x "$ROOT_DIR"/scripts/*.sh 2>/dev/null || true

echo
echo "初始化完成。下一步："
echo "  ./scripts/start.sh"
echo "  ./scripts/start.sh -f   # 启动并跟踪日志"
