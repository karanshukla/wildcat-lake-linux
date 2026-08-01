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
or widgets change, so this is a point-in-time snapshot, kept in sync by an
automated weekly job rather than manual updates.

### Automation

A systemd `--user` timer (`kde-panel-backup.timer`, Sundays 09:00) runs
`~/.local/bin/backup-kde-panel-config.sh`, which copies the two files from
`~/.config/`, and commits + pushes to this repo only if they changed. Chose a
systemd user timer over crond because the push goes through `gh auth
git-credential` against the desktop keyring — that's only reliably unlocked
inside an active login session, which crond jobs run outside of but systemd
`--user` units don't.

Units live in `~/.config/systemd/user/kde-panel-backup.{service,timer}` (not
checked in — machine-local state, not something this repo tracks). Check
status with `systemctl --user list-timers kde-panel-backup.timer`.

### Restoring

```sh
cp panel-config/plasma-org.kde.plasma.desktop-appletsrc ~/.config/
cp panel-config/plasmashellrc ~/.config/
# then either log out/in, or:
plasmashell --replace &
```
