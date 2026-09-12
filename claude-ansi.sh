#!/usr/bin/env bash
# claude-ansi: ANSI unlock for Claude Code; usage: bash claude-ansi.sh [version] [--no-verify] [--no-wrapper] [--replace-claude]
set -euo pipefail

NO_VERIFY=0
REPLACE_CLAUDE=0
NO_WRAPPER=0
VER_ARG=""
for a in "$@"; do
  case "$a" in
    --no-verify) NO_VERIFY=1 ;;
    --no-wrapper) NO_WRAPPER=1 ;;
    --replace-claude) REPLACE_CLAUDE=1 ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) VER_ARG="$a" ;;
  esac
done

OS="$(uname -s)"
case "$OS" in
  Darwin|Linux) ;;
  *) echo "unsupported OS: $OS (darwin/linux only)"; exit 1 ;;
esac

SHARE="$HOME/.local/share/claude/versions"
BIN_DIR="$HOME/.local/bin"
# Claude Code prunes every file under $SHARE that is not a version it still
# points at, which took the patched binary and its snapshot with it. Both now
# live outside the tree the pruner walks.
ANSI_DIR="$HOME/.local/share/claude-ansi"
# The updater rewrites $BIN_DIR/claude on every release, so the `claude` that
# boop and ccz resolve through PATH is a shadow this script owns instead.
SHADOW_DIR="$HOME/.local/bin-ansi"
SHAREExists() { [ -d "$SHARE" ] || { echo "no versions dir: $SHARE (native install required)"; exit 1; }; }
SHAREExists
mkdir -p "$ANSI_DIR"

if [ -n "$VER_ARG" ]; then
  SRC_VER="$VER_ARG"
else
  SRC_VER="$(ls "$SHARE" | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -t . -k 1,1n -k 2,2n -k 3,3n -k 4,4n | tail -1 || true)"
  [ -n "$SRC_VER" ] || SRC_VER="$(ls "$ANSI_DIR" | grep -E '\.stock$' | sed 's/\.stock$//' | sort -t . -k 1,1n -k 2,2n -k 3,3n -k 4,4n | tail -1 || true)"
fi
SRC="$SHARE/$SRC_VER"
STOCK="$ANSI_DIR/$SRC_VER.stock"
DST="$ANSI_DIR/$SRC_VER-ansi"

# Earlier releases kept both files beside the versions the pruner deletes.
for legacy in "$SHARE/$SRC_VER.stock:$STOCK" "$SHARE/$SRC_VER-ansi:$DST"; do
  from="${legacy%%:*}"; to="${legacy##*:}"
  [ -f "$from" ] && [ ! -f "$to" ] && mv -f "$from" "$to" && echo "moved $from -> $to"
done

# Never cp over an existing executable. macOS caches the code-signature state
# per inode; overwriting the bytes in place leaves the cache stale and every
# later exec of that file dies with SIGKILL. Write a fresh inode and rename.
safe_cp() {
  local src="$1" dst="$2" tmp
  tmp="$(mktemp "$dst.tmp.XXXXXX")" || return 1
  cp -f "$src" "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 755 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$dst"
}

if [ ! -f "$SRC" ] && [ -f "$STOCK" ]; then
  echo "version $SRC_VER pruned by claude; patching from $STOCK instead"
  SRC="$STOCK"
fi
[ -f "$SRC" ] || { echo "no such version: $SRC"; exit 1; }
if [ "$SRC" != "$STOCK" ]; then
  safe_cp "$SRC" "$STOCK"
fi
if [ -e "$SHADOW_DIR/claude" ] && ! head -3 "$SHADOW_DIR/claude" 2>/dev/null | grep -q 'claude-ansi\|__REAL_BINARY__\|CLAUDE_ANSI_NO_PROXY'; then
  echo "$SHADOW_DIR/claude was not written by this script; refusing to clobber"
  exit 6
fi

TMP="$(mktemp "$DST.tmp.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
cp -f "$SRC" "$TMP"

python3 - "$TMP" "$SRC_VER" <<'PYEOF'
import sys

