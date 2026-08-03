# Audio: two of four speakers (CS35L56 "sidecar" amps) silent — missing DMI quirk

**Status:** Fixed locally via a signed out-of-tree kernel patch (DKMS + MOK), pending
upstream. Root cause is a missing one-entry DMI quirk in the mainline
`sof_sdw` driver for this exact Dell SKU.
**Component:** `sof_sdw` SoundWire machine driver, CS42L43 codec + 2x CS35L56 amps
**Hardware:** Dell XPS 13 DX13260 (Wildcat Lake), DMI `product_sku` **0E53**

## Symptom

Only the tweeter path (driven directly by the CS42L43 codec) produces sound;
the two woofers, driven by a pair of CS35L56 amp chips, are silent. Not
specific to this install — matches reports from other DellInc.-XPS13DX13260
owners running Fedora, and a corresponding but distinct Ubuntu bug (see
below).

## Root cause

Confirmed via `journalctl -k`: both physical CS35L56 amps probe and boot
firmware correctly —

```
cs35l56 spi-cs35l56-left:  Cirrus Logic CS35L56 Rev B2 OTP1 fw:4.2.1 (patched=0)
cs35l56 spi-cs35l56-right: Cirrus Logic CS35L56 Rev B2 OTP1 fw:4.2.1 (patched=0)
```

but the kernel never wires audio to them:

```
sof-audio-pci-intel-ptl: No SoundWire machine driver found for the ACPI-reported configuration:
sof-audio-pci-intel-ptl: link 2 mfg_id 0x01fa part_id 0x4243 version 0x3
acpi device:20: SDCA function SmartAmp (type 1) at 0x1
sof-audio-pci-intel-ptl: loading topology 1: intel/sof-ipc4-tplg/sof-sdca-1amp-id2.tplg
```

Dell's ACPI tables report only **one** SmartAmp SDCA function, even though
two independently-addressable CS35L56 chips are physically present (wired as
SPI-bridged "sidecar" amps riding on the CS42L43's SoundWire link, not as
separately SoundWire-addressable peripherals). With no dedicated
machine-driver match for this exact hardware, the kernel falls back to a
generic "function topology" loader that trusts ACPI's function count, and
picks the 1-amp topology — tweeters only.

## Investigation trail

**Ruled out — forcing the 2-amp topology file directly.** The correct
topology does ship in the SOF firmware package
(`sof-sdca-2amp-id2.tplg.xz`, alongside 1amp/3amp/4amp variants). Forced it
via `snd_sof`'s `tplg_filename`/`tplg_path` module parameters (required a
full unload/reload of the SOF/SoundWire module chain, since the parameter is
read-only once loaded). The topology loaded, but card construction then
failed outright:

```
sof-audio-pci-intel-ptl: error: can't find BE for DAI alh-copier.Playback-SmartAmp.1
sof_sdw: ASoC: failed to load widget alh-copier.Playback-SmartAmp.1
```

Confirms the missing piece isn't just topology-file selection — the machine
driver never creates a second backend DAI for the second amp regardless of
which topology loads. Cleanly reverted; no lasting effect.

