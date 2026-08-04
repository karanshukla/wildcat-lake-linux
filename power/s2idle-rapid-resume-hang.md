# Rapid lid-cycling on `s2idle` resume causes an unresumable hang

**Status:** Mitigated (behavioral + diagnostics), not fixed. No config change resolves
the underlying bug — see [Root cause](#root-cause). A second incident on
2026-08-03 (below) shows a different failure signature (no suspend attempt
preceded the hang, VT switch also failed to recover it) — likely a related but
distinct bug, not a repeat of the same one. `polkitd` debug logging added as a
result; still not root-caused.

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
