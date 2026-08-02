# Face unlock — AuthFace

**Status (2026-07-30): active, in daily use.** Replaced the biopass fork (see
[../face-unlock-biopass/README.md](../face-unlock-biopass/README.md)) as face
unlock on this machine. Both docs below are work done on top of upstream
AuthFace, not upstream code itself.

**Upstream project:** [pfalkingham/authFace](https://github.com/pfalkingham/authFace)
**Fork/branch:** [karanshukla/vinoAuthFace @ `main`](https://github.com/karanshukla/vinoAuthFace) (work previously tracked on `npu-openvino-liveness`, merged to `main` via PR #1 on 2026-07-30)

AuthFace is a Rust, static-binary, IR-only face-unlock stack for PAM
(`sudo`, KDE lock screen) — no resident daemon, no D-Bus, no GUI dependency
chain (the bundled GTK4 settings GUI was dropped from this fork's build to
cut a large transitive `dnf` dependency tree; the source stays in the repo,
just not wired into the workspace by default). Chosen over biopass for this
machine specifically for its immutable-distro-friendly deploy model and
because it has no resident-daemon architecture to hit the class of crash that
ended the biopass NPU work (see the NPU doc below).

Three pieces of work on top of it:

1. **[npu-openvino-backend.md](npu-openvino-backend.md)** — an opt-in
   OpenVINO NPU inference backend (Cargo feature `npu`, default off). Both
   ONNX models (detector + recognizer) compile and run on the NPU
   (`Intel(R) AI Boost`); real end-to-end auth measured at 0.5–0.8s. Required
   hand-patching this machine's NPU driver — Fedora's packaged version is
   both too old for OpenVINO 2026.2's plugin protocol *and* missing the NPU
   compiler libraries entirely, independent of version. A real detector
   box-decode/normalization bug (2026-07-30, `ef66571`) was fixed on top of
   this; didn't affect detection confidence scoring, but did mean the
   encoder was seeing full uncropped frames instead of face crops until now.
2. **[liveness-and-antispoof.md](liveness-and-antispoof.md)** — upstream
   AuthFace ships with zero anti-spoofing. Three independent layers now
   shipped: a motion-based liveness gate; an empirically confirmed finding
   (two ambient-lighting conditions including a fully dark room) that
   screen-based spoofing is blocked by this hardware's IR-illuminator
   physics, not software; and (2026-07-30) physical-USB-bus-path camera
   pinning, which closes a *different* threat (frame injection from a
   substituted USB device) that the other two layers don't address at all.
   Printed-photo resistance remains untested and open.
3. **[kwallet-not-auto-unlocking.md](kwallet-not-auto-unlocking.md)** —
   (2026-08-02, updated) KWallet doesn't auto-unlock after login. Originally
   attributed to face-auth bypassing `pam_kwallet5` (`kde-fingerprint` PAM
   stack has no hook for it), but reproduced with face-auth disabled —
   plain password login through `plasmalogin` still leaves the wallet
   locked. Root cause: a boot-time race where `pam_kwallet_init`'s
   credential socket closes (~517ms) before `kwalletd6` is D-Bus-activated
   (~2s after login), so the login password has nowhere to land. Confirmed
   as a long-standing, still-open upstream KDE bug (bugs.kde.org #433223,
   #416461), not local misconfiguration — a candidate local workaround was
   tried and reverted (see doc). Unresolved, accepted as a known annoyance.

## Upstream fork activity (2026-07-31 to 2026-08-02)

Not this repo's work directly, but real changes on
[karanshukla/vinoAuthFace](https://github.com/karanshukla/vinoAuthFace) `main`
since the 2026-07-30 migration, worth tracking here since this machine runs
that fork:

- **Camera pixel-format auto-detection.** `Camera::open` previously assumed
  every captured byte was 8-bit GREY; it now reads the driver-reported pixel
  format and handles GREY/YUYV/Y16 correctly, failing fast on anything else.
  Shipped alongside `face-camera-diag`, an offline tool that lists V4L2 nodes
  with driver/card/VID:PID/pixel format and can dump a sample frame as a PGM.
- **Binary distribution.** CI now publishes static musl binaries
  (CPU/tract backend only, no NPU) to GitHub Releases on tag push.
  `deploy.sh` falls back to a checksum-verified download of these when
  `cargo` isn't available, instead of just giving up.
- **CI added**, running workspace tests and the full `deploy.sh`/
  `uninstall.sh` matrix (source build, reused local binaries, checksum
  download) on every push/PR. Caught and fixed an OpenVINO detection gap in
  the process: `deploy.sh` only recognized the tarball install method, not
  system-package (RPM/DEB) installs.
- **Security fix (2026-08-02):** CVE-2026-55832 (`tract-onnx` path traversal
  via unsanitized ONNX `external_data` paths) patched by bumping to
  `tract-onnx` 0.21.17. A Dependabot-authored jump straight to 0.23.4 had
  been tried and reverted first, it broke the build against a dropped
  generic parameter this project's inference code depends on; 0.21.17
  patches the same CVE without leaving the 0.21 line.
- **License correction (2026-08-02):** the recognition model weights
  (`w600k_mbf`/`w600k_r50`) are **not** MIT. InsightFace's model zoo license
  is non-commercial research use only; only InsightFace's library code and
  the separate detector model are MIT. Matters if this fork or its output is
  ever redistributed or used commercially.

## Status

| Piece | State |
|---|---|
| OpenVINO NPU backend (detector + recognizer) | Implemented, merged to `main`, opt-in `npu` Cargo feature |
| Detector box-decode + input-normalization fix, face-crop-before-encode | Fixed 2026-07-30 (`ef66571`) |
| Portable scan-interval (queries camera's native V4L2 frame rate instead of a hardcoded default) | Implemented, merged to `main` |
| Motion-based liveness gate | Implemented, merged to `main`, shipped in `authenticate_scan` |
| Screen-spoof-blocked-by-physics | Confirmed empirically, not a code change — hardware property |
| Camera identity pinning (physical USB bus path + function index, frame-injection defense) | Implemented, merged to `main`, opt-in (`pin-camera.sh`, not wired into `deploy.sh`) |
| Printed-photo anti-spoof | **Open** — no test material available yet |
| NPU-accelerated anti-spoof *model* (the originally planned approach) | Not pursued — see [liveness-and-antispoof.md](liveness-and-antispoof.md#why-this-didnt-become-an-npu-anti-spoof-model) for why |
| Bundled GTK4 settings GUI | Removed from this fork's build (dnf dependency-chain cost); source retained in repo |
| KWallet auto-unlock after login | **Open, accepted** — confirmed known upstream KDE bug (`kwalletd` D-Bus-activation race vs. `pam_kwallet_init`'s credential socket), reproduces even with face-auth disabled, no local fix pursued — see [kwallet-not-auto-unlocking.md](kwallet-not-auto-unlocking.md) |
| Camera pixel-format auto-detection + `face-camera-diag` tool | Merged to `main` upstream, 2026-07-31 |
| Binary distribution (prebuilt musl releases, no-toolchain `deploy.sh` install) | Merged to `main` upstream, 2026-07-31 |
| CI (workspace tests + full `deploy.sh` matrix) | Merged to `main` upstream, 2026-07-31 |
| CVE-2026-55832 (`tract-onnx` path traversal) | Patched upstream, 2026-08-02 (bumped to `tract-onnx` 0.21.17) |
| Recognition-model MIT-license claim | Corrected upstream, 2026-08-02 — weights are non-commercial research use only, not MIT |

## Machine context

Dell XPS 13 DX13260, Wildcat Lake/Panther Lake A0 silicon, Fedora 44 KDE.
Same caveats as [../face-unlock-biopass/npu-openvino-backend.md](../face-unlock-biopass/npu-openvino-backend.md):
NPU driver/tooling support is moving faster than distro packaging can track,
so this work runs against hand-patched binaries rather than `dnf`-managed
packages — revisit once Fedora's `intel-npu-driver` catches up to upstream
`v1.35.0`+ and starts shipping the compiler libraries.
