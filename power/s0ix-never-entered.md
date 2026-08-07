# Platform never enters S0ix (`substate_residencies` stuck at zero) during `s2idle`

**Status:** Partially fixed, root cause of the remaining gap isolated and now
re-confirmed. PCI runtime-PM was a real, confirmed gap and is corrected. The
platform still isn't reaching any S0ix substate. The binding blocker is Intel
ME (CSE), confirmed independent of the host `mei` driver. Re-measured
2026-08-05 on kernel 7.1.6 with the display engine power-gating for the first
time (a candidate co-blocker, now ruled out) — CSE still asserts at the same
rate and residency is still zero. Not fixable from Linux at all; this needs a
Dell/Intel firmware update.
PCI runtime-PM was a real, confirmed gap and is now corrected. The platform
still isn't reaching any S0ix substate. `biopassd`, Chrome/Claude Desktop,
AC-vs-battery, and `intel_lpmd` not running are all ruled out with direct
evidence. The binding blocker is Intel ME (CSE), confirmed independent of the
host `mei` driver, not ISH as earlier evidence suggested. Not fixable from
Linux at all, this needs a Dell/Intel firmware update.

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
| AC power vs. battery | Tested both. | Not the blocker, zero residency either way. |
| `intel_lpmd` not running | See below, real finding, but forcing it to run doesn't fix it either. | Not the blocker. |

### `intel_lpmd` is installed, enabled, and silently dead on every boot

