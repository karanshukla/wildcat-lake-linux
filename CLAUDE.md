# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A documentation/log repository — not a software project. There is no build, lint,
or test tooling; it's a collection of Markdown write-ups tracking discoveries,
fixes, and customizations from running Fedora Linux on a Dell XPS 13 (Wildcat
Lake/Panther Lake, stepping A0 — genuinely early-silicon hardware). It doubles as
a reference to copy from and as source material for upstream bug reports to
Intel/Dell/kernel/KDE maintainers.

The actual system configuration this documents lives on the machine itself
(kernel boot args, udev rules, systemd units, keyd config, etc.) — this repo is
the record of *why* those changes exist, not the files themselves.

## Layout

```
display/                   PSR/DSB display bug and fix
camera/                     kamoso raw-format 5fps issue
audio/                      CS42L43 speaker EQ fix, mic gain fix
input/                      keyd remap, touchpad scroll fix, Claude Desktop quick-entry
face-unlock-biopass/        biopass fork: resident daemon + NPU backend
disk-encryption/            TPM2 LUKS auto-unlock
power/                      S3 deep-sleep hang, s2idle rapid-resume hang, S0ix-never-entered
known-issues.md             everything still open/unresolved
```

`README.md` has a status-summary table mapping every issue to its doc and
current state (worked around / active / unresolved / partially fixed) — update
that table whenever a doc's status changes, it's the single source of truth for
"what's fixed vs. still open."

## Doc conventions

Each investigation doc follows roughly the same shape — match it for new docs:

1. **Symptom** — what was observed, with concrete evidence (command output,
   timestamps, battery percentages, log excerpts).
2. **Root cause** — with evidence, not speculation. Where multiple candidate
   causes were tested and ruled out, document the ruling-out explicitly (what
   was tested, what result excluded it) rather than deleting that trail —
   these repos evolve as new suspects get tested and cleared.
3. **Fix/workaround** — actual commands/config, and its trade-offs.
4. **"For a bug report" section** — summarizing what an upstream maintainer
   would need to reproduce or act on it.

Status lines at the top of a doc (e.g. "Partially fixed", "Reverted to
`s2idle` default") must stay in sync with both `README.md`'s table and
`known-issues.md`. When new evidence changes a doc's conclusion, update the
status line, don't leave a stale verdict alongside newer findings further
down.

Timestamps and dates are recorded absolutely (e.g. `2026-07-25 23:57:37`), not
relatively — these docs get re-read long after "yesterday" stops meaning
anything.

`known-issues.md` is exclusively for problems with no fix or workaround yet.
As soon as something in it gets resolved or worked around, move its narrative
into a doc under the relevant topic directory, link that doc from
`known-issues.md`'s history, and update `README.md`'s status table.

## The biopass fork

`face-unlock-biopass/` documents work on a fork of
[TickLabVN/biopass](https://github.com/TickLabVN/biopass) (branch
`karanshukla/biopass @ feat/resident-biopassd`), not code in this repo. Two
upstream issues are filed against it (#151 NPU/GPU, #152 cold-start latency).
When updating these docs, keep the status table in
`face-unlock-biopass/README.md` in sync with what's actually implemented on
the fork branch vs. merely investigated.

## Git

Commit messages in this repo describe documentation changes about the
underlying system config/investigation (e.g. "Document S0ix never entered
during s2idle, PCI runtime-PM fix"), not code changes — follow that pattern:
summarize what was learned/fixed on the machine, not "update docs."

Never commit PII or other sensitive data. These docs quote real command
output (logs, `journalctl`, hardware IDs, file paths) — scrub anything
personally identifying (usernames tied to real identity beyond what's already
public here, serial numbers, MAC/IP addresses, precise location data, etc.)
before it lands in a commit.
