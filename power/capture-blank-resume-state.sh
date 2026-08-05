#!/bin/bash
# Run this the moment you see backlight-on/gazed-firing/no-video on lid open —
# BEFORE nudging the lid again. A nudge forces a fresh modeset and destroys
# the exact state this captures. Needs sudo (debugfs reads). If the keyboard
# doesn't respond at all, switch VT first (Ctrl+Alt+F3), run it there, then
# Ctrl+Alt+F1/F2 back.
#
# Writes a timestamped bundle to ~/blank-resume-captures/ for comparison
# against a normal resume, and to attach to a bug report. Set
# CAPTURE_OUT_BASE to write elsewhere (e.g. for a confined caller like an
# acpid hook running as root under SELinux, which can't cross into a 700
# home directory without a dac_override it doesn't have).

set -uo pipefail

CARD=0000:00:02.0
DBG=/sys/kernel/debug/dri/$CARD
OUT="${CAPTURE_OUT_BASE:-$HOME/blank-resume-captures}/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

echo "Capturing to $OUT"

# Connector/pipe/plane atomic state — the main thing we're after: is the
# CRTC active with a stale/blank plane, or did the connector never modeset?
sudo cat "$DBG/state" > "$OUT/atomic-state.txt" 2>&1

# Human-readable summary of the same (pipe->connector mapping, link status)
sudo cat "$DBG/i915_display_info" > "$OUT/display-info.txt" 2>&1

# eDP-1 specifics: PSR/panel-replay state (disabled via boot arg, but worth
# confirming it stayed disabled) and panel mode/timings
sudo cat "$DBG/eDP-1/i915_psr_status" > "$OUT/edp1-psr-status.txt" 2>&1
sudo cat "$DBG/eDP-1/i915_psr_sink_status" > "$OUT/edp1-psr-sink-status.txt" 2>&1
sudo cat "$DBG/eDP-1/i915_panel_timings" > "$OUT/edp1-panel-timings.txt" 2>&1

# Hotplug storm detection — did the driver see (and maybe throttle) repeated
# short/long HPD pulses around resume?
sudo cat "$DBG/i915_hpd_storm_ctl" > "$OUT/hpd-storm-ctl.txt" 2>&1

# Display power well use-counts (PW_A/DC_off/etc) — 2026-08-04: pmc_core's
# display-related requirement counters (DISP_SHIM_VNN, DDI_PLL, D2D_DISP_DDI
# QACTIVE) showed zero movement across a real confirmed s2idle sleep while
# CSE's moved substantially in the same window, arguing against a shared
# PMC-level gating mechanism. This is a different, driver-internal signal
# (live use-counts, not historical accrual) worth checking too.
sudo cat "$DBG/i915_power_domain_info" > "$OUT/power-domain-info.txt" 2>&1

# S0ix substate snapshot — s0ix-never-entered.md already root-caused the
# platform never reaching S0ix (ME/CSE firmware never releases VNN), but
# capturing it here too in case a bad lid-open resume ever correlates with
# something unusual on the power-gating side.
sudo cat /sys/kernel/debug/pmc_core/substate_residencies > "$OUT/pmc-substate-residencies.txt" 2>&1
sudo cat /sys/kernel/debug/pmc_core/substate_requirements > "$OUT/pmc-substate-requirements.txt" 2>&1

# Quick sysfs cross-check, no sudo needed
for f in status enabled dpms; do
  echo "$f: $(cat /sys/class/drm/card0-eDP-1/$f 2>&1)" >> "$OUT/sysfs-connector.txt"
done
cat /sys/class/backlight/intel_backlight/brightness >> "$OUT/backlight-brightness.txt" 2>&1

# Recent kernel + full journal FIRST, before anything else touches dmesg.
# 2026-08-03 incidents both got their journalctl -n 300 window entirely (or
# almost entirely) evicted by the GuC log dump below, which floods dmesg
# with 130-300+ lines of an unwritten/poisoned ring buffer (all "z" filler)
# — leaving zero real resume/lid/HPD evidence in either capture. Grab the
# real log lines while they're still in the window, dump GuC log last.
journalctl -k -n 300 --no-pager > "$OUT/dmesg-tail.txt" 2>&1
journalctl -n 300 --no-pager > "$OUT/journal-tail.txt" 2>&1

# Dump the GuC firmware log ring buffer to dmesg (xe.guc_log_level=3 fills
# this continuously, but it never reaches journalctl until something reads
# this node). Do this last — it's only useful if a future `dmesg`/journal
# read happens after this point, and must not come before the tail captures
# above.
sudo cat "$DBG/tile0/gt0/uc/guc_log_dmesg" > /dev/null 2>&1

echo "Done. Files in $OUT:"
ls -la "$OUT"
