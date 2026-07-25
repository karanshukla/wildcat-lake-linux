# wildcat-lake-linux

Discoveries, fixes, and customizations from running Fedora Linux on a Dell XPS 13
(Wildcat Lake). Intended as a log/reference — copy what's useful, or use it as a
starting point for a bug report to Intel/Dell/kernel/KDE maintainers.

## Hardware

- **Model:** Dell XPS 13, DX13260
- **Silicon:** Wildcat Lake / Panther Lake, **stepping A0** (GPU device ID `fd80`)
- **OS:** Fedora 44, KDE Plasma 6, Wayland
- **Audio codec:** CS42L43

This is genuinely early-silicon hardware — several issues below are structural
driver-maturity gaps rather than configuration problems, and the marketing support
claims for this hardware diverge meaningfully from the actual Linux support
timeline as of writing (2026-07-25).

## Status summary

| Area | Issue | Status | Doc |
|---|---|---|---|
| Display | PSR2/DSB deadlock causing glitches under GPU load | Worked around (kernel boot args) | [display/psr-dsb-deadlock.md](display/psr-dsb-deadlock.md) |
| Display | VRR/adaptive sync crash-on-disable in `xe` driver | Unresolved, upstream WIP | [known-issues.md](known-issues.md) |
| Audio | Tinny speakers — zeroed CS42L43 EQ coefficients | Worked around (PipeWire software EQ) | [audio/cs42l43-eq-fix.md](audio/cs42l43-eq-fix.md) |
| Input | Keyboard remapping (Mac-style Alt-as-Cmd) | Active (keyd) | [input/keyd-mac-remap.md](input/keyd-mac-remap.md) |
| Input | Plasma 6 Wayland touchpad scroll-speed regression | Worked around | [input/touchpad-scroll-fix.md](input/touchpad-scroll-fix.md) |
| Face unlock | biopass cold-start latency (every auth attempt reloads models) | Fixed on fork branch (resident daemon) | [face-unlock-biopass/biopassd-resident-daemon.md](face-unlock-biopass/biopassd-resident-daemon.md) |
| Face unlock | NPU/GPU acceleration for biopass inference | Implemented on fork branch, NPU itself blocked by driver maturity | [face-unlock-biopass/npu-openvino-backend.md](face-unlock-biopass/npu-openvino-backend.md) |
| NPU (general) | Driver/tooling maturity for NPU workloads | Unresolved, months-out | [known-issues.md](known-issues.md) |
| Disk | TPM2-sealed LUKS auto-unlock | Active, working | [disk-encryption/tpm2-luks.md](disk-encryption/tpm2-luks.md) |

See [known-issues.md](known-issues.md) for everything still open.

## Layout

```
display/                  PSR/DSB display bug and fix
audio/                     CS42L43 speaker EQ fix
input/                     keyd remap, touchpad scroll fix
face-unlock-biopass/       biopass fork: resident daemon + NPU backend
disk-encryption/           TPM2 LUKS auto-unlock
known-issues.md            everything still open/unresolved
```

Each doc follows roughly the same shape: symptom, root cause (with evidence),
fix/workaround, trade-offs, and a "for a bug report" section summarizing what a
maintainer would need to reproduce or act on it.

## Related

- biopass fork (face-unlock cold-start + NPU work): [karanshukla/biopass @ feat/resident-biopassd](https://github.com/karanshukla/biopass/compare/main...karanshukla:biopass:feat/resident-biopassd)
- Upstream biopass issues filed: [#151](https://github.com/TickLabVN/biopass/issues/151) (NPU/GPU), [#152](https://github.com/TickLabVN/biopass/issues/152) (cold-start latency)
