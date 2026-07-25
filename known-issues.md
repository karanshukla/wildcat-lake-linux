# Known issues — not yet fixed or worked around

Tracking these separately from the fixed/worked-around issues in the other docs,
since they don't have a resolution yet.

## VRR / adaptive sync — crash-on-disable in the `xe` KMS driver

Disabling VRR/adaptive sync crashes the Xe3 KMS driver. Confirmed as a known
upstream work-in-progress issue (not something local config can work around).
Watch upstream `xe` driver changelogs on kernel updates.

## NPU acceleration — immature driver support

- Intel NPU driver `v1.35.0-rc1` describes itself as the "first public preview of
  Wildcat Lake firmware support" as of late July 2026 — this is genuinely
  early-silicon territory, not a configuration problem.
- OpenVINO 2026.1 supports NPU 5020 in principle, but no prebuilt C++ ONNX Runtime
  with an OpenVINO execution provider exists yet — building from source is
  required if going through ONNX Runtime's own EP layer (see
  [face-unlock-biopass/npu-openvino-backend.md](face-unlock-biopass/npu-openvino-backend.md)
  for a working approach that calls OpenVINO directly instead, sidestepping this).
- Practical scope for NPU on Linux today: local embeddings, webcam/CV-scale
  models (face detection/recognition). LLM inference at 7B scale is outperformed
  by a discrete GPU regardless. Fixed/static shapes at compile time are a
  fundamental NPU constraint, not a driver bug.
- No polished, packaged solution yet exists for Wayland-compatible KDE voice
  typing using the Intel NPU (candidates: `whisper-npu-server`, OpenVINO GenAI's
  `WhisperPipeline`) — noted as a want, not attempted.

## General assessment

Wildcat Lake on Linux is genuinely early-silicon territory: the display (PSR/DSB),
VRR, and NPU driver gaps above are structural driver-maturity issues, not
configuration problems, and marketing claims around this hardware's Linux support
diverge significantly from the actual support timeline. Worth re-evaluating
whether to keep this laptop as these mature versus staying on it and continuing to
work around gaps as they're found.
