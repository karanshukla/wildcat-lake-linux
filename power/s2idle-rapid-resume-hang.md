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
see. Leading theory is now a possible link to
[s0ix-never-entered.md](s0ix-never-entered.md): the platform never reaching
real S0ix may mean the display power domain never gets a full clean
power-cycle on any resume, not confirmed. BIOS `Power on LID open` test was
run and produced a **third failure mode**: a display wedge with the lid held
open the entire time (no suspend/resume involved at all — traced to KDE's
idle screen-lock/dim step), which this time did **not** recover with a lid
nudge, forcing a hard power-off. `Power on LID open` has been reverted back
to enabled as a result — see "Third incident" below.

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
