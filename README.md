# claude-ansi

ANSI color for Claude Code. Model-written escape codes render as color instead of showing up as literal `[31m` text.

## TOC

1. [Two problems, two fixes](#two-problems-two-fixes)
2. [Install](#install)
3. [Try it without changing anything](#try-it-without-changing-anything)
4. [Verification gates](#verification-gates)
5. [Rollback and uninstall](#rollback-and-uninstall)
6. [After a Claude Code update](#after-a-claude-code-update)
7. [Known limits](#known-limits)
8. [How the patch works](#how-the-patch-works)
9. [How the proxy works](#how-the-proxy-works)

## Two problems, two fixes

| problem | fix | applies to |
|---|---|---|
| the client strips escape codes before rendering | five same-length regex edits in a copy of the binary | every lane |
| the Anthropic API never sends the escape byte, only the bracket form | a localhost proxy that re-inserts it into streamed text | `claude-color` |

Third-party gateways that already send real escape bytes (z.ai and similar) need the patch alone; point them at the patched binary and skip the proxy.

## Install

```bash
git clone https://github.com/OWNER/claude-ansi
cd claude-ansi
less claude-ansi.sh   # review it; it patches a 200MB binary you own
bash claude-ansi.sh
```

Installs three things and leaves your `claude` command alone:

| name | what it is |
|---|---|
| `claude-color` | wrapper: starts the proxy, then runs the patched binary |
| `claude-stock` | pristine snapshot, for rollback |
| `<version>-ansi` | the patched binary, beside the original |

Requires the native install (`~/.local/share/claude/versions/`), bash, python3, node for the proxy, and on macOS the codesign tools. Linux works; signing is skipped.

## Try it without changing anything

```bash
claude-color
```

Ask it to print something in bracket form, for example `[31mRED[0m`, and it comes out red. Your `claude` command is untouched the whole time.

Make it the default only when you want to:

```bash
alias claude=claude-color              # reversible, per-shell
bash claude-ansi.sh --replace-claude   # repoints ~/.local/bin/claude
```

The wrapper honors an existing `ANTHROPIC_BASE_URL`, so a gateway wrapper that sets its own endpoint composes with it and skips the proxy. `CLAUDE_ANSI_NO_PROXY=1` disables the proxy for one run.

## Verification gates

Every gate must pass before anything is installed. Failure exits nonzero and leaves your setup as it was.

| gate | exit | catches |
|---|---|---|
| all 5 patterns matched at least one site | 3 | renamed minified code in a new release |
| patched copy runs `--version` | 4 | corrupt patch |
| pty render probe renders a red escape sequence | 5 | render-path regressions end to end |
| `~/.local/bin/claude` is not a foreign regular file | 6 | npm or Homebrew installs |
| binary at its final path is signed and runs | 7 | an interrupted install leaving an unsigned or truncated file |

`--no-verify` skips the render probe. The probe writes a UUID-named two-message session into the `~/.claude/projects/` entry for your current directory, resumes it headless in a pty, checks the escape bytes arrived, and deletes the file. Run from a directory Claude Code already trusts; an untrusted one downgrades the probe to SKIP.

## Rollback and uninstall

```bash
rm -f ~/.local/bin/claude-color
rm -f ~/.local/share/claude/versions/*-ansi
ln -sf "$(readlink ~/.local/bin/claude-stock)" ~/.local/bin/claude   # only if you used --replace-claude
```

## After a Claude Code update

`claude update` installs a fresh unpatched binary. Rerun `bash claude-ansi.sh`. The patcher matches patterns rather than offsets, so it usually survives a release untouched; a `0 sites` abort means the regexes were renamed and this repo needs an update.

Claude Code also prunes version directories it no longer points at, which can delete the binary the patcher reads. The script keeps a `<version>.stock` snapshot under a name the pruner ignores and restores from it automatically.

## Known limits

- Escape sequences pasted into the prompt input are still stripped: that path runs through bytecode and a native call, which no same-length byte edit reaches. Model-written color is unaffected.
- Modifying the binary is outside Claude Code's commercial terms. This is an at-your-own-risk local modification and ships none of Anthropic's code.
- Windows is unsupported.

## How the patch works

| layer | edit | effect |
|---|---|---|
| transcript sanitizer, CSI final byte | class end `~` becomes `@` | tool output keeps its color |
| transcript control class | range end 001f becomes 001a | a lone escape byte survives |
| escape plus C1 class | class start 001b becomes 001c | paired strips skip the escape byte |
| markdown inline class | range end 001f becomes 001a | assistant text keeps its color |
| wide normalize class | range end 001f becomes 001a | same, on the normalize path |

Each edit is a same-length byte substitution inside a regex character class: the escape byte falls outside the new bound and stops matching, and the bundle's offset tables stay valid. macOS invalidates the signature on any edit, so the script re-signs with an ad-hoc identity and verifies at the final path.

## How the proxy works

`ansi-proxy.js` listens on localhost and forwards to `api.anthropic.com`, passing your auth headers through untouched. On the way back it rewrites assistant text, turning a bare `[31m` into a real escape sequence. It handles both streamed and non-streamed responses, and carries a buffer across stream chunks so a sequence split down the middle still gets repaired. It writes its port to `~/.cache/claude-ansi/port`, picks another port if the default is taken, and one instance serves every session.

Nothing is logged or stored. Auth material is forwarded and never read.
