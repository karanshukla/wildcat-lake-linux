#!/bin/bash
# On-demand reproducer for the eDP panel wedge documented in
# s2idle-rapid-resume-hang.md.
#
# Every incident before this was opportunistic, so there was no hit rate, and
# without a hit rate none of the candidate levers (LOBF/ALPM off, PSR boot
# args on/off, xe.enable_dc=0) can be A/B'd. This drives the panel through
# the same power transitions the third incident went through (2026-08-04
# 21:01:57: PowerDevil idle-dim, then screen off, lid open the whole time, no
# suspend anywhere) on demand, N times, logging each cycle so the failing
# cycle number survives a forced power-off.
#
# Requires no sudo and no sshd.
#
# IDLE INHIBITION (this is the important part): by default the loop runs under
# both systemd-inhibit (idle:sleep:handle-lid-switch) and kde-inhibit
# (--power --screenSaver). Without them PowerDevil runs its own idle ladder
# underneath the test and half the panel transitions aren't yours. The first
# 50-cycle run on 2026-08-05 was confounded exactly this way: idle-dim at
# cycle 8, an unexplained screen-off at cycle 23, and a full logind idle
# suspend at cycle 37. Pass --allow-idle to deliberately put that collision
# back, which is its own experiment, not the baseline.
#
# DETECTION: bad and good cycles are byte-identical in DRM/atomic state (see
# the doc), so the classic "backlight on, screen black" symptom is only
# visible to your eyes. But the panel dropping to dpms=Off/bl=0 on its own IS
# software-visible, and the loop watches for it once a second through the
# on-dwell. Any such event is logged as ALERT and beeps three times.
#
# Usage:
#   ./reproduce-panel-wedge.sh                      # 50 cycles, idle inhibited
#   ./reproduce-panel-wedge.sh --cycles 200 --jitter
#   ./reproduce-panel-wedge.sh --allow-idle         # collision mode
#   ./reproduce-panel-wedge.sh --fast --mode race   # the collision, deliberately
#   ./reproduce-panel-wedge.sh --mode dim           # explicit dim step per cycle
#   ./reproduce-panel-wedge.sh --mode suspend       # rtcwake + logind suspend
#   ./reproduce-panel-wedge.sh --mark "screen black"   # from a second shell
#
# MODES:
#   dpms     DRM dpms off/on only. The clean control.
#   race     A PowerDevil brightness write issued concurrently with the
#            dpms-on. Reproduces the 2026-08-05 06:14:28 collision, where
#            backlighthelper landed in the same second as --dpms on and the
#            panel wedged. This is the current lead.
#   dim      Brightness dim before the off, restore after the on. Sequential,
#            not concurrent, so it is the control for race.
#   suspend  rtcwake + logind suspend, the lid-open blank path.
#
# READ THE PLAN IT PRINTS BEFORE IT STARTS. Once the loop is running the
# screen is dark most of the time and you cannot read anything.

set -uo pipefail

ORIG_ARGS=("$@")

MODE=dpms
CYCLES=50
OFF_DWELL=8
ON_DWELL=6
JITTER=0
BEEP=1
LOCK=0
CAPTURE=0
ALLOW_IDLE=0
# race mode: fire the brightness write only every Nth cycle. PowerDevil's
# backlighthelper is a dbus-activated privileged helper that idles out after
# ~12s, so a write every cycle keeps it warm and you only ever test an
# in-process sysfs write. The 2026-08-05 06:14:28 collision was a COLD
# activation (systemd unit start + dbus activation + process spawn) landing
# in the same second as the dpms-on. Spacing the writes past the idle-out
# forces that cold path every time.
RACE_EVERY=3

OUT=/var/tmp/panel-wedge-repro
LOG="$OUT/cycles.log"

