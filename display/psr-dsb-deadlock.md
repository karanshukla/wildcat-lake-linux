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

## Fix: disable PSR / PSR2 selective-fetch / Panel Replay via boot args

```bash
sudo grubby --update-kernel=ALL --args="xe.enable_psr=0 xe.enable_psr2_sel_fetch=0 xe.enable_panel_replay=0"
```

Reboot. Verify with:

```bash
journalctl -k -b 0 | grep -c "DSB 0"
```

Before: ~17,800+ per 10-minute session under load. After: 0.

Current `/proc/cmdline` should include:

```
xe.enable_psr=0 xe.enable_psr2_sel_fetch=0 xe.enable_panel_replay=0
```

To revert:

```bash
sudo grubby --update-kernel=ALL --remove-args="xe.enable_psr=0 xe.enable_psr2_sel_fetch=0 xe.enable_panel_replay=0"
```

## Trade-off

PSR lets the display link idle when the screen is static instead of continuously
re-transmitting the frame. Disabling it costs some battery life, most noticeable
during idle/static-screen periods (reading, typing pauses) — rough estimate
~0.5–1W during those periods, maybe 10–20 minutes off a full charge across a mixed
workday. Not precisely measured (no clean before/after power-draw baseline was
captured). No stability downside observed; fully reversible.

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
