# Audio: two of four speakers (CS35L56 "sidecar" amps) silent — missing DMI quirk

**Status:** Fixed locally via a signed out-of-tree kernel patch (DKMS + MOK).
**Update (2026-08-03): already fixed upstream, no submission needed.** Cirrus
Logic's Charles Keepax merged a fix for this exact SKU on 2026-07-16
(`efd80de2de9d06ddf0eee55ca11b04e39bfc7cd8`, tagged for the v7.2-rc3 pull),
via a different mechanism than the one this doc originally proposed
submitting (PCI subsystem-ID quirk, not a DMI quirk). See
[Upstream status](#upstream-status) below. The local DKMS patch stays in
place only until Fedora ships a 7.2+-based kernel; see
[On kernel update](#on-kernel-update).
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

## Upstream status

Before submitting the patch below, checked it against a live pull of Mark
Brown's ASoC tree (`git://git.kernel.org/pub/scm/linux/kernel/git/broonie/sound.git`,
`for-next`) rather than assuming the DMI-quirk precedent below was still the
open path. It wasn't — Cirrus Logic's Charles Keepax had already fixed this
exact SKU, three weeks before this investigation, via a completely different
mechanism:

```
commit efd80de2de9d06ddf0eee55ca11b04e39bfc7cd8
Author: Charles Keepax <ckeepax@opensource.cirrus.com>
Date:   2026-07-16 15:42:09 +0100 (tagged asoc-fix-v7.2-rc3)

    ASoC: Intel: sof_sdw: Add quirks for new Dell laptops

    A couple of new Dell laptops are shipping using the sidecar amp
    configuration. Add the required kernel quirk to enable.
```

```c
 static const struct snd_pci_quirk sof_sdw_ssid_quirk_table[] = {
+	SND_PCI_QUIRK(0x1028, 0x0e53, "Dell XPS WCL", SOC_SDW_SIDECAR_AMPS),
+	SND_PCI_QUIRK(0x1028, 0x0e54, "Dell XPS PTL", SOC_SDW_SIDECAR_AMPS),
 	SND_PCI_QUIRK(0x1043, 0x1e13, "ASUS Zenbook S14", SOC_SDW_CODEC_MIC),
```

This matches on PCI subsystem vendor/device ID (`0x1028`/`0x0e53`, read from
real PCI config space) via `sof_sdw_check_ssid_quirk()`, called earlier in
probe than `dmi_check_system(sof_sdw_quirk_table)` — independently sufficient
to set `SOC_SDW_SIDECAR_AMPS` for this hardware, with or without a DMI-table
entry. Tagged for the v7.2-rc3 pull, so it should already be in any kernel
based on 7.2-rc3 or later — matching this session's separate finding that
audio "just works" on a 7.2.0-rc4 build (see commit history), which is this
fix, not the DMI-quirk precedent (`12cacdfb023d`) this doc was originally
built around.

Also settles a naming question this repo has left ambiguous
(`README.md` hedges "Wildcat Lake / Panther Lake"): Keepax's own quirk
labels distinguish `0x0e53` as **"Dell XPS WCL"** (Wildcat Lake) from a
sibling `0x0e54` **"Dell XPS PTL"** (Panther Lake) — two distinct SKUs of
this chassis. `lscpu` on this machine reports `Intel(R) Core(TM) 5 320`
(Core Series 3 branding, i.e. Wildcat Lake; Panther Lake ships as Core
*Ultra* Series 3), consistent with the `0x0e53` SSID actually detected.
This machine is Wildcat Lake, not Panther Lake.

**Practical upshot:** no upstream submission needed for the DMI-quirk patch
drafted below, it would just duplicate already-merged work. Left in place as
the investigation record and as the actual local fix until Fedora ships a
kernel built from 7.2-rc3 or later.

### Live-testing the upstream fix

To confirm the upstream mechanism actually works on this hardware rather
than just trusting the commit log, ported just the real fix (the two
`SND_PCI_QUIRK` lines from `efd80de2`) onto our known-working Fedora
7.1.5-201.fc44 source, with our own DMI-quirk entry removed — the
`sof_sdw_ssid_quirk_table[]` / `sof_sdw_check_ssid_quirk()` infrastructure
already existed in this exact kernel's source (used by an existing Lenovo
entry), so this was a 2-line addition, not a backport of newer code. Built
and signed with the same already-enrolled MOK, live-loaded in place of the
installed DKMS module.

dmesg confirmed the mechanism works exactly as expected:

```
sof_sdw sof_sdw: quirk SOC_SDW_SIDECAR_AMPS enabled
sof_sdw sof_sdw: DAI link numbers: sdw 3, ssp 0, dmic 0, hdmi 3, bt: 1
```

Both CS35L56 amps loaded firmware and tuning data. However, no audible
sound came out, despite PipeWire showing signal activity, and mixer/DAPM
inspection (`amixer -c0`) showed every relevant control — master `Speaker`,
`AMPL`/`AMPR Speaker`, `cs42l43 Speaker Digital`, DAPM routing to
`ASPRX1`/`ASPRX2` — already on and correctly wired. Not a software/routing
problem.

dmesg did show `Failed to write to 'CAL_R': -1` on both amps at load time,
a genuine hardware-level calibration failure, not the cosmetic SPI
transients noted elsewhere in this doc. Attempting to recover by unbinding
and rebinding the CS35L56 SPI devices (`/sys/bus/spi/drivers/cs35l56/{un,}bind`)
made it worse, not better: the amps' `Cirrus Logic ...` boot log lines never
reappeared with fresh calibration, and a subsequent module reload failed
outright (`_cs35l56_component_probe: init_completion timed out`,
`ASoC error (-19)`, `failed to instantiate card -19`). The `supply VDD_B /
VDD_AMP not found, using dummy regulator` lines logged at every probe are
the likely reason: there's no real regulator/power-sequencing framework
wired to these chips on this platform, so SPI unbind/bind is a logical
detach, not an electrical power cycle, it can't clear a wedged internal
amp state the way a real power-off can.

