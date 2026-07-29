# AuthFace: OpenVINO NPU inference backend

**Fork/branch:** [karanshukla/vinoAuthFace @ `npu-openvino-liveness`](https://github.com/karanshukla/vinoAuthFace/tree/npu-openvino-liveness) (fork of [pfalkingham/authFace](https://github.com/pfalkingham/authFace))

> **Status (2026-07-29): working, on a branch, not yet merged to `main`.**
> Both of AuthFace's ONNX models (face detector, face recognizer) compile and
> run correctly on the NPU, gated behind an opt-in `npu` Cargo feature
> (default off — the existing `tract-onnx` CPU backend is unchanged unless
> explicitly selected). Getting there required patching this machine's NPU
> driver by hand; see [Software stack](#software-stack-that-actually-got-it-working)
> below. Real end-to-end authentication (camera capture → detect → recognize
> → verify) measured at 0.5–0.8s total, most of it now camera/liveness-gate
> time rather than inference.

## Why this is a second attempt at the same problem

[npu-openvino-backend.md](../face-unlock-biopass/npu-openvino-backend.md) (the
biopass fork's version of this work, 2026-07-25) got NPU inference working in
isolated test binaries but hit a fatal heap-corruption crash the moment
OpenVINO was linked into the real resident `biopassd` daemon process — not
root-caused, and the fork was reverted. AuthFace's architecture sidesteps that
entire class of risk structurally, not by fixing it: `face-auth` is a
short-lived process spawned fresh per PAM invocation (via `pam_exec.so`), not
a long-running multi-threaded daemon. There's no persistent process for an
OpenVINO/TBB allocator interaction to corrupt over time. This is an
architectural argument, not a proven absence of that bug class — it just was
never in a position to reproduce it, since nothing here stays resident between
auth attempts.

## The version-skew problem was the *opposite* direction from biopass's

biopass's doc found Fedora's packaged OpenVINO (`2025.1.0`) too **old** for the
installed NPU driver's graph-extension protocol. Four days later, on the same
hardware, this investigation hit version skew running the other way:

- OpenVINO target: `2026.2.1` (same version biopass's doc vendored, for
  continuity/comparison).
- Fedora's `intel-npu-driver` (`updates` repo): `1.32.0`, built 2026-05-21.
- `compile_model(..., "NPU")` failed on **both** OpenVINO `2026.2.1` and
  `2026.1.0` with the identical error:
  ```
  RuntimeError: ... ze_graph_ext_wrappers.cpp:425:
  Compilation failed. Level0 pfnCreate2 result: ZE_RESULT_ERROR_UNSUPPORTED_FEATURE,
  code 0x78000003 - generic error code for unsupported features.
  ```
  Reproducing identically across two OpenVINO minor versions ruled out an
  OpenVINO-side regression and pointed at the driver.

Root cause, once traced: Intel's `intel/linux-npu-driver` upstream cut
**v1.35.0 on 2026-07-24** — five days before this investigation — specifically
to pair with OpenVINO 2026.2. Fedora's `1.32.0` (2026-05-21 build) predates
that pairing.

## A second, independent gap: Fedora's package never shipped the NPU compiler at all

This is not just a version being old — some required files don't exist on
Fedora **at any version** of the `intel-npu-driver` package:

```
$ rpm -ql intel-npu-driver
/usr/lib64/libze_intel_npu.so.1
/usr/lib64/libze_intel_npu.so.1.32.0
/usr/share/doc/intel-npu-driver/README.md
/usr/share/licenses/intel-npu-driver/LICENSE.md
```

`libopenvino_intel_npu_compiler.so` and `libopenvino_intel_npu_compiler_loader.so`
— the libraries that actually turn a model graph into an NPU-executable binary
— are absent entirely. Without them, NPU compilation cannot work regardless of
driver version; this looks like a Fedora packaging gap (the compiler simply
isn't part of the spec's file list), not something a `dnf upgrade` would fix
even once Fedora catches up to `1.35.0`, unless the packaging itself is also
corrected.

Compounding this: upstream `v1.35.0` **only publishes Ubuntu 24.04 `.deb`
packages** (`linux-npu-driver-v1.35.0.20260722-...-ubuntu2404.tar.gz`) — no
RPM, and no Fedora COPR carries it yet either (checked).

## Software stack that actually got it working

1. Kernel driver (`intel_vpu`, in-tree) already loaded; `/dev/accel0` present,
   firmware (`vpu_50xx_v1.bin.xz`) already installed via `linux-firmware`.
   NPU enumerates fine (`Intel(R) AI Boost`) — nothing wrong at this layer.
2. Downloaded upstream's Ubuntu tarball anyway (works on Fedora — these are
   plain userspace `.so`s + firmware blobs, no kernel module, no packaging
   system dependency beyond extraction):
   ```
   curl -L -o npu-driver.tar.gz \
     https://github.com/intel/linux-npu-driver/releases/download/v1.35.0/linux-npu-driver-v1.35.0.20260722-29947505341-ubuntu2404.tar.gz
   ```
3. Extracted the three needed `.deb`s with `dpkg-deb -x` (present on Fedora
   even without a Debian userland) — no `alien`/`rpm2cpio` needed:
   - `intel-driver-compiler-npu` → `libopenvino_intel_npu_compiler.so`,
     `libopenvino_intel_npu_compiler_loader.so`
   - `intel-level-zero-npu` → `libze_intel_npu.so.1.35.0`
4. Backed up the rpm-owned files first (`/root/npu-driver-1.32-backup/`),
   then manually installed:
   ```
   install -m 0755 libze_intel_npu.so.1.35.0 /usr/lib64/
   ln -sf libze_intel_npu.so.1.35.0 /usr/lib64/libze_intel_npu.so.1
   install -m 0755 libopenvino_intel_npu_compiler.so /usr/lib64/
   install -m 0755 libopenvino_intel_npu_compiler_loader.so /usr/lib64/
   ldconfig
   ```
   Rollback path: `sudo dnf reinstall intel-npu-driver` restores the
   rpm-tracked files (`libze_intel_npu.so*`); the two compiler libraries have
   no rpm-tracked counterpart to roll back to since Fedora never shipped them.
5. Result confirmed immediately — both of AuthFace's real production ONNX
   models compiled and ran on `NPU` with no further changes:

   | Model | Purpose | Input shape | Compile time | Steady-state inference |
   |---|---|---|---|---|
   | `w600k_mbf.onnx` (MobileFaceNet) | Face recognition | `1×3×112×112` | 0.44s (Python) / ~58ms (Rust) | ~2ms avg (1.67–3.02ms range, 20 runs) |
   | `version-slim-320.onnx` | Face detection | `1×3×240×320` | 0.15s (Python) / ~17ms (Rust) | ~0.6ms avg (0.53–0.72ms range, 20 runs) |

   (The Python vs. Rust compile-time gap is the vendored-toolkit cold venv vs.
   the app's own warm cache path — not re-measured apples-to-apples, noted
   honestly rather than smoothed over.)

Unlike biopass's doc, **detection compiled and ran on NPU without issue**
here — `version-slim-320.onnx` has no dynamic-reshape-inside-the-graph problem
the way biopass's YOLO export did. Static input shape (`1×3×240×320`, single
image, no batch dimension issue) from the start.

## Rust integration

[`openvino-rs`](https://github.com/intel/openvino-rs) (Intel's own maintained
crate, `openvino = "0.11"`, released 2026-05-06) — high-level bindings over
the C API, dynamic-linking feature (default), no `bindgen`/`libclang` needed
at build time since FFI bindings ship pre-generated.

Built against the vendored C++ toolkit tarball
(`openvino_toolkit_rhel8_2026.2.1.21919.ede283a88e3_x86_64.tgz`, same
`storage.openvinotoolkit.org` source as biopass's doc — GitHub releases don't
host the C++ archives, only Python wheels and release notes), installed under
`~/.local/opt/openvino`, sourced via its `setupvars.sh` for
`INTEL_OPENVINO_DIR`/`PKG_CONFIG_PATH`/`LD_LIBRARY_PATH` at both build and run
time — `openvino-sys`'s build script (`openvino-finder`) locates the install
via those variables.

Feature-gated identically to biopass's `BIOPASS_USE_OPENVINO` pattern: an
opt-in Cargo feature (`npu`), default off, existing CPU backend (`tract-onnx`)
unaffected unless explicitly built with `--features npu` and configured with
`backend = "openvino"` / `npu_device = "NPU"` (env: `FACE_AUTH_BACKEND`,
`FACE_AUTH_NPU_DEVICE`).

## For a bug report

**Fedora's `intel-npu-driver` package** is the most actionable target:
1. It's stuck at `1.32.0` while upstream `linux-npu-driver` has moved to
   `1.35.0` (needed to pair with OpenVINO 2026.2's NPU plugin protocol).
2. Independent of version, the package has **never** shipped
   `libopenvino_intel_npu_compiler.so` / `libopenvino_intel_npu_compiler_loader.so`
   — without them NPU compilation cannot work at all, at any driver version.
   This looks like a packaging omission, not a version-lag issue.

Reproduction is exactly the steps in [Software stack](#software-stack-that-actually-got-it-working)
above; the `ZE_RESULT_ERROR_UNSUPPORTED_FEATURE` / `0x78000003` error is the
sharpest reproducible symptom to lead with.

**Upstream `intel/linux-npu-driver`**: only publishing Ubuntu `.deb`s for
`v1.35.0`, no RPM. Worth an issue asking about RPM/Fedora COPR distribution,
though this is a lower-priority ask than the Fedora packaging gap above since
the files are extractable from the `.deb` regardless.
