#!/usr/bin/env bash
# 仅加载 KEY=value 行，避免 source .env 执行被污染的行（如 docker push 输出）
load_dotenv() {
  local file="${1:-.env}"
  [[ -f "${file}" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
    line="${line#export }"
    if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # 去掉首尾引号（若成对）
      if [[ "${val}" =~ ^\"(.*)\"$ ]]; then
        val="${BASH_REMATCH[1]}"
      elif [[ "${val}" =~ ^\'(.*)\'$ ]]; then
        val="${BASH_REMATCH[1]}"
      fi
      export "${key}=${val}"
    else
      printf '[load-env] 忽略非法行 (%s): %s\n' "${file}" "${line}" >&2
    fi
  done < "${file}"
}
