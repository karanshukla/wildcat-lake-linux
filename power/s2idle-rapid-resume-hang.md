# Rapid lid-cycling on `s2idle` resume causes an unresumable hang

**Status:** Mitigated (behavioral + diagnostics), not fixed. No config change resolves
the underlying bug — see [Root cause](#root-cause). A second incident on
2026-08-03 (below) shows a different failure signature (no suspend attempt
preceded the hang, VT switch also failed to recover it) — likely a related but
distinct bug, not a repeat of the same one. `polkitd` debug logging added as a
result; still not root-caused.

**2026-08-04 update:** built an automated capture pipeline and caught two real
blank-screen-on-lid-open reproductions with full before/after DRM state. Both
are indistinguishable from a clean resume at the kernel/DRM level (atomic
state self-heals within 3s either way, no dmesg errors, PSR/panel config
unchanged) — the fault lives below what any kernel-space instrumentation can
see. BIOS `Power on LID open` test was
run and produced a **third failure mode**: a display wedge with the lid held
open the entire time (no suspend/resume involved at all — traced to KDE's
idle screen-lock/dim step), which this time did **not** recover with a lid
nudge, forcing a hard power-off. `Power on LID open` has been reverted back
to enabled as a result — see "Third incident" below.

**2026-08-05 update: LOBF/ALPM is the new leading theory, and the bug is now
reproducible on demand.** Built `reproduce-panel-wedge.sh`, which drives the
panel through the idle-path power transitions on a loop with no lid and no
suspend involved. Two wedges reproduced in ~80 cycles. Separately, and more
importantly, found that **eDP link power management was never actually
disabled**: `LOBF status: enabled` / `Aux-less alpm status: enabled` on the
live system, despite `xe.enable_psr=0 xe.enable_psr2_sel_fetch=0
xe.enable_panel_replay=0`. LOBF (Link Off Between Frames) physically powers
the eDP main link down between frames, in hardware/firmware, below anything
the DRM atomic state or dmesg can observe — which is exactly the wall every
previous capture hit. The earlier S0ix/ME shared-power-domain theory is
demoted: the display engine's own DC-state counters read all-zero for a
much simpler, local reason (PSR is force-disabled by boot arg, and DC-state
entry on eDP is gated on it). See "2026-08-05" below.

## What happened

Default suspend mode on this hardware is `s2idle`, which has the known cosmetic bug
of resuming to a blank screen (see the `s2idle`/`deep` history in
[s3-deep-sleep-hang.md](s3-deep-sleep-hang.md)) — usually fixed by nudging the lid
closed and open again. On 2026-07-25 ~17:46 EDT, that nudge was done three times in
32 seconds:

| Time (EDT) | Event |
|---|---|
| 17:46:25 | Lid opened |
| 17:46:39 | Lid closed |
| 17:46:40 | Lid opened |
| 17:46:49 | Lid closed |
| 17:46:51 | Lid opened |
| 17:46:57 | Lid closed — **this suspend never resumed** |

The first two resumes completed cleanly in under 0.15s each. Each cycle re-bound
`mei_gsc_proxy` to the `xe` GPU driver and re-ran the GuC/GSC firmware handshake
(`xe 0000:00:02.0: vgaarb: VGA decodes changed...` / `mei_gsc_proxy ... bound
0000:00:02.0 (ops xe_gsc_proxy_component_ops [xe])` on every cycle). One of the
earlier cycles also logged `PM: Some devices failed to suspend, or early wake event
detected` — a warning, but one the driver recovered from at the time.

The third suspend call (`systemd-sleep[10080]`, triggered by the 17:46:57 lid
close) never logged `PM: suspend entry` at all — on every prior cycle that line
appeared within milliseconds of `systemd-sleep: Performing sleep operation
'suspend'...`; this time, nothing. The kernel wedged before reaching the top of its
own suspend path. Symptom while wedged: LCD backlight on, keyboard backlight on,
biopass face-auth camera active (IR LED lit, activated on lid-open), but a
completely black screen — closing and reopening the lid again did not recover it.
Nothing further was logged in that boot. Recovery required a forced power-off,
confirmed by a cold SELinux-policy-reload boot immediately after (not a resume).

## Root cause

Not fully root-caused — no crash dump or stack trace exists, since the hang
happened before the kernel's own suspend-entry logging. Working theory: repeated
rapid suspend/resume cycles force the `xe` driver's GuC/GSC firmware handshake to
restart again almost immediately after the previous cycle finished, and this
platform's firmware re-init path is fragile enough (Panther Lake/Wildcat Lake
**stepping A0** — see [README](../README.md)) that a third rapid cycle in ~30
seconds was enough to wedge it. Consistent with the general early-silicon pattern
in this repo (S3 sleep hang, PSR/DSB deadlock, NPU daemon crash) — this is driver/
firmware immaturity, not a local misconfiguration.

