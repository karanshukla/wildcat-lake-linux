# Optional OpenVINO NPU/GPU inference backend (issue #151)

**Fixes:** [TickLabVN/biopass#151](https://github.com/TickLabVN/biopass/issues/151) — NPU/GPU acceleration
**Diff:** `auth/Dependencies.cmake` (+38), `auth/face/CMakeLists.txt` (+5),
`auth/face/common/onnx_session.{cc,h}` (+159/+48), `auth/face/detection/face_detection.cc` (+5)

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

## Known blockers on Wildcat Lake specifically (driver maturity, not code)

- Intel NPU driver `v1.35.0-rc1` describes itself as the "first public preview of
  Wildcat Lake firmware support" as of late July 2026 — this is genuinely
  early-silicon territory, not a packaging gap.
- OpenVINO 2026.1 supports NPU 5020 in principle, but no prebuilt C++ ONNX Runtime
  with an OpenVINO execution provider exists yet for this combination; building
  from source is the only path today if you want it via ONNX Runtime's own EP
  layer instead of calling OpenVINO directly (this branch calls OpenVINO
  directly, sidestepping that gap).
- Practically, NPU work on current Linux driver maturity is most viable for
  smaller/simpler models (face detection/recognition-scale), not LLM-scale
  inference — fixed/static shapes at compile time are a fundamental NPU
  constraint (see above), and 7B-scale LLM inference is comfortably outperformed
  by a discrete GPU regardless.

## For a bug report / upstream PR

This is additive and opt-in (`BIOPASS_USE_OPENVINO=OFF` by default) with a clean
fallback to the existing, proven ONNX Runtime CPU path at every failure point —
missing device, driver too old to compile, unexpected exception. That fallback
discipline is the main thing worth calling out to maintainers: this should be safe
to merge even before NPU driver support is mature across the fleet of hardware
biopass targets, since it never changes CPU-path behavior for anyone who doesn't
opt in or whose hardware doesn't have a working NPU/GPU OpenVINO plugin.
