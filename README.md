# wildcat-lake-linux

Discoveries, fixes, and customizations from running Fedora Linux on a Dell XPS 13
(Wildcat Lake). Intended as a log/reference — copy what's useful, or use it as a
starting point for a bug report to Intel/Dell/kernel/KDE maintainers.

## Hardware

- **Model:** Dell XPS 13, DX13260
- **Silicon:** Wildcat Lake, **stepping A0** (GPU device ID `fd80`) — confirmed via
  `lscpu` (`Intel(R) Core(TM) 5 320`, Core Series 3 branding) and the kernel's own
  `sof_sdw` PCI SSID quirk table, which labels this exact SKU (`0x0e53`) "Dell XPS
  WCL" as distinct from a sibling `0x0e54` "Dell XPS PTL" (Panther Lake) SKU; see
  [audio/cs35l56-sidecar-amp-quirk.md](audio/cs35l56-sidecar-amp-quirk.md#upstream-status)
- **OS:** Fedora 44, KDE Plasma 6, Wayland
- **Audio codec:** CS42L43

This is genuinely early-silicon hardware — several issues below are structural
driver-maturity gaps rather than configuration problems, and the marketing support
claims for this hardware diverge meaningfully from the actual Linux support
timeline as of writing (2026-07-25).

## Status summary

| Area | Issue | Status | Doc |
|---|---|---|---|
| Display | PSR2/DSB deadlock causing glitches under GPU load | Worked around (kernel boot args), narrowed 2026-08-05 from `xe.enable_psr=0` to `xe.enable_psr=1` (PSR1 kept, PSR2 selective fetch still off) because disabling PSR entirely was what enabled LOBF. Verified: 0 DSB errors under load, LOBF now disabled, DC5/DC6 power-gating restored | [display/psr-dsb-deadlock.md](display/psr-dsb-deadlock.md) |
| Display | VRR/adaptive sync crash-on-disable in `xe` driver | Unresolved, upstream WIP | [known-issues.md](known-issues.md) |
| Display | VRR reports capable+enabled but panel refresh never modulates (pinned 120Hz idle and during video) | Unresolved, confounded by a known KWin bug, root cause not isolated. Policy changed `Always` → `Automatic` 2026-08-05 to test a LOBF link (hypothesis not supported) | [display/vrr-not-engaging.md](display/vrr-not-engaging.md) |
| Power | Forcing S3 (`deep`) sleep hangs unresumably (firmware, not kernel) | Reverted to `s2idle` default | [power/s3-deep-sleep-hang.md](power/s3-deep-sleep-hang.md) |
| Power | Rapid lid-cycling on `s2idle` resume causes an unresumable hang (broader: any eDP panel power-cycle can wedge, lid and suspend not required) | Mitigated (behavioral + diagnostics), not fixed. Reproducible on demand as of 2026-08-05 (`power/reproduce-panel-wedge.sh`). Leading theory now LOBF/aux-less ALPM, which the PSR boot args never disabled and in fact enabled. Candidate fix (`xe.enable_psr=1`) applied and confirmed to disable LOBF; wedge rate not yet re-measured, and kernel 7.1.6 landed in the same reboot with a panel-power fix (`drm/i915/mtl+: Enable PPS before PLL`), so attribution is ambiguous | [power/s2idle-rapid-resume-hang.md](power/s2idle-rapid-resume-hang.md) |
| Power | Platform never enters any S0ix substate during `s2idle` (0 residency) | Partially fixed (PCI runtime-PM udev rule); root cause of the remaining gap confirmed as Intel ME (CSE) firmware, independent of the host `mei` driver; re-confirmed 2026-08-05 on kernel 7.1.6 with the display engine power-gating (candidate co-blocker ruled out); needs a Dell/Intel firmware update | [power/s0ix-never-entered.md](power/s0ix-never-entered.md) |
| Power | `intel_idle` has no Wildcat Lake (`0xD5`) entry, falls back to ACPI `_CST` (no C1E, C10 advertised more conservatively) | Open. Reported to linux-pm 2026-08-05 and answered same day: the omission is **deliberate**, not lag — reusing the Panther Lake values was considered and rejected over possible firmware differences, so adding `0xD5` needs `wult` measurement on real WCL silicon. Not the S0ix blocker — C10 is entered normally | [power/intel-idle-no-wildcat-lake-entry.md](power/intel-idle-no-wildcat-lake-entry.md) |
| Power | Battery charge-limit sysfs attributes exist but every read/write fails (ENXIO/EIO) | Root cause confirmed (BIOS `Battery Charge Configuration` = `ExpressCharge™`, not `Custom`); accepted as-is, not pursued | [power/battery-charge-limit.md](power/battery-charge-limit.md) |
| Power | Power button bypasses KDE's "show logout screen" setting, powers off directly | Unresolved, not root-caused, one occurrence so far | [power/powerkey-bypasses-kde-poweroff.md](power/powerkey-bypasses-kde-poweroff.md) |
| Camera | kamoso negotiates raw YUYV @ 1080p, capped at 5fps (Chrome unaffected) | Workaround (avoid kamoso, or cap its resolution); app itself unpatched | [camera/kamoso-raw-format-5fps.md](camera/kamoso-raw-format-5fps.md) |
| Audio | Tinny speakers — zeroed CS42L43 EQ coefficients | Worked around (PipeWire software EQ) | [audio/cs42l43-eq-fix.md](audio/cs42l43-eq-fix.md) |
| Audio | Hot/noisy mic — UCM ships no default capture gain (boots at hardware max) | Fixed (persisted ALSA state) | [audio/cs42l43-mic-gain-fix.md](audio/cs42l43-mic-gain-fix.md) |
| Audio | LMMS crackles playing note sequences (single notes fine); Akai MPK mini play MIDI setup | Fix applied (buffer bump, PipeWire rate config, RT scheduling grant), verification pending next login | [audio/lmms-crackle-and-midi.md](audio/lmms-crackle-and-midi.md) |
| Audio | Two of four speakers (CS35L56 sidecar amps) never got audio routed — tweeters only | Fixed locally (signed kernel patch, DKMS + MOK enrollment) running the actual upstream fix (Cirrus Logic, merged 2026-07-16, v7.2-rc3), confirmed audibly on a clean cold boot; local patch retires once Fedora ships that kernel | [audio/cs35l56-sidecar-amp-quirk.md](audio/cs35l56-sidecar-amp-quirk.md) |
| Input | Keyboard remapping (Mac-style Alt-as-Cmd) | Active (keyd) | [input/keyd-mac-remap.md](input/keyd-mac-remap.md) |
| Input | Plasma 6 Wayland touchpad scroll-speed regression | Worked around | [input/touchpad-scroll-fix.md](input/touchpad-scroll-fix.md) |
| Input | Claude Desktop quick-entry via Copilot-key remap | Active (keyd) | [input/claude-desktop-quick-entry.md](input/claude-desktop-quick-entry.md) |
| Input | Tap-to-click misfires/cursor jumps while typing | Unresolved, root cause isolated (keyd breaks touchpad DWT) | [known-issues.md](known-issues.md) |
| Input | F5/dictation-key speech feature (NPU Whisper) — pivoted to live captioning | In progress — feasibility spike confirmed working (NPU inference, ~1.19s/30s window, ~0.2s perceived latency via streaming); live-captioning implementation not built yet | [input/f5-voice-typing.md](input/f5-voice-typing.md) |
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
audio/                     CS42L43 speaker EQ fix, mic gain fix, LMMS crackle/MIDI setup,
                           CS35L56 sidecar-amp DMI quirk (missing 2 of 4 speakers)
input/                     keyd remap, touchpad scroll fix, keyd/DWT interaction
desktop/                   raw KDE panel/widget config snapshot (restore point, not a write-up)
face-unlock-biopass/       biopass fork: resident daemon + NPU backend (superseded by AuthFace)
face-unlock-authface/      AuthFace fork: NPU backend, motion liveness gate, screen-spoof physics finding
disk-encryption/           TPM2 LUKS auto-unlock
power/                     S3 deep-sleep hang (reverted to s2idle); s2idle rapid-resume hang
                           (+ reproduce-panel-wedge.sh, on-demand reproducer);
                           S0ix substates never entered (+ measure-s0ix.sh, delta harness);
                           intel_idle missing the Wildcat Lake model entry;
                           battery charge-limit BIOS setting;
                           power button bypassing KDE's logout-screen setting
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
