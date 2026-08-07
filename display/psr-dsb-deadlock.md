# Display: PSR2/DSB deadlock on the `xe` driver (Panther Lake A0)

**Status:** Worked around locally via kernel boot args. Not fixed upstream.
**Component:** `xe` KMS driver, GPU device ID `fd80` (Wildcat Lake / Panther Lake, stepping A0)

## Symptom

Chrome (and other GPU-heavy Wayland clients, e.g. YouTube playback) trigger visible
screen glitching. Correlates exactly with Chrome's Wayland GPU process launching.

## Root cause

PSR2 "selective fetch" — a power-saving feature that partially updates only the
changed regions of the screen instead of re-sending the whole frame — deadlocks the
Display State Buffer (DSB) on pipe A under GPU-heavy compositing load. Confirmed via
kernel log correlation: a burst of thousands of

```
[drm] *ERROR* [CRTC:151:pipe A] DSB 0 poll error
```

messages appears in `journalctl -k` timed exactly with the GPU-heavy client starting.

This is very early silicon (A0 stepping) and appears to be the same bug family as a
documented case on a Dell XPS 14 (also Panther Lake):
[basecamp/omarchy#5573](https://github.com/basecamp/omarchy/issues/5573), where it
caused full panel freezes rather than glitching. That report's fix was a kernel
rollback to `6.19.13` (regression window `6.19.13` → `7.0.3`).

## What didn't fully fix it

Updating the kernel `7.1.4-200.fc44` → `7.1.4-202.fc44` alone. DSB errors still
occurred afterward — this is a driver bug, not a packaging/version issue.

## Fix: disable PSR2 selective-fetch / Panel Replay via boot args

**Revised 2026-08-05** — see "Narrowed to PSR1" below. The original fix
disabled PSR entirely (`xe.enable_psr=0`); it now allows PSR1 and disables
only the selective-fetch path that actually deadlocks the DSB:

```bash
sudo grubby --update-kernel=ALL --args="xe.enable_psr=1 xe.enable_psr2_sel_fetch=0 xe.enable_panel_replay=0"
```

`enable_psr` is not a boolean: `0=disabled, 1=enable up to PSR1, 2=enable up
to PSR2` (`modinfo xe`). The original arg took a bigger hammer than the bug
needed.

Reboot. Verify with:

```bash
journalctl -k -b 0 | grep -c "DSB 0"
```

Before: ~17,800+ per 10-minute session under load. After: 0.

Current `/proc/cmdline` should include:

```
xe.enable_psr=1 xe.enable_psr2_sel_fetch=0 xe.enable_panel_replay=0
```

To revert:

```bash
sudo grubby --update-kernel=ALL --remove-args="xe.enable_psr=1 xe.enable_psr2_sel_fetch=0 xe.enable_panel_replay=0"
```

To go back to the original, blunter version (PSR off entirely) if PSR1 turns
out to trigger the DSB deadlock too:

```bash
sudo grubby --update-kernel=ALL --remove-args="xe.enable_psr=1"
sudo grubby --update-kernel=ALL --args="xe.enable_psr=0"
```

## Trade-off

PSR lets the display link idle when the screen is static instead of continuously
re-transmitting the frame. Disabling it costs some battery life, most noticeable
during idle/static-screen periods (reading, typing pauses) — rough estimate
~0.5–1W during those periods, maybe 10–20 minutes off a full charge across a mixed
workday. Not precisely measured (no clean before/after power-draw baseline was
captured). No stability downside observed; fully reversible.

## Narrowed to PSR1 (2026-08-05): the original arg turned LOBF on

The original `xe.enable_psr=0` had a side effect nobody noticed for two weeks:
it enabled a *different* eDP link-power feature. From
`drivers/gpu/drm/i915/display/intel_alpm.c`:

```c
if (crtc_state->has_psr)
	return;
```

LOBF (Link Off Between Frames, eDP 1.5, part of ALPM) only computes when PSR
is inactive, so disabling PSR entirely is what allowed it to run. LOBF powers
the physical eDP link down between frames rather than stopping frames the way
PSR does, and it is now the leading theory for the panel wedge in
[../power/s2idle-rapid-resume-hang.md](../power/s2idle-rapid-resume-hang.md).
That makes this workaround a candidate contributor to that bug rather than the
unrelated background it had been treated as.

With all three of the original args set:

```
$ sudo cat /sys/kernel/debug/dri/0000:00:02.0/eDP-1/i915_edp_lobf_info
LOBF status: enabled
Aux-less alpm status: enabled

$ sudo cat /sys/kernel/debug/dri/0000:00:02.0/i915_dmc_info
DC3CO count: 0
DC3 -> DC5 count: 0
DC5 -> DC6 allowed count: 0
```

Two problems in one. LOBF was running, and the display engine was never
power-gating at all, since DC-state entry on eDP is gated on PSR. The second
is the mechanism behind this doc's previously-unmeasured ~0.5-1W trade-off
estimate, and it also means `xe.enable_dc=0` is a no-op on this machine.

### After changing to `xe.enable_psr=1`

| | Before | After |
|---|---|---|
| `LOBF status` | enabled | **disabled** |
| `DC5 -> DC6 allowed count` | 0 | **58** |
| `PSR mode` | (disabled) | PSR1 enabled |
| DSB errors under GPU load | 0 | **0** |

The DSB check was taken ~10 minutes into the boot with Chrome's GPU processes
live, the condition that previously produced ~17,800 errors per session. PSR1
does not reintroduce the deadlock, so it is specific to PSR2 selective fetch
and the original arg was over-broad.

Net: same glitch fix, LOBF no longer enabled, display power-gating restored.

Note on reading `lobf_info`: the "Aux-wake alpm status" line is literally the
inverse of the aux-less bit in the source, not an independent signal. Only the
`LOBF status` line means anything on its own.

### The direct LOBF kill switch is unusable here

`eDP-1/i915_edp_lobf_debug` (write non-zero to set `alpm.lobf_disable_debug`)
looks like the obvious lever, but:

```
$ echo 1 | sudo tee .../eDP-1/i915_edp_lobf_debug
tee: '.../i915_edp_lobf_debug': Operation not permitted
$ cat /sys/kernel/security/lockdown
none [integrity] confidentiality
```

Secure Boot forces lockdown integrity mode, which blocks
`DEFINE_SIMPLE_ATTRIBUTE` debugfs files for both read and write. Disabling
Secure Boot would unblock it but breaks TPM2-sealed LUKS auto-unlock (PCR 7,
see [../disk-encryption/tpm2-luks.md](../disk-encryption/tpm2-luks.md)) and
the MOK-enrolled DKMS modules. Hence the PSR1 route instead.

## Fallback

Kernel `6.19.10-300.fc44` was left installed alongside `7.1.4` — bootable from GRUB
as an immediate test/rollback without installing anything, mirroring the omarchy
issue's fix, in case the boot-arg workaround ever regresses.

## Upstream status

No fix merged as of this writing. Timeline described by Intel/Dell tuning as
weeks-to-months out given this is A0 silicon. Worth checking for an upstream fix on
each kernel update — see the `journalctl -k` check above.

## Panel T-CON firmware: considered 2026-08-06, declined

Dell's Drivers & Downloads page lists an "LGD Touch Panel Firmware Update
Utility" (06 Aug 2026, marked Critical). The corresponding package is
`OneClickUpdater_v2.1.0.7_PW123_20260707.zip`, and it does target this exact
panel: `Config.ini` sets `SPCase=LP134WQA-SPB1`, and the panel's EDID
manufacturer ID `30 e4` decodes to `LGD` with descriptor string `LP134WQ`.

It is a T-CON (timing controller) firmware update pushed over the eDP AUX
channel via an Analogix bridge (`AnxAuxCommunication.dll`), payload
`Bin/F979_POL_COMP_LOCKMODE_FINAL_260707.bin` (128 KB). Plausibly relevant in
principle, since PSR and LOBF are negotiated between source and sink, and the
sink is the T-CON.

Dell's release notes for it (Driver ID `10FKG`, version `02.02, A00`,
06 Aug 2026, Firmware / Notebook LCD, marked Critical) state exactly one fix:

