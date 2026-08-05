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

## Narrowed to PSR1: the original args turned LOBF *on* (2026-08-05)

The original `xe.enable_psr=0` had a side effect nobody noticed for two
weeks: it enabled a *different* eDP link-power feature. From
`drivers/gpu/drm/i915/display/intel_alpm.c`, in
`intel_alpm_lobf_compute_config()`:

```c
if (crtc_state->has_psr)
	return;
```

LOBF (Link Off Between Frames) only engages when PSR is **not** active. So
disabling PSR entirely is precisely what allowed LOBF to run on this machine.
LOBF is now the leading theory for the panel wedge in
[../power/s2idle-rapid-resume-hang.md](../power/s2idle-rapid-resume-hang.md),
which makes this workaround a candidate contributor to that bug rather than
unrelated background.

Changed to `xe.enable_psr=1` (PSR1 only) as a result. That re-asserts
`has_psr`, so LOBF never computes, while leaving PSR2 selective fetch — the
mechanism this doc actually root-caused to the DSB deadlock — disabled.

**Verification needed after the next reboot:**

```bash
journalctl -k -b 0 | grep -c "DSB 0"                                      # expect 0
sudo cat /sys/kernel/debug/dri/0000:00:02.0/eDP-1/i915_edp_lobf_info      # expect LOBF status: disabled
sudo cat /sys/kernel/debug/dri/0000:00:02.0/i915_dmc_info                 # expect nonzero DC5/DC6 counts
```

If the DSB error count is nonzero under GPU-heavy load, PSR1 triggers the
deadlock too and the revert command above puts the blunter arg back.

## What the original boot args did NOT disable

Worth stating explicitly, because this doc's args were treated elsewhere in
the repo as meaning "link power management is off." They weren't. With all
three of the *original* args set:

```
$ sudo cat /sys/kernel/debug/dri/0000:00:02.0/eDP-1/i915_edp_lobf_info
LOBF status: enabled
Aux-wake alpm status: disabled
Aux-less alpm status: enabled
```

LOBF (Link Off Between Frames, eDP 1.5, part of ALPM) powers the physical eDP
link down between frames rather than stopping frames the way PSR does. It's a
separate feature with a separate mechanism and no `xe.*` module parameter.

The debugfs node `eDP-1/i915_edp_lobf_debug` (write non-zero to set
`alpm.lobf_disable_debug`) looks like a direct kill switch but **is unusable
on this machine**:

```
$ echo 1 | sudo tee .../eDP-1/i915_edp_lobf_debug
tee: '.../i915_edp_lobf_debug': Operation not permitted

$ cat /sys/kernel/security/lockdown
none [integrity] confidentiality
$ mokutil --sb-state
SecureBoot enabled
```

Secure Boot puts the kernel in lockdown integrity mode, which blocks
`DEFINE_SIMPLE_ATTRIBUTE`-backed debugfs files for both read and write. Not a
permissions issue; `sudo` doesn't help. Disabling Secure Boot would unblock it
but breaks TPM2-sealed LUKS auto-unlock (PCR 7 covers Secure Boot state, see
[../disk-encryption/tpm2-luks.md](../disk-encryption/tpm2-luks.md)) and the
MOK-enrolled DKMS modules. Not worth it for a test, which is why the PSR1
route above was taken instead.

## Power cost of the original args, with a mechanism (2026-08-05)

The trade-off estimate below (~0.5-1W, never measured) now has a confirmed
mechanism behind it. This is measured with the original `xe.enable_psr=0`;
the PSR1 change above should reverse it:

```
$ sudo cat /sys/kernel/debug/dri/0000:00:02.0/i915_dmc_info
DC3CO count: 0
DC3 -> DC5 count: 0
DC5 -> DC6 allowed count: 0
```

Display C-state entry on eDP is gated on PSR, so disabling PSR means the
display engine never power-gates at all, on this machine, ever. That's the
real cost of this workaround. It also means `xe.enable_dc=0` is a no-op here,
which is useful to know before reaching for it as a display-bug lever.

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
