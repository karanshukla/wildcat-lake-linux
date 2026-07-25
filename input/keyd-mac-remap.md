# Keyboard remapping — keyd (Mac-style Alt-as-Cmd layer)

**Status:** Active
**Tool:** [keyd](https://github.com/rvaiya/keyd), config at `/etc/keyd/default.conf`, service active + enabled

## What it does

Remaps held-Alt to act as Ctrl for common Mac-style shortcuts:

```
[alt]
a=C-a  c=C-c  v=C-v  x=C-x  z=C-z  t=C-t  r=C-r
```

## Why keyd over alternatives

- **toshy** — originally used for this plus `Alt-D`→`Super-D` (show desktop) and
  `Alt-L`→`Super-L` (lock) via `toshy_config.py`. Fully purged after diagnosing a
  stuck-modifier/grab-ungrab bug traced to `xwaykeyz` v1.23.3's incompatibility
  with Fedora 44 KDE Wayland. Survived a clean reinstall attempt before being
  abandoned. **If recreating this setup, the Super-D/Super-L binds need to be
  redone in keyd** — they don't carry over automatically.
- **openlogi** — was fighting toshy for input-device grabs while both were
  installed; fully purged (home directory and system remnants) alongside toshy.
- **meta-mac** — considered, rejected as unmaintained / more scope than needed.

keyd operates at a lower level (input subsystem, not a userspace X11/Wayland key
remap daemon), which avoids the whole class of grab/ungrab races that broke toshy
under Wayland.

## Installer

Published as a public gist (`install-mac-shortcuts.sh`) with a curl-based
reinstall command, for quickly reapplying this on a fresh install.

## Left incomplete

MX Master 3S button remap — exploration started, not finished.

## For a bug report

Not itself a bug report — this is a config choice, not a driver/kernel issue. Worth
keeping here as a data point that `xwaykeyz`/toshy has a known stuck-modifier bug
under Fedora 44 KDE Wayland (v1.23.3) if anyone else hits it.
