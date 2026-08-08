# `thermald` has no Wildcat Lake entry, exits on every boot

**Status:** Fixed locally 2026-08-07 (one-line patch to the model table,
built and running via a systemd drop-in). Not yet filed upstream. Unlike
the sibling `intel_idle` gap ([intel-idle-no-wildcat-lake-entry.md](intel-idle-no-wildcat-lake-entry.md)),
this one **is** just table lag and is safe to patch, for a reason worth
understanding: thermald's entry asserts nothing about the silicon. See
"Why this one is patchable" below.

Net effect is a **performance** change, not a cooling one: sustained
power ceiling went 15W → 25W. Read "What this actually changed" before
assuming this made the laptop run cooler. It did not.

Load-tested 2026-08-07: the throttle-*down* half of the control loop
never fires under CPU load, because GDDV binds the passive trip to
`SEN1`, a platform thermistor that saturates ~26°C below the die. So the
practical effect is the power uplift alone.

## Symptom

`thermald.service` starts at boot and immediately exits. It reports
success, so nothing looks wrong unless you go looking:

```
$ sudo systemctl status thermald
○ thermald.service - Thermal Daemon Service
     Active: inactive (dead) since Fri 2026-08-07 22:26:19 EDT
    Process: 955 ExecStart=/usr/bin/thermald --systemd --dbus-enable --adaptive
   Main PID: 955 (code=exited, status=0/SUCCESS)

thermald[955]: 40 CPUID levels; family:model:stepping 0x6:d5:1 (6:213:1)
thermald[955]:  Need Linux PowerCap sysfs
thermald[955]: Unsupported cpu model or platform
thermald[955]: Try option --ignore-cpuid-check to disable this compatibility test
systemd[1]: thermald.service: Deactivated successfully.
```

