#!/usr/bin/env bash
# 从 bnb-chain/reth-bsc 源码构建本地 Docker 镜像（或宿主机二进制）
#
# 用法:
#   bash scripts/build-from-source.sh                    # 默认：最新 release + Docker
#   bash scripts/build-from-source.sh --ref v0.1.2
#   bash scripts/build-from-source.sh --method native
#   bash scripts/build-from-source.sh --update-env         # 写入 .env 的 RETH_IMAGE
#   bash scripts/build-from-source.sh --push --registry ghcr.io/you/bsc-reth
#   bash scripts/build-from-source.sh --no-cache
#
# 环境变量:
#   RETH_BSC_REPO    默认 https://github.com/bnb-chain/reth-bsc.git
#   RETH_BSC_REF     覆盖 --ref（tag / branch）
#   RETH_LOCAL_IMAGE 默认 bsc-reth-local
#   RETH_REGISTRY    远程仓库前缀（与 --push 合用）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="${ROOT_DIR}/.build/reth-bsc"
REPO="${RETH_BSC_REPO:-https://github.com/bnb-chain/reth-bsc.git}"
IMAGE_BASE="${RETH_LOCAL_IMAGE:-bsc-reth-local}"
METHOD=docker
REF=""
UPDATE_ENV=false
DO_PUSH=false
REGISTRY="${RETH_REGISTRY:-}"
NO_CACHE=""

usage() {
  cat <<'EOF'
用法: bash scripts/build-from-source.sh [选项]

从 GitHub 拉取 reth-bsc 源码并构建（默认对齐最新 GitHub Release tag）。

选项:
  --ref <tag|branch>   指定版本，如 v0.1.2、main（默认：自动取 latest release）
  --method docker      使用仓库 Dockerfile 构建镜像（默认，推荐）
  --method native      宿主机 cargo maxperf，再打最小运行时镜像
  --update-env         构建成功后设置 .env 中 RETH_IMAGE=<镜像>:<ref>
  --push               构建后 push 到 --registry / RETH_REGISTRY
  --registry <name>    远程镜像名，如 ghcr.io/org/bsc-reth
  --no-cache           docker build 不使用缓存
  -h, --help

示例:
  bash scripts/build-from-source.sh --ref v0.1.2 --update-env
  bash scripts/build-from-source.sh --push --registry ghcr.io/you/bsc-reth --update-env
  docker compose down && docker compose up -d

注意:
  - Docker 构建约 30–90 分钟，磁盘建议 ≥ 30GB 空闲（含 target 缓存）
  - 从 GHCR latest (1.1.1) 升到 v0.1.x 可能需 db migrate-v2，见 reth-bsc MIGRATE_V2.md
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) REF="$2"; shift 2 ;;
    --method) METHOD="$2"; shift 2 ;;
    --update-env) UPDATE_ENV=true; shift ;;
    --push) DO_PUSH=true; shift ;;
    --registry) REGISTRY="$2"; shift 2 ;;
    --no-cache) NO_CACHE="--no-cache"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

log() { printf '[build-reth] %s\n' "$*"; }

fetch_latest_release_tag() {
  curl -fsSL "https://api.github.com/repos/bnb-chain/reth-bsc/releases/latest" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])"
}

resolve_ref() {
  if [[ -n "${RETH_BSC_REF:-}" ]]; then
    echo "${RETH_BSC_REF}"
  elif [[ -n "${REF}" ]]; then
    echo "${REF}"
  else
    fetch_latest_release_tag
  fi
}

check_prereqs() {
  local missing=()
  command -v git >/dev/null || missing+=("git")
  command -v curl >/dev/null || missing+=("curl")
  command -v python3 >/dev/null || missing+=("python3")
  if [[ "${METHOD}" == "docker" ]]; then
    command -v docker >/dev/null || missing+=("docker")
  else
    command -v cargo >/dev/null || missing+=("rust/cargo")
    command -v clang >/dev/null || missing+=("clang")
    command -v docker >/dev/null || missing+=("docker")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "[build-reth] 缺少依赖: ${missing[*]}" >&2
    [[ " ${missing[*]} " == *" rust/cargo "* ]] && echo "  安装 Rust: https://rustup.rs" >&2
    [[ " ${missing[*]} " == *" clang "* ]] && echo "  Debian/Ubuntu: sudo apt install -y clang libclang-dev pkg-config build-essential" >&2
    exit 1
  fi
}

clone_source() {
  local ref="$1"
  mkdir -p "${ROOT_DIR}/.build"
  if [[ -d "${SRC_DIR}/.git" ]]; then
    log "更新源码 ${SRC_DIR} → ${ref}"
    git -C "${SRC_DIR}" fetch --depth 1 origin "refs/tags/${ref}:refs/tags/${ref}" 2>/dev/null \
      || git -C "${SRC_DIR}" fetch --depth 1 origin "${ref}"
    git -C "${SRC_DIR}" checkout -f "${ref}"
    git -C "${SRC_DIR}" reset --hard "FETCH_HEAD" 2>/dev/null || git -C "${SRC_DIR}" reset --hard "${ref}"
  else
    log "克隆 ${REPO} (${ref})"
    rm -rf "${SRC_DIR}"
    if git ls-remote --exit-code --tags "${REPO}" "refs/tags/${ref}" &>/dev/null; then
      git clone --depth 1 --branch "${ref}" "${REPO}" "${SRC_DIR}"
    else
      git clone --depth 1 --branch "${ref}" "${REPO}" "${SRC_DIR}" \
        || git clone --depth 1 "${REPO}" "${SRC_DIR}"
      git -C "${SRC_DIR}" checkout -f "${ref}"
    fi
  fi
  log "当前源码: $(git -C "${SRC_DIR}" describe --tags --always 2>/dev/null || git -C "${SRC_DIR}" rev-parse --short HEAD)"
}

