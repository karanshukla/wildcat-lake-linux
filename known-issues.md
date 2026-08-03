# Known issues — not yet fixed or worked around

Tracking these separately from the fixed/worked-around issues in the other docs,
since they don't have a resolution yet.

## VRR / adaptive sync — crash-on-disable in the `xe` KMS driver

Disabling VRR/adaptive sync crashes the Xe3 KMS driver. Confirmed as a known
upstream work-in-progress issue (not something local config can work around).
Watch upstream `xe` driver changelogs on kernel updates.

Separately, and possibly related: VRR reports capable and enabled but the
panel's real refresh rate never modulates, confirmed via direct kernel vblank
measurement across both idle desktop and fullscreen video. Root cause not
isolated yet, confounded by a documented KWin bug (open windows/terminals
breaking VRR detection). Full investigation:
[display/vrr-not-engaging.md](display/vrr-not-engaging.md).

## NPU acceleration — inference works, but crashes a real daemon process

Update (2026-07-29): moot for now — face unlock moved from biopass to
[AuthFace](https://github.com/pfalkingham/authFace) (see
[face-unlock-biopass/README.md](face-unlock-biopass/README.md)), so the
biopassd heap-corruption bug below is no longer being chased. Left in place
since the NPU/OpenVINO stack findings are still generally useful evidence.
AuthFace's own NPU work (same day) got both models working on-device — see
[face-unlock-authface/npu-openvino-backend.md](face-unlock-authface/npu-openvino-backend.md)
— including a second, independent Fedora packaging gap (NPU compiler
libraries never shipped at all, any version) beyond the version-skew problem
this section already describes. AuthFace's architecture (short-lived
per-invocation process, not a resident daemon) never had the chance to
reproduce the heap-corruption bug below one way or the other.

