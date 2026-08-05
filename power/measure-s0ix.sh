#!/bin/bash
# Measure whether the platform reaches any S0ix substate across a real
# suspend, and which components asserted a power requirement during it.
#
# See s0ix-never-entered.md. A single snapshot of substate_requirements can't
# tell "always required since boot" apart from "actively blocking during this
# specific sleep" — only a before/after delta over one sleep window can. This
# automates that delta.
#
# Two methodology traps this avoids, both documented in the doc:
#   1. `rtcwake -m mem` writes /sys/power/state directly, bypassing logind, so
#      no PrepareForSleep is emitted and none of the delay-inhibitor holders
#      (NetworkManager, ModemManager, UPower, kwin) run their pre-suspend
#      step. Arm the alarm separately, then suspend through logind.
#   2. Free-running reference clocks (XTAL_AGGR_OFF_STS, SOC_PLL_OFF_STS,
#      CLINK/SMT/SMS/AON*) all advance by an identical large amount every
#      cycle and are not blockers. They're flagged below, not hidden, so the
#      real signal is obvious by contrast.
#
# Usage: sudo ./measure-s0ix.sh [sleep_seconds]   (default 90)
#
# Run it under sudo rather than letting it call sudo itself. It needs
# privileged reads both before and after the suspend, and on this machine
# sudo is face-auth backed, so a mid-run reauth prompt can land on a locked
# or blank screen. One auth up front avoids that.

set -uo pipefail

SECS="${1:-90}"
REQ=/sys/kernel/debug/pmc_core/substate_requirements
RES=/sys/kernel/debug/pmc_core/substate_residencies
OUT=$(mktemp -d /tmp/s0ix-measure.XXXXXX)

trap 'rm -rf "$OUT"' EXIT

snapshot() {  # $1 = label
  sudo cat "$REQ" > "$OUT/req-$1" 2>/dev/null
  sudo cat "$RES" > "$OUT/res-$1" 2>/dev/null
}

# Element name -> counter value, one per line.
parse() { awk -F'|' 'NR>1 && NF>1 {
    split($1, a, ":"); name=a[2]; gsub(/^[ \t]+|[ \t]+$/, "", name);
    val=$(NF-1); gsub(/[ \t]/, "", val);
    if (name != "" && val ~ /^[0-9]+$/) print name, val
  }' "$1"; }

if [[ $EUID -ne 0 ]]; then
  echo "Re-run as: sudo $0 ${SECS}" >&2
  echo "(needs privileged reads on both sides of the suspend; see header)" >&2
  exit 1
fi

echo "Snapshot before..."
snapshot before

echo
echo "Residency BEFORE (accumulated this boot):"
sed 's/^/  /' "$OUT/res-before"

echo
echo "Arming RTC wake for ${SECS}s and suspending through logind..."
sudo rtcwake -m no -s "$SECS" >/dev/null || { echo "rtcwake failed" >&2; exit 1; }
systemctl suspend || { echo "systemctl suspend failed (polkit?)" >&2; exit 1; }

# The script is frozen here along with everything else. Execution resumes
# after wake. Give the resume path a moment to settle before reading.
sleep 15

echo "Snapshot after..."
snapshot after

echo
echo "=============================================================="
echo "Residency AFTER:"
sed 's/^/  /' "$OUT/res-after"

if grep -qE '[[:space:]][1-9][0-9]*$' "$OUT/res-after"; then
  echo
  echo "  >>> NONZERO RESIDENCY. The platform reached an S0ix substate."
else
  echo
  echo "  >>> Still all zero. No S0ix substate entered during this sleep."
fi

echo
echo "=============================================================="
echo "Requirement counter deltas over the sleep window"
echo "(large identical values across many elements = free-running"
echo " reference clocks, not blockers — see the doc)"
echo
join <(parse "$OUT/req-before" | sort) <(parse "$OUT/req-after" | sort) \
  | awk '{ d = $3 - $2; if (d != 0) printf "%12d  %s\n", d, $1 }' \
  | sort -rn \
  | awk 'BEGIN { printf "%12s  %s\n", "DELTA", "ELEMENT" } { print }'

echo
echo "Elements with ZERO delta (did not assert during this sleep):"
join <(parse "$OUT/req-before" | sort) <(parse "$OUT/req-after" | sort) \
  | awk '{ if ($3 - $2 == 0) printf "  %s\n", $1 }'