path, ver = sys.argv[1], sys.argv[2]
data = bytearray(open(path, 'rb').read())
B = chr(92)  # backslash via chr() so this file carries no raw control bytes
failed = []

def sub(old, new, label):
    o, n = old.encode(), new.encode()
    assert len(o) == len(n), label
    count = data.count(o)
    i = 0
    while True:
        j = data.find(o, i)
        if j < 0:
            break
        data[j:j + len(o)] = n
        i = j + len(o)
    print(f'  {label}: {count} site(s)')
    if count == 0:
        failed.append(label)

sub(B+'x1b'+B+'['+'[0-?]*[ -/]*[@-~]',
    B+'x1b'+B+'['+'[0-?]*[ -/]*[@-@]', 'CSI final-byte class')
sub('['+B+'x00-'+B+'x08'+B+'x0b-'+B+'x1f'+B+'x7f-'+B+'x9f]',
    '['+B+'x00-'+B+'x08'+B+'x0c-'+B+'x1a'+B+'x7f-'+B+'x9f]', 'control-char class')
sub('['+B+'u001b'+B+'u0080-'+B+'u009f]',
    '['+B+'u001c'+B+'u0080-'+B+'u009f]', 'ESC+C1 class')
sub('[' + B+'u0000-' + B+'u001f' + B+'u007f' + B+'u2028' + B+'u2029' + ']+',
    '[' + B+'u0000-' + B+'u001a' + B+'u007f' + B+'u2028' + B+'u2029' + ']+',
    'md inline control class')
sub('[' + B+'u0000-' + B+'u001f' + B+'u007f-' + B+'u009f' + B+'u2028' + B+'u2029' + ']',
    '[' + B+'u0000-' + B+'u001a' + B+'u007f-' + B+'u009f' + B+'u2028' + B+'u2029' + ']',
    'wide control class')

if failed:
    print(f'ABORT: 0 sites for {failed}; minified code changed in {ver}')
    sys.exit(3)
open(path, 'wb').write(bytes(data))
print(f'patched {len(data)} bytes')
PYEOF

if [ "$OS" = Darwin ]; then
  codesign --force --sign - "$TMP" >/dev/null 2>&1
  codesign -v "$TMP" && echo 'codesign: valid'
fi
chmod 755 "$TMP"
"$TMP" --version >/dev/null || { echo 'ABORT: patched binary will not run'; exit 4; }

if [ "$NO_VERIFY" -eq 0 ]; then
  echo 'render probe: synthetic session in a pty'
  python3 - "$TMP" <<'PYEOF'
import json
import os
import pty
import select
import sys
import time
import uuid

bin_path = sys.argv[1]
cwd = os.path.realpath(os.getcwd())
proj = os.path.expanduser('~/.claude/projects/' + cwd.replace('/', '-'))
sid = str(uuid.uuid4())
esc = chr(27)
u1, u2 = str(uuid.uuid4()), str(uuid.uuid4())
base = dict(cwd=cwd, sessionId=sid, gitBranch='HEAD', isSidechain=False,
            userType='external', entrypoint='cli')
l1 = dict(base, type='user', parentUuid=None, uuid=u1,
          timestamp='2026-09-09T00:00:00.000Z', permissionMode='default',
          promptId=str(uuid.uuid4()), promptSource='user',
          message={'role': 'user', 'content': 'render test'})
l2 = dict(base, type='assistant', parentUuid=u1, uuid=u2,
          timestamp='2026-09-09T00:00:01.000Z', apiBlockIndex=0,
          message={'role': 'assistant', 'content': [
              {'type': 'text', 'text': esc + '[31mRED' + esc + '[0m'}]})
os.makedirs(proj, exist_ok=True)
sp = os.path.join(proj, sid + '.jsonl')
try:
    with open(sp, 'w') as f:
        f.write(json.dumps(l1) + '\n' + json.dumps(l2) + '\n')
    env = dict(os.environ)
    env.update(TERM='xterm-256color', COLUMNS='100', LINES='40')
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.execve(bin_path, [bin_path, '--resume', sid], env)
    buf = b''
    start = time.time()
    while time.time() - start < 15:
        r, _, _ = select.select([fd], [], [], 1.0)
        if r:
            try:
                c = os.read(fd, 65536)
            except OSError:
                break
            if not c:
                break
            buf += c
    os.kill(pid, 9)
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    red = buf.count((esc + '[31m').encode())
    if red > 0:
        print(f'  PASS: {red} red byte sequence(s) rendered')
        sys.exit(0)
    if b'code.claude.com/docs/en/security' in buf:
        print('  SKIP: trust dialog for this directory; rerun from a trusted dir to verify')
        sys.exit(0)
    print('  FAIL: ANSI did not render')
    sys.exit(5)
