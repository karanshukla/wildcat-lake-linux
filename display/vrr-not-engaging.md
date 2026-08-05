# Display: VRR/adaptive sync reports capable and enabled, but panel refresh never modulates

**Status:** Unresolved. Two independent measurements confirm the physical panel
refresh never leaves 120Hz, but the video-content test is confounded by a
documented KWin Wayland bug, so root cause isn't isolated between "hardware/driver
doesn't do this" and "KWin's VRR heuristic is broken by other open windows."
Investigated 2026-07-26.

## Symptom

Expectation (carried over from prior non-Linux experience with this class of
panel): idle desktop drops refresh rate, video playback ramps to match content.
Observed instead: no visible difference in behavior between idle and video, and
no way to trust app-level FPS counters as a proxy for what the panel is actually
doing.

## Measurement methodology

Neither the compositor nor any userspace tool can be trusted to report the
panel's actual refresh rate, both can be lying or measuring the wrong layer (see
below). Wrote `vblank_watch.py`, which calls `DRM_IOCTL_WAIT_VBLANK` directly
against pipe A (crtc index 0, confirmed as eDP-1 via
`/sys/kernel/debug/dri/0000:00:02.0/crtc-0/i915_pipe` = `A`) on `/dev/dri/card0`,
and times the real inter-vblank interval. This is the actual hardware vblank
interrupt, nothing in userspace can fake it.

Verified the computed ioctl number (`0xc018643a`) and the `union
drm_wait_vblank` struct layout (24 bytes: `type`, `sequence`, `tval_sec`,
`tval_usec`) against known Linux DRM header values before trusting any output.

Needs root (`/dev/dri/card0` is `root:video`, user not in `video` group). Sudo's
credential cache is tty-scoped, so it had to be run interactively from a real
terminal rather than through an automated session.

## Capability confirmed, real-world modulation not