usage() { sed -n '2,45p' "$0" | sed 's/^# \?//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)       MODE="$2"; shift 2 ;;
    --cycles)     CYCLES="$2"; shift 2 ;;
    --off)        OFF_DWELL="$2"; shift 2 ;;
    --on)         ON_DWELL="$2"; shift 2 ;;
    --jitter)     JITTER=1; shift ;;
    --fast)       OFF_DWELL=3; ON_DWELL=2; CYCLES=30; shift ;;  # ~4.5 min
    --no-beep)    BEEP=0; shift ;;
    --lock)       LOCK=1; shift ;;
    --capture)    CAPTURE=1; shift ;;
    --allow-idle) ALLOW_IDLE=1; shift ;;
    --race-every) RACE_EVERY="$2"; shift 2 ;;
    --mark)
      # Timestamp a wedge from a second shell while a run is in progress.
      # The classic symptom (backlight on, screen black) is invisible to
      # every software probe, so the only way to pin it to a cycle number
      # is for a human to say "now". Run this the moment you see it.
      MARK_MSG="${2:-observed}"
      MARK_LINE="MARK ts=$(date -Is) note=\"$MARK_MSG\" state[status=$(cat /sys/class/drm/card0-eDP-1/status 2>/dev/null) enabled=$(cat /sys/class/drm/card0-eDP-1/enabled 2>/dev/null) dpms=$(cat /sys/class/drm/card0-eDP-1/dpms 2>/dev/null) bl=$(cat /sys/class/backlight/intel_backlight/actual_brightness 2>/dev/null)]"
      mkdir -p "$OUT"
      echo "$MARK_LINE" >> "$LOG"
      logger -t panel-wedge-repro "$MARK_LINE"
      echo "$MARK_LINE"
      exit 0 ;;
    -h|--help)    usage ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

case "$MODE" in
  dpms|dim|race|suspend) ;;
  *) echo "mode must be one of: dpms, dim, race, suspend" >&2; exit 1 ;;
esac

# --- re-exec under idle inhibitors -------------------------------------
# systemd-inhibit covers logind's own idle-suspend and lid handling.
# kde-inhibit covers PowerDevil's dim/screen-off, which logind inhibitors
# do not reliably stop on Plasma 6.
if [[ ${PWR_REPRO_INHIBITED:-0} -eq 0 && $ALLOW_IDLE -eq 0 ]]; then
  export PWR_REPRO_INHIBITED=1
  exec systemd-inhibit \
      --what=idle:sleep:handle-lid-switch \
      --who="panel-wedge-repro" --why="panel power-cycle stress test" \
      kde-inhibit --power --screenSaver \
      "$0" "${ORIG_ARGS[@]}"
fi

mkdir -p "$OUT"

# --- audible heartbeat -------------------------------------------------
# The screen is the thing under test, so progress has to come out of a
# channel that isn't the screen. Speakers work (see audio/).
SND_DIR=/usr/share/sounds/freedesktop/stereo
pick_sound() { for f in "$@"; do [[ -f "$SND_DIR/$f.oga" ]] && { echo "$SND_DIR/$f.oga"; return; }; done; }
SND_CYCLE=$(pick_sound message bell dialog-information complete)
SND_ALERT=$(pick_sound dialog-warning bell message)
SND_DONE=$(pick_sound complete bell message)

beep() {
  [[ $BEEP -eq 1 ]] || return 0
  local snd="$1" n="${2:-1}"
  [[ -n "$snd" ]] || return 0
  ( for ((b=0; b<n; b++)); do paplay "$snd" 2>/dev/null; done ) &
}

# --- state probes (all sudo-free) --------------------------------------
CONN=/sys/class/drm/card0-eDP-1
BL=/sys/class/backlight/intel_backlight

probe() {
  echo "status=$(cat "$CONN/status" 2>/dev/null)" \
       "enabled=$(cat "$CONN/enabled" 2>/dev/null)" \
       "dpms=$(cat "$CONN/dpms" 2>/dev/null)" \
       "bl=$(cat "$BL/actual_brightness" 2>/dev/null)"
}

panel_is_on() {
  [[ "$(cat "$CONN/dpms" 2>/dev/null)" == "On" ]] \
  && [[ "$(cat "$CONN/enabled" 2>/dev/null)" == "enabled" ]] \
  && [[ "$(cat "$BL/actual_brightness" 2>/dev/null)" != "0" ]]
}

ALERTS=0
alert() {
  ALERTS=$(( ALERTS + 1 ))
  local msg="ALERT cycle=$CYCLE $1 state[$(probe)] ts=$(date -Is)"
  echo "$msg" >> "$LOG"
  logger -t panel-wedge-repro "$msg"
  beep "$SND_ALERT" 3
}

