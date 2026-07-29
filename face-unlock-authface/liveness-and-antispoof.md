# AuthFace: liveness gate + screen-spoof-blocked-by-physics finding

**Fork/branch:** [karanshukla/vinoAuthFace @ `npu-openvino-liveness`](https://github.com/karanshukla/vinoAuthFace/tree/npu-openvino-liveness)

> **Status (2026-07-29): motion-liveness shipped; screen-spoofing confirmed
> blocked by sensor hardware, not software; printed-photo resistance still
> untested and open.**
> Upstream AuthFace ships with no anti-spoofing at all — this was the primary
> gap flagged when adopting it as biopass's replacement (see
> [../face-unlock-biopass/README.md](../face-unlock-biopass/README.md)). The
> original plan here was "NPU-accelerated anti-spoof inference" (an ML
> classifier stage, mirroring biopass's approach). What actually shipped is
> different and cheaper: a motion heuristic plus a hardware-physics argument,
> not a learned model — documented honestly below, including why the plan
> changed.

## Why this didn't become an NPU anti-spoof model

Researched two real candidate pretrained ONNX anti-spoof models:
- **`anti-spoof-mn3`** (OpenVINO Open Model Zoo, MobileNetV3, CelebA-Spoof-trained,
  Apache-licensed weights) — `128×128×3` **RGB** input, binary real/spoof.
- **MiniFASNet / Silent-Face-Anti-Spoofing** — `80×80×3` **BGR** input, 3-class
  (live/print-attack/replay-attack).

Both are RGB-trained. AuthFace is IR-only (`GREY` V4L2 format, no RGB camera
in the auth path at all). Feeding either model a channel-replicated grayscale
IR frame is a real domain-shift gamble — these models learned color and
print-texture cues from visible-light photography that may not exist in an IR
feed at all. CASIA-SURF's dataset does have a legitimate NIR modality branch,
but no pretrained ONNX release was found anywhere for it — academic-only.
Neither RGB model was empirically tested against real IR frames this session
(deferred deliberately, not for lack of NPU budget — NPU compile is cheap
enough now that trying this later is low-cost if wanted).

Given no ready-made NIR-native model exists, and testing the RGB models risked
burning time on something with a real chance of not transferring, the
investigation went a different direction: what does the *sensor itself*
already give you for free, and what's the cheapest thing that catches the
"hold up a static photo" attack without any learned model at all.

## Layer 1: motion-based liveness gate (shipped)

`preprocess::frame_motion_fraction(a, b)` — counts the fraction of pixels
that changed by more than a per-pixel noise floor (1500 of 65535, ~2.3% of
the equalized 16-bit range) between two consecutive equalized, face-detected
frames during a scan.

`authenticate_scan`'s loop latches a `motion_observed` flag: once any
consecutive frame pair shows motion above `liveness_motion_threshold`
(default `0.01`, i.e. 1% of pixels), the flag stays true for the rest of that
scan window. A cosine-similarity match against stored embeddings only
succeeds if motion has been observed **at some point** in the scan — not
necessarily on the exact matching frame — otherwise it logs and keeps
scanning instead of granting access.

Real measured genuine-motion event (from a live debug run):
```
liveness: motion check frame_num=3 motion=0.4359182119369507 motion_threshold=0.01 motion_observed=true
```
43.6% of pixels changed on an ordinary blink/postural-shift between two
~200ms-apart frames — comfortably above the 1% threshold, wide margin.

**Honestly scoped limitation, not yet tested against the attack it targets:**
this defeats a *rigidly held, perfectly static* photo. It was never tested
against an actual printed photo (none available this session — see below).
A gently wiggled printed photo or tablet would likely still pass this specific
check; it's one layer, not complete liveness detection.

## Layer 2: screen-based spoofing is blocked by sensor physics, confirmed empirically

This machine's IR camera has a real active NIR illuminator — visually
confirmed (flashes visible when the sensor is opened in Kamoso). OLED panels
(and most LCD backlights) neither emit meaningful near-infrared nor reflect
it back the way skin does. Hypothesis: a phone/tablet screen showing a photo
of the victim should be effectively invisible to this specific IR pipeline,
categorically rather than subtly.

**Test method:** built a throwaway calibration tool (not shipped — removed
after use), capturing *raw* (pre-`histogram_equalize`) IR frames and gating on
the production face detector (`version-slim-320.onnx`) actually finding a
face-shaped signal before recording stats (mean brightness, std dev, a
gradient-magnitude texture proxy, min/max). Equalization was deliberately
excluded from the captured stats since it stretches the histogram to be
roughly uniform regardless of source brightness — it would have destroyed
exactly the reflectance-level signal being tested for.

**Genuine baseline** (raw pixel units, 8-bit sensor values scaled ×257 into
`u16` space), three separate capture runs, ~30 frames total:
- `mean` settles to **~15,000–17,400** after a ~3-5 frame auto-exposure
  warm-up (first frames of each run run higher/noisier — discard as warm-up,
  not signal).
- `std_dev` **~11,000–13,800**, `gradient_energy` (mean absolute
  finite-difference) **~330–600**.
- `max` frequently pegged at the full `65535` — a saturated glare hotspot
  (skin/glasses close to the illuminator), not sensor noise.
- One run, conducted in direct sunlight, showed both `mean` and `max`
  meaningfully higher/more saturated than the other two (indoor) runs.
  Sunlight carries its own broadband NIR component independent of the
  camera's own illuminator — a real, unresolved confound for outdoor/sunlit
  use of any reflectance-based check built on this signal later. Noted, not
  fixed.

**Phone-screen attempt:** `0/10` frames captured after **100** detection
attempts. Not "low confidence" — the production face detector found *no*
face-shaped IR structure on the phone screen at all, across a hundred tries.
The attack fails at the detection stage, before recognition or the liveness
check in Layer 1 ever runs.

**Re-tested in a fully dark room** (laptop screen dimmed to minimum, no other
light source) specifically to rule out ambient room lighting as a confound in
either direction:
- Genuine auth continued to work normally (expected — it's IR-illuminated,
  not dependent on ambient visible light).
- The phone-screen spoof attempt **still produced no detection**. This rules
  out "ambient light was somehow making the screen visible under IR" as an
  explanation for the earlier well-lit result — the block holds independent
  of ambient lighting conditions, strengthening rather than complicating the
  physics conclusion.

**Conclusion:** screen-based spoofing (phone/tablet showing a photo or video
of the victim) is blocked by this hardware's sensor+illuminator physics, not
by anything built in software. Confirmed under two different ambient-lighting
conditions, not theorized.

## What's still open

- **Printed photos are untested.** No printed photo was available this
  session. Paper reflects some NIR, unlike OLED — this attack vector is not
  ruled out and remains the actual open gap. If test material becomes
  available: rerun the same raw-frame stats capture method above
  (mean/std/gradient-energy, gated on real face-detector hits) with a printed
  photo held rigidly and also gently moved, to see whether reflectance,
  texture, or the existing motion-liveness check (or none of the three) catch
  it.
- **3D masks / IR-transparent prints**: untested, no material available,
  same as upstream AuthFace's own documented limitation.
- **The calibration tool itself is gone** — deliberately not committed to the
  AuthFace repo (kept the shipped surface minimal per repo owner's choice).
  The method is fully described above and is a small, reproducible script if
  needed again: open the camera, capture raw frames, require a real
  detector hit, compute mean/std/gradient-magnitude on the raw (not
  equalized) frame.
- **Sunlight/high-ambient-NIR confound**: noted above, not investigated
  further. Would need either a normalization step relative to a
  no-illuminator baseline frame, or a "ambient NIR too high, skip this check"
  fallback, if a reflectance-based check is ever built out into a real gate.

## For a bug report

Not applicable — this isn't a driver/kernel/distro bug, it's an application-level
finding about this specific IR-camera-with-illuminator hardware's spoof
resistance characteristics. Worth keeping as reference if evaluating other IR
webcams for the same purpose: an active NIR illuminator appears to be the
single most load-bearing hardware property for free screen-spoof resistance,
more so than sensor resolution or frame rate.
