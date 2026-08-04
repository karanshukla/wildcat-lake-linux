# KWallet doesn't auto-unlock with face-auth login/unlock

**Status (2026-08-03, updated): unresolved, accepted as a known upstream
KDE bug, no local fix pursued.** Original root cause theory (face-auth
bypasses `pam_kwallet5`) falsified — reproduced with face-auth disabled.
Root cause is a boot-time race between `pam_kwallet_init`'s ephemeral
credential socket and `kwalletd`'s lazy D-Bus-activated startup, confirmed
as a long-standing, still-open KDE bug (bugs.kde.org #433223, #416461,
recurring into Plasma 6.18) rather than a local misconfiguration. One
candidate local workaround was tried and reverted — see "2026-08-02 update"
below. **2026-08-03 update:** confirmed reprompting *within* a single
session (not just once per boot) — each portal connection can spin up its
own independently-locked `ksecretd` instance, and Bitwarden's autostarted
Flatpak app is the identified repeat offender; see that section below.

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

## 2026-08-02 update: reproduced with face-auth disabled

The prompt recurred at 13:24–13:26 in a session where face-auth was
explicitly disabled beforehand — greeter login this boot went through plain
`pam_unix` password auth via the `plasmalogin` PAM service, not
fingerprint/face. This falsifies the original theory that biometric login
bypassing `pam_kwallet5` was the (sole) root cause: the wallet failed to
auto-unlock even on a pure password login where `pam_kwallet5` ran the full
auth/setcred/session stack.

**Correction to prior "open uncertainty":** the previous investigation
concluded no PAM service or template wired in `pam_kwallet5` for the greeter,
based on `/etc/pam.d/plasmalogin` not existing. That check missed Fedora's
vendor PAM directory — `/usr/lib/pam.d/plasmalogin` (shipped by
`plasma-login-manager-6.7.3-4.fc44`) does exist and does include it:

```
-auth        optional      pam_kwallet5.so
...
-session     optional      pam_kwallet5.so auto_start
```

Journal confirms it actually ran this boot:

```
13:15:14 plasmalogin-helper[1551]: pam_kwallet5(plasmalogin:auth): pam_sm_authenticate
13:15:14 plasmalogin-helper[1551]: pam_kwallet5(plasmalogin:setcred): pam_sm_setcred
13:15:15 plasmalogin-helper[1551]: pam_kwallet5(plasmalogin:session): pam_sm_open_session
13:15:15 plasmalogin-helper[1595]: pam_kwallet5: final socket path: /run/user/1000/kwallet5.socket
13:15:16 systemd[1559]: Started plasma-kwallet-pam.service - Unlock kwallet from pam credentials.
```
`audit[1551]` for this session shows `grantors=...,pam_unix,pam_kwallet5,...`
for `exe=plasmalogin-helper` — full password-based PAM wiring, working as
designed.

**New evidence — timing race:** `plasma-kwallet-pam.service` (which execs
`pam_kwallet_init`, the `socat`-based credential-socket server) started and
*exited* in 517ms:

```
Aug 02 13:15:16 systemd[1559]: Started plasma-kwallet-pam.service
Aug 02 13:15:16 pam_kwallet_init[2051]: socat[2051] W address is opened in read-write mode but only supports read-only
    Active: inactive (dead) since Sun 2026-08-02 13:15:16 EDT
    Duration: 517ms
```

But `kwalletd6` itself wasn't started until **13:15:18** — 2+ seconds later,
via D-Bus activation on the first real Secret Service/KWallet call, not
eagerly at login:

```
13:15:18 systemd[1559]: Started dbus-:1.1-org.kde.kwalletd6@0.service.
```
(confirmed via `ps -o lstart` on the live `kwalletd6` PID: started
`13:15:18`)

So `pam_kwallet_init`'s listener was already gone by the time `kwalletd6`
came up to read the handed-off password — a ~1.5s gap where nothing was
listening on `/run/user/1000/kwallet5.socket` for `kwalletd6` to connect to.
`kwalletd6` starts locked, with no memory of the login password, and the
manual prompt (this issue) is the result. The `socat ... read-write ...
read-only` warning is a red herring — it appears on every single boot in the
journal history checked (2026-07-25 through today), including boots that
presumably didn't reprompt, so it's not diagnostic on its own.

Confirmed live during this investigation (13:26, ~11 min after login):
`org.kde.KWallet.isOpen kdewallet` over D-Bus returned `false`.

