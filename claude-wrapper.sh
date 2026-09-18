#!/usr/bin/env bash
# claude-ansi wrapper. Resolves the newest installed Claude Code version,
# repatches it if the updater has moved on since the last run, starts the
# ANSI proxy, and execs the patched binary.
set -uo pipefail

SHARE="$HOME/.local/share/claude/versions"
ANSI_DIR="$HOME/.local/share/claude-ansi"
INSTALLER="__INSTALLER__"
PROXY_JS="__PROXY_JS__"
CACHE="$HOME/.cache/claude-ansi"
PORT_FILE="$CACHE/port"
LOCK="$CACHE/patch.lock"

newest() {
  ls "$SHARE" 2>/dev/null \
    | grep -E '^[0-9]+(\.[0-9]+)*$' \
    | sort -t . -k 1,1n -k 2,2n -k 3,3n -k 4,4n \
    | tail -1
}

newest_patched() {
  ls "$ANSI_DIR" 2>/dev/null \
    | grep -E '^[0-9]+(\.[0-9]+)*-ansi$' \
    | sed 's/-ansi$//' \
    | sort -t . -k 1,1n -k 2,2n -k 3,3n -k 4,4n \
    | tail -1
}

# A lock dir left behind by a killed run would stall every later launch.
clear_stale_lock() {
  [ -d "$LOCK" ] || return 0
  local age now mtime
  now="$(date +%s)"
  mtime="$(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || echo "$now")"
  age=$(( now - mtime ))
  [ "$age" -gt 300 ] && rmdir "$LOCK" 2>/dev/null
  return 0
}

repatch() {
  local ver="$1"
  if [ ! -f "$INSTALLER" ]; then
    echo "claude-ansi: installer missing at $INSTALLER; cannot patch $ver" >&2
    return 1
  fi
  command -v python3 >/dev/null 2>&1 || return 1
  mkdir -p "$CACHE"
  # A release that renames the minified code fails every pattern and cannot be
  # fixed by retrying. Without this stamp that failure costs a 200MB copy on
  # every single launch. The stamp is per version, so the next release retries.
  local stamp="$CACHE/failed-$ver"
  if [ -f "$stamp" ]; then
    [ "$INSTALLER" -nt "$stamp" ] || return 1
    rm -f "$stamp"
  fi
  clear_stale_lock
  if mkdir "$LOCK" 2>/dev/null; then
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT
    echo "claude-ansi: patching $ver (first run since the updater installed it)" >&2
    bash "$INSTALLER" "$ver" --no-verify --no-wrapper >&2
    local rc=$?
    rmdir "$LOCK" 2>/dev/null
    trap - EXIT
    if [ "$rc" -ne 0 ]; then
      : > "$stamp"
      echo "claude-ansi: patch of $ver failed (rc=$rc); not retrying until $INSTALLER changes" >&2
    fi
    return $rc
  fi
  # Another launch is mid-patch. Wait it out rather than racing a 200MB copy.
  local i
  for i in $(seq 1 120); do
    [ -d "$LOCK" ] || break
    sleep 1
  done
  return 0
}

# A bare TCP connect proves only that something is listening. An unrelated
# server on the same port would be accepted and Claude Code pointed at it, so
# ask for the health token and match it before trusting the port.
alive() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  exec 3<>"/dev/tcp/127.0.0.1/$p" 2>/dev/null || return 1
  printf 'GET /__claude_ansi_health HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' >&3 2>/dev/null
  local line rc=1
  while IFS= read -r -t 3 line <&3; do
    case "$line" in *claude-ansi-proxy*) rc=0; break ;; esac
  done
  exec 3>&- 2>/dev/null
  exec 3<&- 2>/dev/null
  return $rc
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

VER="$(newest)"
REAL=""
if [ -n "$VER" ]; then
  REAL="$ANSI_DIR/$VER-ansi"
  if [ ! -x "$REAL" ] && [ -z "${CLAUDE_ANSI_NO_PATCH:-}" ]; then
    repatch "$VER"
  fi
fi

# Fall back down the ladder rather than failing to launch: newest patched
# build, then the stock binary the updater installed.
if [ ! -x "$REAL" ]; then
  PREV="$(newest_patched)"
  [ -n "$PREV" ] && [ -x "$ANSI_DIR/$PREV-ansi" ] && REAL="$ANSI_DIR/$PREV-ansi"
fi
if [ ! -x "$REAL" ] && [ -n "$VER" ] && [ -x "$SHARE/$VER" ]; then
  echo "claude-ansi: patch unavailable; running stock $VER without color" >&2
  REAL="$SHARE/$VER"
fi
if [ ! -x "$REAL" ]; then
  echo "claude-ansi: no runnable claude binary under $SHARE" >&2
  exit 127
fi

if [ -z "${ANTHROPIC_BASE_URL:-}" ]; then
  if [ -z "${CLAUDE_ANSI_NO_PROXY:-}" ]; then
    PORT="$(cat "$PORT_FILE" 2>/dev/null)"
    if ! alive "$PORT"; then
      PORT="$(start_proxy)" || PORT=""
    fi
    if alive "$PORT"; then
      export ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT"
      export _CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL=1
    fi
  fi
else
  # An existing upstream (ccz, a gateway) is chained through the proxy rather
  # than ignored, so the ESC byte the API strips gets put back. A URL that
  # already points at this proxy's own port is left alone, or the proxy would
  # wrap itself. The alive/health-token check stays the only trust for the
  # port, so a stale port file cannot repoint a stranger's address.
  if [ -z "${CLAUDE_ANSI_NO_PROXY:-}" ]; then
    PORT="$(cat "$PORT_FILE" 2>/dev/null)"
    case "$ANTHROPIC_BASE_URL" in
      "http://127.0.0.1:$PORT"|"http://127.0.0.1:$PORT/"*) : ;;
      *)
        if ! alive "$PORT"; then
          PORT="$(start_proxy)" || PORT=""
        fi
        if alive "$PORT"; then
          export ANSI_PROXY_UPSTREAM="$ANTHROPIC_BASE_URL"
          export ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT"
          export _CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL=1
        fi
        ;;
    esac
  fi
fi

exec "$REAL" "$@"
