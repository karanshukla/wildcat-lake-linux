# Rapid lid-cycling on `s2idle` resume causes an unresumable hang

**Status:** Mitigated (behavioral + diagnostics), not fixed. No config change resolves
the underlying bug — see [Root cause](#root-cause).

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