BR_IFACE="org.kde.Solid.PowerManagement.Actions.BrightnessControl"
BR_PATH="/org/kde/Solid/PowerManagement/Actions/BrightnessControl"
kde_brightness()     { busctl --user call org.kde.Solid.PowerManagement "$BR_PATH" "$BR_IFACE" brightness 2>/dev/null | awk '{print $2}'; }
kde_set_brightness() { busctl --user call org.kde.Solid.PowerManagement "$BR_PATH" "$BR_IFACE" setBrightness i "$1" >/dev/null 2>&1; }

START_BRIGHTNESS=$(kde_brightness)

# --- cleanup -----------------------------------------------------------
CYCLE=0
DONE_CYCLES=0
cleanup() {
  echo
  echo "restoring display state..."
  kscreen-doctor --dpms on >/dev/null 2>&1
  [[ -n "${START_BRIGHTNESS:-}" ]] && kde_set_brightness "$START_BRIGHTNESS"
  local summary="run ended: completed $DONE_CYCLES of $CYCLES cycles, $ALERTS alert(s)"
  echo "$summary" >> "$LOG"
  logger -t panel-wedge-repro "$summary"
  echo "$summary"
  echo "log: $LOG"
  beep "$SND_DONE" 2
  sleep 1
  exit 0
}
trap cleanup INT TERM

# --- plan --------------------------------------------------------------
cat <<EOF

================ panel wedge reproducer ================
mode           : $MODE
cycles         : $CYCLES
off dwell      : ${OFF_DWELL}s$([[ $JITTER -eq 1 ]] && echo " (+0-4s jitter)")
on  dwell      : ${ON_DWELL}s$([[ $JITTER -eq 1 ]] && echo " (+0-4s jitter)")
idle inhibited : $([[ $ALLOW_IDLE -eq 1 ]] && echo "NO (collision mode: PowerDevil will dim/blank/suspend under the test)" || echo "yes (systemd-inhibit + kde-inhibit)")
$([[ "$MODE" == "race" ]] && echo "race writes    : every $RACE_EVERY cycles (~$(( RACE_EVERY * (OFF_DWELL + ON_DWELL + 3) ))s apart, past backlighthelper's ~12s idle-out, so each is a cold activation)")
heartbeat      : $([[ $BEEP -eq 1 ]] && echo "1 beep per cycle, 3 fast beeps on ALERT, 2 at end" || echo off)
per-cycle log  : $LOG
est. runtime   : ~$(( (CYCLES * (OFF_DWELL + ON_DWELL + 3) + 10) / 60 )) min $(( (CYCLES * (OFF_DWELL + ON_DWELL + 3) + 10) % 60 ))s

WHAT TO DO:
  - Leave the lid open. Do not touch keyboard or touchpad during the run:
    input wakes the panel and voids the cycle.
  - Watch the screen. Each cycle it goes dark ~${OFF_DWELL}s then returns
    ~${ON_DWELL}s. One beep per cycle.
  - A WEDGE is: beeps keep coming, screen stays dark. Count roughly how
    many beeps you heard, then Ctrl-C (works blind).
  - Three fast beeps means the loop itself caught the panel powering down
    on its own. Note when you hear it.
  - If Ctrl-C doesn't bring the screen back, that's itself the finding
    (matches the third incident, where five lid nudges failed). Try a lid
    nudge, then Magic SysRq REISUB before forcing a power-off. SysRq has
    never been tested against this wedge and is worth the data point.
  - After recovery: cat $LOG

Starting in 10s. Ctrl-C now to abort.
========================================================

EOF
sleep 10

logger -t panel-wedge-repro "run start: mode=$MODE cycles=$CYCLES off=$OFF_DWELL on=$ON_DWELL inhibited=$([[ $ALLOW_IDLE -eq 1 ]] && echo no || echo yes)"
echo "run start $(date -Is) mode=$MODE cycles=$CYCLES off=$OFF_DWELL on=$ON_DWELL inhibited=$([[ $ALLOW_IDLE -eq 1 ]] && echo no || echo yes)" >> "$LOG"

[[ $LOCK -eq 1 ]] && { loginctl lock-session; sleep 3; }

jitter() { [[ $JITTER -eq 1 ]] && echo $(( RANDOM % 5 )) || echo 0; }

