# biopassd: resident authentication daemon (issue #152)

**Fixes:** [TickLabVN/biopass#152](https://github.com/TickLabVN/biopass/issues/152) — cold-start latency
**Diff:** `auth/pam/daemon.cc` (new, 393 lines), `auth/pam/pam.cc` (+89), `auth/pam/CMakeLists.txt` (+32),
`auth/pam/biopassd.service` (new), `auth/pam/biopassd.socket` (new), plus a camera-capture
refactor across `auth/face/common/camera_capture.{cc,h}`, `auth/face/face_auth.cc`,
`auth/face/antispoofing/ir_camera_as.cc`.

## Problem

Every PAM authentication attempt forks + execs `biopass-helper auth`, which
constructs a brand-new `AuthManager` (and therefore a brand-new `FaceAuth`) from
scratch: reopening the camera and reloading every ONNX model, on every single
login/unlock/`sudo` attempt.

## Design: idle-exit resident daemon, not always-on

`biopassd` keeps exactly one `AuthManager` warm for as long as it's been recently
used, then exits voluntarily:

- Launched on demand via **systemd socket activation** — `biopassd.socket` owns the
  listening socket; systemd only spawns the binary on the first incoming
  connection.
- Self-exits after an idle timeout (`poll()` timeout on the accept loop) with no
  requests, releasing every loaded model and the camera handle. Idle memory
  footprint is therefore zero — no process even running — rather than "a small
  resident model staying loaded forever."
- Default idle timeout: **1800s (30 min)**, overridable via
  `BIOPASSD_IDLE_TIMEOUT_SECS` in the environment. No fixed Linux convention
  mandates a specific value; 30 minutes comfortably covers a burst of
  login/unlock/sudo attempts without staying loaded through a whole idle workday.
- The next auth attempt after an idle exit pays a fresh cold-start cost — systemd
  respawns the process, re-inheriting the same still-open listening socket — but
  every attempt within an active burst (a normal work session) stays warm.
- This deliberately mirrors how Windows' biometric service (`WbioSrvc`) behaves:
  always registered, but lazy to actually load, and able to go back to sleep.
- Falls back to a plain self-bind (no systemd `LISTEN_FDS` handoff) so it can still
  be started/tested manually.

## Security model

- Runs as a `systemd --user` unit: one instance per logged-in user, under that
  user's own uid.
- Listens on a Unix domain socket under `$XDG_RUNTIME_DIR` (`%t/biopass-daemon.sock`),
  chmod'd to `0600`.
- **Hard refusal of any username other than its own owning user** — this daemon is
  not a general auth broker; it only ever vouches for the one user it runs as.
- Server side verifies the connecting peer via `SO_PEERCRED`, accepting only the
  daemon's own uid or root (e.g. a display manager's privileged PAM stack).
- Client side (`pam.cc`'s `tryResidentDaemon()`) **independently** re-verifies the
  peer's uid via `SO_PEERCRED` before trusting the response — a rogue local
  process squatting on the expected socket path can't self-approve. This function
  is written so any failure (daemon not running, wrong peer uid, malformed
  response, unrecognized result code) falls straight through to the existing
  fork+exec cold-start path with zero behavior change — it must never be able to
  make authentication *more* likely to succeed than the fallback.

## Wire protocol

Line-based, matching the existing style of `previewSession()` in `helper.cc`:

- Client sends: `AUTH <username> <service>\n`
- Daemon replies: `RESULT <code>\n` where code is `0` (`PAM_SUCCESS`), `1`
  (`PAM_AUTH_ERR`), or `2` (`PAM_IGNORE`) — the same codes `biopass-helper`'s
  process exit code already used, so `pam.cc`'s result handling is unchanged
  either way.

## Config change handling

The daemon re-reads `config.yaml` on every call and rebuilds the `AuthManager` only
if a cheap fingerprint of the config fields that matter (method enable/order/model
IDs) has changed — so edits made via the Tauri settings app take effect without a
daemon restart, without paying full model-reload cost on every call "just in case."

## Camera capture refactor (streaming vs. acquired)

Previously `isOpen()` meant "camera acquired *and* actively streaming," and closing
between calls meant re-acquiring (device enumeration, format negotiation, DMA
buffer setup) every time — the expensive part.

The refactor splits this:

- `acquired_` — device acquire/configure/buffer-allocation, safe to leave resident
  across many `capture()` calls.
- `streaming_` — actually powers the sensor (and IR emitter, on IR modules) and
  drives the LED/IR-emitter indicator hardware. Now started/stopped **per
  capture()** via new `startStreaming()`/`stopStreaming()` methods, so the
  indicator LED is only lit for the duration of a real capture, not the whole time
  the daemon holds the camera resident.
- New `warmUp()` method on `ICameraCaptureSession` (no-op by default) lets a caller
  start streaming ahead of the first `capture()`, so a warmup delay elsewhere can
  overlap with the ramp instead of wasting it. Used by the IR anti-spoofing
  presence check (`ir_camera_as.cc`) — previously that path could burn a whole
  ~1s attempt on a black frame because the stabilization sleep ran before the
  stream was actually live.
- **RGB sessions** stop streaming after each `capture()` returns (via a local
  `StopGuard`). **Grey/IR sessions deliberately keep streaming** across repeated
  captures — the IR anti-spoofing check reuses one session across many rapid
  back-to-back captures, and the emitter/auto-exposure need to stay continuously
  warm across that loop; they're torn down at `endAuthenticationSession()` anyway
  since they're ephemeral per-attempt.
- `FaceAuth::endAuthenticationSession()` now deliberately leaves the RGB
  `camera_session_` resident (the #152 payoff) while still always tearing down the
  IR session — the IR teardown is a deliberate anti-spoofing property so a later
  call can never reuse a partially-warmed IR session to bypass the presence check.

## Other changes bundled in this branch

- **PAM module install path auto-detection** (`auth/CMakeLists.txt`): probes for
  `pam_unix.so` across `/lib64/security`, `/usr/lib64/security`,
  `/lib/<multiarch-triplet>/security`, etc. instead of hardcoding
  `/lib/security` — the previous hardcoded path is Debian/Ubuntu-specific and
  silently wrong on Fedora/RHEL/SUSE x86_64 (`/lib64/security`). Override with
  `-DPAM_MODULE_DIR=...` if detection guesses wrong.
- **ONNX Runtime intra-op thread tuning** (`onnx_session.cc`): was hardcoded to 1
  thread; now scales up to `min(4, hardware_concurrency())`. Model inference
  (YOLO detection especially) is the dominant CPU cost of a warm authentication,
  and single-threaded execution left most cores idle.
- **`-Dwerror=false`** added to the vendored libcamera build (`BundleLibcamera.cmake`)
  — unrelated portability fix, needed for this toolchain/libcamera version
  combination to build clean.

## For a bug report / upstream PR

This is scoped as an **optional, additive fast path**: `biopassd`/`biopassd.socket`
are separate install targets, and `pam.cc` only calls into the daemon path if
`tryResidentDaemon()` succeeds cleanly — any distro that doesn't package the daemon
units gets the exact previous fork+exec behavior unchanged. That should make it a
low-risk upstream PR candidate once tested more broadly than one machine.
