# Display: VRR/adaptive sync is never switched on, so the panel never modulates

**Status:** Unresolved, but relocalized on 2026-08-07. The panel and the eDP
link are genuinely VRR-capable, confirmed at three independent layers. The
compositor correctly decides to use adaptive sync. The CRTC's `VRR_ENABLED`
property nevertheless stays `0`, so the flat-120Hz measurements below are the
*expected* result for VRR being off and never showed a modulation failure at
all. Root cause is now narrowed to one of two layers between KWin's decision
and the atomic commit. Decision 2026-08-07: not chasing further, both remaining
candidates are kernel-side and the fix is to wait for driver maturity.

Originally investigated 2026-07-26 under the title "reports capable and enabled
but panel refresh never modulates." That framing was wrong: it was never
enabled. The 2026-07-26 material is kept below as the measurement record, see
[the 2026-08-07 section](#2026-08-07-vrr_enabled-is-0-the-whole-time-which-invalidates-the-framing-above)
for what actually changed.

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

## 2026-08-05: policy changed to `Automatic`; the LOBF hypothesis it tested failed

KWin's VRR policy on eDP-1 was `Always`, forcing adaptive sync on
unconditionally for a panel where it demonstrably never modulates. Changed to
`Automatic` (System Settings > Display & Monitor, writes
`~/.config/kwinoutputconfig.json`).

The reason was not VRR itself. LOBF, the eDP link-power feature that is the
leading theory for the panel wedge in
[../power/s2idle-rapid-resume-hang.md](../power/s2idle-rapid-resume-hang.md),
has a VRR-related gate, so `Always` was the suspected reason it stayed live.

**Not supported.** LOBF was unchanged after the modeset, and the source says
why:

```c
if (!intel_vrr_always_use_vrr_tg(display) || !intel_vrr_is_fixed_rr(crtc_state))
	return;
```

`intel_vrr_always_use_vrr_tg()` is a platform property of `DISPLAY_VER >= 20`
(on Xe3 the VRR timing generator is always used), not compositor policy. What
actually gates LOBF is PSR, see [psr-dsb-deadlock.md](psr-dsb-deadlock.md).

Left on `Automatic` since nothing is lost by it, but it is not a fix for
anything. `Never` was deliberately not tried: disabling VRR outright is a
documented crash-on-disable in this driver (see
[../known-issues.md](../known-issues.md)).

### Re-measuring is now worthwhile, but blocked

The candidate table above lists "`xe.enable_psr=0` collaterally killed the
vblank-stretching path" as untested. The arg is now `xe.enable_psr=1`, so PSR1
is active while PSR2 selective fetch stays off, which makes this a direct
partial test of that candidate.

Blocker: **`vblank_watch.py` no longer exists.** It was written ad hoc during
the 2026-07-26 investigation and never committed to this repo. Rebuild it from
the methodology section above (`DRM_IOCTL_WAIT_VBLANK` on pipe A of
`/dev/dri/card0`, ioctl `0xc018643a`, 24-byte `union drm_wait_vblank`) and
commit it this time. Also set the VRR policy back to `Always` first, or the
result isn't comparable to the measurements above.

Kernel 7.1.6 carries `drm/i915/vrr: require valid min/max vfreq for VRR`, but
that's div-by-zero hardening for invalid EDID ranges and this panel reports a
valid 30-120.

## 2026-08-07: `VRR_ENABLED` is 0 the whole time, which invalidates the framing above

Rebuilt `vblank_watch.py` (it was the blocker noted above) and this time also
read the CRTC's `VRR_ENABLED` DRM property alongside the vblank timing. That
property is what actually answers "did the compositor turn adaptive sync on for
this commit", and no earlier run had read it.

It is `0`. It was `0` for every sample of a 62s run, including ~40s with a
fullscreen client presenting at exactly 40fps.

That retroactively explains 2026-07-26. A panel pinned at 120.00Hz is the
*correct* behaviour when VRR is off. Those runs never demonstrated a modulation
failure, they demonstrated nothing at all. The mpv#10982 "terminal breaks VRR"
confound the doc leaned on is also irrelevant here: that bug is about KWin's
repaint scheduling, and this never gets as far as scheduling.

### The panel and the eDP link are genuinely capable

Three independent layers, none of them the compositor:

| Layer | Check | Result |
|---|---|---|
| Sink DPCD | `0x007` bit 6 `MSA_TIMING_PAR_IGNORED` | Set (`0x007 = 0xc0`). Sink will ignore MSA timing, the eDP prerequisite for adaptive sync |
| EDID | Display Range Limits descriptor | `30-120 Hz V`, `203-203 kHz H`, "supports continuous frequencies" flag set. LGD `LP134WQ` |
| Kernel `xe` | connector `eDP-1` `vrr_capable` property | `1` |

`vrr_capable` is not a rubber stamp: in the shared i915/xe display code
`intel_vrr_is_capable()` requires the VBT `vrr` flag for eDP, *plus* that DPCD
bit, *plus* a monitor range spanning more than 10Hz. All three passed.

Note `vrr_capable` is a DRM connector property, not a sysfs file. Its absence
from `/sys/class/drm/card0-eDP-1/` means nothing, DRM only exports a fixed
handful of attributes there.

### KWin's decision is also correct

Under `Automatic`, KWin's `src/compositor.cpp`:

```cpp
const bool wantsAdaptiveSync = activeWindow && activeWindow->frameGeometry().intersects(primaryView->viewport()) && activeWindow->wantsAdaptiveSync();
const bool vrr = (output->capabilities() & BackendOutput::Capability::Vrr) && (output->vrrPolicy() == VrrPolicy::Always || (output->vrrPolicy() == VrrPolicy::Automatic && wantsAdaptiveSync));
```

`Window::wantsAdaptiveSync()` is just `rules()->checkAdaptiveSync(isFullScreen())`,
and the capability bit comes from exactly the property confirmed above
(`drm_output.cpp`: `if (m_connector->vrrCapable.isValid() && m_connector->vrrCapable.value())`).

Queried KWin's own scripting API while the fullscreen client was up. It
reported `active=ffplay fullScreen=true output=eDP-1 geom=1707x1067`, which is
the full logical size of eDP-1 at scale 1.5. Every branch of that condition was
satisfied, so KWin computed `vrr == true`.

(KWin script `print()` output goes to a debug category that is disabled by
default and never reaches the journal. Reporting over `callDBus` to a
non-existent service and watching with `dbus-monitor` works, the message is
visible on the bus regardless of whether the destination exists.)

### So it is dropped below the decision point

The rest of the chain is short:

```cpp
// compositor.cpp
if (vrr) { frame->setPresentationMode(tearing ? PresentationMode::AdaptiveAsync : PresentationMode::AdaptiveSync); }

// drm_pipeline.cpp
if (m_pending.crtc->vrrEnabled.isValid()) {
    commit->setVrr(m_pending.crtc, m_pending.presentationMode == PresentationMode::AdaptiveSync
                                || m_pending.presentationMode == PresentationMode::AdaptiveAsync);
}

// drm_commit.cpp
void DrmAtomicCommit::setVrr(DrmCrtc *crtc, bool vrr) { addProperty(crtc->vrrEnabled, vrr ? 1 : 0); }
```

Input correct, output `0`. Two candidates, not distinguished:

| Candidate | Status |
|---|---|
| `PresentationMode::AdaptiveSync` never reaches the pipeline's `m_pending.presentationMode` (KWin bug) | Untested |
| The atomic commit carrying `VRR_ENABLED=1` fails and KWin silently falls back to VSync (`xe` bug) | Untested. Kernel log has zero drm/`xe` errors this boot, but KWin probes with `TEST_ONLY` commits and those don't log, so this is not evidence either way |

### The test that would distinguish them, deliberately not run

Set `vrrPolicy` back to `Always`. That collapses the compositor condition to
just the capability bit, removing `activeWindow` and fullscreen from the
picture entirely. Three outcomes, each pointing somewhere different:

| Result | Meaning |
|---|---|
| `VRR_ENABLED` → 1, vblank modulates | `Automatic`'s per-frame path is broken, hardware fine, `Always` is a usable workaround |
| `VRR_ENABLED` → 1, vblank still pinned 120.00 | Driver accepts the property but the timing generator never varies. Genuine display-code bug |
| `VRR_ENABLED` stays 0 | `xe` rejects the commit and KWin falls back. Kernel bug |

The 2026-07-26 runs were taken under `Always` and saw flat 120Hz, but since
they never read `VRR_ENABLED` they cannot distinguish row 2 from row 3.

Not run on 2026-08-07 because reverting `Always` afterwards is exactly the
disable path recorded in [../known-issues.md](../known-issues.md) as crashing
the `xe` driver. Enabling is the safe direction, reverting is not. Both
remaining candidates are kernel-side anyway, so the practical answer is to wait
for driver maturity rather than to buy a workaround at the cost of a crash
risk.

### Prior art: Dell/Omarchy on XPS 14/16, and why backporting is probably the wrong lever

Dell's ["Year of the Linux Laptop: Omarchy on XPS"](https://www.dell.com/en-us/blog/year-of-the-linux-laptop-omarchy-on-xps/)
describes a Panther Lake enablement effort on the XPS 14 and 16 that lists
"Display VRR, panel self-refresh, power optimization, performance tuning, WiFi,
the NPU, OpenVINO GenAI" as all having "needed work", delivered as roughly 20
backports in a temporary `linux-ptl` package "until Linux 7.0 releases".

Tempting to treat this the way the CS35L56 audio quirk was treated, i.e. port
the patch downstream. Two reasons that is probably not the move here:

- **The kernel is already newer.** Those backports targeted a pre-7.0 tree.
  This machine is on 7.1.6, so anything that landed in mainline by 7.0 is
  already present. Backporting would only help for patches that never landed,
  which needs checking before it's worth any effort.
- **The compositor differs, and that is exactly where the evidence points.**
  Omarchy is Hyprland. The failure documented above sits between KWin's
  decision and the DRM atomic commit. A Hyprland (or any non-KWin) session on
  this same kernel exercises a completely different userspace path to the same
  `VRR_ENABLED` property.

That last point makes a live-USB or spare-session Hyprland test the cheapest
remaining discriminator, and a non-destructive one, unlike the `Always` test
above. If `VRR_ENABLED` reaches 1 under Hyprland on kernel 7.1.6, this is a
KWin bug and the kernel is fine. If it stays 0 there too, it is the shared
i915/xe display code and the bug report goes to intel-gfx.

Also worth noting the hardware is not the same: that effort targeted XPS 14/16,
this is an XPS 13 DX13260 on Wildcat Lake stepping A0. The blog does not claim
VRR ended up working, only that it was worked on.

### Tooling

`tools/vblank_watch.py` is committed this time. It polls `VRR_ENABLED` while
measuring, so the two can never be conflated again:

```
sudo ./display/tools/vblank_watch.py              # one-shot VRR property dump
sudo ./display/tools/vblank_watch.py --watch 60   # 60s measurement on pipe A
```

It deliberately avoids `DRM_IOCTL_MODE_GETCONNECTOR`: called with
`count_modes=0` that forces a full connector re-probe (EDID re-read, link
retrain), which this panel has a history of not surviving. Connector names come
from sysfs instead.

## For a bug report

- Hardware: Dell XPS 13 DX13260, Wildcat Lake/Panther Lake, GPU device ID
  `fd80`, stepping A0
- Driver: `xe` KMS, kernel `7.1.4`
- Compositor: KWin 6.7.3, Wayland, Plasma 6
- `eDP-1` confirmed VRR-capable at three layers: DPCD `0x007` bit 6
  `MSA_TIMING_PAR_IGNORED` set, EDID Display Range Limits `30-120 Hz V` with the
  continuous-frequency flag, and DRM connector property `vrr_capable = 1`
  (debugfs `vrr_range` agrees: `Min: 30`, `Max: 120`)
- **The actual defect: CRTC `VRR_ENABLED` never leaves `0`.** Held at `0` for
  all 62s of a run including ~40s with a fullscreen 40fps client, with KWin's
  scripting API concurrently reporting that client as
  `active=… fullScreen=true output=eDP-1` under `vrrPolicy=Automatic`, which
  satisfies every branch of the condition in KWin's `src/compositor.cpp`
- Flat 120.00Hz vblank measurements are a *consequence* of that, not an
  independent symptom. Do not report them as a modulation failure
- Not yet distinguished: KWin never propagating `PresentationMode::AdaptiveSync`
  to `DrmPipeline::m_pending.presentationMode`, versus `xe` rejecting the atomic
  commit that carries `VRR_ENABLED=1` and KWin falling back. No drm/`xe` errors
  in the kernel log, but KWin's `TEST_ONLY` probes don't log
- Boot args at time of measurement: `xe.enable_psr=1 xe.enable_psr2_sel_fetch=0
  xe.enable_panel_replay=0`. PSR1 active, LOBF reported `disabled`
- Known related upstream/KDE bugs, not confirmed as the same root cause:
  [mpv-player/mpv#10982](https://github.com/mpv-player/mpv/issues/10982),
  [bugs.kde.org#443872](https://bugs.kde.org/show_bug.cgi?id=443872) (fixed),
  [bugs.kde.org#500685](https://bugs.kde.org/show_bug.cgi?id=500685) (open)

## Remaining questions

- Which of the two candidates above is actually dropping the request. The
  `Always` test in the table above decides it, at the cost of a crash risk on
  revert.
- Whether `xe` is rejecting the atomic commit at all. A `TEST_ONLY` commit
  carrying `VRR_ENABLED=1`, issued directly rather than through KWin, would
  answer this without touching compositor config, but needs DRM master so it
  means taking the display away from KWin on a spare VT.
- Whether KWin's VRR implementation does anything for plain idle-desktop power
  saving at all, on any hardware, or whether "idle drops to 30Hz" is simply not
  a feature it provides today regardless of this laptop's specific bugs. Note
  the compositor condition keys off the *active* window, not off idleness, which
  suggests it does not.
- Whether this is the same underlying `xe` driver gap as the existing
  crash-on-disable VRR issue in [known-issues.md](../known-issues.md), or a
  fully separate problem.
- The 2026-07-26 candidate "`xe.enable_psr=0 …` collaterally killed the
  vblank-stretching path" is now moot as stated. VRR was never enabled in either
  configuration, so the boot args were never the variable under test.
