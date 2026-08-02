# KWallet doesn't auto-unlock with face-auth login/unlock

**Status (2026-08-02): unresolved, root cause isolated, fix not yet applied.**
Pending a cheap empirical test before deciding whether a PAM change is even
necessary — see "Next step" below.

## Symptom

KWallet repeatedly prompts for a manual password unlock, surfaced through
`xdg-desktop-portal`'s Secret Service bridge rather than as a native KWallet
dialog — easy to misattribute to the portal or to `sudo`/polkit at a glance.
Face-auth (via AuthFace, see [README.md](README.md)) successfully
authenticates login/lock-screen unlock, but never satisfies the wallet
prompt — only typing the account password does.

Evidence, 2026-08-02 session:

```
Aug 02 07:55:18 ksecretd[18943]: Application "xdg-desktop-portal" using kwallet without parent window!
Aug 02 11:06:29 ksecretd[18265]: Application "xdg-desktop-portal" using kwallet without parent window!
```

Multiple apps independently trigger it — Bitwarden (flatpak), Podman Desktop
(flatpak, Electron/NAPI), and VS Code all hit the portal's Secret Service
path and each produced their own errors when kwalletd wasn't reachable/
unlocked:

```
flatpak[2680]: ERROR:dbus/object_proxy.cc:572 Failed to call method: org.kde.KWallet.isEnabled
flatpak[2680]: ERROR:components/os_crypt/sync/kwallet_dbus.cc:113 Error contacting kwalletd6 (isEnabled)
```

## Root cause

**Ruled out first:** not `sudo`/polkit. `polkit.service` and
`plasma-polkit-agent.service` logs show only normal startup — no
authorization-check or auth-agent activity correlating with the prompts.
Not `xdg-desktop-portal` misbehaving either — it's correctly relaying a
Secret Service request to KWallet; the lock is downstream in KWallet itself.

**Confirmed:** the lock-screen/unlock PAM service used for face-auth,
`/etc/pam.d/kde-fingerprint`, has no reference to `pam_kwallet5.so`
anywhere, in either the `auth` or `session` stack:

```
auth        sufficient    pam_exec.so /usr/local/bin/face-auth
auth        substack      fingerprint-auth
auth        include       postlogin
...
session     include       fingerprint-auth
session     include       postlogin
```

Unlocking via face-auth through this stack never touches KWallet at all —
it can't auto-unlock it *or* re-lock it.

More fundamentally, this isn't just a missing line: `pam_kwallet5` unlocks
the wallet by capturing the **plaintext password** during the PAM auth
phase and using it to derive the wallet's Blowfish key. A face embedding
isn't a password — wiring `pam_kwallet5` into `kde-fingerprint` wouldn't
give it anything to decrypt with even if added. Password-based auth is the
only PAM path that can feed it.

**Confirmed via audit log:** this morning's greeter login *did* go through
plain `pam_unix` (password), not fingerprint/face:

```
audit[1499]: op=PAM:authentication grantors=pam_unix acct="karanshukla" exe="/usr/libexec/plasmalogin-helper"
```

So a real password was available at boot login. Whether that password
actually reached `pam_kwallet5` to unlock the wallet is unresolved — see
next paragraph.

**Open uncertainty, not yet resolved:** `pam_kwallet5.so` (package
`pam-kwallet-6.7.3-1.fc44`) is installed at
`/usr/lib64/security/pam_kwallet5.so`, but a full grep of `/etc/pam.d/*`
(`system-auth`, `password-auth`, `login`, `kde-fingerprint`, `kde`) found
**zero** references to it. The package itself ships no PAM template —
only the `.so`, `plasma-kwallet-pam.service`, and an XDG autostart entry
(`pam_kwallet_init.desktop`) that runs `pam_kwallet_init` (a `socat`-based
helper) inside the session. `plasmalogin-helper` (the greeter binary)
references a PAM service literally named `plasmalogin`
(string-verified via `strings`), but `/etc/pam.d/plasmalogin` **does not
exist** on this system — yet login still authenticates successfully via
`pam_unix`. The exact code path connecting greeter-time password capture to
`pam_kwallet_init`'s socket handshake was not traced to certainty, and
guessing wrong here risks a login lockout if acted on. No `with-kwallet`
`authselect` feature exists on this system (`authselect list-features
local` — only `with-pam-gnome-keyring`, GNOME's equivalent, is available).

Also relevant: `kwalletrc` already has `Close When Idle=false` and
`Close on Screensaver=false`, so if the wallet does get one full unlock
per boot, it should stay unlocked through every subsequent face-auth
screen unlock for the rest of the session — repeated prompts would mean
it never got that first unlock, not that something is re-locking it.

## Fix/workaround

**Not yet applied.** Next step is a cheap, reversible test rather than a
PAM edit: manually type the account password the next time KWallet
prompts, and observe whether it stops prompting for the rest of that boot
session. If it does, this was a "one manual unlock per boot" annoyance,
not a real repeat-prompt bug, and no PAM change is needed.

If prompts persist after that test, the considered options are:

1. **Custom `authselect` feature** adding `pam_kwallet5` to
   `system-auth`/`password-auth` properly (not hand-editing the
   authselect-generated files directly, which get silently overwritten).
   Correct blast radius awareness: `system-auth` is `include`d by `sudo`,
   `su`, `sshd`, cron, and `login` — much broader than the existing
   single-file `pam_exec.so` face-auth insertions in `sudo`/`polkit-1`/
   `kde-fingerprint` (see [README.md](README.md)), which only affect their
   one command each.
2. Switch KWallet's backend to a GPG-keyed wallet instead of
   password-derived Blowfish, decoupling it from PAM login entirely.
3. Disable KWallet encryption (blank password) — rejected: pure security
   regression, inconsistent with the TPM2/LUKS auto-unlock work already
   done on this machine (see
   [../disk-encryption/tpm2-luks.md](../disk-encryption/tpm2-luks.md)).

Option 1 is preferred if the cheap test fails, but needs the
`plasmalogin`/`pam_kwallet_init` handshake traced to certainty first —
don't touch `system-auth` blind.

## For a bug report

This isn't clearly a distro/KDE bug so much as a structural interaction:
KWallet's password-derived unlock is fundamentally incompatible with
biometric-only login, and Fedora ships no `authselect` feature or PAM
template to bridge password-based KWallet unlock onto a
fingerprint/face-first auth stack. Worth raising with KDE (`kwallet-pam`)
as a feature request — auto-unlock KWallet via a secondary factor (e.g.,
release a stored key after a successful biometric auth, similar in shape
to how TPM2-sealed LUKS auto-unlock works) rather than requiring the raw
account password specifically.
