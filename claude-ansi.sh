#!/usr/bin/env bash
# claude-ansi: ANSI-unlock patch for Claude Code; usage: bash claude-ansi.sh [version] [--no-verify]
set -euo pipefail

NO_VERIFY=0
VER_ARG=""
for a in "$@"; do
  case "$a" in
    --no-verify) NO_VERIFY=1 ;;
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
SHAREExists() { [ -d "$SHARE" ] || { echo "no versions dir: $SHARE (native install required)"; exit 1; }; }
SHAREExists

if [ -n "$VER_ARG" ]; then
  SRC_VER="$VER_ARG"
else
  SRC_VER="$(ls "$SHARE" | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -t . -k 1,1n -k 2,2n -k 3,3n -k 4,4n | tail -1 || true)"
  [ -n "$SRC_VER" ] || SRC_VER="$(ls "$SHARE" | grep -E '\.stock$' | sed 's/\.stock$//' | sort -t . -k 1,1n -k 2,2n -k 3,3n -k 4,4n | tail -1 || true)"
fi
SRC="$SHARE/$SRC_VER"
STOCK="$SHARE/$SRC_VER.stock"
DST="$SHARE/$SRC_VER-ansi"
if [ ! -f "$SRC" ] && [ -f "$STOCK" ]; then
  echo "version pruned by claude; restoring from $STOCK"
  cp -f "$STOCK" "$SRC"
fi
[ -f "$SRC" ] || { echo "no such version: $SRC"; exit 1; }
if [ "$SRC" != "$STOCK" ]; then
  cp -f "$SRC" "$STOCK"
fi
if [ -e "$BIN_DIR/claude" ] && [ ! -L "$BIN_DIR/claude" ]; then
  echo "$BIN_DIR/claude is a regular file (npm/homebrew install?); refusing to clobber"
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
chmod +x "$TMP"
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
ln -sf "$DST" "$BIN_DIR/claude"
ln -sf "$STOCK" "$BIN_DIR/claude-stock"
echo "claude -> $DST"
echo "claude-stock -> $STOCK (rollback: ln -sf \"\$HOME/.local/share/claude/versions/$SRC_VER.stock\" \"\$HOME/.local/bin/claude\")"
"$DST" --version && echo OK
