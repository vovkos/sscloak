#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$SCRIPT_DIR"

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

CK_BIN="$(find_bin CK_BIN ck-client)"
SS_BIN="$(find_bin SS_BIN ss-local)"
CK_LOG="${CK_LOG:-/tmp/ck-client-sscloak-8443.log}"
SS_LOG="${SS_LOG:-/tmp/ss-local-sscloak-8443.log}"
CK_PID_FILE="${CK_PID_FILE:-/tmp/ck-client-sscloak-8443.pid}"
SS_PID_FILE="${SS_PID_FILE:-/tmp/ss-local-sscloak-8443.pid}"

start_detached() {
  local pid_file="$1"
  local log_file="$2"
  shift 2

  if command -v setsid >/dev/null 2>&1; then
    setsid -f "$@" >"$log_file" 2>&1
    sleep 0.2
    pgrep -n -f "$*" >"$pid_file"
  else
    nohup "$@" >"$log_file" 2>&1 &
    echo "$!" >"$pid_file"
  fi
}

if (( EUID == 0 )); then
  echo "Do not run this with sudo." >&2
  exit 1
fi

if ss -lnt | awk '{print $4}' | grep -qx '127.0.0.1:16789'; then
  echo "Port 127.0.0.1:16789 is already in use" >&2
  exit 1
fi

if ss -lnt | awk '{print $4}' | grep -qx '127.0.0.1:10810'; then
  echo "Port 127.0.0.1:10810 is already in use" >&2
  exit 1
fi

start_detached "$CK_PID_FILE" "$CK_LOG" "$CK_BIN" -c "$PWD/ck-client.json" -l 16789
sleep 1

if ! kill -0 "$(cat "$CK_PID_FILE")" 2>/dev/null; then
  echo "ck-client failed to start. Log:" >&2
  tail -80 "$CK_LOG" >&2
  exit 1
fi

start_detached "$SS_PID_FILE" "$SS_LOG" "$SS_BIN" -c "$PWD/ss-local.json"
sleep 1

if ! kill -0 "$(cat "$SS_PID_FILE")" 2>/dev/null; then
  echo "ss-local failed to start. Log:" >&2
  tail -80 "$SS_LOG" >&2
  kill "$(cat "$CK_PID_FILE")" 2>/dev/null || true
  rm -f "$CK_PID_FILE"
  exit 1
fi

echo "sscloak local client is running on 127.0.0.1:10810"
