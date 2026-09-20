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
#   RETH_DOCKER_HUB_MIRROR  Docker Hub 镜像前缀，如 docker.1ms.run（Hub 超时时自动 retag）
#   RETH_DOCKER_HUB_MIRROR=off  禁用镜像站回退
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
  - Docker Hub 不可达时: export RETH_DOCKER_HUB_MIRROR=docker.1ms.run
  - 或宿主机编译: --method native（仅需拉一次 ubuntu 基础镜像）
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

log() { printf '[build-reth] %s\n' "$*" >&2; }

assert_image_exists() {
  local tag="$1"
  if ! docker image inspect "${tag}" >/dev/null 2>&1; then
    log "错误: 镜像不存在: ${tag}（构建或 push 未成功，已中止）"
    exit 1
  fi
}

# 去掉 Dockerfile 对 docker.io/docker/dockerfile:1.7-labs 的依赖（国内常拉不到），
# 并用 .dockerignore 替代 COPY --exclude=*
prepare_docker_build_context() {
  local ctx="${ROOT_DIR}/.build/docker-build"
  rm -rf "${ctx}"
  mkdir -p "${ctx}"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude='.git' --exclude='dist' "${SRC_DIR}/" "${ctx}/"
  else
    tar -C "${SRC_DIR}" --exclude='.git' --exclude='dist' -cf - . | tar -C "${ctx}" -xf -
  fi
  [[ -f "${ctx}/Dockerfile" ]] || { log "构建上下文中无 Dockerfile"; exit 1; }
  sed -i.bak \
    -e '1{/^# syntax=/d;}' \
    -e 's/COPY --exclude=\.git --exclude=dist \. \./COPY . ./g' \
    -e 's/COPY --exclude=dist \. \./COPY . ./g' \
    "${ctx}/Dockerfile"
  rm -f "${ctx}/Dockerfile.bak"
  cat > "${ctx}/.dockerignore" <<'EOF'
.git
dist
target
EOF
  log "已生成无 labs 语法的 Docker 构建上下文: ${ctx}"
  echo "${ctx}"
}