> Fixed the issue where the touch panel flickers when it is used.

That is a narrow, specific defect: display flicker while the touchscreen is
being touched, i.e. touch-scan noise coupling into the panel. It is none of
the open display bugs here. Not the PSR2/DSB glitching under GPU load, not the
panel wedge, not VRR failing to modulate. No flicker-on-touch symptom has ever
been observed on this machine.

The touchscreen itself is real and present, so the package does target this
hardware: `LXST2024:00 1FD2:5010` on I2C, tagged `ID_INPUT_TOUCHSCREEN=1`.
LX Semicon (VID `1FD2`) supplies the touch-display driver IC for LG Display
panels. It is distinct from the Goodix `GXTP7863` touchpad.

**Declined, deliberately.** The decisive reason is the release note above: it
fixes a defect this machine does not exhibit. The remaining reasons, in order
of weight:

1. The wedge no longer reproduces since `xe.enable_psr=1`. Risking the panel to
   fix something that currently looks fixed is a bad trade.
2. No stated defect, no release notes. The bundled SOP deck only says "run
   tool, see PASS, restart and check the screen".
3. The SOP is for the **wrong panel**: its title reads `LP163WU1-SPB1` (a 16"
   model) while the package targets `LP134WQA-SPB1`. It is an internal rework
   kit reused across models, not a validated per-model release.
4. `Config.ini` is `UpdateMode=FullUpdate` with `AutoRun=1`, so it begins
   flashing on launch with no confirmation step.
5. No signature, verification, result-reporting or rollback story, unlike the
   BIOS capsule path in
   [../firmware/bios-update-capsule-on-disk.md](../firmware/bios-update-capsule-on-disk.md),
   where a bad payload is simply rejected and `last_attempt_status` records
   why. Here a failed write means a dead panel.
6. Windows-only, so running it would require the Windows-To-Go detour that the
   capsule route made unnecessary.

If panel firmware is ever worth revisiting, the thing to look for is a
Dell-signed capsule rather than this rework tool. ESRT entry2
(`ba5c5e4b-d6b8-9845-a498-d25dbb4d2c65`, `fw_version 0`, flagged `Updatable`)
is still unidentified and a panel is a plausible fit; that would be the same
low-risk verified path.

## For a bug report

- Hardware: Dell XPS 13 DX13260, Wildcat Lake/Panther Lake, GPU device ID `fd80`, stepping A0
- Driver: `xe` KMS
- Trigger: any GPU-heavy Wayland client (confirmed with Chrome's GPU process)
- Log signature: `[drm] *ERROR* [CRTC:151:pipe A] DSB 0 poll error`, thousands per session
- Related upstream report: [basecamp/omarchy#5573](https://github.com/basecamp/omarchy/issues/5573)
- Workaround: disable PSR/PSR2-selective-fetch/Panel-Replay via `xe.*` module params