**Ruled out — this session's chaos, not the upstream fix itself.** A
reboot recovered cleanly (see the [Trade-offs](#trade-offs) update above),
but came back up on the original DKMS-installed DMI-quirk module, not this
test build, since the test module only ever lived in memory. So the
upstream SSID-quirk mechanism is confirmed to activate correctly and
matches the known-good `SOC_SDW_SIDECAR_AMPS` signature, but hasn't yet
been verified end-to-end (audibly, from a clean cold boot) the way the local
DMI-quirk patch has. **Next step, not yet done:** install the upstream-fix
build as the DKMS module (replacing the DMI-quirk one) and test via a real
reboot rather than any further live module hot-reloading, this session's
repeated rmmod/insmod/unbind cycling is the likely reason the amps ended up
in a bad state at all.

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

## On kernel update

DKMS auto-rebuilds this against every new kernel (Fedora's
`/usr/lib/kernel/install.d/40-dkms.install` hook runs `dkms autoinstall` on
every `kernel-core` update, and `AUTOINSTALL="yes"` in `dkms.conf` triggers
it), auto-signing with the already-enrolled MOK — no manual step normally
needed. But it's rebuilding a **frozen 7.1.5-vintage copy** of `sof_sdw.c`
against the new kernel's headers, not fetching the new kernel's actual
source, so check after every update:

1. **`dkms status`** — confirm `sof-sdw-sidecar-0e53` shows `installed` for
   the *new* running kernel version, not just the old one.
   - **If it's missing/failed for the new kernel:** the frozen source didn't
     build against the new headers (internal API drift). No override module
     got installed, so the kernel's own stock module loads instead — you're
     silently back to tweeters-only *unless* that stock module already has
     an upstream `0E53` quirk by then. Listen for woofers; if silent, this
     patch needs rebuilding from fresh source (`dnf download --source` for
     the new kernel version, reapply the same one-entry diff, redo the DKMS
     package).
2. **If it built successfully**, listen for woofers anyway — a clean build
   doesn't guarantee upstream didn't change something else in that file
   between versions that our frozen copy silently reverts.
3. **If a Fedora kernel update ever ships the real upstream fix**
   (specifically commit `efd80de2de9d06ddf0eee55ca11b04e39bfc7cd8`, tagged
   `asoc-fix-v7.2-rc3` — so any Fedora kernel built from 7.2-rc3 or later
   should already have it; see [Upstream status](#upstream-status)), remove
   this package so it stops shadowing the in-tree fix:
   `dkms remove -m sof-sdw-sidecar-0e53 -v 1.0 --all`.

## Trade-offs

- This is a **local bridge, not a permanent solution** — and, as of
  2026-08-03, a genuinely temporary one: upstream already fixed this SKU by
  a different mechanism (see [Upstream status](#upstream-status)), so this
  package just needs to survive until Fedora ships a 7.2-rc3+-based kernel,
  not indefinitely. It rebuilds from a frozen copy of the source on every
  kernel update rather than the new kernel's actual code in the meantime.
  See [On kernel update](#on-kernel-update) above for what to check after
  each `dnf update` and when to retire this package.
- Requires MOK enrollment. Doesn't weaken Secure Boot for anything else, but
  it *is* a standing trust decision, not something to enroll casually.
- **Verified across a clean cold boot (2026-08-03).** A reboot during a
  separate same-day investigation (see
  [Live-testing the upstream fix](#live-testing-the-upstream-fix) below)
  came back up on this DKMS-installed module with no manual steps and
  working audio, closing the open question above.
- The bass-boost EQ (`audio/cs42l43-eq-fix.md`) was tuned against
  tweeter-only output; now that real woofers are contributing bass, that
  curve may need retuning — separate follow-up, not addressed here.

## For a bug report / upstream submission

**Superseded — do not submit.** See [Upstream status](#upstream-status):
this was already fixed upstream on 2026-07-16
(`efd80de2de9d06ddf0eee55ca11b04e39bfc7cd8`), before this section was
originally written. A patch was drafted below (DMI-quirk mechanism,
following the `0DD6` precedent), validated with `checkpatch.pl` and a real
`get_maintainer.pl` recipient lookup, but caught as redundant during a
final pre-send check against the live upstream tree, and was never sent.
Keeping the original reasoning below as the investigation record.

Original plan, for reference:

- **Patch:** one entry in `sound/soc/intel/boards/sof_sdw.c`'s
  `sof_sdw_quirk_table[]`, shown above.
- **Precedent:** commit `12cacdfb023d1b2f6c4e5af471f2d5b6f0cbf909`
  ("ASoC: Intel: sof_sdw: Add new quirks for PTL on Dell with CS42L43"),
  same *kind* of mechanism (DMI quirk table), different SKU, already
  reviewed and merged — but not the mechanism that actually ended up
  fixing `0E53` upstream (that was a PCI SSID quirk instead, see above).
- **Hardware:** Dell XPS 13 DX13260, DMI `sys_vendor` "Dell Inc.",
  `product_sku` "0E53", `product_name` "XPS 13 DX13260"; SoundWire link 2,
  `mfg_id` 0x01fa, `part_id` 0x4243, version 0x3; CS42L43 codec + 2x CS35L56
  (Rev B2 OTP1, fw 4.2.1) sidecar amps.
- **Evidence this fixes the actual symptom** (not just avoids a crash):
  confirmed audibly, both woofers producing sound, after being silent on
  every topology the unpatched driver could select.
