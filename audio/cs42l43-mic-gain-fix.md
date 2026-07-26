# Audio: microphone hot/noisy — UCM ships no default capture gain (CS42L43 codec)

**Status:** Fixed (persisted ALSA state). Root cause is a missing default in
Fedora's `alsa-ucm-conf` for this platform, not a hardware fault.
**Component:** CS42L43 codec DMIC array, `sof-soundwire` ALSA source

## Symptom

Mic audio noticeably hissier/hotter than the same laptop under Windows,
despite Windows and Linux running the same beamforming + DRC DSP topology.

## Root cause

The CS42L43 DMIC codec's capture gain control (exposed to userspace as the
UCM-remapped alias `cs42l43 Microphone Capture Volume`, backed by the real
hardware controls `cs42l43 Decimator 3 Volume` / `cs42l43 Decimator 4
Volume`) has no default value set anywhere in this platform's UCM profile.

Checked `/usr/share/alsa/ucm2/codecs/cs42l43-dmic/init.conf`: it wires up
mute switches and the mic-mute LED (`Decimator 3/4 Switch`), but never issues
a `cset` for the volume controls. Checked `/var/lib/alsa/asound.state`
before any fix: no stored value either. With nothing setting it, the codec
boots at its hardware power-on default: **191/191, +31.5 dB — the absolute
ceiling.**

Confirmed this is the actual cause (not the DSP chain) with an A/B recording
test, same silent room, only the gain control changed:

| Gain (`cs42l43 Decimator 3/4 Volume`) | Peak dB | Noise floor dB |
|---|---|---|
| 191/191 (+31.5 dB, stock default) | -7.3 | **-18.3** |
| 140/191 (+6.0 dB) | -18.8 | **-36.8** |

18.6 dB of the ~25.5 dB gain change shows up directly in the noise floor —
running the analog/digital gain pinned to the ceiling amplifies self-noise
into the noise floor sitting only ~11 dB below full scale. Windows never
runs mic gain at the electrical max by default; it auto-calibrates well
below it.

**Ruled out:** the beamforming/DRC DSP pipeline itself. `amixer -c0
controls` confirms `Microphone Capture TDFB beam switch` (on),
`TDFB angle set enum` (0°, centered), and `Microphone Capture DRC switch`
(on) are all active and correctly routed — this mirrors what Windows' Smart
Sound path does. The `sof-audio-pci-intel-ptl` kernel log line `DMICs
detected in NHLT tables: 0` is a red herring: NHLT only describes legacy
PCH-attached DMICs. This array is behind the CS42L43 SoundWire link
(`alsa.components` reports `mic:cs42l43-dmic`), so it doesn't use NHLT at
all and the array is present and working correctly.

## Fix

Set a sane default gain on the real underlying controls and persist it
through ALSA's standard restore path, so it survives reboot instead of
reverting to the codec's max-gain power-on default every time:

```
amixer -c0 sset 'cs42l43 Microphone' 150   # 150/191, +11.0 dB
sudo alsactl store
```

`alsactl store` writes the value into `/var/lib/alsa/asound.state` under the
real control names (`cs42l43 Decimator 3 Volume` / `Decimator 4 Volume`) —
not the UCM alias name, since UCM's `ctl.default.map` remap is a
runtime-only virtual layer and doesn't show up in the raw state dump. This
gets restored automatically at boot by `alsa-restore.service`, no custom
udev rule or script needed.

150/191 (+11 dB) was chosen from the A/B data above, giving noticeably more
headroom than stock without going as low as the 140 test point. Not
fine-tuned against real speech yet, only against ambient noise floor — worth
revisiting with an actual voice recording if it still sounds off.

To revert: `amixer -c0 sset 'cs42l43 Microphone' 191` then `sudo alsactl
store` again.

## For a bug report

- Hardware: Dell XPS 13 DX13260, CS42L43 codec (DMIC array via SoundWire),
  `alsa-sof-firmware`
- Package: `alsa-ucm-conf`, file
  `ucm2/codecs/cs42l43-dmic/init.conf`
- Evidence: no `cset` for `cs42l43 Decimator 3/4 Volume` anywhere in the UCM
  profile; codec boots at hardware max (191/191, +31.5 dB); confirmed via
  `amixer -c0 controls` and `/var/lib/alsa/asound.state` (empty for this
  control before any local fix)
- Ask: UCM profile should ship a sane default capture gain for this
  codec/platform combination instead of leaving it at the hardware ceiling
