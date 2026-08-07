# Updating the BIOS with no LVFS release: UEFI capsule-on-disk

**Status:** Capsule staged 2026-08-06 22:08 EDT, result pending first reboot.

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

## Verification after reboot

```bash
cat /sys/firmware/efi/esrt/entries/entry0/fw_version            # want 67072
cat /sys/firmware/efi/esrt/entries/entry0/last_attempt_status   # want 0
```

`CAPSULE_RESULT_VAR_SUPPORTED` is set, so a rejection is readable rather than
silent. A non-zero `last_attempt_status` distinguishes "firmware rejected the
capsule framing" from "firmware rejected the payload".

## Remaining questions

- Does this firmware's FMP handler require the full FMP capsule structure
  (capsule header + FMP capsule header + image header), or is fwupd's simpler
  form, where `CapsuleGuid` is just the ESRT `fw_class`, sufficient? fwupd's
  simple form is what Dell ships on LVFS for other models, so it is likely
  fine, but it is untested on this platform until the first reboot.
- Does 1.6.0 actually move the S0ix/CSE firmware blocker? That is the entire
  reason for doing this. Unknown until it lands.

## For a bug report

Not a bug, but worth reporting to Dell as a gap: DX13260 has zero LVFS
releases despite the platform fully supporting UEFI capsule-on-disk
(`OsIndicationsSupported = 0x7f`, ESRT System Firmware entry present and
flagged updatable). Everything needed to ship this model on LVFS already
works. Linux users are currently pushed to a Windows-only `.exe` for no
technical reason.
