# Face unlock — biopass fork

**Status (2026-07-29): superseded.** Moved to
[pfalkingham/AuthFace](https://github.com/pfalkingham/authFace) for face unlock
going forward; this fork is no longer being actively developed. Left in place
as the investigation record for the cold-start and NPU work below — still
relevant background if AuthFace hits similar issues.

**Upstream project:** [TickLabVN/biopass](https://github.com/TickLabVN/biopass)
**Fork/branch:** [karanshukla/biopass @ `feat/resident-biopassd`](https://github.com/karanshukla/biopass/compare/main...karanshukla:biopass:feat/resident-biopassd)
**Filed upstream issues:** [#151](https://github.com/TickLabVN/biopass/issues/151) (NPU/GPU acceleration), [#152](https://github.com/TickLabVN/biopass/issues/152) (cold-start latency)

biopass is a Windows-Hello-style face/fingerprint auth stack for Linux (PAM module +
helper binary + camera/ONNX inference). Both issues below trace back to the same
underlying complaint: every PAM authentication attempt (login, unlock, `sudo`) forks
a fresh helper process that rebuilds its `AuthManager` from scratch — reopening the
camera and reloading every ONNX model — so each attempt eats the full cold-start
cost of model load + camera acquire, every single time.

This fork branch fixes that in two independent ways:

1. **[biopassd-resident-daemon.md](biopassd-resident-daemon.md)** — issue #152. A
   resident, idle-exiting user daemon keeps a warm `AuthManager` between PAM calls,
   plus a camera-capture refactor that separates the expensive "acquire/configure/
   allocate buffers" step (safe to keep resident) from actual streaming (only
   powered during a real capture, so the sensor/IR LED indicator isn't stuck on).
2. **[npu-openvino-backend.md](npu-openvino-backend.md)** — issue #151. An optional
   OpenVINO backend that offloads inference to the Intel NPU/GPU when available,
   falling back to the existing ONNX Runtime CPU path otherwise.

## Status

| Piece | State |
|---|---|
| Resident daemon (biopassd) | Implemented, on fork branch, not yet upstreamed as a PR |
| Camera capture refactor (stream on-demand) | Implemented, on fork branch |
| PAM module directory auto-detection | Implemented, on fork branch (portability fix, distro-agnostic) |
| ONNX Runtime intra-op thread tuning | Implemented, on fork branch |
| OpenVINO NPU/GPU backend | Implemented (opt-in build flag), on fork branch |
| NPU acceleration actually engaging on Wildcat Lake | Blocked — see [npu-openvino-backend.md](npu-openvino-backend.md) for driver-maturity caveats |

## Superseded by AuthFace

As of 2026-07-29, face unlock on this machine uses
[pfalkingham/AuthFace](https://github.com/pfalkingham/authFace) instead. No
investigation docs exist for it yet under this repo — this section will be
filled in (or a sibling `face-unlock-authface/` directory added) once there's
something concrete to document.

## Machine context

Dell XPS 13 DX13260, Wildcat Lake/Panther Lake A0 silicon, Fedora 44 KDE. NPU
acceleration work here is happening well ahead of mature vendor driver support —
see the caveats in each doc before assuming these numbers generalize to other
hardware.