Checked for an actual fix as of 2026-07-25: kernel (`7.1.4-204.fc44`),
`linux-firmware` (`20260622`), and BIOS/EC firmware (via `fwupdmgr`) were all
already at the latest available versions. No update exists yet that addresses
this.

## Mitigations applied

None of these fix the bug — they reduce the chance of triggering it and improve
recovery/diagnostics if it happens again.

**1. Don't rapid-fire the lid nudge.** If the screen doesn't come back within a
couple seconds of one lid close/open, don't immediately cycle it again. Try a VT
switch instead (forces a fresh DRM modeset without touching suspend/resume):

```
Ctrl+Alt+F3   # switch to a text console
Ctrl+Alt+F1   # (or F2, whichever VT the session is on) switch back
```

If that doesn't help either, wait ~10-15s before a second lid nudge rather than
cycling it immediately.

**2. Full Magic SysRq enabled**, as a safer emergency-reboot path than holding the
power button (which risks filesystem corruption — see the journal-corruption
evidence in [s3-deep-sleep-hang.md](s3-deep-sleep-hang.md)):

```
echo 'kernel.sysrq = 1' | sudo tee /etc/sysctl.d/99-sysrq.conf
sudo sysctl --system
```

(Was `16` — sync-only — before this.) This machine has no dedicated PrtScn key;
confirmed the "screenshot" key doubles as SysRq (`Alt+screenshot-key+B` triggered
an immediate reboot in testing). Use the full sequence one letter at a time for an
actual hang — `Alt+screenshot-key+R`, then `E`, `I`, `S`, `U`, `B` — not just `B`
alone, which skips the sync/unmount steps that protect against filesystem damage.
Note: SysRq may not respond if the hang is a genuine kernel-level deadlock like
this one; it wasn't tested live against this specific failure mode.

**3. Diagnostic logging added** (`xe.guc_log_level=3`, via `grubby`, all kernel
entries) — pure logging verbosity increase, no behavior change, so it carries none
of the risk of a real config change. If this happens again, `journalctl -k` should
have actual GuC firmware log lines instead of the log just going silent.

```
sudo grubby --update-kernel=ALL --args="xe.guc_log_level=3"
```

**Considered and declined:** `xe.wedged_mode=2` (driver policy: skip the GPU-reset
attempt and declare the device wedged immediately on any detected hang, instead of
the default `upon-critical-error`). Declined because this incident's hang occurred
*before* the kernel even logged `PM: suspend entry` — i.e. before the GPU driver's
own hang-detection logic would run — so it likely wouldn't address this specific
failure, and it would trade away legitimate auto-recovery for any hang that would
otherwise self-heal via a normal reset. Revisit only with real evidence (e.g. GuC
logs from a future occurrence) that it would actually help.

## Second incident (2026-08-03): suspend denied by polkit, not a GuC/GSC deadlock

A second unresumable hang happened 2026-08-03 ~20:44 EDT, again after rapid lid
cycling, again ending in a forced power-off — but the evidence this time points at
a **different mechanism** than the 2026-07-25 incident above, not a repeat of it.

