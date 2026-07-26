# Platform never enters S0ix (`substate_residencies` stuck at zero) during `s2idle`

**Status:** Partially fixed. PCI runtime-PM was a real, confirmed gap and is now
corrected. The platform still isn't reaching any S0ix substate, so a second,
unidentified blocker (likely firmware-level) remains open.

## Symptom

Battery went from 15% to 9% overnight (2026-07-25 23:57 to 2026-07-26 07:48,
lid closed the whole time). That number turned out to be a red herring on its
own, it's within normal `s2idle` drain range, but chasing it surfaced a real
platform bug.

The suspend itself was clean: lid closed 23:57:37, one continuous `s2idle`
sleep for 7h51m, no interruptions, lid reopened 07:48:30. Battery dropped
15%→10% across that window (~0.63%/hour, from `upower` history), then a
further point to 9% in the minute after waking from normal resume overhead.

0.63%/hour looks fine at a glance. The real question is whether the platform
is reaching its S0ix idle floor during that sleep, or just parking the CPU
while everything else stays powered. It's the latter:

```
$ sudo cat /sys/kernel/debug/pmc_core/substate_residencies
pmc0   Substate       Residency
         S0i2.0               0
         S0i2.1               0
         S0i2.2               0
```

All three S0i2 tiers read zero, accumulated across the entire boot (since
2026-07-25 14:05:43) through at least 8 suspend/resume cycles including the
7h51m sleep. Platform-level power gating never engaged once, the whole
night.

## Root cause #1 (confirmed, fixed): every PCI device pinned at `power/control=on`

```
$ cat /sys/class/nvme/nvme0/device/power/control
on
$ for c in /sys/bus/pci/devices/*/power/control; do cat $c; done
on
on
on
... (every PCI device, all "on")
```

Not just NVMe, every PCI device on the system had runtime PM disabled. No
device could reach D3, and Intel's platform power gating requires D3 before
granting any S0ix substate. That maps directly to the flat-zero
`substate_residencies`.

Red herring to rule out first here: it's easy to assume no power-management
daemon is running at all. One is. This system runs `tuned` + `tuned-ppd`
(Fedora's stock swap-in for `power-profiles-daemon`, same D-Bus interface,
confirmed active and correctly wired to KDE's Power Mode slider). The actual
gap is narrower:

| Component | Covers PCI runtime PM? |
|---|---|
| `tuned` `balanced`/`balanced-battery` profiles | No. CPU governor/EPP, ACPI `platform_profile`, audio codec idle timeout, SATA ALPM, `vm.laptop_mode`. Nothing PCI-wide. |
| stock `60-autosuspend.rules` udev rule | No. Only enables devices hwdb-tagged `ID_AUTOSUSPEND=1`, mostly USB HID peripherals. |
| TLP | Would cover it (`RUNTIME_PM_ON_BAT`), but isn't installed. |
| `power-profiles-daemon` | Conflicts at the package level with already-installed `tuned-ppd` (both provide `ppd-service`). Don't install it. |

### Fix

A udev rule, independent of the tuned/ppd stack, requesting `auto` runtime PM
for every PCI device on `add`:

```
# /etc/udev/rules.d/90-pci-runtime-pm.rules
ACTION=="add", SUBSYSTEM=="pci", ATTR{power/control}="auto"
```

Applied live, no reboot needed:

```
sudo udevadm control --reload
sudo udevadm trigger --action=add --subsystem-match=pci
```

Verified every PCI device's `power/control` flipped to `auto` immediately,
persists across reboots via the udev rule (normal coldplug). This sets `auto`
as a request only, the kernel still defers to whether each device's own
driver considers runtime suspend safe.

## Root cause #2 (unresolved): S0ix still zero after the PCI fix

Fresh suspend/resume after the fix (lid closed ~5.5 min, plugged in), then
re-checked:

```
$ sudo cat /sys/kernel/debug/pmc_core/substate_residencies
pmc0   Substate       Residency
         S0i2.0               0
         S0i2.1               0
         S0i2.2               0
```

Still zero. The PCI gap was real and worth fixing regardless, but it wasn't
the only blocker, or wasn't the binding one.

Ruled out:

| Candidate | Evidence | Verdict |
|---|---|---|
| `biopassd` (resident face-unlock daemon, holds `/dev/video0` open) | Underlying USB camera device `power/{control,runtime_status}` shows `auto`/`suspended`, actually suspended at hardware level despite the open handle. | Not the blocker. Holding the fd open doesn't block device runtime suspend. |
| Chrome / Claude Desktop / any userspace app | Kernel freezes all userspace tasks before suspending any device on the way into `s2idle`. A running Electron process can't hold a device active during actual sleep, it isn't running. `systemd-inhibit --list` shows only `delay`-type sleep inhibitors (NetworkManager, ModemManager, UPower, `kwin_wayland`, `claude-desktop`, all brief pre-suspend cleanup), no `block`-type ones. | Not the blocker. Journal confirms suspend actually happened and lasted the full 7h51m. |

Not yet root-caused: `/sys/kernel/debug/pmc_core/substate_requirements` shows
large pending-request counters against `CSE`/`CSMERTC` (Intel ME) and `ISH`
(sensor hub) voltage-rail requirement bits. Firmware-level, not controlled by
any userspace process or udev rule. Consistent with this repo's general
early-silicon (stepping A0) pattern (see [../known-issues.md](../known-issues.md)),
but not confirmed as root cause, no per-component blocker trace done yet.

## Trade-off / current state

Keeping the PCI runtime-PM udev rule regardless. It's correct, carries no
real downside since the driver still gates whether a device actually
suspends, and is a prerequisite for S0ix even if not sufficient alone.

Overnight power draw is still the `s2idle`-without-S0ix baseline (~0.63%/hour
observed), not genuine platform idle power. Not alarming, but likely leaving
real battery life on the table versus a platform that actually reaches
S0i2/S0i3.

## Remaining questions

- Which specific firmware component (ME/CSE, ISH, or something else) is the
  binding LTR/VNN blocker. Needs a controlled suspend cycle with services
  stopped one at a time, diffing `substate_requirements` before/after.
- Whether `ltr_show`'s live `CURRENT_PLATFORM`/`AGGREGATED_SYSTEM` ~0.7ms
  aggregate requirement (observed once, not isolated to a source) is the same
  thing blocking substate entry or a separate signal.
- Whether this is fixable at all on current firmware, or another entry for
  the early-silicon pile like [s3-deep-sleep-hang.md](s3-deep-sleep-hang.md)
  and [s2idle-rapid-resume-hang.md](s2idle-rapid-resume-hang.md).
