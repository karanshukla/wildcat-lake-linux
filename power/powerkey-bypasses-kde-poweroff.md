# Power button bypasses KDE's "show logout screen" setting, powers off directly

**Status:** Unresolved, not root-caused. One confirmed occurrence, not yet
reproduced on demand.

## What happened

KDE Power Management (`Settings > Power Management > On AC Power`) is
configured with `When power button pressed: Show logout screen`. Pressing
the power button on 2026-08-04 at 21:24:19 EDT instead powered the machine
off immediately, no logout screen, no confirmation, straight to shutdown.

`journalctl -b -1` for that session:

```
21:24:19  systemd-logind[1031]: Power key pressed short.
21:24:19  systemd-logind[1031]: The system will power off now!
21:24:19  systemd-logind[1031]: System is powering down.
21:24:19  systemd[1]: Stopping plasma-powerdevil.service - Powerdevil...
21:24:19  systemd[1]: Stopped plasma-powerdevil.service - Powerdevil.
...
21:25:01  systemd[1]: Reached target poweroff.target - System Power Off.
```

`logind` ran its own native power-key handler directly, bypassing KDE
entirely.

## Root cause

Not established. What's confirmed:

- **`logind`'s compiled-in default is `poweroff`.** No override in
  `/etc/systemd/logind.conf` or `logind.conf.d/`; runtime query confirms
  `HandlePowerKey` = `"poweroff"`. This default is only supposed to apply
  when nothing else is handling the key — a desktop session is expected to
  inhibit it.
- **PowerDevil is designed to inhibit this**, and does, right now:
  `systemd-inhibit --list` on this machine currently shows PowerDevil
  holding a `block`-mode inhibitor covering
  `handle-power-key:handle-suspend-key:handle-hibernate-key:handle-lid-switch`
  ("KDE handles power events"). A `block`-mode inhibitor is supposed to make
  `logind` defer entirely to the inhibitor holder instead of running its own
  handler — so this shouldn't have been possible with the inhibitor in place.
- **PowerDevil did not crash in the affected boot.** It started at 21:07:52
  (`journalctl -b -1 _COMM=org_kde_powerdevil`), ran for the full ~17 minutes
  up to the incident with no errors, and `plasma-powerdevil.service` shows no
  restart anywhere in that boot's log, only being stopped *after* the
  poweroff sequence had already begun.

So the inhibitor mechanism exists, is correctly configured, and the process
holding it was alive and apparently healthy the whole time — yet `logind`
acted as if no inhibitor existed at the moment the key was pressed. Whether
the inhibitor was actually held at that exact instant (a transient drop) or
whether `logind` failed to honor a genuinely-held inhibitor isn't
distinguishable from the available evidence; there's no capture of inhibitor
state *at* the moment of failure, only confirmation it's healthy before and
after.

**Circumstantial context, not proof:** this happened the same day as
extensive suspend/resume/lock churn and three forced reboots (see
[s2idle-rapid-resume-hang.md](s2idle-rapid-resume-hang.md)'s "Third
incident"), and is the same general shape as an already-documented, also
unresolved issue: PowerDevil failing to reliably own a power-management
event it's supposed to inhibit (see that doc's 2026-08-03 section, where 11
of 13 lid-close suspend requests were denied by `polkitd` with no clear
cause). Whether these share a root mechanism (PowerDevil/`logind`/`polkitd`
session-state fragility building up under repeated suspend/crash/reboot
cycling) or are coincidentally similar-looking separate bugs isn't
established — flagging the pattern, not claiming the link.

**Ruled out:** a boot parameter suggestion found online
(`acpi_backlight=native`) does not apply here — that changes which ACPI
interface controls display backlight brightness, unrelated to `logind` power-
key handling or inhibitors. Not applied.

## For a bug report

Not enough evidence yet for a solid upstream report — needs a live capture of
`systemd-inhibit --list` at the moment of a repeat occurrence (or ideally,
`busctl` monitoring of `org.freedesktop.login1` inhibitor
acquire/release around a power-key press) to show whether the inhibitor
actually lapses or `logind` disregards a held one. If it recurs:

1. Immediately run `systemd-inhibit --list` (if the machine is still up long
   enough) or check the next boot's `journalctl -b -1` for the same
   `Power key pressed short.` → `will power off now!` sequence.
2. Check whether `plasma-powerdevil.service`/`org_kde_powerdevil` shows any
   crash, restart, or D-Bus disconnection immediately before the event.
3. Check `loginctl session-status` for the active session's state
   (`active`/`online`) at the time, in case a session-activity edge case is
   involved (by analogy with the polkit `allow_active`/`allow_inactive`
   theory in the lid-switch incident).

Platform: Dell XPS 13 DX13260, Fedora 44, KDE Plasma 6 (Wayland),
`systemd-logind` current default `HandlePowerKey=poweroff`, no local
override.
