# `intel_idle` has no Wildcat Lake entry, falls back to ACPI `_CST`

**Status:** Open, reported upstream. Not the S0ix blocker — see
[s0ix-never-entered.md](s0ix-never-entered.md). A cheap test exists
(`intel_idle.table=`) but was deliberately not run; see "Untested
hypothesis" below. Found 2026-08-05.

## Symptom

`intel_idle` loads, finds no model match for this CPU, and builds its
C-state list from ACPI `_CST` instead of a native table:

```
$ cat /sys/devices/system/cpu/cpuidle/current_driver
intel_idle

$ for s in /sys/devices/system/cpu/cpu0/cpuidle/state*/; do \
    echo "$(cat $s/name) $(cat $s/desc)"; done
POLL     CPUIDLE CORE POLL IDLE
C1_ACPI  ACPI FFH MWAIT 0x0
C2_ACPI  ACPI FFH MWAIT 0x21
C3_ACPI  ACPI FFH MWAIT 0x60
```

The `_ACPI` suffixes and `ACPI FFH MWAIT` descriptions are the fallback
path. A recognized platform gets states named `C1`, `C1E`, `C6S`, `C10`.

Surfaced by [intel/S0ixSelftestTool](https://github.com/intel/S0ixSelftestTool),
which is worth running on this machine even though its own verdict is
unreliable (see "What the tool got wrong" below).

## Root cause

The model exists in the family header but not in the driver's match
table.

```c
/* arch/x86/include/asm/intel-family.h */
#define INTEL_WILDCATLAKE_L    IFM(6, 0xD5)      /* present */

/* drivers/idle/intel_idle.c — match table ends at: */
X86_MATCH_VFM(INTEL_PANTHERLAKE_L, &idle_cpu_ptl),   /* no WCL entry */
```

Panther Lake was added 2026-03-11 (`intel_idle: Add Panther Lake
C-states table`). `INTEL_PANTHERLAKE_R` (0xE5) is also in the family
header and also absent from `intel_idle`, so this looks like the usual
lag between the two rather than anything specific to Wildcat Lake.

## What the fallback actually costs

Not much, and this matters for deciding whether to chase it. Against
`ptl_cstates`, the nearest existing table:

- **C1** matches exactly.
- **C6S** carries the same MWAIT `0x21` hint, timings differ (127us/381us
  here vs 300us/300us).
- **C1E** (MWAIT `0x01`) is not exposed at all.
- **C10** has the correct MWAIT `0x60` hint but is advertised at 1048us
  exit latency / 3144us target residency, vs ptl's 370us / 2500us.

The MWAIT hints themselves are correct, so no state is unreachable. C10
is entered heavily already — 701,765 entries and 1,022 seconds over ~2h
uptime on cpu0.

Quantifying the upside before spending anything on it: `C2_ACPI`
averages ~498us per entry (867,104,684us / 1,739,573), far below either
C10 target residency. So relaxing 3144 → 2500 would promote very little
of that bucket. The missing C1E is probably the larger of the two gaps.

## No DKMS route

```
$ grep INTEL_IDLE /boot/config-$(uname -r)
CONFIG_INTEL_IDLE=y

$ modinfo intel_idle
modinfo: ERROR: Module intel_idle not found.
```

Built into `vmlinuz`, not a module. The approach that worked for
CS35L56 ([../audio/cs35l56-sidecar-amp-quirk.md](../audio/cs35l56-sidecar-amp-quirk.md))
does not apply — there is nothing for DKMS to build or MOK to sign.
Patching this locally means a full kernel rebuild plus re-signing
`vmlinuz` on every kernel update.

## Untested hypothesis: `intel_idle.table=`

`intel_idle` gained a boot parameter on 2026-01-07 (`intel_idle: Add
cmdline option to adjust C-states table`) that rewrites latency and
residency values without a rebuild:

```bash
sudo grubby --update-kernel=ALL --args="intel_idle.table=C2_ACPI:300:300,C3_ACPI:370:2500"
```

It applies here. `cmdline_table_adjust()` is called after
`intel_idle_cpuidle_driver_init()` and operates on the built driver
table regardless of whether it came from a native table or `_CST`.

Two limits:

- It matches states **by name** and only edits existing ones
  (`pr_err("C-state '%s' was not found\n", name)`). It cannot add C1E,
  which is the larger gap.
- Results can't be validated at the package level, since `turbostat`
  also lacks model 0xD5 and can't read PC-state residency.

**Risk if the ptl timings are wrong for this silicon:** `exit_latency`
feeds PM QoS, which is how drivers cap how deep the governor may idle.
Advertising C10 at 370us when it really takes 1048us would let a driver
holding a 500us constraint permit C10 wrongly. Symptom would be audio
underruns or USB isochronous drops, not data loss, and it reverts with
`--remove-args`.

Worth noting the BIOS values are not uniformly conservative: `C2_ACPI`
advertises **127us against ptl's 300us**, i.e. more aggressive, while
C3_ACPI is more conservative. So "the OEM padded everything" doesn't
hold, and neither source is obviously the safer one.

Deliberately not run (2026-08-05). Low risk, low measurable reward, and
it does not touch S0ix either way. Baseline captured before deciding, in
case this is revisited.

## Not the S0ix blocker

Worth stating plainly, since the two look related and aren't. S0ix needs
the cores in CC10; they are already getting there (701,765 C10 entries).
The binding blocker is CSE/ME firmware, confirmed independent of the host
`mei` driver across three measurements. See
[s0ix-never-entered.md](s0ix-never-entered.md). Fixing this doc's issue
would not move `substate_residencies` off zero.

## What the tool got wrong

`S0ixSelftestTool` reports "Your system did not achieve PC2 state or PC2
residency is low". Ignore that verdict. Its own output shows why:

```
The system does not support the Pkg%pc2.
The system does not support the Pkg%pc3.
The system does not support the Pkg%pc6.
The system does not support the Pkg%pc8.
```

That is `turbostat` not knowing which MSRs to read on model 0xD5, not
the hardware failing to reach those states. Package C-states are simply
unmeasurable here today.

What the tool did independently confirm is `SYS%LPI 0.00`, corroborating
the zero S0ix residency from a source other than `pmc_core`.

## For a bug report

Reported to `linux-pm@vger.kernel.org` (maintainers Rafael J. Wysocki,
Artem Bityutskiy; `R:` Len Brown). Sent as a report rather than a patch:
target residencies are silicon-specific and can't be verified from
outside Intel, so asserting `ptl_cstates` fits Wildcat Lake would be a
guess.

- Hardware: Dell XPS 13 DX13260, BIOS 1.3.0 (2026-06-25)
- CPU: Intel Core 5 320, family 6 model 213 (`0xD5`) stepping 1
- Kernel 7.1.6-201.fc44.x86_64, `CONFIG_INTEL_IDLE=y`,
  `CONFIG_ACPI_PROCESSOR_CSTATE=y`
- No `intel_idle` module parameters set (`no_acpi=N`, `use_acpi=N`,
  `no_native=N`, `states_off=0`, `max_cstate=9`)
- Ask: add an entry for 0xD5 with the correct table for the silicon

## The wider pattern

Fourth piece of Intel tooling found not to know model 0xD5:

| Tool | Symptom | Status |
|---|---|---|
| `intel_lpmd` | "Platform not supported yet", exits on every boot | [intel/intel-lpmd#123](https://github.com/intel/intel-lpmd/issues/123), fix proposed in [#124](https://github.com/intel/intel-lpmd/pull/124) |
| `thermald` | "Unsupported cpu model or platform" | Not filed |
| `turbostat` | Can't read package C-state residency | Not filed |
| `intel_idle` | Falls back to ACPI `_CST` | Reported to linux-pm 2026-08-05 |
