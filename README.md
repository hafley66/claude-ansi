# claude-ansi

ANSI color unlock for Claude Code's native install. Runs one script; your assistant text and tool output keep their escape codes instead of being scrubbed to plain text.

## TOC

1. [What it does](#what-it-does)
2. [Install](#install)
3. [Verification gates](#verification-gates)
4. [Rollback](#rollback)
5. [After a Claude Code update](#after-a-claude-code-update)
6. [Known limits](#known-limits)
7. [How it works](#how-it-works)

## What it does

Claude Code strips ANSI escape sequences at several layers before rendering. This script copies the binary, makes five same-length regex edits inside the copy so ESC (0x1b) falls out of each character class, re-signs it (macOS), verifies it, and repoints the `claude` symlink. The original binary is never modified; `claude-stock` links to it for rollback.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/claude-ansi/main/claude-ansi.sh -o claude-ansi.sh
less claude-ansi.sh   # review it; it patches a 200MB binary you own
bash claude-ansi.sh
```

Requires the native install (`~/.local/share/claude/versions/`), bash, python3, and on macOS the Xcode signing tools. Linux works; codesign is skipped.

## Verification gates

Every gate must pass before the symlink swap. Any failure aborts with a nonzero exit and leaves `claude` untouched.

| gate | exit | catches |
|---|---|---|
| all 5 patterns matched at least one site | 3 | renamed minified code in a new release |
| patched copy runs `--version` | 4 | corrupt patch, bad sign |
| pty render probe: synthetic session renders `\x1b[31m` | 5 | render-path regressions end to end |
| `~/.local/bin/claude` is a symlink | 6 | npm or Homebrew installs (script refuses to clobber) |

`--no-verify` skips the render probe. The probe writes a UUID-named two-message session into the `~/.claude/projects/` entry for your current directory, resumes it headless in a pty, checks the red bytes arrived, and deletes the file. Run the script from a directory Claude Code already trusts; an untrusted directory downgrades the probe to SKIP, not FAIL.

## Rollback

```bash
ln -sf "$(readlink ~/.local/bin/claude-stock)" ~/.local/bin/claude
```

`claude-stock` points at a pristine snapshot the script keeps beside the patched copy.

## After a Claude Code update

`claude update` installs a fresh unpatched binary and repoints `claude`. Rerun `bash claude-ansi.sh`. It is pattern-based, not offset-based, so it usually survives releases untouched; a `0 sites` abort means the regexes were renamed and this repo needs an update.

Claude Code prunes version directories it no longer considers current, which can delete the stock binary the patcher reads. The script keeps a `<version>.stock` snapshot (prune-proof, non-version-named) and auto-restores the version directory from it when it finds the prune already happened.

## Known limits

- Pasting escape sequences into the prompt input still strips them: that path runs through bytecode and the native `Bun.stripANSI`, which no same-length byte edit reaches. Model-emitted ANSI renders fine; `claude -p "$(printf ...)"` carries ESC through argv fine.
- Modifying the binary is outside Claude Code's commercial terms. This is an at-your-own-risk local modification; it ships none of Anthropic's code.
- Windows is unsupported.

## How it works

| layer | pattern edit | effect |
|---|---|---|
| transcript sanitizer CSI class | `[@-~]` -> `[@-@]` | tool output keeps `\x1b[31m` |
| transcript control class | `\x0b-\x1f` -> `\x0c-\x1a` | lone ESC survives |
| ESC+C1 class | class start 001b -> 001c | paired C1 strips skip ESC |
| markdown inline class | range end 001f -> 001a | assistant text keeps ESC |
| wide normalize class | range end 001f -> 001a | same, normalize path |

All edits are same-length byte substitutions inside regex character classes: ESC (0x1b) falls below the new upper bound (0x1a) and stops matching, and the binary's offset tables stay valid. macOS invalidates the code signature on any byte edit, so the script re-signs with an ad-hoc identity.