**What happened:** between 20:38 and 20:44:31, the lid was cycled 13 times. AC
power was connected throughout (`ACPI: AC: AC Adapter [ADP1] (on-line)`, logged
once at boot, no further transitions logged that boot — so a change in power
source doesn't explain the pattern below, though a *static* AC-vs-battery
PowerDevil lid-action profile hasn't been ruled out as a contributing factor).
Only 2 of the 13 closes actually suspended (`PM: suspend entry` logged in the same
second as `Lid closed`, clean resume both times). The other 11 all produced:

```
polkitd: Operator of unix-session:2 FAILED to authenticate to gain authorization
for action org.freedesktop.login1.suspend for system-bus-name::1.83
[/usr/libexec/org_kde_powerdevil] (owned by unix-user:karanshukla)
```

— with no `PM: suspend entry` at all, arriving several seconds to ~25s after the
corresponding `Lid closed` (vs. same-second for the 2 that succeeded). The fatal
close, 20:44:31, was the last event logged in the boot; nothing else from the
kernel or logind followed. One userspace flatpak process kept writing its own
client-side log lines once a second until 20:45:01 (proving the kernel and
journald were still alive), but display and input were both fully dead —
**Ctrl+Alt+F3 (VT switch) did not recover it either**, which the 2026-07-25
incident never tested. That's the strongest new data point: it argues against a
suspend/resume-path deadlock specifically (nothing even suspended on the fatal
close) and toward the DRM/panel-power path itself — the `xe` driver's
connector/CRTC/backlight handling, which normal DPMS-off/on on lid-close goes
through independently of suspend — being what's actually wedged.

**Investigated and ruled out** as the cause of the polkit denials:
- **A static polkit rule blocking the action.** Checked every rule file that
  ships (`11-fedora-kde-policy`, `plasma-setup-polkit`, `50-default`, upower's
  rules) — none reference `org.freedesktop.login1.suspend`. It's on the
  unmodified default policy (`allow_active=yes`, `allow_inactive=auth_admin_keep`).
- **`sudo` invocations (there were many that evening, for unrelated DKMS/kernel
  work) knocking `unix-session:2` out of logind's "active" state.** Reproduced
  live: ran `sudo`, checked `loginctl show-session 2 -p Active` before/during/
  after — stayed `yes` throughout — and a direct `pkcheck` for the suspend
  action granted instantly with a sudo child session still present.
- **PowerDevil crashing and dropping its `block`-mode inhibitor on
  `handle-lid-switch`** (the mechanism that's supposed to keep logind's own
  native `HandleLidSwitch=suspend` — confirmed live, default, unoverridden —
  from *also* independently firing on every lid event). No PowerDevil restart
  is logged that boot; it started once at login and ran continuously. This
  doesn't rule out the inhibitor lapsing for some other reason, just rules out
  the obvious "it crashed" explanation.

**Not root-caused.** The one solid, reproducible signal is the timing split
itself: the 2 successes were instantaneous (`Lid closed` and `PM: suspend entry`
in the same second), while all 11 failures had a multi-second gap before the
denial — consistent with polkit falling into the `allow_inactive` branch
(session judged not-active at that instant, which a non-interactive background
call can never satisfy, so it eventually times out and fails) rather than the
instant `allow_active` grant every other test today produced. Why polkit would
judge the session inactive only during this incident isn't established.
`polkitd` runs at `--log-level=notice` by default, which logs only the verdict,
not the reasoning — see Mitigations below for the fix to that going forward.

**New candidate lead (2026-08-04): `Power on LID open` BIOS setting.** Checked
BIOS setup (Advanced tab) and found `Power on LID open: <Enabled>`. This is an
EC/firmware-level feature — the embedded controller itself asserts a power-on
signal whenever the lid is physically opened, entirely independent of
`systemd-logind`/PowerDevil/polkit. That's a real candidate mechanism for this
incident specifically: most of the lid-close events that night never actually
suspended (polkit kept denying the request, per above), so the OS believed the
machine was awake the whole time — but the EC has no visibility into that; it
fires its own "power on" trigger on every physical lid-open regardless. Racing
an EC-level wake signal against a system that's already running, on a `xe`
driver already known to have a fragile panel-power path on this early-silicon
Panther Lake stepping (see [psr-dsb-deadlock.md](../display/psr-dsb-deadlock.md)),
is a plausible way to land in the "backlight on, keyboard lit, black screen,
doesn't even respond to VT switch" state observed. Not tested yet — candidate
experiment is disabling `Power on LID open` and repeating rapid lid-cycling to
see if the hang stops recurring; trade-off would be needing a keypress/power-
button tap to wake the display after closing the lid, since lid-open alone
would no longer do it.

**Refined mechanism theory: slow lid-open, not just EC/OS race.** A specific
trigger condition worth calling out: opening the lid *slowly* is a plausible
way to put the lid's Hall-effect sensor through its hysteresis/dead-zone for an
extended period instead of a crisp transition — producing a noisy or
never-fully-resolved signal at the kernel/evdev level, while the EC's own
`Power on LID open` firmware path (a coarser, independent trigger) fires
anyway. Supporting evidence: every other lid transition in the crashed boot —
dozens of opens/closes during the earlier rapid-nudge testing — shows up
cleanly as `systemd-logind: Lid opened`/`Lid closed`. The one that mattered
doesn't: there is no `Lid opened` entry anywhere in the journal after the final
`Lid closed` at 20:44:31, even though the lid was physically opened (that's
when the blank screen was observed). If this were purely a software/suspend
deadlock, the raw lid-switch evdev event should still have registered
regardless of what happened downstream — its total absence points at the
sensor signal itself never resolving into a clean "open" state at the kernel
level, consistent with a slow open rather than a fast nudge.

**Decision: leaving `Power on LID open` enabled, untested.** High confidence
this setting is at least a contributing factor, but the convenience of the
display just coming back on lid-open (no keypress needed) is worth more than
closing out this specific lead — accepted as a known, live risk rather than
traded away. Revisit if the hang starts recurring often enough to outweigh the
convenience.

**Update (2026-08-04): new correlating evidence, still not confirmed.** The
blank-screen failure has never once occurred waking from a source other than
lid-open (keypress, power button) — only lid-open triggers it. That's
consistent with the race theory above: non-lid wakes only go through the
normal ACPI-mediated logind/kernel resume path, while lid-open uniquely adds
the EC's independent `Power on LID open` signal racing against that same
path. Circumstantial, not proof — no BIOS A/B test has been run yet.

Two real blank-screen incidents were captured this same day with
`capture-blank-resume-state.sh` (19:29 and 20:48 EDT), but neither is usable
as evidence: the script dumped `guc_log_dmesg` *before* grabbing
`journalctl -n 300`, and that dump (130-300+ lines of an unwritten/poisoned
GuC log ring, all `z` filler) evicted the actual resume/lid/HPD lines from
the 300-line window — one capture is 100% GuC-dump noise, zero real log
content. Script fixed (journal/dmesg tails now grabbed first, GuC dump moved
last) so the next occurrence produces usable data.

What the captures *did* show, despite the log eviction: `atomic-state.txt`
for both incidents shows a fully normal-looking pipe A, CRTC active, a real
attached framebuffer (not `FB:0`), DPMS on, backlight on, PSR correctly
disabled. The driver's own view of the display pipe is completely healthy
during the black-screen state. That argues against an atomic-commit/DSB-style
deadlock as the mechanism for *this* symptom specifically (unlike the
PSR/DSB bug in [psr-dsb-deadlock.md](../display/psr-dsb-deadlock.md)) — if
the fault were there, the atomic state dump should show it. Points instead at
something downstream of the atomic commit: the physical eDP link/panel power
sequencing, plausibly consistent with an EC-level power-on event racing the
driver's resume path before the panel is actually in the state the atomic
dump reports.

**Proposed confirmation test (not yet run):** disable `Power on LID open` in
BIOS, then reproduce the normal suspend/lid-open workflow over several
cycles, including at least one deliberately slow open (per the hysteresis
theory above). If the blank-screen state stops recurring where it previously
would have, that confirms the EC signal as the trigger. Cheap, fully
reversible, only cost is losing auto-wake-on-open (a keypress would be needed
after opening the lid).

**If confirmed, this is a real root-cause fix, not just a workaround** — it
removes one side of the actual race (EC hardware trigger vs. ACPI-mediated
resume) rather than avoiding the trigger behaviorally. It does not fix the
underlying reason the `xe` driver's panel-power path can't tolerate two
concurrent wake triggers in the first place — that's a driver-maturity gap
needing an upstream fix, same bucket as the DSB deadlock — but no OS-side
lever touches that part regardless.

## Update (2026-08-04, continued): automated capture, real reproductions, revised theory

**Automated capture pipeline.** Manual capture can't win the race against the
only available recovery: a lid nudge is what fixes the black screen, and
nudging is exactly what destroys the live DRM/debugfs state
`capture-blank-resume-state.sh` needs. Built an automatic hook instead:
`acpid` (installed for this purpose) fires on every raw `button/lid.*` ACPI
event, before any human reaction can touch the state — good and bad cycles
both get captured, bad ones just happen to be the ones worth reading.

Getting there hit several SELinux walls, since `acpid` runs confined as
`apmd_t`: denied `dac_override` (can't cross into the 700 home directory at
all, not to write output and not even to exec a script living under it),
denied read access to debugfs/journal outright, and denied
`service:start` on a custom systemd unit. Final architecture: `acpid` →
`systemctl start capture-blank-resume.service` (permitted via a small
hand-written SELinux policy module scoped to exactly that one
`apmd_t → systemd_unit_file_t : service start` rule) → the actual capture
script, running unconfined under systemd, writing to `/var/tmp` (world-
traversable, no override needed) instead of `~`. This was temporary
diagnostic instrumentation, not a permanent fixture.

**Removed (2026-08-05):** kernel-space instrumentation had hit its ceiling —
DRM/dmesg state came back identical between bug and non-bug resumes, so
further captures weren't adding signal. Uninstalled `acpid`, the trigger/
capture scripts, the `capture-blank-resume.service` unit, the
`capture_blank_resume_acpid` SELinux module, and the captured data under
`/var/tmp/blank-resume-captures`. The repo's own
`capture-blank-resume-state.sh` stays as a reference for what the capture
logic did.

**Delayed capture (t0 / t+3s / t+8s).** The original single-shot capture
can't tell "compositor hasn't remodeled yet" apart from "actually stuck" —
both look identical immediately after a resume. Fixed by having the trigger
capture three times: immediately, then again at +3s and +8s (via `systemd-run`,
detached from the triggering service's cgroup so it survives after the
oneshot service exits). Also added a `pmc_core substate_residencies`/
`substate_requirements` snapshot to both the automated hook and the
canonical `capture-blank-resume-state.sh`, to check whether a bad resume
ever correlates with anything unusual on the S0ix power-gating side (see
below).

**Two real reproductions captured and analyzed (20:47:51 and 20:48:03 EDT),
against a clean resume for comparison (20:48:29).** Result: no distinguishing
signal anywhere in kernel-observable state.

- Connector/CRTC atomic state: all three captures show pipe A disabled and
  the connector unbound (`crtc=(null)`) at t0, then fully recovered
  (`enable=1, active=1, crtc=pipe A`) by t+3s — identical pattern whether the
  screen was actually blank or not. This confirms the t0-disabled state is
  just the universal post-resume transient (the capture fires faster than
  KWin's own re-modeset), not a bug signature. It also means the driver's own
  bookkeeping self-heals within 3 seconds in both bad cycles, even though the
  user-visible black screen persisted until a further lid nudge — the actual
  fault isn't visible in DRM atomic state at any point sampled.
- PSR status, PSR sink status, and panel timings: byte-identical across all
  three captures, PSR still correctly disabled, no sink error status.
- `dmesg`: identical `PM: suspend/resume devices took ~0.39s` timing and zero
  errors/warnings across all three — no DP/eDP/link-training complaints, no
  DSB/underrun signatures.
- One red herring, ruled out: `kdeconnectd` crashed (SIGABRT, coredump
  confirmed via `coredumpctl`) one second after the first reproduction. Did
  not recur for the second reproduction or the clean resume, so it's an
  unrelated, separate bug (KDE Connect crashing on some resumes), not the
  cause of the display hang.

Net effect: kernel/DRM-level instrumentation has hit its ceiling. Whatever's
actually failing isn't observable at the atomic-commit level, in PSR/panel
config, or in dmesg — it has to be at or below the physical eDP link/panel-
power sequencing itself, or in compositor state that isn't logged.

**Revised theory: possible link to the platform never reaching real S0ix.**
Previously treated [s0ix-never-entered.md](s0ix-never-entered.md) (platform
never leaves the `s2idle`-without-S0ix floor because Intel ME/CSE firmware
never releases its own VNN power requirement, confirmed independent of the
host `mei` driver) as an unrelated battery-life issue. Reconsidering: if the
display power domain shares any of the platform-level power gating that
ME/CSE is blocking, then every sleep on this machine — buggy resume or not —
is doing a shallow, partial power-cycle rather than a full clean one. That
would mean the eDP/panel-power path never actually goes through the
power-down/power-up sequence a genuinely-idle platform would, on *any*
resume. That's a plausible explanation for why the bug is invisible to every
piece of software-observable state checked above: if the fault is a physical
power-sequencing edge case that only manifests because the platform never
fully quiesces between sleeps, DRM atomic state and dmesg would look
completely normal either way, which is exactly what was found. Not
confirmed — there's no direct evidence yet that the eDP power well is
actually gated by the same platform-level mechanism the ME is blocking, that
link is the missing piece. But it upgrades this from "two unrelated bugs" to
a specific, testable mechanism worth tracking as the leading theory.

**BIOS confirmation test — partial run.** Disabled `Power on LID open` in
BIOS (reboot required). First post-change lid cycle (20:53:45 close →
20:53:52 open, 7s) produced a genuine, complete suspend/resume — confirmed
via `PM: suspend entry (s2idle)`, Wi-Fi deauthenticating on suspend and
reassociating on resume, `ACPI: EC: interrupt blocked`/`unblocked`, full
device suspend/resume timing — not just a screen lock, a real (if brief)
`s2idle` cycle. No display bug on this resume (captured, self-healed by t+3s
same as every clean resume so far). One clean cycle isn't a confirmation
either way; the proposed test (several more cycles, including at least one
deliberately slow open) still hasn't been run.

## Third incident (2026-08-04, ~21:01-21:06 EDT): idle-lock wedge, no lid or suspend involved, lid-nudge recovery failed for the first time

Happened during the BIOS test from the update above, with the lid held open
the entire time. Timeline (all times EDT, previous boot `20:53-21:05`):

| Time | Event |
|---|---|
| 20:53:52 | Lid opened (clean resume, already covered above) |
| 21:01:57 | `org.kde.powerdevil.backlighthelper` runs (idle-dim step); `gazed`'s later log dates the session lock to this same second |
| 21:01:57–21:04:24 | **Screen never recovers.** No kernel errors, no `PM: suspend entry` anywhere in this window |
| 21:04:24 | Second `backlighthelper` run + a `gazed` face-auth attempt (`lock_elapsed_ms=148255` ≈ 148s since 21:01:57) — user trying to wake it |
| 21:04:29–21:05:16 | Five lid close/open cycles in under a minute — **the usual nudge recovery, none of which worked** |
| ~21:06 | Forced power-off, fresh boot |

**This was not a suspend/resume event.** There's no `PM: suspend entry`
anywhere in the previous boot's kernel log after 20:53:53. The kernel-level
"`Lockdown: systemd-logind: hibernation is restricted`" burst at 21:01:57
looked like a smoking gun at first (it's the same message that showed up
during real suspend attempts elsewhere in this doc), but it's a red herring
here: it coincides with routine `CanHibernate()`-style property probing, not
an actual sleep call, and `backlighthelper` running at the exact same second
is PowerDevil's ordinary idle-timeout backlight dim, not suspend prep. The
actual event was KDE's own idle screen-lock, independent of ACPI suspend and
independent of the lid entirely — lid stayed open from 20:53:52 all the way
to 21:04:29.

**Why this matters:** all prior investigation in this doc assumed the
trigger was always a lid-open racing an ACPI/EC resume path. This incident
had no lid event, no suspend, no resume anywhere near the wedge — just KDE's
ordinary idle-dim/lock sequence toggling the display. That points at a
broader root cause than "lid-open specifically": the `xe` driver's
panel/backlight power path may be fragile across *any* DPMS-off→DPMS-on
transition on this eDP output, whether it's triggered by ACPI suspend/resume,
the EC's lid-open signal, or plain userspace idle-timeout blanking. The
common thread across all three failure modes in this doc (this one, the
2026-08-03 polkit-denied incident, and the ordinary lid-open blank-screen
bug) may simply be "power-cycling this panel is unreliable," not anything
specific to lid switches.

**The recovery trick failed for the first time.** Every previous occurrence
in this doc and in `capture-blank-resume-state.sh` testing was recoverable
with a lid close/open nudge. This one wasn't — five nudges in under a
minute, no recovery, forced power-off required. The one thing different this
time: `Power on LID open` was disabled in BIOS for the confirmation test
proposed in the update above. Working theory for *why* the nudge stopped
working: the lid-nudge recovery may not actually be forcing a fresh OS-level
modeset at all — it may be riding on the EC's own independent "power on lid
open" hardware signal to force a physical panel/backlight power-cycle that
bypasses the (already-wedged) `xe` driver state entirely. With that EC
behavior disabled, a lid nudge only round-trips through the same OS-level
DPMS/resume code path that's already stuck, so it can't recover anything.
If that's right, the BIOS setting was never purely a bug trigger — it may
also be the only thing that makes recovery-without-a-hard-reset possible at
all, at least for this class of wedge. Not proven (only one data point: the
one incident it happened to coincide with), but consistent with everything
observed so far.

**Decision: `Power on LID open` re-enabled**, reverted immediately after this
incident. Given the theory above, disabling it trades "possibly reduces one
race" for "definitely removes the only known recovery path for at least one
wedge variant" — a bad trade until there's a demonstrated alternative
recovery method (VT switch already failed for the 2026-08-03 incident;
whether Magic SysRq (`Alt+screenshot-key+REISUB`) would have worked here
wasn't tested before the forced power-off).

**Not yet done:** confirming whether Magic SysRq recovers this wedge variant
(would give a safe recovery path that doesn't depend on the BIOS setting,
if it works). Also worth checking KDE's idle-lock/dim timings
(`powermanagementprofilesrc`) to reproduce this deliberately (idle out the
session without touching the lid) rather than waiting for it to recur
naturally.

## 2026-08-05: on-demand reproducer, LOBF/ALPM found still enabled, collision correlation

Three separate findings, in descending order of importance.

### Finding 1: eDP link power management was never actually off

The boot args from [psr-dsb-deadlock.md](../display/psr-dsb-deadlock.md) were
treated throughout this doc as meaning "link power management is disabled."
They don't. On the live system, with all three args in `/proc/cmdline`:

```
$ sudo cat /sys/kernel/debug/dri/0000:00:02.0/eDP-1/i915_edp_lobf_info
LOBF status: enabled
Aux-wake alpm status: disabled
Aux-less alpm status: enabled
```

LOBF (Link Off Between Frames) is an eDP 1.5 feature, part of ALPM (Advanced
Link Power Management), new on Xe3. It is **not** PSR. PSR stops sending
frames when the image is static and lets the panel self-refresh from its own
memory; LOBF keeps sending frames and powers the physical link down in the
gaps between them, hundreds of times a second, in hardware and display
firmware. Disabling PSR, PSR2 selective fetch, and Panel Replay leaves LOBF
running.

The active variant here is **aux-less** ALPM: the link is brought back on
hardcoded timing with no AUX handshake and no confirmation the panel actually
came back, as opposed to aux-wake, which does handshake.

Why this is now the leading theory:

- A link that fails to come back produces exactly the observed symptom:
  driver state healthy, atomic commit fine, backlight on, no image.
- It operates below every layer instrumented so far, which explains the
  central negative result of the 2026-08-04 captures (DRM atomic state, PSR
  status, panel timings, and dmesg all byte-identical between good and bad
  resumes).
- New feature, new silicon, A0 stepping. Same pattern as everything else in
  this repo.

Not confirmed. No A/B has been run with LOBF disabled, because the only kill
switch found is the writable debugfs node `eDP-1/i915_edp_lobf_debug` (no
`xe.*` module parameter exists for it), and its write semantics haven't been
read yet.

### Finding 2: the display engine never enters DC5/DC6, and the cause is local

```
$ sudo cat /sys/kernel/debug/dri/0000:00:02.0/i915_dmc_info
DMC initialized: yes
version: 2.31
DC3CO count: 0
DC3 -> DC5 count: 0
DC5 -> DC6 allowed count: 0
```

The 2026-08-04 leading theory was that the display power domain might never
get a clean power-cycle because the platform never reaches S0ix (see
[s0ix-never-entered.md](s0ix-never-entered.md)), with "is the eDP power well
gated by the same mechanism the ME is blocking" named as the missing piece.
The premise is true and the explanation is simpler than the ME: DC-state
entry on eDP is gated on PSR, and PSR is force-disabled by this machine's own
boot arg. The display genuinely never power-gates, for a local, self-inflicted
reason.

Two consequences. The S0ix link is demoted from leading theory (see the
status block at the top of this doc). And `xe.enable_dc=0`, an obvious-looking
lever for a panel-doesn't-come-back bug, is **ruled out as a no-op** on this
machine: display C-states already never engage.

### Finding 3: on-demand reproduction, and what actually correlates

`reproduce-panel-wedge.sh` (in this directory) drives the panel through
DPMS off/on cycles on a loop with the lid open and no suspend involved,
logging each cycle to `/var/tmp/panel-wedge-repro/cycles.log` so the failing
cycle number survives a forced power-off. It requires no sudo.

It cannot auto-detect the classic symptom — bad and good cycles are identical
in every software-readable probe, so the detector is a human watching the
screen — but it does detect the panel dropping to `dpms=Off`/`bl=0` on its
own, and it emits an audible per-cycle heartbeat so progress is followable
with the screen dark.

Results:

| Config | Cycles | Collision events | Wedges |
|---|---|---|---|
| DPMS off/on, idle inhibited | 13 | 0 | 0 |
| DPMS off/on, KDE idle ladder live, 8s/6s dwells | 50 | ~3 | 1 |
| DPMS off/on, KDE idle ladder live, 3s/2s dwells | 30 | 1 | 1 |
| Concurrent *warm* brightness write on the dpms-on, idle inhibited | 30 | 29 | 0 |

The first run was confounded and is not a baseline: the script generates no
input, so PowerDevil counted the whole run as idle and ran its full
escalation underneath the test (dim at cycle 8, an unlogged screen-off at
cycle 23, a full logind idle suspend at cycle 37). The script now runs under
`systemd-inhibit --what=idle:sleep:handle-lid-switch` plus
`kde-inhibit --power --screenSaver` by default, with `--allow-idle` to put
the collision back deliberately.

**The correlation.** Both wedges happened when a second actor touched panel
power concurrently with the driver's own transition. The 3s/2s run pins it to
the second:

| Time | Event |
|---|---|
| 06:14:25 | cycle 16 begins, script issues `kscreen-doctor --dpms off` |
| **06:14:28** | script issues `--dpms on` (3s dwell) **and** `dbus-:1.3-org.kde.powerdevil.backlighthelper@10.service` starts, same second |
| 06:14:30 | cycle 16 post-probe: `dpms=On bl=23041`; wedge observed by eye, recovered on a later cycle |

Note the denominator that matters. The natural runs are 2 for 2 on *collision
events*, not 2 for 80 on cycles. Collisions are rare only because KDE's idle
timers fire slowly.

**Ruled out: a warm concurrent brightness write is not sufficient.** A `race`
mode was added to fire a PowerDevil `setBrightness` call concurrently with
every dpms-on. 29 such writes, zero wedges. But that run did not test the
mechanism that correlated: `backlighthelper` is a D-Bus-activated privileged
helper that idles out after ~12s, and a write every 7s kept it warm for the
whole run. Exactly one activation is logged for those 30 cycles
(`backlighthelper@13` at 06:19:31), against a cold activation — systemd unit
start, D-Bus activation, process spawn, then the sysfs write — in the event
that actually correlated. `--race-every N` now spaces the writes past the
idle-out to force the cold path; that run hasn't been done.

A second difference can't be faked with a D-Bus call at all: PowerDevil
deciding it is idle is a policy state transition, and a raw `setBrightness`
isn't. Whatever else that transition does is unaccounted for.

### Mitigations applied

Neither is a root-cause fix. Both remove an ingredient.

**1. Adaptive Sync set from `Always` to `Automatic` on eDP-1** (System
Settings > Display & Monitor; writes `~/.config/kwinoutputconfig.json`).
Rationale: in `xe`, LOBF's config is computed in the Adaptive-Sync-SDP path,
so forcing VRR on unconditionally was the suspected reason LOBF is always
live. Costs nothing real, since VRR never actually modulates on this panel
(see [vrr-not-engaging.md](../display/vrr-not-engaging.md)). `Automatic`
rather than `Never` deliberately, because disabling VRR outright is a
documented crash-on-disable in this driver (see
[known-issues.md](../known-issues.md)).

**Result: LOBF stayed enabled.** Re-read after the change and after the
resulting modeset, `i915_edp_lobf_info` still reports `LOBF status: enabled` /
`Aux-less alpm status: enabled`. So the VRR-policy-keeps-LOBF-alive
hypothesis is **not supported**. The setting was left on `Automatic` anyway
(nothing is lost), but it does not do what it was applied to do.

**2. Recommended, not yet applied: turn off KDE's screen dimming.** This
removes the one actor present in both reproductions. As of this writing
`~/.config/powerdevilrc` is unchanged (mtime 2026-08-04 21:41) and contains
no `DimDisplay` section, so the setting has not persisted.

### Remaining questions

- Read the write semantics of `eDP-1/i915_edp_lobf_debug` and, if it takes a
  disable, apply it at boot via a small systemd unit. This is the direct test
  of the leading theory and it hasn't been run. Requires a sudo read from a
  real terminal.
- Run `--mode race --race-every 3` to test the cold-activation collision that
  the warm-write run missed.
- `drm.debug=0x1e` (KMS + ATOMIC) has never been enabled. Every capture to
  date is a snapshot; a sequencing fault is invisible in snapshots by
  construction. The 2026-08-04 conclusion that kernel-space instrumentation
  had "hit its ceiling" was premature on this point.
- Sink-side DPCD has never been read. All captures are driver-side. Reading
  sink power state (DPCD 0x600) and lane/link status (0x202-0x205) over
  `/dev/drm_dp_aux0` during a wedge would separate "driver thinks the link is
  up, sink is in D3" from "both agree, backlight is the problem".
- Whether the PSR boot args themselves are a contributing variable. All three
  failure modes in this doc occurred with PSR, PSR2 selective fetch, and
  Panel Replay force-disabled, and that has never been treated as a variable.
  Leaving Panel Replay off while LOBF runs is plausibly a combination Intel
  never validated.
- Whether Magic SysRq recovers this wedge. Still untested (carried over from
  the third incident).
- `lvfs-testing` is disabled in `fwupd`, and the last documented firmware
  check is 2026-07-25. Dell ships XPS BIOS/EC/ME betas there.

## Mitigations applied (2026-08-03 addition)

**`polkitd` debug logging enabled**, so a repeat occurrence produces the actual
authorization-decision reasoning instead of just a pass/fail verdict:

```
sudo mkdir -p /etc/systemd/system/polkit.service.d
sudo tee /etc/systemd/system/polkit.service.d/99-debug-logging.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/lib/polkit-1/polkitd --no-debug --log-level=debug
EOF
sudo systemctl daemon-reload
sudo systemctl restart polkit.service
```

Verified polkit still authorizes normally after the restart (`pkcheck` against
`org.freedesktop.login1.suspend` returns success). Same rationale as the
existing `xe.guc_log_level=3` mitigation below: pure logging increase, no
behavior change, in place so the next occurrence produces real diagnostic data
instead of another after-the-fact timing reconstruction.

## Trade-off accepted

Still on `s2idle` (the right default per [s3-deep-sleep-hang.md](s3-deep-sleep-hang.md)).
The occasional blank-screen-on-resume cosmetic bug remains, and a full unresumable
hang remains a real (if rare) risk if the lid is nudged repeatedly and quickly. No
config exists today that removes the underlying risk — only behavioral avoidance
and better diagnostics/recovery if it recurs.

## For a bug report

Reproduction isn't fully pinned down — the one confirmed trigger is three lid
close/open cycles within about 30 seconds, but it's unclear if that's necessary or
just what happened this time. Useful evidence for an upstream report against
`drm/xe` (Panther Lake/Wildcat Lake, device ID `fd80`, stepping A0):

- The final suspend call never logs `PM: suspend entry (s2idle)`, unlike every
  prior cycle in the same sequence, where it appears within milliseconds.
- Each prior cycle re-binds `mei_gsc_proxy` to `xe` and re-runs the GuC/GSC
  firmware handshake; one cycle logged `PM: Some devices failed to suspend, or
  early wake event detected` and still recovered.
- No thermal, OOM, or panic signatures anywhere in the logs — this is a clean
  hang/deadlock, not a crash.
- `xe.guc_log_level=3` is now enabled going forward, so a repeat occurrence should
  produce real GuC firmware log data to attach.

**2026-08-03 incident addendum** — useful evidence for a *second*, likely
separate report (this one probably against `kde/powerdevil` or the
`xe`/DRM panel-power path rather than firmware re-init):

- The fatal hang was **not** preceded by a real suspend — no `PM: suspend entry`
  at all on the last lid close, unlike the 2026-07-25 incident where the third
  cycle at least reached the suspend call before wedging.
- **VT switch (Ctrl+Alt+F3) also failed to recover it** — new data point,
  untested in the first incident — pointing at the DRM/panel-power (DPMS)
  path rather than the suspend/resume path specifically.
- 11 of 13 lid-close events that boot got `polkitd: ... FAILED to authenticate`
  for `org.freedesktop.login1.suspend`, requested by `org_kde_powerdevil`, with
  no corresponding kernel suspend activity — a separate, unexplained oddity
  co-occurring with (not necessarily causing) the hang. `polkitd` is now running
  with `--log-level=debug` (see Mitigations) so a repeat should show the actual
  authorization decision, not just the verdict.
- Kernel/journald/network stayed alive after the hang (a flatpak process kept
  logging once a second for another 30s) — this is a display/input-level wedge,
  not a full kernel freeze or panic (no panic/oops/wedged-GPU signature anywhere
  in the log).
