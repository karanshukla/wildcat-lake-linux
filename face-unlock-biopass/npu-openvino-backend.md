# Optional OpenVINO NPU/GPU inference backend (issue #151)

**Fixes:** [TickLabVN/biopass#151](https://github.com/TickLabVN/biopass/issues/151) — NPU/GPU acceleration
**Diff:** `auth/Dependencies.cmake` (+38), `auth/face/CMakeLists.txt` (+5),
`auth/face/common/onnx_session.{cc,h}` (+159/+48), `auth/face/detection/face_detection.cc` (+5)

> **Status (2026-07-25): reverted from the live daemon, do not deploy.**
> The NPU/GPU inference itself works — recognition and anti-spoofing both
> compiled and ran correctly on the NPU with real speedups (numbers below).
> But installing this into the actual resident `biopassd` process crashed it
> with heap corruption on the very first authentication attempt, which in
> turn briefly took down `sudo` system-wide (see
> [Critical: crashes the resident daemon](#critical-crashes-the-resident-daemon-do-not-deploy)
> below). The machine this was tested on has since been rolled back to the
> pre-OpenVINO binary (commit `b1f3cc2`). The code stays on the fork branch,
> gated behind `BIOPASS_USE_OPENVINO=OFF` by default, specifically so this
> record and the branch can be picked back up later without redoing the
> OpenVINO vendoring/reshape/device-probe work from scratch.

## What this adds

An opt-in build flag, `BIOPASS_USE_OPENVINO` (default `OFF`), that lets
`OnnxSession` — the shared inference wrapper used by detection, recognition, and
anti-spoofing — probe Intel NPU/GPU via OpenVINO instead of always running on ONNX
Runtime CPU. The public interface (constructor + `run()`, returning `Ort::Value`)
is unchanged regardless of backend, so calling code never knows or cares which one
actually ran.

Probe order at construction time: **NPU, then GPU**, falling back to the existing
ONNX Runtime CPU path if neither compiles the model successfully. Override via the
`BIOPASS_INFERENCE_DEVICE` env var (`AUTO` | `NPU` | `GPU` | `CPU`) — `CPU` skips
the OpenVINO probe entirely.

## Why OpenVINO is vendored, not system-packaged

Fedora 44 ships OpenVINO `2025.1.0`, whose NPU plugin speaks an older
graph-extension protocol than current Intel NPU drivers report —
`compile_model()` fails outright on newer chips against it. The build instead
`FetchContent`-vendors a pinned upstream release (`2026.2.1.21919.ede283a88e3`),
the same pattern already used for ONNX Runtime, so the NPU backend doesn't
silently change behavior out from under a build as distro packaging catches up.

## Why detection (YOLO) is excluded

`FaceDetection` constructs its `OnnxSession` with `allow_openvino=false`
unconditionally. Its ONNX export has a dynamic reshape buried inside the graph
(not just the input batch dimension, which the NPU-side fix below handles) that
crashed the NPU compiler with a hard `abort()` during development — not a
throwable exception, so no amount of try/catch in `OnnxSession` can protect
against it. Detection stays CPU-only until that's root-caused on the model side.
Recognition and anti-spoofing are unaffected and do attempt NPU/GPU.

## Static-shape handling

NPU/GPU compilers require fully static shapes. Every model in this codebase is
exported with a dynamic (symbolic) batch dimension, which `compile_model()`
otherwise rejects (observed NPU error: "missing upper bound for one or more
nodes"). Since every call site always runs single-image inference, the code
reshapes each model's inputs to pin `batch=1` before compiling — exact, not an
approximation, given the actual call pattern.

## Compile cache

NPU/GPU model compilation is far more expensive than an ONNX Runtime CPU session
load. Anti-spoofing rebuilds its `OnnxSession` on every single auth attempt
(rather than caching it for the daemon's lifetime), so without a persistent
compile cache this path would pay full recompilation cost on every login — likely
net *slower* than just using CPU. `ov::cache_dir` (pointed at
`/var/cache/biopassd/openvino`) makes `compile_model()` reuse a compiled blob
keyed by model+device+config after the first run, even across process restarts.

One `ov::Core` per process (function-local static) — device/plugin enumeration is
expensive and would otherwise repeat per `OnnxSession` (detection, recognition,
anti-spoofing each construct their own).

## Measured results (isolated test binaries, not the daemon — see crash section below)

CPU numbers are ONNX Runtime CPU / OpenVINO CPU plugin, whichever was tested for
that row; NPU numbers are the vendored OpenVINO 2026.2.1 NPU plugin. Averaged over
10 runs after a warm-up call, same host (Dell XPS 13, Wildcat Lake NPU).

| Model | CPU | NPU | Note |
|---|---|---|---|
| Detection (YOLOv8n-face, 640×640) | 28.4ms | not attempted | dynamic reshape inside the graph (not just batch) hard-`abort()`s the NPU compiler — see below |
| Recognition (EdgeFace, 112×112) | 4.2ms | 2.9ms | works, ~31% faster |
| Anti-spoof (MobileNetV3, 128×128) | 1.3ms | 0.65ms | works, ~49% faster |

Detection dominates total inference time (~84% of the ~34ms combined CPU total),
so it's also the model that would benefit most from NPU offload in principle — but
it's the one that doesn't compile at all (see below), and even a generous 40%
speedup on it would only save ~11ms against a warm-auth total that's dominated by
camera power-cycle (~1.1s) and RGB auto-exposure convergence (~872ms), not
inference. NPU/GPU offload here is a power-efficiency play for an always-resident
daemon, not a latency one — consistent with OpenVINO's own guidance that GPU/NPU
gives negligible wins for single-frame (non-batched) inference.

### Detection's crash is a different bug than the batch-dim one above

`shape_check` on the exported graphs showed detection's *declared input* is
already fully static (`[1,3,640,640]`), unlike recognition/anti-spoof's dynamic
batch dim (`[?,3,112,112]`). The `abort()` traced to a `Reshape`/shape-computation
node buried *inside* the graph (likely NMS-related), not the input boundary — so
the `reshape(batch=1)` fix that unblocked the other two models doesn't apply here.
Confirmed via manual reproduction with a disposable standalone OpenVINO program
(bypassing all biopass code) before concluding this, specifically so a second
crash wouldn't happen inside anything that could take down the real daemon.

## Verifying it's actually engaging the NPU/GPU

Per-call timing is logged at debug level:

```
journalctl -u biopassd -f
```

watch for:

```
OnnxSession: OpenVINO 'NPU' inference took 12.34ms
```

This is deliberately logged per-call (not just at startup) because compiling
successfully at startup doesn't prove the device is actually doing inference work
on every subsequent call.

## Software stack that actually got the NPU working (for next time)

None of this is packaged together anywhere; it took a fair amount of digging to
assemble on Fedora 44:

1. Kernel driver (`intel_vpu`/`ivpu`, in-tree, mainline since ~6.8) — already
   present, `/dev/accel/accel0` existed with firmware loaded (`vpu_50xx_v1.bin`)
   before touching anything.
2. `sudo dnf install oneapi-level-zero` — the generic Level Zero loader
   (`libze_loader.so.1`). Without it: `Cannot load library 'libze_loader.so.1'`.
3. `sudo dnf install intel-npu-driver intel-npu-compiler` — the actual
   vendor NPU userspace driver + on-device compiler. Without it: Level Zero
   loads but `zeInit` fails with `ZE_RESULT_ERROR_UNINITIALIZED`.
4. Fedora's own `openvino`/`openvino-devel`/`openvino-plugins` packages
   (`2025.1.0`) are **not enough** — their NPU plugin speaks graph-extension
   protocol `1.10`, while the driver above reports `1.16`; `compile_model()`
   fails outright (`Missing upper bound for one or more nodes` — misleading
   error text for what's actually a protocol mismatch). Fix: vendor a much
   newer OpenVINO release directly from Intel's own S3 bucket
   (`storage.openvinotoolkit.org`, not GitHub releases — those don't host the
   C++ tarballs, only Python wheels and release notes) rather than waiting on
   distro packaging. Used `2026.2.1.21919.ede283a88e3` (~112MB), which does not
   ship a `plugins.xml` — modern OpenVINO auto-discovers plugins by scanning
   next to `libopenvino.so` itself, so no extra manifest wiring was needed.
5. Downgrading `intel-npu-driver` back toward the compiler's older expected
   protocol version was the *wrong* direction — the older driver (`1.16.0`)
   couldn't even `zeInit` against this specific (very new) NPU/firmware
   combination. The newer driver (`1.32.0`) was necessary for the hardware,
   and the actual fix was the OpenVINO version bump above, not a driver
   downgrade.

## Critical: crashes the resident daemon, do not deploy

This is the reason this branch is not installed anywhere despite the NPU
numbers above being real and reproducible in isolation.

**What happened:** installed the OpenVINO-enabled build into the actual
`biopassd` systemd user service. On the very first real authentication attempt
(sent directly over the daemon's Unix socket, bypassing PAM/sudo for safety),
`biopassd` crashed:

```
malloc(): invalid size (unsorted)
```

— a heap-corruption abort, inside a background worker thread, while
constructing the `FaceRecognition` model's inference session for the first
time in that process. `systemd-coredump` caught it; the process restarted
(`Restart=on-failure`), and — because systemd socket-activation accepts a
connection immediately even before the backing service is actually running —
a second, unrelated bug (no read timeout on that connection) turned a
crash-loop into `sudo` hanging system-wide, which needed a hard reboot.

**Root cause, as far as it's understood:** `BIOPASS_INFERENCE_DEVICE=CPU` was
set (forcing `initOpenVino()` to never run, i.e. the OpenVINO API is never
actually called) and the daemon **still crashed the same way**, confirming
this isn't about NPU compilation at all. `BIOPASS_USE_OPENVINO=ON` links
OpenVINO — and its bundled Intel TBB allocator (`libtbbmalloc.so.2`, visible
in every crash's loaded-module list) — into the process **unconditionally at
build time**, regardless of which device gets used at runtime. Just having
that library loaded alongside `biopassd`'s existing threads (libcamera's own
event-loop thread, ONNX Runtime's own internal thread pool) was enough to
corrupt the process heap the first time anything allocated through a
now-shared/contended allocator path.

**Why this wasn't caught earlier:** it never reproduced in either of two
disposable, single-purpose test programs built against the exact same
vendored OpenVINO and the exact same models (that's how the NPU numbers above
were measured safely). It only showed up inside the real, multi-threaded,
long-running daemon process — the class of bug that hides from targeted
testing and only bites in production. Not root-caused further than this;
next step would be running the actual daemon (not a standalone repro) under
`valgrind`/ASan to catch the allocator collision directly, since it isn't
reproducible any other way found so far.

**What was done about it:** immediately reverted `/usr/bin/biopassd`,
`/usr/bin/biopass-helper`, `/lib64/security/libbiopass_pam.so`, and
`libbiopass_{det,reg,as}.so` to the byte-identical pre-OpenVINO build
(commit `b1f3cc2`, verified via `md5sum`) — the same binary that had the
resident-daemon latency work (3.0s → 1.86s warm auth) already in it, so that
optimization was never at risk, only tonight's new NPU addition. The fork
branch keeps the code (`BIOPASS_USE_OPENVINO` defaults `OFF`, so a normal
build/clone is unaffected), with an explicit crash warning added to
`Dependencies.cmake` and `onnx_session.h` so nobody flips the flag on for a
resident-daemon deployment without reading this first.

## For a bug report / upstream PR

**Not ready to propose upstream yet** — unlike the resident-daemon (#152) work,
this one has a confirmed crash in the exact deployment model (a long-running
daemon) that upstream would actually run it in. The fallback discipline
(`BIOPASS_USE_OPENVINO=OFF` by default, graceful device-probe fallback within
`OnnxSession`) means it's *safe to have on a branch* — nobody's build breaks by
building normally — but it is **not** safe to recommend anyone actually enable
it until the TBB/threading interaction above is root-caused.
