# Audio: tinny/thin internal speakers (CS42L43 codec)

**Status:** Workaround in place (software EQ). Root cause is unfixed at the driver/firmware level.
**Component:** CS42L43 codec, `sof-soundwire` ALSA sink

## Root cause

The CS42L43 codec's onboard hardware EQ (`cs42l43 EQ Coefficients`, numid=70) ships
all-zero even though `cs42l43 EQ Switch` is on. Dell's real tuning curve was never
loaded — only an inert default is present. No published coefficient set exists yet
for this model. This is **not** a volume/gain issue; turning it up just makes thin
audio louder.

## Fix: PipeWire filter-chain EQ

A PipeWire filter-chain virtual sink EQs the signal before it reaches the real
`sof-soundwire Speaker` ALSA sink.

System: PipeWire 1.6.8, WirePlumber 0.5.14 — both support
`libpipewire-module-filter-chain` natively. Fedora ships a ready
`filter-chain.service` systemd `--user` unit (disabled by default; enable it) that
loads `~/.config/pipewire/filter-chain.conf.d/*.conf`.

### `~/.config/pipewire/filter-chain.conf.d/bass-eq.conf`

```
context.modules = [
    { name = libpipewire-module-filter-chain
        args = {
            node.description = "Bass Boost EQ (Speakers)"
            media.name       = "Bass Boost EQ (Speakers)"
            filter.graph = {
                nodes = [
                    {
                        type    = builtin
                        name    = preamp
                        label   = linear
                        control = { "Mult" = 0.708 "Add" = 0.0 }
                    }
                    {
                        type    = builtin
                        name    = eq_band_1
                        label   = bq_lowshelf
                        control = { "Freq" = 100.0  "Q" = 0.9 "Gain" = 7.0 }
                    }
                    {
                        type    = builtin
                        name    = eq_band_2
                        label   = bq_peaking
                        control = { "Freq" = 200.0  "Q" = 1.1 "Gain" = 4.0 }
                    }
                    {
                        type    = builtin
                        name    = eq_band_3
                        label   = bq_peaking
                        control = { "Freq" = 3000.0 "Q" = 1.5 "Gain" = -2.0 }
                    }
                    {
                        type    = builtin
                        name    = eq_band_4
                        label   = bq_peaking
                        control = { "Freq" = 6000.0 "Q" = 1.2 "Gain" = -1.5 }
                    }
                    {
                        type    = builtin
                        name    = eq_band_5
                        label   = bq_highshelf
                        control = { "Freq" = 10000.0 "Q" = 0.9 "Gain" = -1.0 }
                    }
                    {
                        type    = builtin
                        name    = safety_clamp
                        label   = clamp
                        control = { "Min" = -0.98 "Max" = 0.98 }
                    }
                ]
                links = [
                    { output = "preamp:Out"      input = "eq_band_1:In" }
                    { output = "eq_band_1:Out"   input = "eq_band_2:In" }
                    { output = "eq_band_2:Out"   input = "eq_band_3:In" }
                    { output = "eq_band_3:Out"   input = "eq_band_4:In" }
                    { output = "eq_band_4:Out"   input = "eq_band_5:In" }
                    { output = "eq_band_5:Out"   input = "safety_clamp:In" }
                ]
            }
            audio.channels = 2
            audio.position = [ FL FR ]
            capture.props = {
                node.name    = "effect_input.bass_eq"
                node.description = "Bass Boost EQ (Speakers)"
                media.class  = Audio/Sink
            }
            playback.props = {
                node.name    = "effect_output.bass_eq"
                node.passive = true
                target.object = "alsa_output.pci-0000_00_1f.3-platform-sof_sdw.HiFi__Speaker__sink"
            }
        }
    }
]
```

| Stage | Type | Freq | Q | Gain | Purpose |
|---|---|---|---|---|---|
| preamp | linear | — | — | −3 dB | headroom so the boosts below don't clip |
| band 1 | low shelf | 100 Hz | 0.9 | +7 dB | restore missing bass |
| band 2 | peaking | 200 Hz | 1.1 | +4 dB | warmth/body |
| band 3 | peaking | 3 kHz | 1.5 | −2 dB | tame "tinny" resonance |
| band 4 | peaking | 6 kHz | 1.2 | −1.5 dB | reduce harshness |
| band 5 | high shelf | 10 kHz | 0.9 | −1 dB | smooth extreme top end |
| safety clamp | clamp | — | — | ±0.98 | hard limiter so boosts can't digitally clip |

### `~/.config/wireplumber/wireplumber.conf.d/51-rename-raw-speaker.conf`

Renames the raw ALSA sink so it's obviously not the one to pick (selecting it
bypasses the EQ):

```
monitor.alsa.rules = [
  {
    matches = [
      { node.name = "alsa_output.pci-0000_00_1f.3-platform-sof_sdw.HiFi__Speaker__sink" }
    ]
    actions = {
      update-props = {
        node.description = "Speakers (raw, unequalized - do not use)"
        priority.session = 100
      }
    }
  }
]
```

## Dead ends investigated (don't retry these)

- **Calf Bass Enhancer (LV2 harmonic exciter)** — installed `lv2-calf-plugins`,
  wired it in, fails to load. Fedora's build of PipeWire's filter-chain module only
  compiles in `builtin`/`ladspa`/`ebur128` plugin loaders; there is no LV2 support
  at all (`/usr/lib64/spa-0.2/filter-graph/` has no lv2 loader).
- **LSP Plugins (LADSPA)** — inspected `lsp-plugins-ladspa.so` directly via
  `strings` (no install needed); no bass-exciter/harmonic plugin exists in it
  either. LSP is mastering/dynamics-focused, not psychoacoustic.
- A real harmonic exciter would need Carla as an LV2 host bridged into PipeWire's
  JACK-compatible graph. Not attempted — heavier setup, extra always-running
  process, for marginal gain.

## Conclusion

Further bass boost beyond this EQ is a hardware/driver limitation (reviews of the
DX13260 independently confirm weak bass) — more digital gain just adds distortion,
not audible bass. Considered closed unless external speakers or the Carla route are
wanted later.

## Known gotcha (not a bug, don't re-diagnose)

KDE's volume OSD/popup shows the "primary" hardware device by default and hides
virtual/filter-chain sinks behind a "show virtual devices" toggle, **regardless of
which sink is actually set as the PipeWire default**. This looks like a
volume-key/loudness mismatch bug but isn't — it's Plasma's OSD defaulting its
visible slider to the raw device. Left as-is rather than trying to hide the raw
sink from Plasma entirely (would require relying on an unconfirmed PipeWire
`media.class` convention).

## For a bug report

- Hardware: Dell XPS 13 DX13260, CS42L43 codec, `alsa-sof-firmware`
- Evidence: `amixer` shows `cs42l43 EQ Coefficients` (numid=70) all-zero while
  `cs42l43 EQ Switch` is on
- Ask: published/loaded Dell tuning coefficient set for this model, or firmware
  update that loads one
