# Desktop config backups

Unlike the rest of this repo (investigation docs about *why* a config exists),
`panel-config/` is a raw snapshot of the actual KDE Plasma panel/widget layout
files, kept here as a restore point rather than a write-up.

## panel-config/

- `plasma-org.kde.plasma.desktop-appletsrc` — panel containments, applet
  order, and per-widget config (system tray items, task manager, clock,
  kicker/app launcher, folder-view desktop containment).
- `plasmashellrc` — panel geometry: alignment, floating, thickness,
  length mode, visibility per panel.

Both live in `~/.config/` normally. Plasma rewrites them on the fly as panels
or widgets change, so this is a point-in-time snapshot (last updated
2026-08-01), not something kept continuously in sync.

### Restoring

```sh
cp panel-config/plasma-org.kde.plasma.desktop-appletsrc ~/.config/
cp panel-config/plasmashellrc ~/.config/
# then either log out/in, or:
plasmashell --replace &
```
