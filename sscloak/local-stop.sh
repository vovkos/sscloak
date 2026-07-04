#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CK_PID_FILE="${CK_PID_FILE:-/tmp/ck-client-sscloak-8443.pid}"
SS_PID_FILE="${SS_PID_FILE:-/tmp/ss-local-sscloak-8443.pid}"

if [[ -f "$SS_PID_FILE" ]] && kill -0 "$(cat "$SS_PID_FILE")" 2>/dev/null; then
  kill "$(cat "$SS_PID_FILE")" 2>/dev/null || true
  rm -f "$SS_PID_FILE"
fi

if [[ -f "$CK_PID_FILE" ]] && kill -0 "$(cat "$CK_PID_FILE")" 2>/dev/null; then
  kill "$(cat "$CK_PID_FILE")" 2>/dev/null || true
  rm -f "$CK_PID_FILE"
fi

pkill -f "ck-client .*$SCRIPT_DIR/ck-client.json" 2>/dev/null || true
pkill -f "ss-local .*$SCRIPT_DIR/ss-local.json" 2>/dev/null || true
