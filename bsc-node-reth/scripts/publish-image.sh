#!/usr/bin/env bash
# 构建 reth-bsc 源码镜像并推送到远程仓库
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

# shellcheck disable=SC1091
[[ -f .env ]] && source .env || true

REGISTRY="${1:-${RETH_REGISTRY:-}}"
REF="${2:-${RETH_BSC_REF:-}}"

if [[ -z "${REGISTRY}" ]]; then
  echo "用法: bash scripts/publish-image.sh <registry> [ref]" >&2
  echo "  例: bash scripts/publish-image.sh ghcr.io/you/bsc-reth v0.1.2" >&2
  echo "  或 .env 设置 RETH_REGISTRY=..." >&2
  exit 1
fi

ARGS=(--push --registry "${REGISTRY}" --update-env)
[[ -n "${REF}" ]] && ARGS+=(--ref "${REF}")

exec bash scripts/build-from-source.sh "${ARGS[@]}"