finally:
    if os.path.exists(sp):
        os.remove(sp)
PYEOF
fi

mv -f "$TMP" "$DST"
trap - EXIT

if [ "$OS" = Darwin ]; then
  codesign -v "$DST" 2>/dev/null || codesign --force --sign - "$DST" >/dev/null 2>&1
  codesign -v "$DST" || { echo "ABORT: $DST is unsigned; macOS will hang on it"; exit 7; }
fi
"$DST" --version >/dev/null || { echo "ABORT: $DST will not run after install"; exit 7; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The wrapper repatches itself by re-running this script, so it needs a copy
# that outlives the clone. Vendor the three files the wrapper depends on and
# point it at those, leaving the clone free to be moved or deleted.
VENDOR="$ANSI_DIR/lib"
vendor_sources() {
  [ "$HERE" = "$VENDOR" ] && return 0
  mkdir -p "$VENDOR" || return 1
  local f
  for f in claude-ansi.sh claude-wrapper.sh ansi-proxy.js; do
    [ -f "$HERE/$f" ] || return 1
    cp -f "$HERE/$f" "$VENDOR/$f.tmp" || return 1
    mv -f "$VENDOR/$f.tmp" "$VENDOR/$f" || return 1
  done
  chmod 755 "$VENDOR/claude-ansi.sh"
}

# Write the wrapper to a fresh inode and rename, so a wrapper currently
# executing this repatch keeps reading the file it was launched from.
install_wrapper() {
  local dest="$1" tmp
  tmp="$(mktemp "$(dirname "$dest")/.claude-ansi.XXXXXX")" || return 1
  sed -e "s|__INSTALLER__|$VENDOR/claude-ansi.sh|" -e "s|__PROXY_JS__|$VENDOR/ansi-proxy.js|" \
    "$HERE/claude-wrapper.sh" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 755 "$tmp"
  mv -f "$tmp" "$dest"
}

if [ "$NO_WRAPPER" -eq 0 ] && [ -f "$HERE/claude-wrapper.sh" ] && [ -f "$HERE/ansi-proxy.js" ]; then
  vendor_sources && echo "sources vendored to $VENDOR"
  install_wrapper "$BIN_DIR/claude-color" \
    && echo "claude-color installed (proxy re-injects ANSI; honors an existing ANTHROPIC_BASE_URL)"
  if [ "$REPLACE_CLAUDE" -eq 1 ]; then
    mkdir -p "$SHADOW_DIR"
    install_wrapper "$SHADOW_DIR/claude" && echo "claude shadow installed at $SHADOW_DIR/claude"
    case ":$PATH:" in
      *":$SHADOW_DIR:"*) ;;
      *) echo "ADD TO YOUR SHELL PROFILE, after every other PATH line:"
         echo "  export PATH=\"$SHADOW_DIR:\$PATH\"" ;;
    esac
  else
    echo "claude untouched; run claude-color to try it (--replace-claude shadows \`claude\` on PATH)"
  fi
fi
ln -sfn "$STOCK" "$BIN_DIR/claude-stock"

# Keep the two newest of each kind; the rest are dead weight at 200MB apiece.
for kind in '-ansi' '.stock'; do
  ls "$ANSI_DIR" 2>/dev/null | grep -F -- "$kind" | sed "s|${kind}\$||" \
    | sort -t . -k 1,1n -k 2,2n -k 3,3n -k 4,4n | head -n -2 \
    | while read -r old; do rm -f "$ANSI_DIR/$old$kind" && echo "pruned $old$kind"; done
done

echo "stock snapshot: $STOCK"
"$DST" --version && echo OK