for ((CYCLE=1; CYCLE<=CYCLES; CYCLE++)); do
  OFF_D=$(( OFF_DWELL + $(jitter) ))
  ON_D=$(( ON_DWELL + $(jitter) ))
  TS=$(date -Is)
  T_START=$SECONDS

  logger -t panel-wedge-repro "cycle $CYCLE begin off=${OFF_D}s on=${ON_D}s"

  # The panel should be On coming into a cycle. If it isn't, something
  # other than this script powered it down during the previous on-dwell.
  panel_is_on || alert "panel not On at cycle start"
  PRE=$(probe)

  if [[ "$MODE" == "dim" ]]; then
    # Replicates the third incident's opening move: PowerDevil's idle-dim
    # step (backlighthelper) immediately before the screen goes off.
    kde_set_brightness $(( ${START_BRIGHTNESS:-4000} / 3 ))
    sleep 2
  fi

  case "$MODE" in
    suspend)
      # Real logind suspend path, not rtcwake writing /sys/power/state
      # directly. See the methodology note in s0ix-never-entered.md.
      sudo rtcwake -m no -s "$OFF_D" >/dev/null 2>&1
      systemctl suspend
      sleep $(( OFF_D + 5 ))
      RC_OFF=0; RC_ON=0
      ;;
    race)
      # Reproduces the 2026-08-05 06:14:28 collision deliberately: a
      # PowerDevil brightness write issued concurrently with the DRM
      # dpms-on, instead of waiting for the idle timer to land one there
      # by luck. Alternates the target so every cycle is a real change.
      kscreen-doctor --dpms off >/dev/null 2>&1; RC_OFF=$?
      sleep "$OFF_D"
      if (( CYCLE % RACE_EVERY == 0 )); then
        # Alternate the target so each write is a real change. Spacing
        # them RACE_EVERY cycles apart lets backlighthelper idle out in
        # between, so this is a cold activation racing the dpms-on.
        if (( (CYCLE / RACE_EVERY) % 2 == 0 )); then
          RACE_BR=$(( ${START_BRIGHTNESS:-4000} / 3 ))
        else
          RACE_BR=${START_BRIGHTNESS:-4000}
        fi
        kde_set_brightness "$RACE_BR" &
        RACE_PID=$!
        kscreen-doctor --dpms on >/dev/null 2>&1; RC_ON=$?
        wait "$RACE_PID" 2>/dev/null
      else
        kscreen-doctor --dpms on >/dev/null 2>&1; RC_ON=$?
      fi
      ;;
    *)
      kscreen-doctor --dpms off >/dev/null 2>&1; RC_OFF=$?
      sleep "$OFF_D"
      kscreen-doctor --dpms on  >/dev/null 2>&1; RC_ON=$?
      ;;
  esac

  [[ "$MODE" == "dim" ]] && kde_set_brightness "${START_BRIGHTNESS:-4000}"

  sleep 2
  POST=$(probe)
  panel_is_on || alert "panel not On 2s after dpms on"

  echo "cycle=$CYCLE ts=$TS off=${OFF_D}s on=${ON_D}s rc_off=$RC_OFF rc_on=$RC_ON pre[$PRE] post[$POST]" >> "$LOG"
  logger -t panel-wedge-repro "cycle $CYCLE end post[$POST]"

  if [[ $CAPTURE -eq 1 ]]; then
    # Opt-in. Off by default because sudo here is face-auth backed and the
    # "Please look at the camera" prompt is invisible on a dark screen.
    CAPTURE_OUT_BASE="$OUT/captures" "$(dirname "$0")/capture-blank-resume-state.sh" >/dev/null 2>&1
  fi

  beep "$SND_CYCLE"

  # Watch the panel once a second through the on-dwell rather than only
  # sampling at the next cycle's start. Cycle 23 of the 2026-08-05 run
  # showed the panel going to dpms=Off/bl=0 somewhere inside this window,
  # and a start-of-cycle probe can't tell you when.
  for ((t=0; t<ON_D; t++)); do
    sleep 1
    panel_is_on || { alert "panel powered down ${t}s into on-dwell"; break; }
  done

  # A cycle taking far longer than its own dwells means the machine
  # suspended mid-run (the 2026-08-05 run did, at cycle 37).
  ELAPSED=$(( SECONDS - T_START ))
  EXPECTED=$(( OFF_D + ON_D + 4 ))
  if (( ELAPSED > EXPECTED + 10 )); then
    alert "cycle took ${ELAPSED}s vs expected ~${EXPECTED}s (suspend mid-run?)"
  fi

  DONE_CYCLES=$CYCLE
done

cleanup
