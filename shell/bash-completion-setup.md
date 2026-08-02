# Shell tab-completion setup (Ghostty / bash)

**Status:** Resolved — stock `bash-completion` + hand-written/self-generated
per-app scripts. Predictive ghost-text (`ble.sh`) was tried and reverted;
unstable in combination with raw-terminal-mode TUI programs.

## Symptom

Wanted predictive/dropdown-style tab completion in Ghostty — not just for
bash builtins, but for locally-installed, non-packaged CLI tools like `gaze`
(a face-auth CLI, see [face-unlock-authface/](../face-unlock-authface/)) that
don't ship any shell completion of their own.

## Root cause

Ghostty is a terminal emulator only — it doesn't interpret commands or know
what's installed. Completion is entirely a shell-layer feature. The shell in
use was plain interactive `bash` with only the base `bash-completion`
package installed: that gives static Tab-menu completion (press Tab, get a
column list) for anything that ships or registers a completion script, but
no predictive "ghost text" suggestion, and nothing at all for tools with no
script.

Two specific tools had nothing to complete against:
- `gaze` (`/usr/bin/gaze`) — a locally-built Rust/clap CLI, confirmed via
  `rpm -qf /usr/bin/gaze` → "file /usr/bin/gaze is not owned by any
  package", so no distro-shipped completion exists. It also exposes no
  completion generator: `gaze completions`, `gaze completion`, and
  `gaze --generate-completions` all error with "unrecognized
  subcommand"/"unexpected argument".
- `claude` (Claude Code CLI, Commander.js-based) — same situation: no
  `completion` subcommand, no shipped script.

## Fix attempted, then reverted: ble.sh

[ble.sh](https://github.com/akinomyoga/ble.sh) is a bash line-editor
replacement that adds fish/zsh-style autosuggestions (gray "ghost text" from
history) plus a real completion menu on Tab, layered on top of bash's
existing completion system. Installed the prebuilt release tarball
(`v0.4.0-devel3`) to `~/.local/share/blesh/` and sourced it from `.bashrc`.

Two bugs made it not worth keeping:

1. **Duplicate prompt line on every new shell.** Opening a new Ghostty tab
   showed the prompt printed twice (empty, stacked) before any input.
   Suspected cause: ble.sh's default `attach=prompt` timing draws its own
   prompt copy on top of bash's native first-prompt draw. Tried the
   documented fix — source with `--noattach` as the very first line of
   `.bashrc`, call `ble-attach` explicitly as the very last line (after all
   other prompt/completion setup) — this is ble.sh's own recommended
   ordering for exactly this symptom. **Did not resolve it**; the duplicate
   prompt persisted with the corrected ordering too.

2. **Pager state got permanently wedged after `gaze auth`.** `gaze auth`
   drives the camera through a raw-terminal-mode TUI (countdown, live match
   %). The command itself worked correctly (authenticated at 96.9%, 417ms),
   but after it exited, ble.sh's internal screen/pager state was left
   desynced — it started printing `[ble: press RET to continue]`
   repeatedly, and pressing Enter (RET) did not clear it, confirmed by the
   user testing it directly. Only closing the terminal tab recovered; the
   already-running bash process couldn't be salvaged by editing config,
   since ble.sh was already loaded into that session's memory.

Given a "nice to have" feature was producing a wedged terminal, reverted
entirely: removed both `.bashrc` lines (`source ... --noattach` /
`ble-attach`) and deleted `~/.local/share/blesh`.

## Fix that stuck: stock bash-completion + per-app scripts

Fedora's `bash-completion` package (already installed) is sufficient for
*discoverable* completion — Tab shows a candidate list/menu — without
predictive ghost-text. Audited what was actually installed:

**Already covered, no action needed** (each ships its own completion via
its package, auto-loaded lazily from `/usr/share/bash-completion/completions/`):
`dnf`, `git`, `docker`, `podman`, `npm`, `cargo`, `rustup`, `flatpak`,
`code`, `gh`, `tmux`, `jq`, `pip3`, `just`, `pytest`, `rg`, `ssh`,
`systemctl`, `journalctl`.

**Added, self-generated** (tool has a built-in completion-script generator,
just needed capturing and saving):
- `bat` — `bat --completion bash > ~/.local/share/bash-completion/completions/bat`

**Added, hand-written** (no package, no generator exposed — copies kept in
[completions/](completions/)):
- `gaze` — covers all subcommands (`auth`, `add-face`, `refine-face`,
  `list-faces`, `remove-face`, `rename-face`, `clear-user`, `config`,
  `doctor`, `uninstall`) with their actual per-subcommand flags (scraped
  from each `gaze <subcommand> --help`), plus dynamic `-u`/`--user`
  completion against system usernames (`compgen -u`).
- `claude` — subcommand names (`agents`, `auth`, `auto-mode`, `doctor`,
  `gateway`, `install`, `mcp`, `plugin`, `plugins`, `project`,
  `setup-token`, `ultrareview`, `update`, `upgrade`), plus flag names
  scraped from `claude --help` (61 long flags + 8 short). Flag names only —
  no value completion (e.g. `--model` won't suggest `sonnet`/`opus`), and
  since there's no `claude completion` generator to regenerate from, this
  list will silently go stale whenever flags are added/renamed upstream and
  needs re-scraping by hand. Falls back to file completion for positional
  args (prompts/paths).

All installed under `~/.local/share/bash-completion/completions/` (the XDG
user completions dir) — Fedora's `bash-completion` package scans this
automatically, no `.bashrc` wiring required.

**Not pursued:**
- `ruff generate-shell-completion bash` reliably crashes (SIGABRT) on this
  install — confirmed via `coredumpctl list ruff` (real coredump, PID and
  timestamp matched the exact command run). A genuine bug in this `ruff`
  build, not a local workaround target — skipped rather than chased.
- `pipx` completion needs `pipx install argcomplete` +
  `register-python-argcomplete` wiring (the `argcomplete` package is
  already present via `pip show argcomplete`, so this is a small follow-up
  if ever wanted) — not done, wasn't in scope of what was asked for.

## For a bug report

**ble.sh** — both the duplicate-prompt-on-attach and the pager desync after
a raw-terminal-mode subprocess exits look like real upstream bugs
(`akinomyoga/ble.sh`), but reproduction currently depends on `gaze`, which
isn't public. Before filing, would need to reduce to a generic repro: a
small script that does `stty raw`/`tput smcup` (or similar direct terminal
mode manipulation) then restores and exits, to confirm ble.sh's state
tracking — not something specific to `gaze` — is what breaks.

**ruff** — `ruff generate-shell-completion bash` SIGABRTs. Coredump
captured (`coredumpctl list ruff`, 2026-08-02 16:38:45 EDT) but the
backtrace has no symbols (stripped release binary), so it's not directly
actionable upstream without either a debug build or `RUST_BACKTRACE=full`
against a symboled binary.