| Check | Result |
|---|---|
| DRM debugfs `vrr_range` on eDP-1 | `Min: 30`, `Max: 120` (panel is VRR-capable) |
| KWin per-output config (`kscreen-doctor -o`) | `Vrr: Always` (compositor policy set to use it) |
| Vblank measurement, idle desktop, screen locked, ~62s continuous | Pinned at 120.00Hz average (119.93-120.08Hz jitter only), zero deviation, until the ioctl started erroring (`EINVAL`, consistent with the CRTC going inactive when the panel DPMS'd off) |
| Vblank measurement, fullscreen 30fps synthetic video (ffmpeg `testsrc2`, VP9, confirmed exactly 30fps via `ffprobe`), ~49s | Pinned at 120.00Hz average (119.93-120.08Hz), zero tracking to the known 30fps source |

Two clean, independent runs, same result: the physical panel never leaves
120Hz.

## The idle test was confounded once, then fixed

First idle-test attempt was invalid: watching the vblank log scroll live in a
terminal is itself continuous on-screen motion, which alone forces KWin to keep
committing frames at max rate. Redid it with the logger backgrounded to a file
(nothing printed live) and the screen actually locked. That's the clean 62s
result above.

## The video test is NOT clean, and this is a known KWin bug independent of this hardware

Every video test here had a terminal open, because launching/monitoring the
background logger requires one. That's a real confound: from the mpv project's
own VRR bug thread
([mpv-player/mpv#10982](https://github.com/mpv-player/mpv/issues/10982)), a
maintainer states directly that "merely painting stuff in the terminal causes
plasma to break VRR," and multiple independent reporters in that thread needed
to close or minimize *every other window*, not just the fullscreen video
client, before KWin would engage VRR at all.

Related KDE bugs, not confirmed to be the same root cause here, but the same
class of problem:

- [bugs.kde.org#443872](https://bugs.kde.org/show_bug.cgi?id=443872): KWin was
  scheduling repaints for windows even when fully covered by a fullscreen
  window, which broke VRR timing for the fullscreen client. Fixed in Plasma
  5.23.3 (November 2021).
- [bugs.kde.org#500685](https://bugs.kde.org/show_bug.cgi?id=500685): adaptive
  sync randomly sticks at the panel's minimum Hz when switching window focus
  between apps. Still open as of the report (February 2025, Plasma 6.3.1, AMD
  GPU), so this class of bug isn't fully resolved even years after the first
  fix landed.

So the 120Hz-pinned video result could be this KWin bug, not a genuine
hardware/driver VRR failure. Not distinguished yet.

## Separate finding: KWin's own FPS counter measures the wrong thing for this question

Enabled KWin's built-in "Show FPS" effect live via `qdbus-qt6` (`reconfigure`
alone does not reload it, has to be `org.kde.kwin.Effects.loadEffect showfps`
against the `/Effects` path; ships disabled by default, metadata at
`/usr/share/kwin-wayland/builtin-effects/showfps.json`).

It showed ~9fps while typing into a chat window, at the exact same moment the
vblank ioctl was independently confirming the physical panel was still
scanning out 120 times a second. Not a contradiction, they measure different
layers:

- Show FPS = how often KWin's compositor decides it has new content worth
  painting (correctly low while typing, since only a few things change per
  second).
- Vblank ioctl = how often the physical panel actually redraws, electrically,
  which stays at 120Hz regardless of whether the frame changed.

That gap is itself informative: even when KWin's own render loop knows it has
nothing new to show, that decision isn't reaching the DRM connector to extend
the vblank period. If VRR were engaged end-to-end, the panel's real refresh
would track KWin's repaint cadence (clamped to the 30Hz floor), not sit fixed
at max.

## Candidate root causes, not yet distinguished

| Candidate | Status |
|---|---|
| KWin's VRR is scoped to fullscreen-client frame pacing (tear avoidance for variable render times), not idle-desktop power saving, and just doesn't do the latter at all | Plausible, matches how VRR is discussed in the KWin/mpv bug threads above, not confirmed against this KWin version's actual source |
| Terminal-open-during-test breaking VRR detection (mpv#10982-class bug) | Confirmed to exist as a general KWin bug, not yet isolated as *the* cause here |
| `xe.enable_psr=0 xe.enable_psr2_sel_fetch=0 xe.enable_panel_replay=0` (from [psr-dsb-deadlock.md](psr-dsb-deadlock.md)) collaterally killed whatever vblank-stretching path the `xe` driver uses for VRR, alongside fixing the DSB deadlock | Plausible, not tested. Re-enabling Panel Replay to check risks reintroducing the DSB deadlock under GPU-heavy load |

## 2026-08-05: policy changed to `Automatic`, and the LOBF hypothesis it was meant to test failed

KWin's VRR policy on eDP-1 was `Always`, i.e. adaptive sync forced on
unconditionally for a panel where it demonstrably never modulates. Changed to
`Automatic` (System Settings > Display & Monitor; writes
`~/.config/kwinoutputconfig.json`), verified via `kscreen-doctor -o`:

```
Output: 1 eDP-1
	Vrr: Automatic
```

The reason for the change was not VRR itself. In `xe`, LOBF (Link Off Between
Frames, the eDP link-power feature that is the current leading theory for the
panel wedge in
[../power/s2idle-rapid-resume-hang.md](../power/s2idle-rapid-resume-hang.md))
has its config computed in the Adaptive-Sync-SDP path, so `Always` was the
suspected reason LOBF is permanently live.

**The hypothesis is not supported.** Re-read after the change and the
resulting modeset:

```
LOBF status: enabled
Aux-less alpm status: enabled
```

Unchanged, and the driver source says why. From
`drivers/gpu/drm/i915/display/intel_alpm.c`, the VRR-related gate in
`intel_alpm_lobf_compute_config()` is:

```c
if (!intel_vrr_always_use_vrr_tg(display) || !intel_vrr_is_fixed_rr(crtc_state))
	return;
```

`intel_vrr_always_use_vrr_tg()` is a platform property of `DISPLAY_VER >= 20`
(on Xe3 the VRR timing generator is always used), not the compositor's
adaptive-sync policy. No KWin setting can affect it. The hypothesis was wrong
about the mechanism, not just the magnitude.

What actually gates LOBF here is PSR: `if (crtc_state->has_psr) return;`. See
[psr-dsb-deadlock.md](psr-dsb-deadlock.md), where `xe.enable_psr=0` has now
been narrowed to `xe.enable_psr=1` for exactly this reason.

Left on `Automatic` regardless, since nothing is lost by it, but it should not
be recorded as a fix for anything. `Never` was deliberately not tried:
disabling VRR outright is a documented crash-on-disable in this driver (see
[../known-issues.md](../known-issues.md)).

One incidental correction to the table above: this doc previously listed
"`xe.enable_psr=0 ...` collaterally killed the vblank-stretching path" as an
untested candidate for the VRR failure. It is still untested, but note that
`enable_psr` is an int (`0=disabled, 1=up to PSR1, 2=up to PSR2`), so the
narrower `xe.enable_psr=1` now in place is itself a partial test of that
candidate. Re-measure vblank after the next reboot.

## For a bug report

- Hardware: Dell XPS 13 DX13260, Wildcat Lake/Panther Lake, GPU device ID
  `fd80`, stepping A0
- Driver: `xe` KMS, kernel `7.1.4`
- Compositor: KWin 6.7.3, Wayland, Plasma 6
- `eDP-1` confirmed VRR-capable (30-120Hz DPCD range via debugfs `vrr_range`)
  and KWin's VRR policy set to `Always`
- Direct `DRM_IOCTL_WAIT_VBLANK` measurement on pipe A shows flat 120Hz across
  both a genuinely idle/locked screen and a fullscreen exactly-30fps synthetic
  video, contrary to expected VRR behavior
- `xe.enable_psr=0 xe.enable_psr2_sel_fetch=0 xe.enable_panel_replay=0` boot
  args are set, unconfirmed whether that's connected
- Known related upstream/KDE bugs, not confirmed as the same root cause:
  [mpv-player/mpv#10982](https://github.com/mpv-player/mpv/issues/10982),
  [bugs.kde.org#443872](https://bugs.kde.org/show_bug.cgi?id=443872) (fixed),
  [bugs.kde.org#500685](https://bugs.kde.org/show_bug.cgi?id=500685) (open)

## Remaining questions

- Re-run the fullscreen video test with zero other windows or terminals open
  (start the logger, then fully close the terminal before going fullscreen) to
  separate the KWin-terminal-breaks-VRR confound from a genuine hardware/driver
  gap.
- Whether re-enabling `xe.enable_panel_replay` alone (leaving PSR/PSR2
  selective-fetch off) restores VRR modulation, at the cost of risking the DSB
  deadlock again under GPU load.
- Whether KWin's VRR implementation does anything for plain idle-desktop power
  saving at all, on any hardware, or whether "idle drops to 30Hz" is simply not
  a feature it provides today regardless of this laptop's specific bugs.
- Whether this is the same underlying `xe` driver gap as the existing
  crash-on-disable VRR issue in [known-issues.md](../known-issues.md), or a
  fully separate problem.
