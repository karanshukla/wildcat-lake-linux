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
- No polished, packaged solution yet exists for Wayland-compatible KDE voice
  typing using the Intel NPU (candidates: `whisper-npu-server`, OpenVINO
  GenAI's `WhisperPipeline`) — noted as a want, not attempted.

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

## General assessment

Wildcat Lake on Linux is genuinely early-silicon territory: the display (PSR/DSB),
VRR, and NPU driver gaps above are structural driver-maturity issues, not
configuration problems, and marketing claims around this hardware's Linux support
diverge significantly from the actual support timeline. Worth re-evaluating
whether to keep this laptop as these mature versus staying on it and continuing to
work around gaps as they're found.