`status=0/SUCCESS` and "Deactivated successfully" are the reason this
went unnoticed for so long. The daemon calls `exit(EXIT_SUCCESS)` on the
unsupported-CPU path, so systemd sees a clean exit, `Restart=on-failure`
never triggers, and the unit stays `enabled` while doing nothing. This is
the same daemon already noted in passing as not recognizing this chip in
[s3-deep-sleep-hang.md](s3-deep-sleep-hang.md#root-cause).

Fedora package version at time of writing: `thermald 2.5.9`.

## Root cause

Model `0xD5` is absent from thermald's own supported-CPU table.

```c
/* src/thd_platform_intel.cpp */
static supported_ids_t intel_id_table[] = {
    ...
    { 6, 0xcc, 1 }, // Panther Lake L
    { 15, 0x01, 1 }, // Nova Lake S      <- 0xd5 should be between these
    { 15, 0x03, 1 }, // Nova Lake U/P/H/Hx
    { 0, 0, 0 }
};
```

`check_cpu_id()` walks that table, finds no match, `processor_id_match()`
returns false, and `cthd_engine_adaptive::thd_engine_init()` bails:

```c
/* src/thd_engine_adaptive.cpp:670 */
if (!ignore_cpuid_check) {
    check_cpu_id();
    if (!processor_id_match()) {
        thd_log_msg("Unsupported cpu model or platform\n");
        thd_log_msg("Try option --ignore-cpuid-check to disable this compatibility test\n");
        exit(EXIT_SUCCESS);
    }
}
```

That is the whole failure. It is a lookup table, nothing more.

### The PowerCap message is a red herring

` Need Linux PowerCap sysfs` reads like a missing-kernel-feature
diagnosis. It is not. `src/thd_platform_intel.cpp:157` prints it
unconditionally on any table miss, without ever checking whether powercap
exists:

```c
if (!valid) {
    thd_log_msg(" Need Linux PowerCap sysfs\n");
}
```

Ruled out explicitly, since chasing it would have been the obvious wrong
turn. Powercap is present and fully populated:

```
$ ls /sys/class/powercap/
intel-rapl  intel-rapl:0  intel-rapl:0:0  intel-rapl:0:1  intel-rapl:0:2
intel-rapl:1  intel-rapl-mmio  intel-rapl-mmio:0  intel-rapl-mmio:0:0
```

### Everything else the adaptive path needs was already present

Verified before patching, to confirm that clearing the CPUID gate would
not just move the failure one step later:

| Requirement | Source | Present |
|---|---|---|
| `int3400 thermal` driver bound | `/sys/bus/platform/drivers/int3400 thermal/` | `INTC10FC:00` |
| `firmware_node/path` | `INTC10FC:00/firmware_node/path` | `\_SB_.IETM` |
| GDDV data vault | `INTC10FC:00/data_vault` | 1208 bytes |
| RAPL powercap sysfs | `/sys/class/powercap/` | MSR + MMIO |
| ACPI platform profile | `/sys/firmware/acpi/platform_profile_choices` | `low-power balanced performance` |

Note that thermald discovers INT3400 by scanning the driver directory for
any entry starting with `INT` (`set_int3400_base_path()`), so the newer
`INTC10FC` ACPI ID needed no special handling. `available_uuids` reads
`UNKNOWN` and `current_uuid` reads `INVALID`, which is normal on recent
client platforms where policy comes from GDDV rather than UUID selection.

## Why this one is patchable and `intel_idle` isn't

This is the interesting part, and the reason these two docs reach
opposite conclusions about sending a patch.

The `intel_idle` entry for a platform is a **table of measured
silicon-specific constants** (exit latencies, target residencies).
Asserting Panther Lake's numbers fit Wildcat Lake would be a guess, which
is exactly why upstream rejected doing so and why no patch was sent.

thermald's entry is a **three-field tuple**, and the third field settles
it:

```c
typedef struct {
    unsigned int family;
    unsigned int model;
    unsigned int adaptive_only;
} supported_ids_t;
```

Every recent client platform (Lunar Lake, Arrow Lake, Panther Lake, Nova
Lake) is marked `adaptive_only = 1`, meaning thermald carries **no
thermal constants for it at all**. It reads the platform's own GDDV
tables out of firmware at runtime and implements whatever those say.
Adding `{ 6, 0xd5, 1 }` therefore asserts exactly one thing: *this
platform is driven by its own firmware tables.* That is not a guess about
silicon, and it is empirically confirmed by the daemon then successfully
parsing this machine's GDDV and naming a real target
(`Balance Mode-28C`).

So: `intel_idle` needs measurement on real hardware before a patch is
defensible. thermald needs a line in a list.

## Fix

One line, alongside the other adaptive-only platforms:

```diff
     { 6, 0xcc, 1 }, // Panther Lake L
+    { 6, 0xd5, 1 }, // Wildcat Lake L
     { 15, 0x01, 1 }, // Nova Lake S
```

Local branch `add-wildcat-lake-support` (commit `198cca6`) on a clone of
[intel/thermal_daemon](https://github.com/intel/thermal_daemon), built
from master at `2d93d94` (version 2.5.12-rc1).

Build deps beyond a stock Fedora 44 toolchain:

```bash
sudo dnf install -y gtk-doc libevdev-devel autoconf-archive
./autogen.sh && make -j$(nproc)
```

### Install without fighting the package manager

The Fedora unit runs `/usr/bin/thermald`, which `dnf` owns. Rather than
overwrite it (next update reclaims it), install the built binary
alongside and repoint the unit with a drop-in:

```bash
sudo install -m 0755 ./thermald /usr/local/bin/thermald
sudo restorecon -v /usr/local/bin/thermald
sudo mkdir -p /etc/systemd/system/thermald.service.d
```

`/etc/systemd/system/thermald.service.d/override.conf`:

```ini
[Service]
ExecStart=
ExecStart=/usr/local/bin/thermald --systemd --dbus-enable --adaptive
```

The empty `ExecStart=` is required; systemd rejects a second `ExecStart`
on a non-oneshot service without first clearing the inherited one.

```bash
sudo systemctl daemon-reload && sudo systemctl restart thermald
```

SELinux is a non-issue here, checked rather than assumed: `/usr/bin/thermald`
is `bin_t` and `matchpathcon /usr/local/bin/thermald` also resolves to
`bin_t`, with no dedicated thermald domain in policy. The `restorecon` is
there only because copying out of `$HOME` would otherwise carry
`user_home_t`.

D-Bus activation has no gap either:
`/usr/share/dbus-1/system-services/org.freedesktop.thermald.service` sets
`Exec=/bin/false` and `SystemdService=dbus-org.freedesktop.thermald.service`,
so bus-activated starts route through systemd and pick up the override
too. The packaged D-Bus policy, `tmpfiles.d` entry for `/run/thermald`,
and `/etc/thermald` all stay in place untouched.

Confirmed running:

```
$ systemctl status thermald
● thermald.service - Thermal Daemon Service
     Active: active (running) since Fri 2026-08-07 22:36:51 EDT
    Drop-In: /etc/systemd/system/thermald.service.d
             └─override.conf
   CGroup: └─15496 /usr/local/bin/thermald --systemd --dbus-enable --adaptive

thermald[15496]: 40 CPUID levels; family:model:stepping 0x6:d5:1 (6:213:1)
thermald[15496]: Polling mode is enabled: 4
```

### Revert

```bash
sudo rm -rf /etc/systemd/system/thermald.service.d /usr/local/bin/thermald
sudo systemctl daemon-reload && sudo systemctl restart thermald
```

## What this actually changed

Worth being blunt, because the intuitive reading ("thermal daemon now
works, so the laptop runs cooler") is backwards.

| | Before (thermald dead) | After |
|---|---|---|
| MMIO PL1 | 15W, static | 15W floor, 25W ceiling, dynamic |
| Governed by | nothing in userspace | GDDV `Balance Mode-28C` |
| Passive trips | unused | 54°C / 55°C on SEN1 → `rapl_controller_mmio` (thermald-internal, see below) |

Those 54/55°C trips are **thermald's own**, built from GDDV and polled
internally. They are not kernel thermal-zone trips, and looking for them
in sysfs is misleading: `thermal_zone2` (SEN1) advertises its two passive
trips as disabled, with only the firmware backstops populated.

```
$ cd /sys/class/thermal/thermal_zone2   # SEN1
$ cat trip_point_0_temp trip_point_1_temp    # the two "passive" trips
-274000
-274000
$ cat trip_point_2_type trip_point_2_temp    # firmware backstop
critical
110050
```

Measured delta on
`/sys/devices/virtual/powercap/intel-rapl-mmio/intel-rapl-mmio:0/constraint_0_power_limit_uw`:
`15000000` before, `25000000` after. thermald read the firmware's
`PL1MAX 25000` / `PL1MIN 15000` and raised the sustained power ceiling by
10W.

So under sustained load this machine now draws more power and runs
*warmer* than it did with thermald broken. The old static 15W cap
"protected" it by never letting it approach a trip at all. What the fix
buys is a closed loop in place of a blunt cap: above 54°C thermald walks
PL1 back toward the 15W floor in 500mW steps, and releases it as things
cool. In practice that downward branch never fires here, for reasons in
"The throttle-down path is dormant" below, so the working effect is
simply a higher sustained ceiling.

This was never a safety issue in either direction. Kernel thermal core,
ACPI firmware trips, and hardware PROCHOT/TCC throttling all operate
independently of thermald. A dead thermald was costing performance, not
risking hardware.

### Reading the log without being misled

Two things in `--loglevel=info` output look like bugs and are not.

**RAPL state climbing past `max_state`.** Log lines read
`curr_state:20000000, max_state:15000000`, which looks like a ceiling
being violated. `max_state` in the RAPL cooling device is **inverted**:
it is the power *floor*, not the cap. `src/thd_cdev_rapl.cpp:44` states
it directly ("If request to set a state which less than max_state i.e.
lowest rapl power limit then limit to the max_state"). GDDV's
`PL1MIN 15000` becomes `max_state = 15000000`. The real ceiling is
`phy_max`, from `PL1MAX`. The observed ramp was ordinary unthrottling
toward 25W at 38°C, well under the trip.

**`sysfs write failed tcc_offset_degree_celsius`.** Cosmetic. GDDV asks
for `TccOffset 0`; `/sys/devices/pci0000:00/0000:00:04.0/tcc_offset_degree_celsius`
already reads `0`, and the kernel rejects the redundant write. Nothing
changes either way.

### The throttle-down path is dormant, not merely unverified

Tested 2026-08-07 and **not reproducible by CPU load**, which turns out to
be a property of the platform's policy rather than a gap in testing.

Six cores of `openssl speed -evp aes-256-cbc` for four minutes. SEN1
peaked at **49°C against the 54°C trip** and PL1 never left 25W. A second,
longer soak (roughly seven minutes total, unintentionally) did not move it
either: SEN1 stalled at 50°C.

The reason is which sensor GDDV binds the trip to. `SEN1` is
`\_SB_.IETM.SEN1`, a platform thermistor, not the die. It saturates far
below the silicon:

| Sensor | ACPI path | Peak under sustained 6-core load |
|---|---|---|
| **SEN1** (what the trip watches) | `\_SB_.IETM.SEN1` | **50°C** |
| SEN2 | `\_SB_.IETM.SEN2` | 74°C |
| TCPU | processor thermal device | 75°C |
| `x86_pkg_temp` | package DTS | 76°C |

A ~26°C gap. SEN1 climbed 38 → 49°C over the first four minutes and then
essentially stopped, holding 50°C while the package went a further 17
degrees higher. Any of the other three sensors would have crossed 54°C
within the first two minutes.

So the closed loop described above is real and correctly wired, but on
this platform it is **effectively a hold-at-25W policy**. Reaching the
passive trip would take high ambient temperature or a sustained combined
CPU+GPU load, not CPU work alone. Not worth manufacturing to watch a
counter move, and the practical effect of the fix is the 15W → 25W uplift
with the throttle branch dormant.

Worth flagging if this doc ever feeds an upstream conversation: binding
the passive trip to the slowest-responding sensor in the platform is a
firmware/GDDV choice, not thermald's. thermald implements what it is told.

One oddity recorded rather than explained: thermald writes `25000000`
while `constraint_0_max_power_uw` on the same MMIO domain advertises
`15000000`. The sysfs maximum is evidently advisory, not enforced.

### If cooler is the actual goal

This is the wrong lever. thermald in adaptive mode implements the
firmware's envelope, and this platform's balanced envelope is 25W.
`/sys/firmware/acpi/platform_profile` reads `balanced`, which is why
`Balance Mode-28C` was selected. Setting it to `low-power` should select
a lower-PL1 target. **Untested**: the GDDV targets on this machine have
not been enumerated, so treat that as a lead rather than a finding.

## For a bug report

Not yet filed as of 2026-08-07. This should go upstream as an actual
patch rather than a report, which is the opposite call from `intel_idle`,
for the reason in "Why this one is patchable" above: the change asserts
no silicon-specific values. Precedent is the `intel_lpmd` fix for the
same missing model
([intel/intel-lpmd#123](https://github.com/intel/intel-lpmd/issues/123),
[#124](https://github.com/intel/intel-lpmd/pull/124)).

- Hardware: Dell XPS 13 DX13260, BIOS 1.6.0
- CPU: Intel Core 5 320, family 6 model 213 (`0xD5`) stepping 1
- Kernel 7.1.6-201.fc44.x86_64, Fedora 44
- thermald 2.5.9 (Fedora package) and master `2d93d94` (2.5.12-rc1), both affected
- Platform: `INTC10FC:00` INT3400 with a populated 1208-byte `data_vault`,
  `\_SB_.IETM`, RAPL MSR + MMIO both present
- Ask: add `{ 6, 0xd5, 1 }` to `intel_id_table[]` in
  `src/thd_platform_intel.cpp`, alongside the other adaptive-only client
  platforms
- Evidence it works: with the entry added, thermald parses this machine's
  GDDV, selects target `Balance Mode-28C`, and drives
  `rapl_controller_mmio` between the firmware's own `PL1MIN`/`PL1MAX`

## The wider pattern

Fifth entry in the running tally of Intel tooling that does not know
model `0xD5`, and the second to be fixed locally. The table in
[intel-idle-no-wildcat-lake-entry.md](intel-idle-no-wildcat-lake-entry.md#the-wider-pattern)
is the canonical version.

The useful distinction that keeps emerging: a missing model ID is only
hard to fix when the table behind it holds *measured* values. `intel_idle`
is that case. `thermald`, `intel_lpmd`, and `turbostat` are all just
lookups gating access to logic that would work fine once reached.
