# Disk encryption — TPM2-sealed LUKS auto-unlock

**Status:** Active

TPM2-sealed LUKS auto-unlock enabled via `systemd-cryptenroll` (binary present at
`/usr/bin/systemd-cryptenroll`). Root volume unlocks automatically at boot using
the TPM2 seal instead of a manual passphrase prompt, while still falling back to
passphrase if the TPM seal doesn't validate (e.g. after a firmware/boot-chain
change that alters PCR measurements).

## Setup

Enroll the LUKS volume against the TPM2:

```bash
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/nvme0n1p3
```

- `--tpm2-device=auto` picks up the machine's discrete/firmware TPM2 automatically.
- `--tpm2-pcrs=7` seals to PCR 7 (Secure Boot policy/state) **only**. This was
  verified against the actual enrollment on 2026-08-06 via
  `cryptsetup luksDump`, which reports `tpm2-hash-pcrs: 7`, sha256 bank,
  `tpm2-srk: true`, no PIN. An earlier revision of this doc claimed PCR 0+7
  and flagged itself as unverified; that claim was wrong.

Sealing to more PCRs (e.g. boot loader, kernel, initrd measurements) makes the
seal tighter but brittle across routine kernel/initrd updates, since those
regenerate the measurements and would then require re-enrolling.

**Consequence of PCR 7 only:** the seal survives a firmware/BIOS update, since
firmware code is measured into PCR 0, not PCR 7. It does *not* survive a Secure
Boot state change. Disabling Secure Boot on 2026-08-06 for the `Shell.efi`
work invalidated the seal immediately, which is why the passphrase prompt
returned that day. Re-enroll after Secure Boot goes back on:

```bash
sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 /dev/nvme0n1p3
```
- Replace `/dev/nvme0n1p3` with the actual LUKS partition (`lsblk` /
  `blkid` to confirm — this is a placeholder, not verified against this specific
  machine's partition layout).

`crypttab` does **not** need a `tpm2-device=auto` option on this system. The
actual entry is just:

```
# /etc/crypttab
luks-<uuid>  UUID=<uuid>  none  discard,x-initrd.attach
```

`systemd-cryptsetup` auto-detects the LUKS2 `systemd-tpm2` token and attempts
it without being told to. Adding `tpm2-device=auto` is harmless but redundant.
Verified 2026-08-06.

Followed by rebuilding the initramfs so the TPM2 unlock hook is included:

```bash
sudo dracut -f
```

**Verified 2026-08-06** against this machine, via `cryptsetup luksDump` and
`/etc/crypttab`. The volume is `/dev/nvme0n1p3` (LUKS2) with two keyslots, one
passphrase and one TPM2, and a single `systemd-tpm2` token on PCR 7. The
earlier "not independently re-verified" caveat on this doc is resolved; both
the PCR selection and the `crypttab` claim it carried turned out to be wrong
and have been corrected above.

## For a bug report

Not a bug — standard `systemd-cryptenroll` TPM2 usage. Included here only as an
inventory entry so the full disk/boot chain is documented in one place.
