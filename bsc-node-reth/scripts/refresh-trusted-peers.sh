#!/usr/bin/env bash
# 从 RPC admin_peers 抓取已握手的 BSC peer，写入 config/trusted-peers.txt（持久化优先连接）
# 不读 known-peers.json：其中是 discovery 见过的全部节点（数千个、含错链），会撑爆 --trusted-peers
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"
TRUSTED_FILE="${ROOT_DIR}/config/trusted-peers.txt"
ROUNDS="${ROUNDS:-6}"
INTERVAL="${INTERVAL:-10}"
RESTART="${RESTART:-0}"
MAX_TRUSTED="${MAX_TRUSTED:-50}"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/load-env.sh"
load_dotenv "${ROOT_DIR}/.env"

HTTP_BIND="${HTTP_BIND_ADDR:-127.0.0.1}"
HTTP_PORT="${HTTP_PORT:-8545}"
RPC="http://${HTTP_BIND}:${HTTP_PORT}"

log() { printf '[refresh-trusted] %s\n' "$*"; }

fetch_admin_peers() {
  curl -fsS -m 15 -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"admin_peers","params":[],"id":1}' \
    "${RPC}" 2>/dev/null || true
}

TMP="$(mktemp)"
trap 'rm -f "${TMP}" "${TMP}.raw"' EXIT

log "RPC ${RPC}，${ROUNDS} 轮 × ${INTERVAL}s 抓取 admin_peers（上限 ${MAX_TRUSTED} 个）…"
for i in $(seq 1 "${ROUNDS}"); do
  fetch_admin_peers >> "${TMP}.raw" 2>/dev/null || true
  sleep "${INTERVAL}"
done

python3 - "${TRUSTED_FILE}" "${TMP}.raw" "${MAX_TRUSTED}" <<'PY'
import json, re, sys
from pathlib import Path

trusted_path = Path(sys.argv[1])
raw_path = Path(sys.argv[2])
max_trusted = int(sys.argv[3])
enode_re = re.compile(r"enode://[0-9a-fA-F]{128}@[0-9.]+:[0-9]+")

def extract_from_text(text: str) -> set[str]:
    return set(enode_re.findall(text))

def extract_from_json_obj(obj) -> set[str]:
    out = set()
    if isinstance(obj, str):
        out |= extract_from_text(obj)
        return out
    if isinstance(obj, list):
        for x in obj:
            out |= extract_from_json_obj(x)
        return out
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in ("enode", "url", "enode_url", "enr") and isinstance(v, str):
                out |= extract_from_text(v)
            else:
                out |= extract_from_json_obj(v)
        return out
    return out

found = set()
blob = raw_path.read_text(errors="ignore") if raw_path.exists() else ""
found |= extract_from_text(blob)
for line in blob.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        found |= extract_from_json_obj(json.loads(line))
    except json.JSONDecodeError:
        continue

existing = []
if trusted_path.exists():
    for line in trusted_path.read_text().splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        for part in s.split(","):
            part = part.strip()
            if part.startswith("enode://"):
                existing.append(part)

def node_id(enode: str) -> str:
    return enode[len("enode://"):].split("@", 1)[0].lower()

# 按节点 ID 去重（同一节点换 IP/端口只留一条）；本次已连接的优先，其余用旧列表补足
merged, seen = [], set()
for e in sorted(found) + existing:
    if len(merged) >= max_trusted:
        break
    nid = node_id(e)
    if nid in seen:
        continue
    seen.add(nid)
    merged.append(e)

trusted_path.parent.mkdir(parents=True, exist_ok=True)
header = [
    "# 额外 trusted peer（每行一个 enode）",
    f"# 由 scripts/refresh-trusted-peers.sh 维护（admin_peers，最多 {max_trusted} 个）；与 start.sh 内置官方节点合并",
    "",
]
trusted_path.write_text("\n".join(header + merged) + ("\n" if merged else ""))
print(f"[refresh-trusted] 写入 {trusted_path}：本次已连接 {len(found)} 个，合计 {len(merged)} 个 enode")
if not merged and not found:
    print("[refresh-trusted] 未解析到 enode。请确认 HTTP_API 含 admin，且 RPC 可访问。", file=sys.stderr)
    sys.exit(1)
PY

if [[ "${RESTART}" == "1" ]]; then
  log "重启容器使 --trusted-peers 生效 …"
  docker compose down && docker compose up -d
fi

log "完成。trusted 列表在 config/trusted-peers.txt；也可复制到 .env 的 RETH_TRUSTED_PEERS。"
