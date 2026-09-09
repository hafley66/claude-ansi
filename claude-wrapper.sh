#!/usr/bin/env bash
set -uo pipefail
REAL="__REAL_BINARY__"
PROXY_JS="__PROXY_JS__"
CACHE="$HOME/.cache/claude-ansi"
PORT_FILE="$CACHE/port"

alive() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null || return 1
  exec 3>&- 2>/dev/null
  return 0
}

start_proxy() {
  command -v node >/dev/null 2>&1 || return 1
  mkdir -p "$CACHE"
  rm -f "$PORT_FILE"
  ANSI_PROXY_PORT="${ANSI_PROXY_PORT:-8791}" nohup node "$PROXY_JS" >"$CACHE/proxy.log" 2>&1 &
  local i port
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    port="$(cat "$PORT_FILE" 2>/dev/null)"
    if alive "$port"; then
      echo "$port"
      return 0
    fi
    sleep 0.2
  done
  return 1
}

if [ -z "${ANTHROPIC_BASE_URL:-}" ] && [ -z "${CLAUDE_ANSI_NO_PROXY:-}" ]; then
  PORT="$(cat "$PORT_FILE" 2>/dev/null)"
  if ! alive "$PORT"; then
    PORT="$(start_proxy)" || PORT=""
  fi
  if alive "$PORT"; then
    export ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT"
  fi
fi

exec "$REAL" "$@"
