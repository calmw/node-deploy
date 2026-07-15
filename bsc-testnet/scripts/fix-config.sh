#!/usr/bin/env bash
# 强制重写 config.toml（不依赖 git pull / 模板文件）
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "${ROOT_DIR}/scripts/setup.sh" repair
