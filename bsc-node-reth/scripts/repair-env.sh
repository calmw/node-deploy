#!/usr/bin/env bash
# 从 .env 去掉非 KEY=value 行（修复误写入的 docker push 输出等）
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
EXAMPLE="${ROOT_DIR}/.env.example"

if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${EXAMPLE}" "${ENV_FILE}"
  echo "[repair-env] 已从 .env.example 创建 .env"
  exit 0
fi

python3 - "${ENV_FILE}" "${EXAMPLE}" <<'PY'
import re
import shutil
import sys
from pathlib import Path

env_path = Path(sys.argv[1])
example_path = Path(sys.argv[2])
valid = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

raw = env_path.read_text().splitlines()
kept, dropped = [], []
for i, line in enumerate(raw, 1):
    s = line.strip()
    if not s or s.startswith("#"):
        kept.append(line)
        continue
    if s.startswith("export "):
        s = s[7:].strip()
    if valid.match(s):
        kept.append(line)
    else:
        dropped.append((i, line))

if not dropped:
    print("[repair-env] .env 无非法行，无需修改")
    sys.exit(0)

bak = env_path.with_suffix(".env.bak-repair")
shutil.copy2(env_path, bak)
env_path.write_text("\n".join(kept) + ("\n" if kept else ""))
print(f"[repair-env] 已备份 → {bak}")
print(f"[repair-env] 已删除 {len(dropped)} 行非法内容，例如:")
for i, line in dropped[:8]:
    print(f"  L{i}: {line[:120]}")
if len(dropped) > 8:
    print(f"  … 共 {len(dropped)} 行")

# 若缺少 RETH_IMAGE，从 example 补默认
keys = set()
for line in kept:
    s = line.strip()
    if s.startswith("#") or not s:
        continue
    if "=" in s:
        keys.add(s.split("=", 1)[0].replace("export ", "").strip())

needed = []
for line in example_path.read_text().splitlines():
    s = line.strip()
    if not valid.match(s):
        continue
    k = s.split("=", 1)[0]
    if k not in keys:
        needed.append(s)

if needed:
    with env_path.open("a") as f:
        f.write("\n# repair-env 从 .env.example 补全\n")
        for s in needed:
            f.write(s + "\n")
    print(f"[repair-env] 已补全 {len(needed)} 个缺失变量")
PY

echo "[repair-env] 完成。请检查 RETH_IMAGE / RETH_REGISTRY 是否正确。"
