#!/usr/bin/env bash
# 从 bitcoin.conf 读取 key=value（兼容 [signet] 等段，勿用 source）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="${ROOT_DIR}/config/bitcoin.conf"

if [[ $# -lt 1 ]]; then
  echo "用法: conf-get.sh <key>" >&2
  exit 1
fi

if [[ ! -f "${CONF}" ]]; then
  exit 1
fi

grep -E "^${1}=" "${CONF}" 2>/dev/null | tail -1 | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