Update (2026-07-25): NPU inference itself is **not** blocked by driver
maturity the way this section previously claimed — with the kernel driver,
`oneapi-level-zero`, `intel-npu-driver`/`intel-npu-compiler`, and a vendored
OpenVINO 2026.2.1 (Fedora's packaged 2025.1.0 is too old — protocol mismatch),
two of three biopass models compiled and ran correctly on the NPU with real
measured speedups. Full details and the software stack that got it working:
[face-unlock-biopass/npu-openvino-backend.md](face-unlock-biopass/npu-openvino-backend.md).

The actual open blocker is different and more serious: linking OpenVINO into a
long-running multi-threaded daemon process (`biopassd`) crashed it with heap
corruption on the first real use, reproducing even with the OpenVINO API
never called at runtime — not root-caused yet, see the doc above. This is a
threading/allocator interaction bug, not a driver-maturity gap.

Remaining genuine driver-maturity notes:
- Fixed/static shapes at compile time are a fundamental NPU constraint (not a
  driver bug) — one of the three biopass models (YOLO face detection) has a
  dynamic reshape buried inside its graph that hard-crashes the NPU compiler
  and hasn't been worked around.
- Practical scope for NPU on Linux today: local embeddings, webcam/CV-scale
  models. LLM inference at 7B scale is outperformed by a discrete GPU
  regardless.
- No polished, packaged solution yet exists for a Wayland-compatible KDE
  speech feature using the Intel NPU — pivoted 2026-08-03 from toggle-mode
  voice typing to live captioning. Feasibility spike complete and confirmed
  working (NPU inference, correct transcription, ~1.19s per 30s window,
  ~0.2s perceived latency via token streaming); live-captioning
  implementation itself (continuous capture, overlay display) not built yet
  — [input/f5-voice-typing.md](input/f5-voice-typing.md),
  code at [karanshukla/vinoWhisper](https://github.com/karanshukla/vinoWhisper).
  Worth noting: the "actively maintained" `whisper-npu-server` fork pointer
  404s (repo doesn't exist), so this'll need to be built mostly from scratch
  rather than copied.
- Want: NPU-powered real-time mic noise suppression, replacing CPU-based
  options (NoiseTorch/RNNoise, DeepFilterNet's default CPU backend). Intel
  already provides the pieces, just not glued together for this: DeepFilterNet2/3
  converted to OpenVINO IR with NPU as a selectable device is proven working in
  [openvino-plugins-ai-audacity](https://github.com/intel/openvino-plugins-ai-audacity/blob/main/doc/feature_doc/noise_suppression/README.md)
  (models: [Intel/deepfilternet-openvino](https://huggingface.co/Intel/deepfilternet-openvino)
  on Hugging Face), but that plugin processes static Audacity tracks, not a live
  mic stream. A real-time PipeWire version would need to be built by combining
  that model with a streaming architecture like
  [yas-sim/openvino-real-time-noise-suppression-demo](https://github.com/yas-sim/openvino-real-time-noise-suppression-demo)
  (currently CPU/GPU/MYRIAD-only, PyAudio-based, no PipeWire). Non-trivial part
  is the GRU hidden-state bookkeeping between frames plus the STFT/ERB-band math
  that sits outside the ONNX/IR graph, best cribbed from the Audacity plugin's
  C++ source rather than reimplemented from the paper. Speaker-side "ML EQ" for
  the tinny-speaker problem doesn't have an NPU equivalent worth chasing; that
  stays DSP/psychoacoustic (EasyEffects), same as the existing
  [audio/cs42l43-eq-fix.md](audio/cs42l43-eq-fix.md) fix. Not started — parking
  here until there's time to build it; will get its own doc under `audio/` once
  there's something concrete.

## KWallet doesn't auto-unlock after login

Originally suspected as a face-auth gap (AuthFace's `kde-fingerprint` PAM
stack has no `pam_kwallet5` hook, and a face embedding can't supply the
plaintext password `pam_kwallet5` needs anyway) — but reproduced 2026-08-02
with face-auth disabled, on a plain password login through the greeter's
`plasmalogin` PAM service, which does correctly run `pam_kwallet5` (it's
wired in via Fedora's vendor `/usr/lib/pam.d/plasmalogin`, not
`/etc/pam.d/plasmalogin` which doesn't exist — the earlier "no PAM template"
finding only checked the latter). Result either way: KWallet stays locked
and apps requesting secrets through `xdg-desktop-portal`'s Secret Service
bridge each trigger their own manual-unlock prompt, easy to mistake for the
portal or `sudo`/polkit misbehaving (ruled out — polkit logs show nothing
anomalous). Root cause: `pam_kwallet_init`'s credential-handoff socket
exits (~517ms after login) before `kwalletd6` is D-Bus-activated (~2s after
login, on first real Secret Service call) — a timing race, not a PAM
wiring or biometric-auth gap. Confirmed as a long-standing, still-open
upstream KDE bug (bugs.kde.org #433223, #416461), not local
misconfiguration — a candidate local workaround (forcing early
`org.freedesktop.secrets` activation) was tried and reverted, see the doc.
Accepted as a known annoyance; no local fix pursued. Full investigation:
[face-unlock-authface/kwallet-not-auto-unlocking.md](face-unlock-authface/kwallet-not-auto-unlocking.md).

## Touchpad — tap-to-click misfires while typing (keyd interaction)

Tap-to-click cursor jumps and misfired clicks while typing, on a touchpad with
no haptic feedback (tap-to-click is the only practical click method here).
Root cause isolated via `libinput debug-events`: disable-while-typing (DWT) is
enabled and works correctly when the physical keyboard drives events directly,
but fails to fully suppress the touchpad when `keyd`'s virtual re-injected
keyboard device drives the same keystrokes. Confirmed with a clean A/B (same
hardware, same palm-swipe test, keyd stopped vs. running). Exact internal
libinput mechanism not pinned down yet. Full investigation:
[input/keyd-breaks-touchpad-dwt.md](input/keyd-breaks-touchpad-dwt.md).

## History

- **Two of four speakers (CS35L56 sidecar amps) silent** — was tracked here
  as unresolved (ACPI under-reports the SDCA SmartAmp count, no upstream
  quirk existed for this Dell SKU). Fixed 2026-08-03 via a signed local
  kernel patch (one DMI quirk entry, following an exact already-merged
  precedent for a sibling SKU). Full investigation and fix:
  [audio/cs35l56-sidecar-amp-quirk.md](audio/cs35l56-sidecar-amp-quirk.md).

## General assessment

Wildcat Lake on Linux is genuinely early-silicon territory: the display (PSR/DSB),
VRR, and NPU driver gaps above are structural driver-maturity issues, not
configuration problems, and marketing claims around this hardware's Linux support
diverge significantly from the actual support timeline. Worth re-evaluating
whether to keep this laptop as these mature versus staying on it and continuing to
work around gaps as they're found.
