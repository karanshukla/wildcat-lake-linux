# Touchpad — Plasma 6 Wayland scroll-speed regression

**Status:** Worked around via `kcminputrc`
**Component:** KDE Plasma 6, Wayland touchpad scroll handling

## Symptom

Default touchpad scroll speed under Plasma 6 on Wayland is noticeably too fast —
a regression relative to expected/previous behavior.

## Fix

`~/.config/kcminputrc`:

```ini
ScrollFactor=0.3
NaturalScroll=true
```

`ScrollFactor` lowered from the Plasma default to compensate.

## For a bug report

- Component: Plasma 6 Wayland touchpad scroll speed
- Symptom: default scroll speed feels much faster than expected/previous Plasma
  versions on the same hardware
- Workaround: manually lowering `ScrollFactor` in `kcminputrc`
- Not yet filed upstream against KDE — worth checking if this is a known
  regression before filing.
