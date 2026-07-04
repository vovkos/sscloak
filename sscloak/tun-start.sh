#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

if [[ -f "$SCRIPT_DIR/runtime.env" ]]; then
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/runtime.env"
fi

find_bin() {
  local env_name="$1"
  shift
  local configured="${!env_name:-}"
  local search_dirs="${BIN_SEARCH_DIRS:-/usr/local/bin:/usr/bin:/bin:/opt}"

  if [[ -n "$configured" ]]; then
    [[ -x "$configured" ]] && printf '%s\n' "$configured" && return 0
    echo "$env_name is set but not executable: $configured" >&2
    return 1
  fi

  local candidate
  for candidate in "$@"; do
    if [[ "$candidate" == */* ]]; then
      [[ -x "$candidate" ]] && printf '%s\n' "$candidate" && return 0
    elif command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    else
      local search_dir found
      while IFS= read -r search_dir; do
        [[ -d "$search_dir" ]] || continue
        found="$(find "$search_dir" -type f -name "$candidate" -perm /111 -print -quit 2>/dev/null || true)"
        if [[ -n "$found" ]]; then
          printf '%s\n' "$found"
          return 0
        fi
      done < <(printf '%s\n' "$search_dirs" | tr ':' '\n')
    fi
  done

  return 1
}

TUN_DEV="${TUN_DEV:-tun1}"
SOCKS_ADDR="${SOCKS_ADDR:-127.0.0.1:10810}"
TUN2SOCKS_BIN="$(find_bin TUN2SOCKS_BIN tun2socks)"

exec "$TUN2SOCKS_BIN" -device "tun://$TUN_DEV" -proxy "socks5://$SOCKS_ADDR" -loglevel info
