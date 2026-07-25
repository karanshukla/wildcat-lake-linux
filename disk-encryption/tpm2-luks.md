# Disk encryption — TPM2-sealed LUKS auto-unlock

**Status:** Active

TPM2-sealed LUKS auto-unlock enabled via `systemd-cryptenroll` (binary present at
`/usr/bin/systemd-cryptenroll`). Root volume unlocks automatically at boot using
the TPM2 seal instead of a manual passphrase prompt, while still falling back to
passphrase if the TPM seal doesn't validate (e.g. after a firmware/boot-chain
change that alters PCR measurements).

## Setup

Enroll the LUKS volume against the TPM2, sealed to the standard firmware/boot PCR
banks:

```bash
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/nvme0n1p3
```

- `--tpm2-device=auto` picks up the machine's discrete/firmware TPM2 automatically.
- `--tpm2-pcrs=0+7` seals to PCR 0 (firmware/UEFI code) and PCR 7 (Secure Boot
  policy/state) — the standard Fedora-recommended pair. Sealing to more PCRs (e.g.
  boot loader, kernel, initrd measurements) makes the seal tighter but brittle
  across routine kernel/initrd updates, since those regenerate the measurements
  and would then require re-enrolling; 0+7 is the common middle ground.
- Replace `/dev/nvme0n1p3` with the actual LUKS partition (`lsblk` /
  `blkid` to confirm — this is a placeholder, not verified against this specific
  machine's partition layout).

`crypttab` then needs the `tpm2-device=auto` option so the initrd actually
attempts the TPM2 unlock at boot instead of only prompting for a passphrase:

```
# /etc/crypttab
luks-<uuid>  UUID=<uuid>  none  tpm2-device=auto
```

Followed by rebuilding the initramfs so the TPM2 unlock hook is included:

```bash
sudo dracut -f
```

**Caveat:** the exact commands/PCR selection above are the standard
Fedora/`systemd-cryptenroll` pattern, not independently re-verified against this
specific machine's actual enrollment (the `/etc/crypttab` entry was not
re-checked in this pass — permission denied when last attempted). Confirm with
`sudo cat /etc/crypttab` and `systemd-cryptenroll /dev/nvme0n1p3` (lists enrolled
slots/PCRs) before treating this as authoritative, or before copying it to
another machine.

## For a bug report

Not a bug — standard `systemd-cryptenroll` TPM2 usage. Included here only as an
inventory entry so the full disk/boot chain is documented in one place.