# 解析 Dockerfile 的 FROM，经镜像站拉取并 retag 为原名（Build 仍用原 Dockerfile 引用）
prefetch_dockerfile_base_images() {
  local dockerfile="$1"
  python3 - "${dockerfile}" <<'PY'
import os, re, subprocess, sys

dockerfile = sys.argv[1]
mirror_cfg = os.environ.get("RETH_DOCKER_HUB_MIRROR", "docker.1ms.run").strip()
mirrors = []
if mirror_cfg.lower() not in ("", "off", "none", "false", "0"):
    mirrors.append(mirror_cfg.rstrip("/"))

def log(msg: str) -> None:
    print(f"[build-reth] {msg}", file=sys.stderr)

def mirror_candidates(ref: str):
    out = []
    for m in mirrors:
        out.append(f"{m}/{ref}")
        if "/" not in ref.split("@", 1)[0]:
            out.append(f"{m}/library/{ref}")
    # 去重保序
    seen = set()
    dedup = []
    for x in out:
        if x not in seen:
            seen.add(x)
            dedup.append(x)
    return dedup

def docker_pull(ref: str) -> bool:
    p = subprocess.run(["docker", "pull", ref], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return p.returncode == 0

def pull_with_fallback(ref: str) -> None:
    if docker_pull(ref):
        log(f"已拉取 {ref}")
        return
    log(f"直连 Docker Hub 失败: {ref}，尝试镜像站…")
    for cand in mirror_candidates(ref):
        if docker_pull(cand):
            subprocess.run(["docker", "tag", cand, ref], check=True)
            log(f"✓ 经镜像站拉取并 tag 为 {ref}（来源 {cand}）")
            return
    log(f"错误: 无法拉取基础镜像 {ref}")
    if mirrors:
        log(f"  已尝试镜像前缀: {mirrors[0]}（可改 RETH_DOCKER_HUB_MIRROR 或设为 off 仅直连 Hub）")
    else:
        log("  可设置: export RETH_DOCKER_HUB_MIRROR=docker.1ms.run")
    sys.exit(1)

stages = set()
for raw in open(dockerfile):
    line = raw.strip()
    if not line.upper().startswith("FROM "):
        continue
    m = re.match(r"^FROM\s+(\S+)(?:\s+AS\s+(\S+))?", line, re.I)
    if not m:
        continue
    img, as_name = m.group(1), m.group(2)
    if img.lower() == "scratch":
        continue
    if img not in stages:
        pull_with_fallback(img)
    if as_name:
        stages.add(as_name)
    elif "/" not in img and "@" not in img and ":" not in img:
        stages.add(img)
PY
}

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
  [[ -f "${SRC_DIR}/Dockerfile" ]] || { log "源码中无 Dockerfile"; exit 1; }
  local build_ctx
  build_ctx="$(prepare_docker_build_context)"
  prefetch_dockerfile_base_images "${build_ctx}/Dockerfile"
  log "Docker 构建 ${tag}（profile=maxperf，约 30–90 分钟）..."
  # RUSTFLAGS 必须加引号，否则 -C 会被 docker 当成 CLI 选项，导致缺少 build context
  local -a build_cmd=(docker build)
  [[ -n "${NO_CACHE}" ]] && build_cmd+=("${NO_CACHE}")
  build_cmd+=(
    -f "${build_ctx}/Dockerfile"
    --build-arg BUILD_PROFILE=maxperf
    --build-arg FEATURES=jemalloc,asm-keccak
    --build-arg "RUSTFLAGS=-C target-cpu=native"
    -t "${tag}"
    "${build_ctx}"
  )
  "${build_cmd[@]}"
  assert_image_exists "${tag}"
  docker tag "${tag}" "${IMAGE_BASE}:latest"
  log "✓ 镜像: ${tag} 与 ${IMAGE_BASE}:latest"
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
  prefetch_dockerfile_base_images "${ctx}/Dockerfile"
  log "打包最小运行时镜像 ${tag}..."
  local -a build_cmd=(docker build)
  [[ -n "${NO_CACHE}" ]] && build_cmd+=("${NO_CACHE}")
  build_cmd+=(-t "${tag}" "${ctx}")
  "${build_cmd[@]}"
  assert_image_exists "${tag}"
  docker tag "${tag}" "${IMAGE_BASE}:latest"
  log "✓ 镜像: ${tag}"
}

update_env() {
  local tag="$1"
  local env_file="${ROOT_DIR}/.env"
  [[ -f "${env_file}" ]] || cp "${ROOT_DIR}/.env.example" "${env_file}"
  # 避免 tag 含 / 时 sed 误解析；用 python 写入更稳
  python3 - "${env_file}" "${tag}" <<'PY'
import sys
path, tag = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
out, found = [], False
for line in lines:
    if line.startswith("RETH_IMAGE="):
        out.append("RETH_IMAGE=" + tag)
        found = True
    else:
        out.append(line)
if not found:
    out.append("RETH_IMAGE=" + tag)
open(path, "w").write("\n".join(out) + "\n")
PY
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
  assert_image_exists "${local_tag}"
  docker tag "${local_tag}" "${remote_ref}"
  docker tag "${local_tag}" "${remote_latest}"
  log "推送 ${remote_ref} ..."
  docker push "${remote_ref}" >&2
  log "推送 ${remote_latest} ..."
  docker push "${remote_latest}" >&2
  assert_image_exists "${remote_ref}"
  log "✓ 已上传 ${remote_ref}"
}

main() {
  check_prereqs
  local ref
  ref="$(resolve_ref)"
  log "目标版本: ${ref} | 方式: ${METHOD}"
  clone_source "${ref}"

  local image_tag="${IMAGE_BASE}:${ref}"
  case "${METHOD}" in
    docker) build_docker "${ref}" ;;
    native) build_native "${ref}" ;;
    *)
      echo "[build-reth] 未知 --method: ${METHOD}" >&2
      exit 1
      ;;
  esac
  assert_image_exists "${image_tag}"

  local final_tag="${image_tag}"
  if ${DO_PUSH}; then
    push_remote "${ref}" "${image_tag}"
    final_tag="${REGISTRY}:${ref}"
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
