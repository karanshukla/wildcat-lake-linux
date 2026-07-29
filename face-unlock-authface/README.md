# Face unlock — AuthFace

**Status (2026-07-29): active, in daily use.** Replaced the biopass fork (see
[../face-unlock-biopass/README.md](../face-unlock-biopass/README.md)) as face
unlock on this machine. Both docs below are work done on top of upstream
AuthFace, not upstream code itself.

**Upstream project:** [pfalkingham/authFace](https://github.com/pfalkingham/authFace)
**Fork/branch:** [karanshukla/vinoAuthFace @ `npu-openvino-liveness`](https://github.com/karanshukla/vinoAuthFace/tree/npu-openvino-liveness)

AuthFace is a Rust, static-binary, IR-only face-unlock stack for PAM
(`sudo`, KDE lock screen) — no resident daemon, no D-Bus, no GUI dependency
chain (the bundled GTK4 settings GUI was dropped from this fork's build to
cut a large transitive `dnf` dependency tree; the source stays in the repo,
just not wired into the workspace by default). Chosen over biopass for this
machine specifically for its immutable-distro-friendly deploy model and
because it has no resident-daemon architecture to hit the class of crash that
ended the biopass NPU work (see the NPU doc below).

Two pieces of work on top of it:

1. **[npu-openvino-backend.md](npu-openvino-backend.md)** — an opt-in
   OpenVINO NPU inference backend (Cargo feature `npu`, default off). Both
   ONNX models (detector + recognizer) compile and run on the NPU
   (`Intel(R) AI Boost`); real end-to-end auth measured at 0.5–0.8s. Required
   hand-patching this machine's NPU driver — Fedora's packaged version is
   both too old for OpenVINO 2026.2's plugin protocol *and* missing the NPU
   compiler libraries entirely, independent of version.
2. **[liveness-and-antispoof.md](liveness-and-antispoof.md)** — upstream
   AuthFace ships with zero anti-spoofing. Added a motion-based liveness
   gate, and separately confirmed (empirically, under two different ambient
   lighting conditions including a fully dark room) that screen-based
   spoofing — a phone/tablet showing a photo of the victim — is blocked by
   this hardware's IR-illuminator physics, not by any software logic.
   Printed-photo resistance remains untested and open.

## Status

| Piece | State |
|---|---|
| OpenVINO NPU backend (detector + recognizer) | Implemented, opt-in `npu` Cargo feature, on fork branch |
| Portable scan-interval (queries camera's native V4L2 frame rate instead of a hardcoded default) | Implemented, on fork branch |
| Motion-based liveness gate | Implemented, on fork branch, shipped in `authenticate_scan` |
| Screen-spoof-blocked-by-physics | Confirmed empirically, not a code change — hardware property |
| Printed-photo anti-spoof | **Open** — no test material available yet |
| NPU-accelerated anti-spoof *model* (the originally planned approach) | Not pursued — see [liveness-and-antispoof.md](liveness-and-antispoof.md#why-this-didnt-become-an-npu-anti-spoof-model) for why |
| Bundled GTK4 settings GUI | Removed from this fork's build (dnf dependency-chain cost); source retained in repo |

## Machine context

Dell XPS 13 DX13260, Wildcat Lake/Panther Lake A0 silicon, Fedora 44 KDE.
Same caveats as [../face-unlock-biopass/npu-openvino-backend.md](../face-unlock-biopass/npu-openvino-backend.md):
NPU driver/tooling support is moving faster than distro packaging can track,
so this work runs against hand-patched binaries rather than `dnf`-managed
packages — revisit once Fedora's `intel-npu-driver` catches up to upstream
`v1.35.0`+ and starts shipping the compiler libraries.
