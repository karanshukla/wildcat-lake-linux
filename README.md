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
| Display | VRR reports capable+enabled but panel refresh never modulates (pinned 120Hz idle and during video) | Unresolved, confounded by a known KWin bug, root cause not isolated | [display/vrr-not-engaging.md](display/vrr-not-engaging.md) |
| Power | Forcing S3 (`deep`) sleep hangs unresumably (firmware, not kernel) | Reverted to `s2idle` default | [power/s3-deep-sleep-hang.md](power/s3-deep-sleep-hang.md) |
| Power | Rapid lid-cycling on `s2idle` resume causes an unresumable hang | Mitigated (behavioral + diagnostics), not fixed | [power/s2idle-rapid-resume-hang.md](power/s2idle-rapid-resume-hang.md) |
| Power | Platform never enters any S0ix substate during `s2idle` (0 residency) | Partially fixed (PCI runtime-PM udev rule); root cause of the remaining gap confirmed as Intel ME (CSE) firmware, independent of the host `mei` driver; needs a Dell/Intel firmware update | [power/s0ix-never-entered.md](power/s0ix-never-entered.md) |
| Camera | kamoso negotiates raw YUYV @ 1080p, capped at 5fps (Chrome unaffected) | Workaround (avoid kamoso, or cap its resolution); app itself unpatched | [camera/kamoso-raw-format-5fps.md](camera/kamoso-raw-format-5fps.md) |
| Audio | Tinny speakers — zeroed CS42L43 EQ coefficients | Worked around (PipeWire software EQ) | [audio/cs42l43-eq-fix.md](audio/cs42l43-eq-fix.md) |
| Audio | Hot/noisy mic — UCM ships no default capture gain (boots at hardware max) | Fixed (persisted ALSA state) | [audio/cs42l43-mic-gain-fix.md](audio/cs42l43-mic-gain-fix.md) |
| Audio | LMMS crackles playing note sequences (single notes fine); Akai MPK mini play MIDI setup | Fix applied (buffer bump, PipeWire rate config, RT scheduling grant), verification pending next login | [audio/lmms-crackle-and-midi.md](audio/lmms-crackle-and-midi.md) |
| Audio | Two of four speakers (CS35L56 woofer amps) never get audio routed — tweeters only | Unresolved, root cause confirmed (ACPI under-reports SmartAmp count, no backend DAI for 2nd amp); needs kernel machine-driver quirk or Dell ACPI fix | [known-issues.md](known-issues.md) |
| Input | Keyboard remapping (Mac-style Alt-as-Cmd) | Active (keyd) | [input/keyd-mac-remap.md](input/keyd-mac-remap.md) |
| Input | Plasma 6 Wayland touchpad scroll-speed regression | Worked around | [input/touchpad-scroll-fix.md](input/touchpad-scroll-fix.md) |
| Input | Claude Desktop quick-entry via Copilot-key remap | Active (keyd) | [input/claude-desktop-quick-entry.md](input/claude-desktop-quick-entry.md) |
| Input | Tap-to-click misfires/cursor jumps while typing | Unresolved, root cause isolated (keyd breaks touchpad DWT) | [known-issues.md](known-issues.md) |
| Face unlock | biopass cold-start latency (every auth attempt reloads models) | Superseded — moved to [AuthFace](https://github.com/pfalkingham/authFace); fork left as investigation record | [face-unlock-biopass/biopassd-resident-daemon.md](face-unlock-biopass/biopassd-resident-daemon.md) |
| Face unlock | NPU/GPU acceleration for biopass inference | Superseded — moved to [AuthFace](https://github.com/pfalkingham/authFace); fork left as investigation record | [face-unlock-biopass/npu-openvino-backend.md](face-unlock-biopass/npu-openvino-backend.md) |
| Face unlock | AuthFace NPU inference backend (OpenVINO) | Working, merged to `main` — required hand-patching the NPU driver (Fedora's package is both too old and missing the compiler libs); real detector box-decode/normalization bug also fixed 2026-07-30 | [face-unlock-authface/npu-openvino-backend.md](face-unlock-authface/npu-openvino-backend.md) |
| Face unlock | AuthFace shipped with no anti-spoofing | Three layers shipped: motion-liveness gate, screen-spoofing confirmed blocked by IR-illuminator physics (not software), and physical-USB camera pinning (frame-injection defense); printed-photo resistance still open | [face-unlock-authface/liveness-and-antispoof.md](face-unlock-authface/liveness-and-antispoof.md) |
| Face unlock | KWallet doesn't auto-unlock after login (reproduced with face-auth disabled too) | Unresolved, accepted — confirmed known upstream KDE bug (kwalletd D-Bus-activation race vs. PAM credential handoff, not biometric auth or local config), no local fix pursued | [face-unlock-authface/kwallet-not-auto-unlocking.md](face-unlock-authface/kwallet-not-auto-unlocking.md) |
| NPU (general) | Driver/tooling maturity for NPU workloads | Unresolved, months-out | [known-issues.md](known-issues.md) |
| Disk | TPM2-sealed LUKS auto-unlock | Active, working | [disk-encryption/tpm2-luks.md](disk-encryption/tpm2-luks.md) |
| Shell | No tab-completion in Ghostty for unpackaged CLI tools (e.g. `gaze`) | Worked around (stock `bash-completion` + custom scripts); predictive ghost-text (`ble.sh`) tried, reverted — unstable with raw-mode TUI apps | [shell/bash-completion-setup.md](shell/bash-completion-setup.md) |

See [known-issues.md](known-issues.md) for everything still open.

## Layout

```
display/                  PSR/DSB display bug and fix; VRR not engaging
camera/                    kamoso raw-format 5fps issue
audio/                     CS42L43 speaker EQ fix, mic gain fix, LMMS crackle/MIDI setup
input/                     keyd remap, touchpad scroll fix, keyd/DWT interaction
desktop/                   raw KDE panel/widget config snapshot (restore point, not a write-up)
face-unlock-biopass/       biopass fork: resident daemon + NPU backend (superseded by AuthFace)
face-unlock-authface/      AuthFace fork: NPU backend, motion liveness gate, screen-spoof physics finding
disk-encryption/           TPM2 LUKS auto-unlock
power/                     S3 deep-sleep hang (reverted to s2idle); s2idle rapid-resume hang;
                           S0ix substates never entered
shell/                     bash-completion setup for gaze/claude/bat; ble.sh tried & reverted
known-issues.md            everything still open/unresolved
```

Each doc follows roughly the same shape: symptom, root cause (with evidence),
fix/workaround, trade-offs, and a "for a bug report" section summarizing what a
maintainer would need to reproduce or act on it.

## Related

- Face unlock (current): [pfalkingham/AuthFace](https://github.com/pfalkingham/authFace), fork with NPU backend + liveness: [karanshukla/vinoAuthFace @ npu-openvino-liveness](https://github.com/karanshukla/vinoAuthFace/tree/npu-openvino-liveness)
- biopass fork (superseded, kept as investigation record for cold-start + NPU work): [karanshukla/biopass @ feat/resident-biopassd](https://github.com/karanshukla/biopass/compare/main...karanshukla:biopass:feat/resident-biopassd)
- Upstream biopass issues filed: [#151](https://github.com/TickLabVN/biopass/issues/151) (NPU/GPU), [#152](https://github.com/TickLabVN/biopass/issues/152) (cold-start latency)