**Found the real upstream mechanism.** A user-forwarded Ubuntu bug
([#2159594](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2159594))
against the *same DMI SKU (0E53)*, but a different symptom (`cs42l43` PLL
crash — `No suitable PLL config: 0xffffffea, 0Hz` — total silence rather
than partial), reported root cause as "missing machine-driver quirk for
Dell SSID 0E53" and confirmed fixed on mainline `7.2.0-rc4`. A second,
earlier Ubuntu bug
([#2139391](https://bugs.launchpad.net/ubuntu/+source/linux-oem-6.17/+bug/2139391),
the original Dell "Bolan" PTL bring-up) described *our exact symptom* —
"internal speaker fails while other functions are working" — fixed by a
coordinated kernel + `linux-firmware` + `sof-firmware` + `alsa-ucm-conf`
patch stack, confirmed resolved to "all audio functions work as expected."

Traced the actual kernel fix: commit `12cacdfb023d1b2f6c4e5af471f2d5b6f0cbf909`
("ASoC: Intel: sof_sdw: Add new quirks for PTL on Dell with CS42L43",
Deep Harsora / Maciej Strozek, merged upstream) adds exactly one DMI quirk
table entry — for SKU **0DD6**, not ours:

```c
{
	.callback = sof_sdw_quirk_cb,
	.matches = {
		DMI_MATCH(DMI_SYS_VENDOR, "Dell Inc"),
		DMI_EXACT_MATCH(DMI_PRODUCT_SKU, "0DD6")
	},
	.driver_data = (void *)(SOC_SDW_SIDECAR_AMPS),
},
```

`SOC_SDW_SIDECAR_AMPS` is documented in `include/sound/soc_sdw_utils.h` as
*"2x Sidecar amplifiers + CODEC internal speaker"* — a literal, word-for-word
description of this hardware. Its implementation
(`sound/soc/sdw_utils/soc_sdw_bridge_cs35l56.c`,
`asoc_sdw_bridge_cs35l56_add_sidecar()`) adds the missing extra DAI link and
codec-conf entries for the two sidecar amps — precisely the backend DAI that
was missing in the ruled-out test above. Confirmed via Fedora's own kernel
source (`dnf download --source kernel-core-7.1.5-201.fc44`) that this whole
mechanism already ships, tested, in our exact running kernel
(`7.1.5-201.fc44`) — used by several *other* Dell/Lenovo SKUs already (lines
576, 584, 632, 648, 655, 663, 690, 698 of `sof_sdw.c`; also a Lenovo `0x3821`
quirk). Dell shipped this same CS42L43 + 2×CS35L56 design across multiple
SKUs; `0DD6` got its quirk upstream in January 2026, ours (`0E53`) never did.

**First patch attempt looked like a no-op.** Added the analogous DMI entry
for SKU `0E53`, built and loaded it — topology stayed on `sof-sdca-1amp-id2`,
no `cs35l56` mixer controls appeared. Rather than conclude the mechanism was
wrong, added instrumentation: the driver's `log_quirks()` prints whether
`SOC_SDW_SIDECAR_AMPS` matched, but only at `dev_dbg` level (invisible by
default, and writing to `/sys/kernel/debug/dynamic_debug/control` is blocked
outright — `Operation not permitted` — by Secure Boot's kernel lockdown,
even as root). Worked around by passing the debug flag as an `insmod`
module parameter instead (`dyndbg=+p`), which lockdown does not block.
Confirmed directly:

```
sof_sdw sof_sdw: quirk SOC_SDW_SIDECAR_AMPS enabled
sof_sdw sof_sdw: DAI link numbers: sdw 3, ssp 0, dmic 0, hdmi 3, bt: 1
```

(`sdw 3` — up from the normal 2 — confirms the sidecar bridge DAI link was
added.) No widget-linking error this time (contrast with the ruled-out
`tplg_filename`-forcing test above); card built successfully. Some
non-fatal SPI/SoundWire transient errors were logged during amp bring-up
(`Failed to disable/enable SPI controller: -5`,
`cs35l56 spi-cs35l56-right: Hibernate wake failed: -5`) — plausibly
artifacts of the amps having been power-cycled through many module
reload/rebind cycles earlier in the same session rather than a real defect
in the fix; worth re-checking after a clean cold boot. Restarted PipeWire/
WirePlumber and confirmed **audibly** — real, working bass from both
woofers, not just a clean probe log.

## Fix

One-line-equivalent change to `sound/soc/intel/boards/sof_sdw.c`, immediately
after the existing `0DD6` entry:

```c
{
	.callback = sof_sdw_quirk_cb,
	.matches = {
		DMI_MATCH(DMI_SYS_VENDOR, "Dell Inc"),
		DMI_EXACT_MATCH(DMI_PRODUCT_SKU, "0E53")
	},
	.driver_data = (void *)(SOC_SDW_SIDECAR_AMPS),
},
```

Since this is a security-sensitive, in-tree driver file, it can't be patched
live — it has to be rebuilt as a kernel module and reloaded. Full mechanism:

1. **Get matching kernel source.** `dnf download --source kernel-core-<running-version>`,
   extract `sound/soc/intel/boards/{sof_sdw.c,sof_sdw_hdmi.c,sof_sdw_common.h,
   sof_hdmi_common.h,hda_dsp_common.h}` and `sound/soc/codecs/{rt711.h,hdac_hda.h}`
   (transitive local includes) from the source tarball inside the SRPM —
   guarantees exact ABI compatibility, no tag-guessing against upstream.
2. **Apply the quirk-table addition above, build out-of-tree** against
   `kernel-devel` matching the running kernel:
   ```
   obj-m := snd-soc-sof-sdw.o
   snd-soc-sof-sdw-objs := sof_sdw.o sof_sdw_hdmi.o
   ```
   `make -C /usr/src/kernels/$(uname -r) M=<builddir> modules`
3. **Secure Boot blocks unsigned modules** (`insmod` fails with
   `Key was rejected by service`) — same wall as unsigned mainline/COPR
   kernels, but scoped narrower: enroll a locally-generated **MOK** via
   `mokutil --import` instead of disabling Secure Boot outright. Secure Boot
   stays fully on; the firmware just additionally trusts this one key for
   modules we sign ourselves. One-time physical step: reboot, confirm
   enrollment at the blue "MOK Manager" screen (Enroll MOK → password →
   confirm).
4. **Sign and load** with the kernel's own `scripts/sign-file`, then
   `insmod`. (Note: `sign-file` modifies its target in place if no separate
   output path is given — sign to a *new* file, not over the only build
   output, or a failed signing attempt destroys the build.)
5. **Persist across reboots/kernel updates via DKMS.** Package the patched
   sources under `/usr/src/sof-sdw-sidecar-0e53-1.0/` with a `dkms.conf`
   (`BUILT_MODULE_NAME=snd-soc-sof-sdw`, installs to the kernel's
   `updates`/`extra` module directory, which `depmod` prioritizes over the
   stock in-tree copy without deleting it). Point DKMS's own MOK-signing
   support at the same already-enrolled key
   (`/etc/dkms/framework.conf.d/*.conf`: `mok_signing_key=`,
   `mok_certificate=`) so it auto-rebuilds *and* auto-signs on every kernel
   update, no manual re-signing needed. `dkms add && dkms build && dkms install`.

Verified installed and signed: `/lib/modules/7.1.5-201.fc44.x86_64/extra/snd-soc-sof-sdw.ko.xz`,
correct `vermagic`, `sig_id: PKCS#7` matching the enrolled MOK fingerprint.

## Trade-offs

- This is a **local bridge, not a permanent solution** — it re-implements a
  single already-upstream mechanism for one additional SKU, following an
  exact precedent. Once a kernel shipping the equivalent `0E53` quirk (or
  Fedora backports it) is installed, this DKMS package should be removed to
  avoid any conflict with the in-tree fix (unlikely in practice — DKMS-built
  modules only override the *stock* kernel's own module for the *same*
  kernel version, but cleaner to not carry dead weight).
- Requires MOK enrollment. Doesn't weaken Secure Boot for anything else, but
  it *is* a standing trust decision, not something to enroll casually.
- Not yet verified across a clean cold boot (only tested via live
  module-reload cycles within one already-running session) — the harmless
  SPI transient errors noted above are worth re-checking after a real
  power-off/power-on cycle, though audio was confirmed working audibly
  regardless.
- The bass-boost EQ (`audio/cs42l43-eq-fix.md`) was tuned against
  tweeter-only output; now that real woofers are contributing bass, that
  curve may need retuning — separate follow-up, not addressed here.

## For a bug report / upstream submission

This is essentially ready to submit upstream as-is, following the exact
precedent already merged for SKU `0DD6`:

- **Patch:** one entry in `sound/soc/intel/boards/sof_sdw.c`'s
  `sof_sdw_quirk_table[]`, shown above.
- **Precedent:** commit `12cacdfb023d1b2f6c4e5af471f2d5b6f0cbf909`
  ("ASoC: Intel: sof_sdw: Add new quirks for PTL on Dell with CS42L43"),
  same mechanism, different SKU, already reviewed and merged.
- **Hardware:** Dell XPS 13 DX13260, DMI `sys_vendor` "Dell Inc.",
  `product_sku` "0E53", `product_name` "XPS 13 DX13260"; SoundWire link 2,
  `mfg_id` 0x01fa, `part_id` 0x4243, version 0x3; CS42L43 codec + 2x CS35L56
  (Rev B2 OTP1, fw 4.2.1) sidecar amps.
- **Evidence this fixes the actual symptom** (not just avoids a crash):
  confirmed audibly, both woofers producing sound, after being silent on
  every topology the unpatched driver could select.
- **Target:** `alsa-devel` mailing list / the SOF project, same route as the
  precedent commit.
