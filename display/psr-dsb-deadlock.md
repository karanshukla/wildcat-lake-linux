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

## For a bug report

- Hardware: Dell XPS 13 DX13260, Wildcat Lake/Panther Lake, GPU device ID `fd80`, stepping A0
- Driver: `xe` KMS
- Trigger: any GPU-heavy Wayland client (confirmed with Chrome's GPU process)
- Log signature: `[drm] *ERROR* [CRTC:151:pipe A] DSB 0 poll error`, thousands per session
- Related upstream report: [basecamp/omarchy#5573](https://github.com/basecamp/omarchy/issues/5573)
- Workaround: disable PSR/PSR2-selective-fetch/Panel-Replay via `xe.*` module params