**Confirmed known upstream issue, not local misconfiguration:** this exact
race (`kwalletd` D-Bus-activated on demand, activated too late to receive
the PAM-captured password) is a long-standing, still-unresolved KDE bug
across multiple Plasma major versions — [bugs.kde.org #433223](https://bugs.kde.org/show_bug.cgi?id=433223)
("KWallet doesn't unlock automatically when user logs in"),
[#416461](https://bugs.kde.org/show_bug.cgi?id=416461) (same, on 5.18), and
still surfacing as of Plasma 6.18
([NixOS#446596](https://github.com/NixOS/nixpkgs/issues/446596)).

**Ruled out: `org.freedesktop.secrets` D-Bus service file.** A commonly
suggested workaround (add
`~/.local/share/dbus-1/services/org.freedesktop.secrets.service` pointing
at `kwalletd6`, to force earlier activation) was tried and reverted on
2026-08-02. Checked via `busctl --user list` first: on this system
(`kf6-kwallet-6.28.0-1.fc44`) `org.freedesktop.secrets` is owned by
**`ksecretd`**, a separate process from `kwalletd6` — `kwalletd6` only owns
`org.kde.kwalletd`/`kwalletd5`/`kwalletd6`. Pointing that busname's service
file at `kwalletd6` would misfire if it were ever activated on-demand (spawns
a process that doesn't implement the requested interface, request times out
instead of failing over to the real backend) — a new failure mode, not a
fix. More fundamentally it doesn't touch the actual bug anyway:
`org.kde.kwalletd6.service` already exists and already works (it's what
activated `kwalletd6` at 13:15:18 in the logged boot); the problem was never
missing activation plumbing, it's that the already-working activation fires
after `pam_kwallet_init`'s credential window has closed. A service file for
an unrelated busname can't change that timing. Removed the file; confirmed
`org.freedesktop.secrets` ownership (PID) was unaffected before/after.

**Next step:** given this is confirmed as upstream's unresolved race rather
than something wrong in this system's config, not chasing a local fix
further — the fix has to land in `kwallet-pam`/`plasma-workspace` itself.
Treating this as accepted: type the password once per boot when it prompts,
`kwalletrc`'s idle/screensaver auto-close being off means it should hold for
the rest of the session. Revisit only if upstream ships a fix, or if it
starts reprompting *within* a session rather than once per boot.

## 2026-08-03 update: reprompts within a single session, not just once per boot

The 2026-08-02 update's closing note said this should be revisited "if it
starts reprompting *within* a session rather than once per boot." That
happened tonight: two separate prompts, 21:20:26 and 21:28:52, 8 minutes
apart, same boot, well past the login window.

**Root cause extension — the portal's `kwallet` backend isn't a shared
singleton.** `org.freedesktop.impl.portal.desktop.kwallet` is activated as a
fresh transient systemd service per connection (`dbus-:1.1-...@0.service`,
`@1.service`, incrementing), each spawning its own independent `ksecretd`
process with its own independent lock state — confirmed live: two `ksecretd`
PIDs (10392, 14432) running simultaneously, `org.freedesktop.Secret.Collection
Locked` true on the current one despite an earlier instance having already
been unlocked/prompted this session. This is a different (and separate)
process from `kwalletd6` (confirmed previously) — `kwalletd6`'s own `isOpen
kdewallet` also independently reads `false` right now, so neither backend
ever got the PAM-handed-off password this boot, and each is locked on its own
schedule. "Type the password once and it holds" only works if nothing ever
opens a second independent portal connection for the rest of the boot — not a
safe assumption.

**Repeat offender identified: Bitwarden's Flatpak app.** `com.bitwarden.desktop`
autostarts at login (`/app/Bitwarden/bitwarden-app --autostart ...`, PID 2829)
and is running as *two* parallel sandboxed instances (`flatpak ps` shows two
separate app IDs under `com.bitwarden.desktop`). It's spamming a failed
`ashpd`/zbus property-watch retry once a second:

```
flatpak[2829]: [NAPI] [WARN] zbus::proxy: Failed to populate properties cache
via GetAll: org.freedesktop.DBus.Error.UnknownMethod: Object does not exist
at path "/org/freedesktop/portal/desktop/request/1_128/ashpd_wPY0vGT2R1"
```

That retry churn correlates with the fresh portal-backend spawns that produced
tonight's two separate prompts. Not fully root-caused to certainty (didn't
trace the exact ashpd call graph), but Bitwarden is the only flatpak app
actively cycling portal connections in the background between the two prompt
timestamps, and it's the same app the 2026-08-02 entry already flagged as one
of the multiple apps hitting this path.

**Revised guidance:** still accepted, still no local fix pursued (same
upstream-race root cause, now shown to recur mid-session rather than once).
Practical expectation update: don't expect one manual unlock to hold for the
whole session — with Bitwarden's Flatpak autostarted, a second or third prompt
in the same boot is plausible. If this becomes annoying enough to revisit,
the cheapest lever is disabling Bitwarden's Flatpak autostart (trades away
auto-launch for fewer cold portal-backend spawns), not a KWallet/PAM change.

## For a bug report

Already reported upstream, no action needed from this end beyond linking
evidence if asked: [bugs.kde.org #433223](https://bugs.kde.org/show_bug.cgi?id=433223)
and [#416461](https://bugs.kde.org/show_bug.cgi?id=416461) describe the same
race (`kwalletd` D-Bus-activated on demand, too late to receive the
PAM-captured password), and it's still recurring in Plasma 6.18
([NixOS#446596](https://github.com/NixOS/nixpkgs/issues/446596)). This
machine's logs are a clean confirming data point if a maintainer wants
fresh evidence: `/usr/lib/pam.d/plasmalogin` correctly wires in
`pam_kwallet5.so auto_start`, the full auth/setcred/session stack ran this
boot via plain `pam_unix` (no biometric auth involved), and
`pam_kwallet_init`'s `socat`-based credential listener exited (~517ms) a
full 1.5s+ before `kwalletd6` was D-Bus-activated (~2s after login, on first
real Secret Service call) — a clean window where the handed-off password
had nowhere to land. The original biometric-incompatibility angle
(`kde-fingerprint` PAM stack has no `pam_kwallet5` hook, and a face
embedding isn't a password `pam_kwallet5` could use anyway) is still true
and could still be its own feature request, but it is not what's causing
this specific recurring prompt — see the 2026-08-02 update above.