build_docker() {
  local ref="$1"
  local tag="${IMAGE_BASE}:${ref}"
  [[ -f "${SRC_DIR}/Dockerfile" ]] || { echo "[build-reth] 源码中无 Dockerfile" >&2; exit 1; }
  log "Docker 构建 ${tag}（profile=maxperf，约 30–90 分钟）..."
  docker build ${NO_CACHE} \
    -f "${SRC_DIR}/Dockerfile" \
    --build-arg BUILD_PROFILE=maxperf \
    --build-arg FEATURES=jemalloc,asm-keccak \
    --build-arg RUSTFLAGS=-C target-cpu=native \
    -t "${tag}" \
    "${SRC_DIR}"
  docker tag "${tag}" "${IMAGE_BASE}:latest"
  log "✓ 镜像: ${tag} 与 ${IMAGE_BASE}:latest"
  echo "${tag}"
}

build_native() {
  local ref="$1"
  local tag="${IMAGE_BASE}:${ref}"
  log "宿主机 cargo maxperf 构建..."
  cd "${SRC_DIR}"
  export RUSTFLAGS="-C target-cpu=native"
  make maxperf
  local bin="${SRC_DIR}/target/maxperf/reth-bsc"
  [[ -x "${bin}" ]] || { echo "[build-reth] 未找到 ${bin}" >&2; exit 1; }
  "${bin}" --version || true

  local ctx="${ROOT_DIR}/.build/docker-native"
  rm -rf "${ctx}"
  mkdir -p "${ctx}"
  cp "${bin}" "${ctx}/reth-bsc"
  cat > "${ctx}/Dockerfile" <<'DOCKERFILE'
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY reth-bsc /usr/local/bin/reth-bsc
RUN ln -sf /usr/local/bin/reth-bsc /usr/local/bin/bsc-reth
WORKDIR /data
DOCKERFILE
  log "打包最小运行时镜像 ${tag}..."
  docker build ${NO_CACHE} -t "${tag}" "${ctx}"
  docker tag "${tag}" "${IMAGE_BASE}:latest"
  log "✓ 镜像: ${tag}"
  echo "${tag}"
}

update_env() {
  local tag="$1"
  local env_file="${ROOT_DIR}/.env"
  [[ -f "${env_file}" ]] || cp "${ROOT_DIR}/.env.example" "${env_file}"
  if grep -q '^RETH_IMAGE=' "${env_file}"; then
    sed -i.bak "s|^RETH_IMAGE=.*|RETH_IMAGE=${tag}|" "${env_file}"
    rm -f "${env_file}.bak"
  else
    echo "RETH_IMAGE=${tag}" >> "${env_file}"
  fi
  if grep -q '^RETH_COMPOSE_PULL=' "${env_file}"; then
    sed -i.bak 's/^RETH_COMPOSE_PULL=.*/RETH_COMPOSE_PULL=false/' "${env_file}"
    rm -f "${env_file}.bak"
  else
    echo "RETH_COMPOSE_PULL=false" >> "${env_file}"
  fi
  log "已写入 ${env_file}: RETH_IMAGE=${tag}"
}

push_remote() {
  local ref="$1"
  local local_tag="$2"
  [[ -n "${REGISTRY}" ]] || { echo "[build-reth] --push 需要 --registry 或 RETH_REGISTRY" >&2; exit 1; }
  local remote_ref="${REGISTRY}:${ref}"
  local remote_latest="${REGISTRY}:latest"
  docker tag "${local_tag}" "${remote_ref}"
  docker tag "${local_tag}" "${remote_latest}"
  log "推送 ${remote_ref} ..."
  docker push "${remote_ref}"
  log "推送 ${remote_latest} ..."
  docker push "${remote_latest}"
  log "✓ 已上传 ${remote_ref}"
  echo "${remote_ref}"
}

main() {
  check_prereqs
  local ref
  ref="$(resolve_ref)"
  log "目标版本: ${ref} | 方式: ${METHOD}"
  clone_source "${ref}"

  local image_tag
  case "${METHOD}" in
    docker) image_tag="$(build_docker "${ref}")" ;;
    native) image_tag="$(build_native "${ref}")" ;;
    *)
      echo "[build-reth] 未知 --method: ${METHOD}" >&2
      exit 1
      ;;
  esac

  local final_tag="${image_tag}"
  if ${DO_PUSH}; then
    final_tag="$(push_remote "${ref}" "${image_tag}")"
  fi

  if ${UPDATE_ENV}; then
    update_env "${final_tag}"
  else
    echo ""
    log "下一步: 在 .env 中设置 RETH_IMAGE=${final_tag}"
    log "  docker compose down && docker compose up -d"
  fi
}

main
