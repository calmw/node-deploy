#!/usr/bin/env bash
# refresh-static-nodes.sh
# 抓取当前节点已连接的真实 peer enode，去重合并后写入 config.toml 的 StaticNodes，
# 并确保 DialRatio=1。适用于对称 NAT / 多层 NAT 等 discovery 不可靠的环境。
#
# 用法:
#   bash scripts/refresh-static-nodes.sh              # 抓取并写入 config（不重启）
#   ROUNDS=24 INTERVAL=5 bash scripts/refresh-static-nodes.sh   # 多抓一会儿
#   RESTART=1 bash scripts/refresh-static-nodes.sh    # 写入后自动重启生效
#   MERGE=0 bash scripts/refresh-static-nodes.sh      # 不合并旧的，仅用本次抓到的
#
# 环境变量:
#   BSC_CONTAINER  容器名      (默认 bsc-node)
#   BSC_DATADIR    容器内datadir(默认 /bsc/node)
#   ROUNDS         抓取轮数    (默认 12)
#   INTERVAL       每轮间隔秒  (默认 5)
#   MERGE          合并已有 StaticNodes (默认 1)
#   RESTART        写入后自动重启 (默认 0)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${ROOT_DIR}/config/config.toml"
CONTAINER="${BSC_CONTAINER:-bsc-node}"
DATADIR="${BSC_DATADIR:-/bsc/node}"
ROUNDS="${ROUNDS:-12}"
INTERVAL="${INTERVAL:-5}"
MERGE="${MERGE:-1}"
RESTART="${RESTART:-0}"

ENODE_RE='enode://[0-9a-f]{128}@[0-9.]+:[0-9]+'

log(){ printf '[refresh] %s\n' "$*"; }
attach(){ docker exec "$CONTAINER" geth attach --datadir "$DATADIR" --exec "$1" 2>/dev/null; }

# 0) 前置检查
command -v docker  >/dev/null || { echo "[refresh] 需要 docker"  >&2; exit 1; }
command -v python3 >/dev/null || { echo "[refresh] 需要 python3" >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "[refresh] 找不到 config: $CONFIG" >&2; exit 1; }
docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" \
  || { echo "[refresh] 容器 $CONTAINER 未运行" >&2; exit 1; }

# 1) 多轮抓取已连接 peer 的 enode，并顺手固化为 trusted（滚雪球）
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
log "开始抓取 enode: ${ROUNDS} 轮 × ${INTERVAL}s（同时把连上的 peer 固化为 trusted）..."
for i in $(seq 1 "$ROUNDS"); do
  attach 'admin.peers.forEach(function(p){try{admin.addTrustedPeer(p.enode);}catch(e){} console.log(p.enode);})' \
    >> "$TMP" 2>/dev/null || true
  now="$(grep -oE "$ENODE_RE" "$TMP" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
  printf '\r[refresh] 第 %s/%s 轮，已抓到唯一 enode: %s 个    ' "$i" "$ROUNDS" "$now"
  sleep "$INTERVAL"
done
printf '\n'

# 2) 规整 + 合并已有 StaticNodes
NEW="$(grep -oE "$ENODE_RE" "$TMP" 2>/dev/null | sort -u || true)"
if [[ "$MERGE" == "1" ]]; then
  OLD="$(grep -oE "$ENODE_RE" "$CONFIG" 2>/dev/null || true)"
else
  OLD=""
fi
ALL="$(printf '%s\n%s\n' "$OLD" "$NEW" | grep -E '^enode://' | sort -u || true)"
COUNT="$(printf '%s\n' "$ALL" | grep -c '^enode://' || true)"

if [[ "${COUNT:-0}" -eq 0 ]]; then
  echo "[refresh] 没有抓到任何 enode（当前 peer 可能为 0），未修改 config。" >&2
  echo "[refresh] 可稍后在有 peer 时重试，或先用 NAT_MODE=any 让它先连上几个。" >&2
  exit 2
fi
log "合并后共 ${COUNT} 个唯一 enode"

# 3) 备份 + 写入 config.toml
cp "$CONFIG" "${CONFIG}.bak.$(date +%s)"
ENODE_LIST="${TMP}.enodes"
printf '%s\n' "$ALL" > "$ENODE_LIST"
python3 - "$CONFIG" "$ENODE_LIST" <<'PYEOF'
import re, sys
cfg, enode_file = sys.argv[1], sys.argv[2]
enodes = [l.strip() for l in open(enode_file) if l.strip().startswith('enode://')]
if not enodes:
    print("[refresh] 错误: enode 列表为空，未写入 config", file=sys.stderr)
    sys.exit(1)
s = open(cfg).read()
arr = "StaticNodes = [\n" + ''.join('  "%s",\n' % e for e in enodes) + "]"
if re.search(r'StaticNodes\s*=\s*\[[^\]]*\]', s, flags=re.DOTALL):
    s = re.sub(r'StaticNodes\s*=\s*\[[^\]]*\]', arr, s, count=1, flags=re.DOTALL)
else:
    s = re.sub(r'(?m)^(\[Node\.P2P\].*)$', r'\1\n' + arr, s, count=1)
if not re.search(r'(?m)^\s*DialRatio\s*=', s):
    if re.search(r'(?m)^NoDiscovery\s*=.*$', s):
        s = re.sub(r'(?m)^(NoDiscovery\s*=.*)$', r'\1\nDialRatio = 1', s, count=1)
    else:
        s = re.sub(r'(?m)^(\[Node\.P2P\].*)$', r'\1\nDialRatio = 1', s, count=1)
open(cfg, 'w').write(s)
print("[refresh] 已写入 %d 个 StaticNodes + DialRatio=1" % len(enodes))
PYEOF
rm -f "$ENODE_LIST"

# 4) 验证
log "当前 [Node.P2P] 配置:"
sed -n '/\[Node.P2P\]/,/EnableMsgEvents/p' "$CONFIG"

# 5) 可选重启
if [[ "$RESTART" == "1" ]]; then
  log "重启容器使配置生效 ..."
  (cd "$ROOT_DIR" && docker compose restart)
  sleep 60
  log "重启后 peer 数: $(attach 'net.peerCount' || echo '?')"
else
  log "完成。下次重启后生效:  cd $ROOT_DIR && docker compose restart"
fi