Checking the community first: this exact hardware generation (Panther Lake /
Wildcat Lake XPS) has an active Linux user base outside this repo, notably
[Omarchy](https://github.com/basecamp/omarchy) (Arch + Hyprland, popular on
these chips) and the community
[`cachyos-xps-postinstall`](https://github.com/spencerbull/cachyos-xps-postinstall)
toolkit, which explicitly ports Omarchy's Dell XPS Panther Lake hardware
enablement work to CachyOS. Its `30-intel-power-media` module installs and
enables `intel-lpmd` (Intel's own Low Power Mode Daemon, which actively
manages core parking/EPP to help a platform reach S0ix) for a specific list
of CPU model IDs.

`intel-lpmd` turned out to already be installed on this machine
(`intel-lpmd-0.1.0-2.fc44`), enabled, and running, sort of:

```
$ systemctl status intel_lpmd.service
Active: inactive (dead) since ...; 14h ago
Main PID: 892 (code=exited, status=2)
```

It exits immediately on every single boot. Running it directly in debug mode
shows why:

```
[INFO]40 CPUID levels; family:model:stepping 0x6:d5:1 (6:213:1)
[INFO]Platform not supported yet.
[DEBUG]Supported platforms: family 6 models 151,154,170,172,183,186,189,191,204
```

This CPU is family 6 model 213 (`0xd5`, Wildcat Lake). Not in `intel_lpmd`'s
hardcoded supported-platform list, an upstream gap, not a packaging or config
issue. (The CachyOS script's own model-ID allowlist is the identical list,
lifted straight from `intel_lpmd`'s own check.)

Filed upstream: [intel/intel-lpmd#123](https://github.com/intel/intel-lpmd/issues/123).

There's a `--ignore-platform-check` flag to force it to run anyway. Tested it
directly, twice, both suspend/resume cycles fully clean and confirmed real
(see methodology note below): `substate_residencies` still reads zero with
`intel_lpmd` running the whole time. So `intel_lpmd`'s absence wasn't the
cause either, ruled out cleanly rather than left as a loose end.

Kept it running permanently anyway via a systemd drop-in, since its actual
job (EPP/core-parking management based on live utilization) is about
*active*-idle efficiency, a different mechanism from suspend-time S0ix, so it
can still be worth having even though it didn't fix this specific bug:

```
# /etc/systemd/system/intel_lpmd.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/bin/intel_lpmd --systemd --dbus-enable --ignore-platform-check
```

Falls back to the generic `/etc/intel_lpmd/intel_lpmd_config.xml` (no
model-specific config exists for M213 yet), applied via `daemon-reload` +
`restart`, confirmed `active (running)`.

Since a proper fix (`id_table` entry + tuned config, instead of just
ignoring the platform check) looked doable, built and tested one from
source. Confirmed on this hardware: `intel_lpmd`'s own CPUID-based
detection reports 2 P-cores, 0 E-cores, 4 L-cores (`2P0E4L-15W`), matching
Intel ARK's published spec for the Core 5 320 (2 Performance-cores, 0
Efficient-cores, 4 Low Power Efficient-cores) and *not* what `lscpu -e`'s
L2-instance grouping suggests (looks like a single E-core cluster). Opened
upstream: [intel/intel-lpmd#124](https://github.com/intel/intel-lpmd/pull/124).

### Testing methodology note (matters if revisiting this)

First attempt used `rtcwake -m mem -s N` to automate suspend/resume without
touching the lid. This is a real, valid trap: `rtcwake` on this system writes
directly to the kernel's `/sys/power/state`, bypassing `systemd-logind`
entirely. Comparing journal output side by side:

| | Real lid-close suspend | `rtcwake -m mem` |
|---|---|---|
| `systemd-logind: Lid closed` | yes | n/a |
| `systemd-logind: The system will suspend now!` | yes | **no** |
| `ModemManager: system is about to suspend` | yes | **no** |
| Screen actually locks (`kscreenlocker_greet` spawns) | yes | **no** |

Without logind's `Suspend()` D-Bus call, it never emits `PrepareForSleep`, so
none of the processes holding `delay`-type sleep inhibitors (NetworkManager,
ModemManager, UPower, `kwin_wayland`'s lock-the-screen action) get a chance
to run their pre-suspend step, including the one that locks the screen. The
kernel-level suspend itself is still real (`PM: suspend entry/exit`, correct
`s2idle`, correct elapsed duration), so this didn't invalidate the original
overnight finding (that was a real lid-close, went through logind properly).
But it meant the two `intel_lpmd` test cycles done this way weren't a clean
comparison to real-world suspend.

Fix: arm the wake alarm separately, then suspend through the path that
actually calls logind:

```
sudo rtcwake -m no -s 90       # arms the RTC alarm only, returns immediately
sudo systemctl suspend         # goes through logind's real Suspend() D-Bus call
```

Confirmed this route is equivalent to a real lid-close: `kscreenlocker_greet`
actually spawned and locked the session. Re-ran the `intel_lpmd` test this
way, still zero residency, this is the result that stands.

One more loose thread worth a closer look separately: every resume in every
test logged `nvme nvme0: failed to allocate host memory buffer`. Not yet
connected to the S0ix problem, but a real recurring warning on every single
resume regardless of test method.

## Root cause #3 (confirmed): Intel ME (CSE), independent of the host `mei` driver

A single snapshot of `substate_requirements` can't tell "always required since
boot" apart from "actively blocking during this specific sleep." Fixed that by
diffing the counter values immediately before suspend against immediately
after resume, isolating exactly what accrued during the sleep window itself.

Control cycle (~90s real `s2idle`, everything loaded as normal, driven through
logind per the methodology note above, not `rtcwake` directly):

| Signal | Delta over ~90s | Read |
|---|---|---|
| `XTAL_AGGR_OFF_STS`, `SOC_PLL_OFF_STS`, `CLINK_PGD0_PG_STS`, `SMT1`/`SMS1`/`SMS2`, `AON2`/`AON3`/`AON5` | +2,942,943 (identical across all of them) | Free-running reference clock, not a real blocker, ignore |
| `CSE_PGD0_PG_STS` / `CSE_VNN_REQ_STS` | +65,332 | Continuously asserted "required" the entire sleep |
| `CSMERTC_VNN_REQ_STS` | +65,298 | Tracks CSE almost exactly, expected (ME's RTC subcomponent) |
| `ISH_VNN_REQ_STS` | 0 | Did not move, in this cycle or any other tested |

`ISH_VNN_REQ_STS` read exactly 0 before, during, and after every test in this
investigation, with the ISH driver stack fully loaded and sensors present.
The earlier suspicion of ISH as a co-blocker doesn't hold up under an actual
delta measurement, ISH is cleanly ruled out.

CSE is the standout, and its counter climbs continuously through the sleep
regardless. Tested whether that's the Linux `mei` host driver holding the
ME device active, or the ME firmware's own independent behavior:

```
$ sudo rmmod mei_gsc_proxy && sudo rmmod mei_me && sudo rmmod mei
$ ls /dev/mei*
ls: cannot access '/dev/mei*': No such file or directory
```

Repeated the same suspend/diff cycle with the entire `mei` stack unloaded
(`/dev/mei0` gone, no host driver bound at all):

| Signal | Delta with `mei` loaded | Delta with `mei` unloaded |
|---|---|---|
| `CSE_PGD0_PG_STS` / `CSE_VNN_REQ_STS` | +65,332 | +65,263 |
| `CSMERTC_VNN_REQ_STS` | +65,298 | +65,230 |

Same rate within noise, unloading the host driver changed nothing. The
Management Engine is its own co-processor running its own firmware
independent of the host OS, and it kept asserting its power requirement with
no Linux-side driver bound to it at all. This rules out every remaining
userspace lever: no udev rule, no driver unbind, no systemd unit can touch
this, it's ME firmware behavior. Only a Dell/Intel firmware (BIOS/ME) update
could change it.

Reloaded `mei`/`mei_me`/`mei_gsc_proxy` after, confirmed `mei_gsc_proxy`
re-bound cleanly (`bound 0000:00:02.0 (ops xe_gsc_proxy_component_ops [xe])`),
system fully back to its normal state.

Consistent with this repo's general early-silicon (stepping A0) pattern, see
[../known-issues.md](../known-issues.md).

## New candidate co-blocker, untested (2026-08-05): the display engine was never power-gating either

Every measurement in this doc was taken while the display engine was pinned
on. Discovered while investigating the panel wedge in
[s2idle-rapid-resume-hang.md](s2idle-rapid-resume-hang.md):

```
$ sudo cat /sys/kernel/debug/dri/0000:00:02.0/i915_dmc_info    # before 2026-08-05
DC3CO count: 0
DC3 -> DC5 count: 0
DC5 -> DC6 allowed count: 0
```

Display C-state entry on eDP is gated on PSR, and PSR was force-disabled by
this machine's own `xe.enable_psr=0` boot arg (from
[../display/psr-dsb-deadlock.md](../display/psr-dsb-deadlock.md)). So the
display power wells never went down, ever, on any of the suspend cycles tested
in this doc.

That matters here because S0ix requires the display power wells to be off.
The ME/CSE finding above is solid and independently confirmed (it survives
unloading the entire `mei` stack), but it was never established as the *only*
blocker — a pinned display engine is a second, entirely separate reason the
platform could never have reached an S0ix substate, and it was invisible
because nobody looked at `i915_dmc_info` during that investigation.

### Tested 2026-08-05, and ruled out

Re-measured with `xe.enable_psr=1` in place, DC5/DC6 accruing normally, and on
kernel 7.1.6-201. 90s sleep through logind, via `measure-s0ix.sh` in this
directory:

```
Residency AFTER:
  S0i2.0  0
  S0i2.1  0
  S0i2.2  0
```

Still zero. Removing the display blocker changed nothing.

| Element | Delta over ~90s (2026-07) | Delta over ~90s (2026-08-05) | Read |
|---|---|---|---|
| free-running clocks (`XTAL_AGGR`, `SOC_PLL`, `SMT`/`SMS`, `AON2/3/5`, `CLINK`, `FILTER_PLL`) | +2,942,943 | +2,912,188 | Reference baseline, not blockers |
| `CSE_VNN_REQ_STS` / `CSE_PGD0_PG_STS` | +65,332 | **+61,338** | Unchanged. Still asserting through the whole sleep |
| `CSMERTC_VNN_REQ_STS` | +65,298 | +61,304 | Tracks CSE, expected (ME's RTC subcomponent) |
| `ISH_VNN_REQ_STS` | 0 | 0 | Still ruled out |
| `DISP_SHIM_VNN_REQ_STS`, `DDI_PLL_OFF_STS`, `D2D_DISP_DDI_QACTIVE_REQ_STS` | 0 | **0** | Display asserts nothing during sleep, before or after the change |

The display elements read zero-delta both before and after the display engine
started power-gating, which is about as direct as this gets: the display was
never participating in the S0ix blockage in either direction. The hypothesis
above is closed.

Two incidental details from this run, not previously recorded:

- `AON4_OFF_STS` moved +61,338, exactly matching CSE rather than the
  free-running AON2/3/5 group. It's presumably in the ME's always-on domain.
- `SE_TCSS_PLL_OFF_STS` moved +61,264, also tracking CSE closely.

**Net effect: this strengthens the original conclusion rather than changing
it.** CSE is now confirmed as the binding blocker across three independent
measurements, on two kernels, with the display power path in two materially
different states. That's a better bug report to Dell than the original.

## Corroboration: Intel's own S0ix Selftest Tool agrees

Ran [intel/S0ixSelftestTool](https://github.com/intel/S0ixSelftestTool)
(`./s0ix-selftest-tool.sh -s`) independently of the hand-rolled
`measure-s0ix.sh` above, three times: 2026-08-05 07:23 and 07:26 (alongside
the display-engine test), and fresh on 2026-08-06 with kernel 7.1.6. Same
conclusion every time, from Intel's own diagnostic script rather than a
custom one:

```
Low Power S0 Idle is:1
Your system supports low power S0 idle capability.

S0ix substate residency before S2idle:
  0 0 0

Turbostat output:
SYS%LPI
0.00
0.00

The system does not support the Pkg%pc2/pc3/pc6/pc8.
Your system did not achieve PC2 state or PC2 residency is low.
```

The 2026-08-06 run also captured what the two 2026-08-05 runs didn't: the
active `cpuidle` driver and per-state sysfs dump. `current_driver` reads
`intel_idle`, but the state table underneath is ACPI-sourced
(`C1_ACPI`/`C2_ACPI`/`C3_ACPI`, descriptions `ACPI FFH MWAIT 0x0/0x21/0x60`),
not `intel_idle`'s normal native table. Consistent with
[intel-idle-no-wildcat-lake-entry.md](intel-idle-no-wildcat-lake-entry.md):
no static table entry for model `0xD5`, so `intel_idle` falls back to
building its state table from ACPI `_CST` instead.

Logged for next time: the two 2026-08-05 runs' archived `.log` files cut off
mid-way, both ending at the same line (`Check what's the CPU idle driver
status:`) with nothing after it. Not a script crash, the tool's
`debug_no_pc2()` function (`s0ix-selftest-tool.sh:743,745`) pipes `cat
current_driver` and `grep .../state*/*` straight to the terminal instead of
through the script's own `log_output()` wrapper, so that output was only ever
visible live, never saved to the log. If a future run needs that section
preserved, wrap the invocation in `tee` rather than relying on the tool's own
archiving.

## For a bug report

Easiest reproduction is `measure-s0ix.sh` in this directory, which automates
the delta method below (`sudo ./measure-s0ix.sh 90`), or
`S0ixSelftestTool`'s `s0ix-selftest-tool.sh -s` for Intel's own equivalent
check. Manual steps, to Dell (BIOS/ME firmware):

1. `sudo cat /sys/kernel/debug/pmc_core/substate_requirements`, note
   `CSE_VNN_REQ_STS`/`CSE_PGD0_PG_STS` values.
2. `sudo systemctl suspend` (lid-close or logind path, not `rtcwake` directly,
   see methodology note above), sleep at least 60s, resume.
3. Re-read `substate_requirements`, diff against step 1. `CSE_*` will have
   climbed continuously through the sleep window while `substate_residencies`
   stays at all-zero.
4. Optionally confirm host-driver-independence: `sudo rmmod mei_gsc_proxy
   mei_me mei`, repeat steps 1-3. Same climb rate, no `mei` bound at all.

Platform: Dell XPS 13 DX13260, Wildcat Lake/Panther Lake stepping A0, GPU
device ID `fd80`. Kernel 7.1.5-200.fc44, `s2idle` only (no S3). PCI
runtime-PM already set to `auto` for all devices (prerequisite, not
sufficient alone). This points at the ME/CSE firmware never releasing its own
VNN/power-gating requirement, not at anything the OS controls.

## Trade-off / current state

Keeping the PCI runtime-PM udev rule regardless. It's correct, carries no
real downside since the driver still gates whether a device actually
suspends, and is a prerequisite for S0ix even if not sufficient alone.

Overnight power draw is still the `s2idle`-without-S0ix baseline (~0.63%/hour
observed), not genuine platform idle power. Not alarming, but likely leaving
real battery life on the table versus a platform that actually reaches
S0i2/S0i3.

## Remaining questions

- Whether `ltr_show`'s live `CURRENT_PLATFORM`/`AGGREGATED_SYSTEM` ~0.7ms
  aggregate requirement (observed once, not isolated to a source) is the same
  ME/CSE signal or a separate one.
- The recurring `nvme nvme0: failed to allocate host memory buffer` on every
  resume, unconnected to this investigation so far, but consistently present.
- Whether Wildcat Lake support lands in a future `intel_lpmd` release. Issue
  filed at [intel/intel-lpmd#123](https://github.com/intel/intel-lpmd/issues/123),
  fix proposed at [intel/intel-lpmd#124](https://github.com/intel/intel-lpmd/pull/124).
  Moot for this specific bug either way, `intel_lpmd` manages CPU
  core-parking/EPP, not ME firmware state, so it was never going to touch
  this blocker regardless of platform-check support.
- `intel_idle` also has no entry for model `0xD5` and runs from ACPI
  `_CST` here, found 2026-08-05 (see
  [intel-idle-no-wildcat-lake-entry.md](intel-idle-no-wildcat-lake-entry.md)).
  Also not this blocker: S0ix needs the cores in CC10 and they already get
  there. Noted so it doesn't get re-investigated as a candidate. It does
  mean `turbostat` can't read package C-states on this model, so PC10 is
  currently unmeasurable.
- Whether Dell ships a BIOS/ME firmware update that changes this behavior.
  This is now confirmed as the only remaining lever, nothing left to try from
  the OS side. Checked 2026-08-05 on both `lvfs` and `lvfs-testing`:
  `No updates available` on both channels. DX13260 has zero LVFS releases at
  all. Otherwise, another entry for the early-silicon pile like
  [s3-deep-sleep-hang.md](s3-deep-sleep-hang.md) and
  [s2idle-rapid-resume-hang.md](s2idle-rapid-resume-hang.md).

## BIOS 1.6.0 tested 2026-08-06: does not fix it, and could not have

BIOS was updated 1.3.0 -> 1.6.0 by extracting Dell's Windows-only `.exe` and
staging the signed image as a UEFI capsule-on-disk, no Windows needed. See
[../firmware/bios-update-capsule-on-disk.md](../firmware/bios-update-capsule-on-disk.md).
The flash succeeded on the first attempt (`last_attempt_status 0`,
`fw_version 67072` = `0x010600`, `dmidecode` 1.6.0 dated 07/16/2026).

Measured immediately after, with `power/measure-s0ix.sh 90`:

```
PM: suspend entry (s2idle)   22:32:07
PM: suspend exit             22:33:38     (91 s, clean, no wedge)

S0i2.0  0     S0i2.1  0     S0i2.2  0
slp_s0_residency_usec        0
Package C10  4,555,167 -> 95,615,798
```

Cores reach CC10 as always. The platform still enters no S0ix substate. **No
change from 1.3.0.**

This is not evidence against root cause #3. It is what root cause #3 predicts.
Dell's `platform.ini` for this package sets:

```
[Region]   BIOS=1  GbE=0  ME=0  EC=0  DESC=0  Platform_Data=0
[UpdateEC] Flag=0
```

so the update wrote the BIOS region only and never touched CSE firmware.
Confirmed afterwards: ESRT entry1 `fw_version` is unchanged at 1345.

### The CSE firmware is separately updatable, and that is the lever

ESRT entry1, GUID `865d322c-6ac7-4734-b43e-55db5a557d63`, is the Intel ME/CSE
firmware. `/sys/class/mei/mei0/fw_ver` reports `21.50.1.1345`, and entry1's
`fw_version` is `1345`. The build numbers match exactly.

fwupd lists it as `Updatable`, "Updated via capsule-on-disk", with
`lowest_supported_fw_version 1000`. So the mechanism to update CSE firmware on
this machine exists and works. What is missing is a CSE capsule to feed it:
Dell's BIOS package deliberately excludes the ME region, and there is no LVFS
release for this model.

(`mei0/fw_ver` reports three partition versions, `21.50.1.1345`,
`21.50.1.1345` and `21.50.1.1375`. Which of those ESRT tracks is not
established; the match on 1345 is the operational one.)

That makes the ask to Dell specific and small: publish a CSE firmware capsule,
or ship this model on LVFS at all. Everything on the host side already works.
