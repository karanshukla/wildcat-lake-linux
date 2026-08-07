# Updating the BIOS with no LVFS release: UEFI capsule-on-disk

**Status:** Worked. BIOS 1.6.0 flashed 2026-08-06 22:29 EDT on the first
attempt, from Linux, no Windows involved.

Dell publishes BIOS 1.6.0 for the XPS 13 DX13260 as a Windows `.exe` only.
There is no LVFS release for this model at all (zero entries), so
`fwupdmgr update` has nothing to offer. This documents finding a working
update path from Linux without Windows.

## Symptom

`fwupdmgr update` reports nothing available. BIOS stays at 1.3.0 (2026-06-25)
despite 1.6.0 being on Dell's support site. This matters because the S0ix
blocker is Intel ME (CSE) firmware, which needs a Dell firmware update to fix.
See [../power/s0ix-never-entered.md](../power/s0ix-never-entered.md).

## What was tried and ruled out

| Attempt | Result |
|---|---|
| F12 BIOS Flash Update with the extracted `.fd` | Rejected, "no capsule header" |
| `InterToolx64.efi` from a UEFI Shell | Ran, then failed on missing `platform.ini` |
| `IHISI 10h` SMI from the pre-boot Shell | "Function not supported" |
| Windows-To-Go on Ventoy to run `H2OFFT-Wx64.exe` | Considered, not attempted, unnecessary |

The `IHISI 10h` failure was misread at the time as the platform lacking flash
capability. It is not. It only means that one SMI entry point is unavailable
from the pre-boot Shell.

`InterToolx64.efi` was also a dead end for a second reason, independent of the
missing `platform.ini`. `platform.ini` says:

```
[MULTI_FD]
InterTool=0
FD#01=CPUID,FFFFFFFF,000D0651,DX13260WCL.fd
FD#02=CPUID,FFFFFFFF,000C06C3,DX13260PTL.fd
```

`InterTool=0` means InterTool does not support multi-FD image selection, and
this is a multi-FD package. It was never going to pick the right image.

## Root cause of the confusion

