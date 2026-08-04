# Battery charge-limit sysfs attributes fail with I/O errors

Status: **Accepted, not pursued** — root cause identified, no fix applied by choice.

## Symptom

`BAT0` exposes the standard Linux charge-threshold sysfs attributes —
`charge_control_start_threshold`, `charge_control_end_threshold`, and
`charge_types` — but every read or write against them fails:

```
$ cat charge_control_end_threshold
cat: charge_control_end_threshold: No such device or address   # ENXIO
$ cat charge_control_start_threshold
cat: charge_control_start_threshold: No such device or address # ENXIO
$ cat charge_types
cat: charge_types: Input/output error                          # EIO
$ echo 80 | sudo tee charge_control_end_threshold
tee: charge_control_end_threshold: No such device or address   # ENXIO
```

Nothing charge-related ever lands in `~/.config/powerdevilrc` either — KDE
PowerDevil's own attempts to set a limit fail the same way, silently. Its
`org.kde.powerdevil.chargethresholdhelper` D-Bus helper is active, so Plasma
believes the capability exists.

## Root cause

The `dell_laptop` kernel module is loaded and has correctly registered a
battery hook against the generic ACPI battery device (`PNP0C0A`) — that's why
the sysfs attributes exist at all. Per the upstream kernel patch that
implements this
(["platform/x86:dell-laptop: Add knobs to change battery charge settings"](https://lkml.iu.edu/hypermail/linux/kernel/2408.2/04555.html)),
they're backed by two Dell SMBIOS tokens — `BAT_CUSTOM_CHARGE_START`
(`0x0349`) and `BAT_CUSTOM_CHARGE_END` (`0x034A`) — read via
`dell_send_request_for_tokenid()`.

Initial theory was that Dell hadn't implemented these tokens at all in this
BIOS build, by analogy with the [CS35L56 sidecar-amp
quirk](../audio/cs35l56-sidecar-amp-quirk.md) (a genuine early-Wildcat-Lake
firmware gap). That was ruled out: BIOS Setup (Advanced tab, InsydeH2O),
photographed 2026-08-04, confirms `Battery Charge Configuration` is a real,
present option — currently set to the factory-default `ExpressCharge™`, not
`Custom`. The `BAT_CUSTOM_CHARGE_START/END` tokens are only live when this
mode is `Custom`; on `ExpressCharge™` there's nothing for the OS-side
threshold calls to act on, which produces the ENXIO/EIO exactly. Driver code
is correct; the failure is one layer down, in the SMBIOS call itself, gated
by BIOS-side charge mode.

(A separate `Advanced Battery Charge Configuration` entry, currently
`Disabled`, is a different feature — scheduled/conditional charging — not
required for the basic threshold.)

BIOS is `1.3.0` (2026-06-25) on `XPS 13 DX13260`; not that it matters for this
particular issue, since the fix is a BIOS *setting*, not a BIOS *update*.

## Decision: not pursued

The fix would be switching `Battery Charge Configuration` → `Custom` in BIOS
Setup, which trades `ExpressCharge™`'s faster charging for the ability to cap
max state-of-charge (e.g. stop at 80%) to reduce long-term battery wear.
Deliberately left as-is: battery longevity isn't a priority here, so there's
no reason to give up faster charging for a benefit that doesn't matter in
this case.

## For a bug report

Not applicable — this isn't a bug. The driver, ACPI hook, and KDE integration
are all working correctly; the sysfs failure is the expected behavior of
`dell_laptop`'s custom-charge tokens when the BIOS charge mode isn't set to
`Custom`. Anyone hitting the same ENXIO/EIO pattern on a Dell laptop should
check `Battery Charge Configuration` in BIOS Setup before assuming a
driver/firmware gap.
