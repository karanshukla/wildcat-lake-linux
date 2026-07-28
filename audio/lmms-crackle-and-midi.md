# LMMS: Akai MPK mini play MIDI setup, and note-sequence crackle

**Status:** MIDI setup resolved (not a bug, workflow gap). Crackle fix applied
(ALSA buffer bump + PipeWire rate config + RT scheduling grant), verification
pending next login.
**Component:** LMMS 1.2.2, PipeWire 1.6.8, ALSA sequencer, Akai MPK mini play

## Part 1: Akai not detected in LMMS

Not a bug. `amidi -l` and `aconnect -l` both showed the MPK mini play fine
(kernel ALSA-seq client 20, port "MPK mini play MIDI 1") the whole time. LMMS's
ALSA-Sequencer MIDI backend was correctly selected and created its own client
(128, "LMMS") on launch. The client just had **zero ports**, because LMMS only
creates a MIDI port when a track explicitly enables receiving on it, and no
project was open yet.

Fix: create/open an instrument track, open its MIDI tab, enable "Receive MIDI
events," select "MPK mini play MIDI 1" as the input. LMMS creates the port then;
`aconnect -l` shows it under client 128 once done.

## Part 2: crackle when playing note sequences (single notes fine)

### Root cause

Two contributing factors, one confirmed non-factor:

1. **Buffer/quantum mismatch.** LMMS's ALSA buffer was `256` frames (~5.8ms)
   against PipeWire's default quantum of `1024` (~21ms). Misaligned periods
   between an ALSA-plugin client and PipeWire's graph quantum is a known
   source of crackle independent of sample rate.
2. **Real sample-rate mismatch was present but likely not the main driver.**
   LMMS 1.2.2 hardcodes 44100Hz output (no user-facing samplerate setting
   exists anywhere in `~/.lmmsrc.xml` or Edit > Settings), while PipeWire's
   graph was locked to `48000` only (`default.clock.allowed-rates = [ 48000 ]`
   in `pipewire.conf`). PipeWire resamples internally regardless of this
   list; the list only governs whether the graph's *running* clock can switch
   rates, which it never did for LMMS's plain ALSA-shim stream (confirmed via
   `pw-metadata -n settings`, stayed at 48000 throughout).
3. **The actual best explanation: LMMS's own mixing thread runs unprivileged.**
   Per-thread scheduling check (`chrt -p` across every `/proc/<pid>/task/*`)
   showed PipeWire's own I/O thread (`data-loop.0`) correctly at
   `SCHED_RR` priority 20, but every LMMS thread, including the ones doing
   actual synthesis/mixing, sat at plain `SCHED_OTHER` priority 0. A single
   held note is a flat, low workload that never gets unlucky with preemption;
   a sequence of notes creates periodic CPU spikes (voice alloc, envelope
   trigger) right where a missed deadline shows up as an audible glitick.
   This lines up exactly with the reported symptom (single note fine,
   sequence crackles).

Why the mixing thread was never RT: `ulimit -r` was `0` for this user, and
LMMS was not in the `pipewire` group, the only group with an `rtprio 70` grant
(`/etc/security/limits.d/25-pw-rlimits.conf`, installed by the PipeWire
project). Without that ceiling, any attempt to raise scheduling priority fails
silently with `EPERM`.

### Dead end: switching LMMS to the JACK backend

LMMS's binary does import `sched_setscheduler` and has RT-request symbols
(`WJACK_acquire_real_time_scheduling`), but they're gated behind the **JACK**
backend, not ALSA. Tried switching `<mixer audiodev>` to
`JACK (JACK Audio Connection Kit)` (`pipewire-jack-audio-connection-kit` is
installed, provides `/usr/lib64/pipewire-0.3/jack/libjack.so.0`, no real
`jackd` needed). Result: worse on both counts.

| | ALSA backend | JACK backend (tried) |
|---|---|---|
| LMMS thread scheduling | `SCHED_OTHER` | still `SCHED_OTHER` (RT-request code never fired, likely gated on a `jack_is_realtime()` check PipeWire's JACK shim doesn't satisfy) |
| Audio output | works, routes through `bass_eq` | **silent** — JACK ports don't auto-connect to the speaker sink the way Pulse/ALSA streams do |

Reverted. Not worth re-attempting without deeper investigation into why
PipeWire's JACK shim doesn't trip LMMS's RT path.

### Fix applied

1. `~/.lmmsrc.xml`: `framesperaudiobuffer` `256` → `1024`, matching PipeWire's
   quantum.
2. `~/.config/pipewire/pipewire.conf.d/10-rates.conf` (symlinked from Fedora's
   disabled-by-default `/usr/share/pipewire/pipewire.conf.avail/10-rates.conf`):
   adds 44100/88200/96000 to `allowed-rates` alongside 48000. Kept user-scoped
   rather than system-wide (`/etc`) to match how the `bass_eq` filter-chain is
   already user-scoped. Belt-and-suspenders; the scheduling fix below is
   expected to matter more.
3. Added `karanshukla` to the `pipewire` system group
   (`sudo usermod -aG pipewire karanshukla`), granting the `rtprio 70` ceiling
   from `25-pw-rlimits.conf`. Group changes don't apply to an already-open
   session; requires logout/login.
4. `~/.local/share/applications/lmms.desktop`: user override of the system
   `.desktop` file, `Exec=chrt -r 20 lmms %f` instead of `Exec=lmms %f`. Since
   `pthread_create` inherits the creating thread's scheduling policy by
   default, launching the whole process under `chrt -r 20` should carry
   `SCHED_RR` priority 20 to every LMMS thread, not just the main one.
   Priority 20 chosen to match (not exceed) PipeWire's own I/O thread, so it
   doesn't starve PipeWire itself. `SCHED_RR` over `SCHED_FIFO` deliberately,
   since FIFO threads that don't yield can lock out equal-priority
   competitors indefinitely; RR time-slices instead.

Confirmed `chrt -r 20` fails with `EPERM` in the current session (expected,
group membership not yet refreshed). Verification of the actual crackle fix
is pending next login.

## For a bug report

Not applicable, everything here is local config/LMMS 1.2.2 behavior, not a
kernel or firmware issue. If the JACK-backend dead end above gets revisited,
the useful upstream question would be to LMMS or PipeWire: why does
`pipewire-jack`'s `jack_is_realtime()` (or whatever gate LMMS checks) not
satisfy LMMS's `WJACK_acquire_real_time_scheduling` call path.

## Remaining questions

- Does the `chrt -r 20` wrapper actually kill the crackle after relogin, or
  was the buffer bump alone sufficient and the scheduling piece unnecessary?
- If crackle persists even with RT scheduling, next diagnostic step is
  `pw-top` during live playback to catch xruns directly, at which point the
  `powersave` governor / `balanced-battery` tuned profile becomes a relevant
  suspect again (not touched in this pass, at request).
