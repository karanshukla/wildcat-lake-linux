# Claude Desktop on Linux — Copilot-key quick-entry shortcut

**Status:** Active

## Claude Desktop install

Running the unofficial Fedora RPM build from
[aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian)
releases — there's no official Linux package, so this is a community-maintained
repackaging.

## Copilot-key remap via keyd

Bound `Ctrl+Alt+Space` through keyd to emit the dedicated Copilot key, so pressing
that combo triggers Claude Desktop's quick-entry window the same way the Windows
Copilot key opens Copilot on machines that have one — this laptop's keyboard has
no physical Copilot key, so keyd is standing in for it via remap rather than a
raw hardware key.

**Exact keyd config block not re-verified in this pass** — this entry describes
the behavior, not confirmed syntax. If recreating this, the config lives in
`/etc/keyd/default.conf` alongside the [Mac-style Alt remap](keyd-mac-remap.md),
likely using keyd's macro/keysym-remap syntax to bind the chord to the Copilot
keysym (KDE and most desktop shells recognize `XF86Copilot`-style dedicated-key
codes) that Claude Desktop's global shortcut is bound to catch. Confirm against
`/etc/keyd/default.conf` directly before copying this elsewhere.

## For a bug report

Not a bug — a workaround for the absence of a physical Copilot key on hardware
that predates that key's introduction, paired with an unofficial (but functional)
Linux build of Claude Desktop.
