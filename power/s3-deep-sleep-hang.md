# Forcing S3 (`deep`) sleep hangs unresumably — reverted to `s2idle`

**Status:** Reverted. Do not set `mem_sleep_default=deep` on this machine.

## What was tried, and why

Default suspend mode on this hardware is `s2idle` (S0ix), which has a known
cosmetic annoyance: the screen sometimes stays blank on resume (nudging the
lid/keyboard again wakes it, but it's an ugly workaround). To fix that, real
S3 ("deep") suspend was forced instead:

```
sudo grubby --update-kernel=ALL --args="mem_sleep_default=deep"
```

## What happened

The very next suspend/resume cycle hung unresumably:

1. Journal shows a clean suspend entry (`PM: suspend entry (deep)`) at the
   time the lid closed / idle timeout hit.
2. Nothing after that. No resume messages, no wake-up log lines — the journal
   for that boot session just stops dead at the suspend-entry line. The
   machine hung *during* the actual sleep/wake cycle itself, not on lid-open.
3. Recovery required holding the power button for 30s (forced power-off), then
   powering back on — a fresh BIOS POST and full RAM re-enumeration, not a
   resume. That itself confirms it wasn't a normal wake.
4. On the next boot, `journald` explicitly flagged the damage: `File
   .../system.journal corrupted or uncleanly shut down, renaming and
   replacing` — direct evidence of an unclean power loss, not a graceful
   shutdown.

No thermal, OOM, or kernel-panic signatures appear anywhere in the logs
around the incident, which rules out overheating or a driver panic as the
cause — this looks specifically like a firmware-level failure to actually
resume from S3, not a Linux kernel crash.

## Root cause

This chip (`Core 5 320` marketing name; the kernel/thermald don't even fully
recognize it — `thermald` logs `Unsupported cpu model or platform`) is
early-silicon Wildcat Lake. Many recent Intel mobile platforms advertise S3
support but don't have a properly validated real-deep-sleep implementation in
firmware at this stage — forcing it can trade a cosmetic blank-screen bug for
a hard, unresumable hang. This is consistent with the general pattern on this
hardware (see [known-issues.md](../known-issues.md)): marketing support claims
diverging from actual current Linux support maturity.

## Fix

Revert back to the default `s2idle`:

```
sudo grubby --update-kernel=ALL --remove-args="mem_sleep_default=deep"
```

Verify current state:

```
cat /sys/power/mem_sleep   # should show [s2idle] deep -- s2idle active, deep available but not selected
cat /proc/cmdline           # should NOT contain mem_sleep_default=deep
```

## Trade-off accepted

Back to the occasional blank-screen-on-resume with `s2idle` (workaround:
nudge the lid or keyboard on wake). Strictly preferable to a hard hang that
risks data loss and journal corruption on every suspend.

## For a bug report

Reproduction is simple (one `grubby --args` change, one suspend cycle) but
the actual failure is inside Intel's firmware/EC S3 resume path, not
something a kernel patch on the Linux side can fix. Worth filing against
Intel/Dell directly if pursuing further, with the journal evidence above
(suspend-entry log with no subsequent resume messages, followed by an
uncleanly-shutdown journal on next boot) as the reproduction artifact.