The `.fd` is not a raw flash image. It is a PE32+ stub with an Authenticode
SECURITY directory (1760 bytes, signer `CN=LuxSharePC`, Dell's ODM Luxshare)
wrapping the 17.4 MB BIOS blob in a fake `.reloc` section at raw offset
`0x5be0`. So F12 was right to reject it: it is a signed payload that still
needs a UEFI capsule header wrapped around it.

## The platform supports capsule-on-disk

This is the finding that unblocked everything.

```
$ sudo cat /sys/firmware/efi/esrt/entries/entry0/{fw_class,fw_type,fw_version}
e9a4014c-2408-4d3a-8909-ba0fa6a29420
1
66304
```

`fw_version 66304` is `0x010300`, i.e. BIOS 1.3.0, so the encoding is
`0xMMmmpp` and 1.6.0 is `0x010600` = 67072. `fw_type 1` is System Firmware.
fwupd already lists this entry as `Updatable` with summary "UEFI System
Resource Table device (Updated via capsule-on-disk)".

```
OsIndicationsSupported = 0x7f
  [x] FILE_CAPSULE_DELIVERY_SUPPORTED
  [x] FMP_CAPSULE_SUPPORTED
  [x] CAPSULE_RESULT_VAR_SUPPORTED
```

That matches `[SecureUpdate] viaESP=3` in Insyde's `platform.ini`, which means
"try ESP first, fall back to memory". The capsule mechanism was available the
whole time. The only thing missing was a capsule to hand it.

Confirming the payload is the right one: the Insyde BVDT inside
`DX13260WCL.fd` carries `$ESRT` followed by `00 06 01 00` (`0x010600` = 1.6.0)
and then GUID `e9a4014c-2408-4d3a-8909-ba0fa6a29420`, the same GUID as ESRT
entry0. The image declares itself as 1.6.0 targeting exactly the entry fwupd
wants to update.

Image selection is by CPUID. `0x000D0651` is family 6, extended model `0xD`,
model 5, stepping 1. `/proc/cpuinfo` reports family 6, model 213 (`0xD5`),
stepping 1, and fwupd reports `CPUID\PRO_0&FAM_06&MOD_D5&STP_1`. So
`DX13260WCL.fd` is correct and `DX13260PTL.fd` is the Panther Lake sibling SKU.

## Procedure

Dell's `.exe` is a 7-Zip SFX:

```bash
7z x Dell_XPS_13_DX13260_1.6.0.exe -o./dellbios
```

Stage the capsule:

```bash
sudo fwupdtool install-blob DX13260WCL.fd 2e98d67f69a896b83ba22baef6ffc2f57d9566aa
```

The device ID is fwupd's System Firmware entry, from `fwupdmgr get-devices`.
fwupd wraps the signed `.fd` in a 4 KB capsule header and writes
`/boot/efi/EFI/UpdateCapsule/CapsuleUpdateFile0000.bin` (18,260,608 bytes,
= 18,256,512 payload + 4,096 header), then sets `OsIndications = 0x4`.

Nothing is written to SPI at this point. The flash happens during POST on the
next boot, automatically. No F2, no F12, no key to press.

To abort before rebooting:

```bash
sudo rm /boot/efi/EFI/UpdateCapsule/CapsuleUpdateFile0000.bin
sudo chattr -i /sys/firmware/efi/efivars/OsIndications-8be4df61-93ca-11d2-aa0d-00e098032b8c
sudo rm /sys/firmware/efi/efivars/OsIndications-8be4df61-93ca-11d2-aa0d-00e098032b8c
```

## Why the risk is lower than it looks

Only the BIOS region is written:

```
[Region]   BIOS=1  GbE=0  ME=0  EC=0  DESC=0  Platform_Data=0
[UpdateEC] Flag=0
```

No ME, EC or descriptor writes, so there is no mismatched-component failure
mode. The payload is Dell/Luxshare-signed and unmodified, and the firmware
verifies it before writing, so a bad capsule should be rejected rather than
half-flashed. `lowest_supported_fw_version` is 0, so there is no anti-rollback
wall between 1.3.0 and 1.6.0.

Pre-flight: AC connected (`[AC_Adapter] BatteryBound=10`), and ESP needs about
18 MB free.

## Result

Flashed on the first attempt. After reboot:

```
entry0  fw_version            67072      (0x010600 = 1.6.0)
        last_attempt_version  67072
        last_attempt_status   0          (success)

$ sudo dmidecode -s bios-version       -> 1.6.0
$ sudo dmidecode -s bios-release-date  -> 07/16/2026
```

`/boot/efi/EFI/UpdateCapsule/` is empty and `OsIndications` is cleared, so the
firmware consumed the capsule and tidied up after itself, exactly as the spec
says it should.

ESRT entry1 (1345) and entry2 (0) are unchanged, which confirms `[Region]`
was honoured: only the BIOS region was written, ME and EC untouched.

**fwupd's simple capsule form is sufficient on this platform.** No hand-built
FMP structure was needed, even though `FMP_CAPSULE_SUPPORTED` is advertised.
`CapsuleGuid` = the ESRT `fw_class` is enough. That answers the main open
question from the staging attempt.

## Gotcha: the BIOS update wipes MOK enrollment, which silently kills audio

Budget one extra reboot for this on any future BIOS update.

MOK (Machine Owner Key) enrollment lives in UEFI NVRAM, and the flash
reinitialises it. After updating to 1.6.0 and re-enabling Secure Boot,
`mokutil --list-enrolled` returned exactly one certificate, Fedora's. The
`CN=wildcat-lake-linux DKMS signing key` used to sign the CS35L56 sidecar-amp
module (see [../audio/cs35l56-sidecar-amp-quirk.md](../audio/cs35l56-sidecar-amp-quirk.md))
was gone.

Symptom is not an obvious signing error. It presents as **no sound card at
all**:

```
$ aplay -l
no soundcards found...

$ journalctl -k -b | grep SoundWire
sof-audio-pci-intel-ptl 0000:00:1f.3: No SoundWire machine driver found for
  the ACPI-reported configuration: link 2 mfg_id 0x01fa part_id 0x4243 version 0x3
```

The SOF/SoundWire stack loads normally and the codec modules are all present,
so nothing looks rejected. The out-of-tree `snd_soc_sof_sdw` simply never
loads, so the ACPI configuration matches no machine driver and no card is
registered. There is no "key was rejected by service" line to grep for.

Nothing is lost. The module and both key files survive on disk
(`/etc/pki/wildcat-lake-mok/MOK.{der,priv}`); only the firmware's record of
trusting them is cleared. Re-enrol and reboot:

```bash
sudo mokutil --import /etc/pki/wildcat-lake-mok/MOK.der   # sets a one-time password
sudo reboot                                                # MokManager: Enroll MOK -> Continue -> Yes -> password
```

Confirmed fixed 2026-08-06 22:51: two certificates enrolled, card back as
`sofsoundwire` / `DellInc.-XPS13DX13260-1.6.0-0865D8`, both
`spi-cs35l56-left` and `-right` up on
`cs35l56-b2-dsp1-misc-10280e53-spkid1.wmfw`.

Note the TPM2 LUKS seal needed **no** action, because it is PCR 7 only and
PCR 7 tracks Secure Boot state: turning Secure Boot back on restored PCR 7 to
its original value and the seal validated again by itself. See
[../disk-encryption/tpm2-luks.md](../disk-encryption/tpm2-luks.md).

## Does it fix S0ix? No, and it could not have

Tested the same night with `../power/measure-s0ix.sh 90`. A clean 91-second
`s2idle` cycle (`suspend entry` 22:32:07, `suspend exit` 22:33:38) left every
substate at 0, identical to 1.3.0. Package C10 accumulated normally, so the
cores still reach CC10; the platform still never reaches S0ix.

That is the predicted result, not a surprise. `[Region] ME=0` means this
package only ever writes the BIOS region, and the S0ix blocker is CSE-side.
ESRT entry1 is unchanged at 1345 afterwards, confirming ME was untouched.

**ESRT entry1 is the CSE firmware.** GUID
`865d322c-6ac7-4734-b43e-55db5a557d63`, `fw_version 1345`, and
`/sys/class/mei/mei0/fw_ver` reports `21.50.1.1345`. It is flagged `Updatable`
via capsule-on-disk with `lowest_supported_fw_version 1000`, so the delivery
mechanism for a CSE update already works on this machine. The only missing
piece is a capsule from Dell. Details in
[../power/s0ix-never-entered.md](../power/s0ix-never-entered.md).

## Remaining questions

- Will Dell publish a CSE firmware capsule, or list DX13260 on LVFS at all?
  That is now the single remaining lever for S0ix.
- Whether 1.6.0 changed anything else worth noticing. The panel wedge did not
  reproduce on the post-update suspend, but `xe.enable_psr=1` from 2026-08-05
  is the more likely reason and one clean cycle proves little either way.

## For a bug report

Not a bug, but worth reporting to Dell as a gap: DX13260 has zero LVFS
releases despite the platform fully supporting UEFI capsule-on-disk
(`OsIndicationsSupported = 0x7f`, ESRT System Firmware entry present and
flagged updatable). Everything needed to ship this model on LVFS already
works. Linux users are currently pushed to a Windows-only `.exe` for no
technical reason.
