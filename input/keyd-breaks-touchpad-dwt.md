# Touchpad — keyd's virtual keyboard breaks disable-while-typing (DWT)

**Status:** Unresolved — root cause isolated via libinput debug-events, no fix yet

## Symptom

Tap-to-click is enabled (no haptic trackpad on this hardware, so tap-to-click is
the only practical click method). While typing, the cursor intermittently jumps
and clicks land in the wrong place, consistent with palm/heel-of-hand contact on
the pad not being rejected.

## Root cause

Captured with `libinput debug-events`, comparing typing+deliberate-palm-swipe with
keyd running vs. keyd stopped.

The touchpad (`GXTP7863:00`, Goodix, `event5`) already reports `dwt-on` and
`dwtp-on` in its capability line, so this isn't a case of disable-while-typing
being off:

```
-event5   DEVICE_ADDED  GXTP7863:00 27C6:0D4C Touchpad  cap:pg  size 117x67mm
          tap (dl off) left scroll-nat scroll-2fg-edge click-buttonareas-clickfinger
          dwt-on dwtp-on
```

**With keyd running:** keystrokes appear on `event10` (keyd's virtual `uinput`
keyboard) rather than the physical keyboard, since keyd grabs the physical
device (`event3`, "AT Translated Set 2 keyboard") exclusively and re-emits
everything through its own device. During a deliberate palm swipe across the pad
while actively typing, `POINTER_MOTION`/`GESTURE_HOLD_BEGIN` events leaked
through as little as 108ms after a keypress, well inside the window DWT should
be suppressing:

```
event10  KEYBOARD_KEY     +3.856s  *** (-1) pressed
event5   GESTURE_HOLD_BEGIN +3.964s  1
```

**With keyd stopped:** the same physical keyboard (`event3`) drives 10.3s of
continuous typing (+1.306s to +11.659s), same deliberate palm swipe on the pad
throughout. Zero `POINTER_MOTION` or gesture events anywhere in that window.
DWT suppressed the pad completely for the full duration.

That's a clean A/B: same touchpad hardware, same firmware, same palm contact,
same DWT config. The only variable is which device the keystrokes arrive on.
**Ruled out:** touchpad firmware, palm-pressure/size heuristics, DWT being
disabled, panel/hardware quality. All fine on their own — confirmed by the
keyd-off capture suppressing 100% of motion for over 10 seconds straight.
**Confirmed:** keyd's re-injected virtual keyboard device does not fully drive
libinput's DWT the way genuine physical keyboard events do, even though it
correctly reports `cap:k` and its `KEYBOARD_KEY` events are processed normally
elsewhere (keyd's remaps all work as expected).

**Not yet identified:** the exact internal libinput mechanism this breaks.
Candidates, none confirmed: per-device DWT timer/pairing that doesn't extend to
synthetic `uinput` devices the same way; `SYN_REPORT` batching or timing
differences between real hardware and keyd's re-injection; udev tagging on the
virtual device that libinput's DWT path treats differently from `cap:k`
detection used elsewhere. Would need to read libinput's DWT source
(`evdev-mt-touchpad.c` or equivalent) to pin this down further.

## Fix/workaround

None implemented. Options considered, not applied:

- **Stop keyd while typing-sensitive** — not practical, defeats the point of
  the [Mac-style Alt remap](keyd-mac-remap.md) and the
  [Copilot-key quick-entry bind](claude-desktop-quick-entry.md).
- **Disable tap-to-click** — would eliminate the misfire (no click without a
  deliberate tap), at the cost of the only click method available on this
  no-haptic touchpad. Not applied; not acceptable as a daily-driver trade-off.
- **Real fix** — needs to happen upstream in keyd (re-inject in a way libinput's
  DWT recognizes) or in libinput (recognize synthetic keyboards for DWT
  purposes). Not investigated yet.

## For a bug report

- **Component:** libinput disable-while-typing vs. `keyd`'s `uinput`
  re-injected virtual keyboard device.
- **Reproduction:** run keyd with any remap active, capture
  `sudo libinput debug-events` while typing continuously and deliberately
  dragging a palm across the touchpad. Compare against the same test with keyd
  stopped (physical keyboard driving events directly).
- **Expected:** DWT suppresses all touchpad motion during active typing,
  regardless of which keyboard device the keystrokes originate from.
- **Actual:** DWT fully suppresses motion when keystrokes come from the
  physical keyboard; motion leaks through within ~100ms of a keypress when
  keystrokes come from keyd's virtual keyboard.
- **Hardware:** Goodix `GXTP7863:00` (27C6:0D4C) touchpad, Dell XPS 13 Wildcat
  Lake, Fedora 44, KDE Plasma 6 Wayland.
- Not yet filed upstream (keyd or libinput) — root cause isolated but internal
  mechanism not pinned down.
