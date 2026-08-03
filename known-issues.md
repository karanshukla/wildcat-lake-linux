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

## Audio — two of four speakers (CS35L56 woofer amps) never get audio routed

Symptom: only the tweeter path (driven directly by the CS42L43 codec) plays
anything; the two woofers behind the CS35L56 amp chips are silent. First
flagged by matching reports from other DellInc.-XPS13DX13260 owners running
Fedora, then independently reproduced and root-caused on this machine
(2026-08-03).

Root cause, confirmed via `journalctl -k`: both physical CS35L56 amps probe
and boot firmware correctly —
```
cs35l56 spi-cs35l56-left:  Cirrus Logic CS35L56 Rev B2 OTP1 fw:4.2.1 (patched=0)
cs35l56 spi-cs35l56-right: Cirrus Logic CS35L56 Rev B2 OTP1 fw:4.2.1 (patched=0)
```
but the kernel never wires audio to them:
```
sof-audio-pci-intel-ptl: No SoundWire machine driver found for the ACPI-reported configuration:
sof-audio-pci-intel-ptl: link 2 mfg_id 0x01fa part_id 0x4243 version 0x3
acpi device:20: SDCA function SmartAmp (type 1) at 0x1
sof-audio-pci-intel-ptl: loading topology 1: intel/sof-ipc4-tplg/sof-sdca-1amp-id2.tplg
```
No SoundWire machine-driver quirk exists yet for this exact link
configuration (early silicon), so the kernel falls back to a generic
"function topology" loader that trusts ACPI's reported SDCA function count —
and Dell's ACPI tables report only **one** SmartAmp function, despite two
independently-addressable CS35L56 chips being present. Result: `aplay -l`
exposes a single 2-channel "Speaker" PCM (tweeters only), and no `cs35l56`
mixer controls exist on the card.

Tested and ruled out as a local/config-level fix: the correct topology does
ship in the SOF firmware package
(`/usr/lib/firmware/intel/sof-ipc4-tplg/sof-sdca-2amp-id2.tplg.xz`, alongside
1amp/3amp/4amp variants), so forced it via the `snd_sof` module's
`tplg_filename`/`tplg_path` parameters (the param is read-only once loaded —
required a full unload/reload of the entire SOF/SoundWire module chain). The
2-amp topology loaded, but the card then failed to build entirely:
```
sof-audio-pci-intel-ptl: loading topology: intel/sof-ipc4-tplg/sof-sdca-2amp-id2.tplg
sof-audio-pci-intel-ptl: error: can't find BE for DAI alh-copier.Playback-SmartAmp.1
sof_sdw: ASoC: failed to load widget alh-copier.Playback-SmartAmp.1
```
Even the matching topology has nowhere to attach the second amp's stream,
because the machine driver only ever creates one backend DAI — a direct
consequence of ACPI under-reporting the SmartAmp count. Cleanly reverted
(unload/reload back to default params); no lasting effect on the system.

No local fix exists. What's actually needed: a kernel machine-driver quirk
(`snd_soc_sof_sdw`/`snd_sof_intel_hda_generic`) hardcoding a second backend
DAI for this device (SoundWire link 2, mfg_id 0x01fa, part_id 0x4243,
version 0x3), or a Dell BIOS/ACPI update correctly reporting 2 SmartAmp
functions instead of 1.

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
- No polished, packaged solution yet exists for Wayland-compatible KDE voice
  typing using the Intel NPU. Design done, scaffolded, not functional yet —
  [input/f5-voice-typing.md](input/f5-voice-typing.md),
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

## General assessment

Wildcat Lake on Linux is genuinely early-silicon territory: the display (PSR/DSB),
VRR, and NPU driver gaps above are structural driver-maturity issues, not
configuration problems, and marketing claims around this hardware's Linux support
diverge significantly from the actual support timeline. Worth re-evaluating
whether to keep this laptop as these mature versus staying on it and continuing to
work around gaps as they're found.
