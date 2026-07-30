# F5/dictation-key voice typing (NPU-accelerated Whisper)

**Status:** Scaffolded, not functional yet. Code:
[karanshukla/vinoWhisper](https://github.com/karanshukla/vinoWhisper).

## What it does (planned)

The F-row has a dual-mode key: physical icon is a dictation/voice-typing
symbol. Its default (non-Fn) press already emits `Meta+H` at the hardware/
kernel level — mirroring the Windows convention (Win+H = voice typing).
Fn+that same key emits literal `F5`. Right now `Meta+H` is just borrowed as
a launcher: KDE's `kglobalshortcutsrc` binds it to Ghostty's `new-window`
action (`com.mitchellh.ghostty.desktop`).

The idea: give the key its actual intended job. Local, NPU-accelerated
Whisper transcription (OpenVINO), toggled by the same `Meta+H` press,
injected as text at the cursor via `ydotool`. This also resolves the
"Wayland-compatible KDE voice typing using the Intel NPU" want already
tracked in `known-issues.md`.

## Why NPU, and why not the obvious existing project

Now that OpenVINO is proven working on this NPU (AuthFace face-unlock), this
is the next practical NPU use — it's a genuinely good fit (small model, low
power, always-resident).

The "actively maintained" fork pointer for `whisper-npu-server`
(`ellenhp/whisper-npu-server` → "check `mecattaf/whisper-npu-server`")
**404s — that GitHub repo doesn't exist.** Only a container image
(`ghcr.io/mecattaf/whisper-npu-server`) and HF model repos are reachable,
via a third fork's (`wormyrocks/whisper-npu-server`) README. That whole
ecosystem (original + forks) is sway/niri-native: hold-to-record wrapper, no
KDE/Plasma integration anywhere, and **no source anywhere documents the
text-injection mechanism** (ydotool/wtype/xdotool) — that part was always
private/unpublished on the original author's machine. So the
transcription-server *idea* is reusable (persistent local service to avoid
NPU model-load latency on every keypress), but the KDE-Wayland wiring
(hotkey → record → inject) has to be built from scratch.

Live system facts confirmed (read-only checks, 2026-07-30): `openvino`/
`openvino-genai` not installed, `ydotool`/`ydotoold` not installed, no
whisper model cached anywhere. `/dev/uinput` exists and the user is already
in the `input` group, so `ydotool` should work without extra udev rules
(unconfirmed — the existing `+` ACL on the device is worth understanding
before assuming). KDE Plasma 6.7.3, Wayland. KDE Wayland does not support
`wtype`'s virtual-keyboard protocol, so `ydotool` (uinput-based) is the
standard workaround.

## Planned architecture

Code lives in a separate repo (not here — this repo is docs-only per
`CLAUDE.md`, mirroring how the AuthFace/biopass forks live outside it):
[karanshukla/vinoWhisper](https://github.com/karanshukla/vinoWhisper),
local checkout at `~/Development/vinoWhisper`.

1. **Model conversion** — `optimum-intel`'s `optimum-cli export openvino` to
   convert `openai/whisper-small.en` to OpenVINO IR locally, rather than
   trusting mecattaf's pre-converted weights (whose GitHub presence has
   partially disappeared). Swappable later for `base.en` (faster, lower
   quality) or a larger/turbo variant if accuracy disappoints.
2. **Persistent transcription service** — local-only (127.0.0.1) Python HTTP
   server using `openvino_genai.WhisperPipeline(model_path, device="NPU")`.
   NPU inference needs the static-pipeline code path per OpenVINO GenAI's
   NPU docs — confirm the exact constructor property against whatever
   `openvino_genai` version actually installs, API may have moved since.
   Runs as a `systemd --user` service so the model loads once at login
   instead of eating ~10-30s NPU compile/load latency per dictation press.
3. **Recording + injection wrapper (toggle mode)** — Python script invoked
   twice per dictation, state in a pidfile under `$XDG_RUNTIME_DIR`. First
   press: `pw-record` (16kHz mono) to a temp WAV + `notify-send` cue.
   Second press: kill recorder, POST the WAV to the local transcription
   service, inject the returned text at the cursor via `ydotool type`.
   Toggle rather than hold-to-record: KDE global shortcuts fire on press,
   not press-and-hold-then-release, so true hold-to-record would mean
   bypassing KDE shortcuts and reading raw evdev events instead. Toggle is
   simpler to get working first; hold-to-record is a possible later
   revision if the UX bugs me.
4. **ydotool setup** — install `ydotool`, enable `ydotoold` as a user
   service, verify `/dev/uinput` access actually works given current
   `input` group membership.
5. **KDE wiring** — repoint the existing `Meta+H` global shortcut from
   Ghostty's `new-window` action to the toggle script. No `keyd` involvement
   needed; `Meta+H` is a real hardware-level chord, not something `keyd`
   manufactures. Ghostty's shortcut goes unbound as a result — fine to
   rebind later (Fn-mode `F5` is a natural symmetric spot, not decided yet).

## Verification plan (once built)

1. Standalone CLI test first: converted model + a pre-recorded test WAV
   through `WhisperPipeline(..., device="NPU")`, confirm correct
   transcription and measure latency — before wiring any hotkey, to isolate
   model/NPU correctness from input-injection plumbing.
2. Test `ydotool type` alone (e.g. into Kate) to confirm uinput permissions
   work end-to-end before connecting it to real transcription output.
3. Wire the KDE shortcut last; test the full press-record-press-transcribe-
   inject loop in a plain text field, then Ghostty, then a browser text box
   (different apps handle synthetic uinput input slightly differently).
4. Confirm the NPU is actually doing the inference (not silently falling
   back to CPU) — reuse whatever NPU-utilization check worked during the
   AuthFace NPU work.

## Open items (not blocking, for whenever this gets picked up)

- No visual "recording in progress" indicator beyond a `notify-send` toast
  in the first pass — a proper OSD/plasmoid would be nicer, out of scope
  for a first working version.
- Model size (`small.en` vs. `base.en` vs. a larger/turbo variant) is a call
  to make once real accuracy on my own voice/accent can be heard — starting
  with `small.en` as a default, not a fixed choice.

## For a bug report

Not applicable yet — nothing built, no bug to report. If `ydotool`/uinput
turns out to need more than `input`-group membership on this system, or if
OpenVINO GenAI's NPU static-pipeline requirement changes behavior
unexpectedly, that's worth a note here once hit.
