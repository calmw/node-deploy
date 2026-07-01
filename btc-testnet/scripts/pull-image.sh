#!/usr/bin/env bash
# 拉取 bitcoind 镜像；失败时尝试多个镜像加速，或本地从 bitcoincore.org 构建
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DO_BUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build|-b) DO_BUILD=1; shift ;;
    -h|--help)
      cat <<EOF
用法: ./scripts/pull-image.sh [--build]

  默认：依次尝试 Docker Hub 与多个镜像加速前缀
  --build：跳过拉取，直接从 bitcoincore.org 本地构建（约 90MB 下载）
EOF
      exit 0
      ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

[[ -f .env ]] && set -a && source .env && set +a

VERSION="${BITCOIN_VERSION:-31.0}"
CANONICAL_IMAGE="bitcoin/bitcoin:${VERSION}"
TARGET_IMAGE="${BITCOIN_IMAGE:-${CANONICAL_IMAGE}}"

print_help() {
  cat <<EOF
镜像拉取失败。DaoCloud 等公益加速近年常 403/限流，可尝试：

  1. 本地构建（推荐，不依赖 Docker Hub）：
       ./scripts/pull-image.sh --build
       ./scripts/start.sh -f

  2. 配置 Docker registry-mirrors 后重启 Docker，再重试：
       "registry-mirrors": [
         "https://docker.1ms.run",
         "https://docker.1panel.live",
         "https://docker.xuanyuan.me"
       ]
     然后：docker pull ${CANONICAL_IMAGE}

  3. 手动指定可用加速前缀（成功后再 start）：
       docker pull docker.1ms.run/bitcoin/bitcoin:${VERSION}
       docker tag docker.1ms.run/bitcoin/bitcoin:${VERSION} ${CANONICAL_IMAGE}

  4. 阿里云 ACR 个人加速（较稳定）：控制台开通后把专属地址写入 registry-mirrors

  5. docker login（提高 Docker Hub 拉取限额，有时可缓解 reset）
EOF
}

try_pull() {
  local image="$1"
  echo "拉取 ${image} ..."
  docker pull "${image}"
}

tag_canonical() {
  local source="$1"
  if [[ "${source}" != "${CANONICAL_IMAGE}" ]]; then
    docker tag "${source}" "${CANONICAL_IMAGE}"
    echo "已标记为 ${CANONICAL_IMAGE}"
  fi
}

build_image() {
  echo "本地构建 ${CANONICAL_IMAGE}（bitcoincore.org 官方二进制）..."
  if docker build \
    --build-arg "BITCOIN_VERSION=${VERSION}" \
    -t "${CANONICAL_IMAGE}" \
    -f "${ROOT_DIR}/Dockerfile" \
    "${ROOT_DIR}"; then
    echo "构建完成: ${CANONICAL_IMAGE}"
    return 0
  fi
  echo "本地构建失败" >&2
  return 1
}

if docker image inspect "${CANONICAL_IMAGE}" >/dev/null 2>&1 && [[ "${DO_BUILD}" -eq 0 ]]; then
  echo "镜像已存在: ${CANONICAL_IMAGE}"
  exit 0
fi

if [[ "${DO_BUILD}" -eq 1 ]]; then
  build_image
  exit $?
fi

if try_pull "${TARGET_IMAGE}"; then
  tag_canonical "${TARGET_IMAGE}"
  echo "镜像就绪: ${CANONICAL_IMAGE}"
  exit 0
fi

# 未显式指定 BITCOIN_IMAGE 时，尝试多个镜像加速前缀
if [[ -z "${BITCOIN_IMAGE:-}" ]]; then
  MIRRORS=(
    "docker.1ms.run/bitcoin/bitcoin:${VERSION}"
    "docker.1panel.live/bitcoin/bitcoin:${VERSION}"
    "docker.xuanyuan.me/bitcoin/bitcoin:${VERSION}"
  )
  for mirror in "${MIRRORS[@]}"; do
    echo
    if try_pull "${mirror}"; then
      tag_canonical "${mirror}"
      exit 0
    fi
    echo "失败: ${mirror}"
  done
fi

echo
echo "所有拉取方式均失败。"
if [[ "${BITCOIN_BUILD_ON_FAIL:-0}" == "1" ]]; then
  echo "尝试本地构建..."
  build_image && exit 0
fi

print_help
exit 1
