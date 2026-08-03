# F5/dictation-key speech feature (NPU-accelerated Whisper)

**Status (2026-08-03): pivoted from toggle-mode voice typing to live
captioning.** Feasibility spike complete and confirmed working end to end
(NPU inference, correct transcription, benchmarked latency). Live-captioning
implementation (continuous capture, on-screen overlay, streaming display)
not built yet — only the underlying transcription layer has been verified.
Code: [karanshukla/vinoWhisper](https://github.com/karanshukla/vinoWhisper).

## What it does (planned)

The F-row has a dual-mode key: physical icon is a dictation/voice-typing
symbol. Its default (non-Fn) press already emits `Meta+H` at the hardware/
kernel level — mirroring the Windows convention (Win+H = voice typing).
Fn+that same key emits literal `F5`. Right now `Meta+H` is just borrowed as
a launcher: KDE's `kglobalshortcutsrc` binds it to Ghostty's `new-window`
action (`com.mitchellh.ghostty.desktop`).

Originally scoped as toggle-mode voice typing (press to record, press again
to transcribe + inject text via `ydotool`). Pivoted 2026-08-03 to **live
captioning** instead: continuous local transcription displayed on-screen as
you speak, not injected as text into whatever has focus. Still local,
NPU-accelerated Whisper (OpenVINO), still triggered by the same key — the
transcription backend and hardware story are identical, only what happens
with the output changes. Reasoning: same "Wayland-compatible KDE voice
feature using the Intel NPU" want tracked in `known-issues.md`, but
captioning is a more natural fit for continuous speech than toggle-mode
dictation into a text field.

## Why NPU, and why not the obvious existing project

Now that OpenVINO is proven working on this NPU (AuthFace face-unlock), this
is the next practical NPU use — it's a genuinely good fit (small model, low
power, always-resident). This reasoning is unchanged by the pivot to live
captioning; still the same model, same hardware, same "keep it local and NPU
resident" motivation.

The "actively maintained" fork pointer for `whisper-npu-server`
(`ellenhp/whisper-npu-server` → "check `mecattaf/whisper-npu-server`")
**404s — that GitHub repo doesn't exist.** Only a container image
(`ghcr.io/mecattaf/whisper-npu-server`) and HF model repos are reachable,
via a third fork's (`wormyrocks/whisper-npu-server`) README. That whole
ecosystem (original + forks) is sway/niri-native: hold-to-record wrapper, no
KDE/Plasma integration anywhere, and **no source anywhere documents the
text-injection mechanism** (ydotool/wtype/xdotool) — that part was always
private/unpublished on the original author's machine. So the
transcription-server *idea* is reusable (persistent local service to avoid
NPU model-load latency), but the KDE-Wayland wiring has to be built from
scratch regardless of toggle-mode vs. live-captioning.

## Feasibility spike (2026-08-03)

Ran end to end on this machine: NPU driver check, model conversion, NPU
inference benchmark, model-size/accuracy trade-off experiment, and a
token-streaming perceived-latency test. All confirmed working. Three real
bugs hit along the way, all root-caused and fixed (not worked around with
guesses) — documented below since two of them are pure Python/toolchain
version-skew issues that would bite anyone doing OpenVINO GenAI work on
this machine right now, not just this feature.

### Bug 1: Python 3.14 breaks `optimum`'s export code entirely

**Symptom:** every `optimum-cli export openvino` / `OVModelForSpeechSeq2Seq.from_pretrained(..., export=True)`
call failed with `TypeError: NormalizedConfig.__init__() got multiple values
for argument 'allow_new'`, on every combination of `optimum`/`optimum-intel`/
`transformers` versions tried (latest PyPI releases, a downgraded pre-2.0
`optimum-intel`, even the exact git commit pinned by openvino.genai's own
`export-requirements.txt`).

**Root cause:** Python 3.14 made `functools.partial` implement the
descriptor protocol (`__get__`). `optimum` has used
`NORMALIZED_CONFIG_CLASS = SomeConfig.with_args(allow_new=True, ...)` as a
class attribute throughout its export code for years — a `functools.partial`
factory, never meant to be accessed as a bound method. On 3.14, accessing it
via an instance (`self.NORMALIZED_CONFIG_CLASS(self._config)`) now
auto-binds `self` as an extra leading positional argument, colliding with
the partial's own keyword-bound `allow_new`. Reproduced in isolation:

```python
import functools

class Foo:
    def __init__(self, a, b=1, **kw):
        print("Foo init", a, b, kw)

class Bar:
    ATTR = functools.partial(Foo, b=2, c=3)

bar = Bar()
bar.ATTR("x")
# TypeError: Foo.__init__() got multiple values for argument 'b'
```

This is a real, version-independent break in a widespread HuggingFace
`optimum` idiom, not a version-pairing problem — confirmed by trying every
package combination above and hitting the identical failure every time.

**Fix:** use Python 3.13 (`/home/karanshukla/.local/bin/python3.13` is
already on this box) for the venv doing model export. No known downside
besides being capped below 3.14 until upstream works around the descriptor
change.

**For a bug report:** worth filing against `huggingface/optimum` — the
`NORMALIZED_CONFIG_CLASS = X.with_args(...)` class-attribute idiom is used
across dozens of model configs in that codebase, all equally broken on
Python 3.14. Haven't checked if this is already reported upstream.

### Bug 2: NPU static pipeline needs a KV-cache decoder the default export doesn't produce

**Symptom:** `ov_genai.WhisperPipeline(model_dir, device="NPU", STATIC_PIPELINE=True)`
raised `RuntimeError: Check '!self_attn_nodes.empty()' failed at .../pipeline_static.cpp:463`.

**Root cause:** the default `optimum-cli export openvino --task
automatic-speech-recognition-with-past` produces a stateful decoder (KV
cache hidden inside the model as internal state, not exposed as
inputs/outputs). NPU's static pipeline construction needs the separate
`decoder_with_past` submodel with explicit KV-cache tensors instead. Matches
upstream issue
[openvinotoolkit/openvino.genai#1728](https://github.com/openvinotoolkit/openvino.genai/issues/1728)
exactly.

**Fix:** add `--disable-stateful` to the export command. Confirmed this
alone is sufficient on Python 3.13 with current `optimum`/`optimum-intel`
(no need to manually force `attn_implementation="sdpa"` — that was only
needed mid-diagnosis while also working around Bug 3 via a different export
path; the plain CLI with `--disable-stateful` handles it directly once
Bugs 1 and 3 are also addressed).

### Bug 3: stable `openvino_genai` (2026.2.1) can't parse the current export's attention-mask graph shape

**Symptom:** even with `--disable-stateful`, pipeline construction still hit
the same `self_attn_nodes.empty()` assertion. Traced into
`pipeline_static.cpp`'s `add_attention_mask_input` pass: it pattern-matches
`ScaledDotProductAttention` nodes expecting the attention-mask input (port 3)
sourced from a `Slice` or `Select` node. The exported graph does have
`ScaledDotProductAttention` ops (confirmed by inspecting op types directly:
24 SDPA nodes in the decoder-with-past submodel, matching whisper-small's 12
layers × self+cross attention) — but the shape/pattern the current
`optimum-intel` export produces around that mask input doesn't match what
this specific stable release's matcher expects.

**Root cause:** version skew between `openvino_genai`'s C++ pattern-matcher
and whatever `optimum-intel` export version it was tested against. Confirmed
by checking upstream's own `openvino.genai/samples/export-requirements.txt`
and `deployment-requirements.txt`: they pin `optimum-intel` to an exact git
commit *and* `openvino_genai~=2026.4.0.0.dev` (a **nightly** build), not the
current PyPI stable release (2026.2.1) — i.e. upstream itself doesn't trust
the stable/PyPI-optimum-intel pairing for Whisper NPU export right now.

**Fix:** install nightly `openvino`/`openvino_genai`/`openvino_tokenizers`
from `https://storage.openvinotoolkit.org/simple/wheels/nightly` (`--pre`
flag required). Confirmed NPU still enumerates correctly under the newer
core (`Intel(R) AI Boost` present, same as stable). This is an ongoing cost,
not a one-time fix — worth re-checking each time a new stable OpenVINO
release ships whether it's caught up, since pinning a moving nightly target
indefinitely isn't a comfortable place to sit long-term.

### Result: NPU inference confirmed correct, not a silent CPU fallback

With all three bugs fixed: NPU pipeline compiles (24.3s one-time cost,
matches "load once, serve many" expectations already assumed in the
scaffold), produces **correct** transcription of a synthesized test clip.
Cross-checked that the NPU path is real and not a silent fallback to CPU: the
same non-stateful export, loaded with `device="CPU"`, fails outright
(`Port for tensor name beam_idx was not found`) since CPU's dynamic pipeline
expects a stateful graph. NPU succeeding on a graph CPU can't even load is
about as clean a proof as it gets without pulling driver-level counters.

## Model size and accuracy trade-off (2026-08-03)

Benchmarked whisper-tiny.en, whisper-base.en, whisper-small.en (fp16), and
whisper-small.en (int8-quantized) on this NPU, same 30s synthesized test
clip, same harness:

| Model | Steady-state latency | vs. small.en fp16 | Transcription |
|---|---|---|---|
| small.en fp16 | 1.19s | baseline | perfect, word for word |
| small.en int8 | 1.065s | ~10% faster | perfect, identical to fp16 |
| base.en fp16 | 0.464s | 2.6x faster | real errors ("MPU" for NPU, "Dumps" for jumps, "Cap Shunning" for captioning, twice) |
| tiny.en fp16 | 0.314s | 3.8x faster | garbled throughout, hallucinated a repeated phrase at the end |

**Decision: small.en, fp16 or int8, not a smaller model.** Model size is the
dominant latency lever (small→base→tiny), but base.en and tiny.en both
introduce real transcription errors on this test. INT8 weight quantization
on small.en is free (NPU handles it with zero observed accuracy cost) but
only buys ~10%, since the bottleneck is fixed compute over the 30s window,
not weight memory bandwidth. Caveat: single synthesized espeak-ng clip, not
a real accuracy benchmark, small sample, robotic voice — but it's the same
clip across all four models, so the relative ranking should hold even if
absolute error counts wouldn't survive a real test set with natural speech.

## Perceived-latency finding: token streaming gets you to ~0.2s

Whisper's encoder always processes a fixed 30-second/3000-mel-frame window
internally regardless of how much actual speech is in it — architectural
constant (positional embeddings sized for it), not something OpenVINO or the
NPU impose. So the ~1.19s per-call cost doesn't come down by feeding shorter
audio; it's close to a fixed floor for a full-window call.

But `WhisperPipeline.generate()` supports a token-level streamer callback
(`Callable[[str], bool]`, one caveat: only for audio under 30s). Tested
against small.en fp16 on NPU: **first token at 0.204s**, consistent across
repeated runs. Full first sentence ("The quick brown fox jumps over the lazy
dog.") readable by 0.32s. Words then arrive steadily at roughly 12ms/token
until the full ~1.2s call completes in the background.

**Implication for live captioning:** don't wait for `generate()` to return —
wire the streamer callback straight into the caption display. Perceived
latency is ~0.2s ("close to instant" for a captioning UX), actual compute is
still ~1.2s per window running underneath. Design around the 0.2s number,
not the 1.19s one. One artifact: trimming audio to fit the streamer's <30s
requirement caused a hallucinated repeated phrase at the very end,
consistently, both test runs — normal Whisper behavior when audio is cut
mid-thought, not a streaming bug, but relevant if a sliding-window
implementation trims chunks near a 30s boundary.

## Planned architecture (live captioning, not yet built)

Code lives in a separate repo (not here — this repo is docs-only per
`CLAUDE.md`, mirroring how the AuthFace/biopass forks live outside it):
[karanshukla/vinoWhisper](https://github.com/karanshukla/vinoWhisper),
local checkout at `~/Development/vinoWhisper`.

The transcription backend below is now confirmed working (model conversion,
NPU inference, streaming). What's not yet built is the live-captioning
consumer of that backend — a fresh architecture pass is needed for:

1. **Continuous chunked capture**, replacing the toggle-mode
   start/stop-into-one-WAV recorder with a rolling buffer.
2. **On-screen caption overlay**, replacing `ydotool type` entirely —
   captions must not be typed into whatever has keyboard focus. Needs an
   always-on-top surface instead (exact tech TBD, likely a minimal Qt/GTK
   window on KDE/Wayland).
3. **Streaming-aware server API**, since the existing one-shot `POST
   /transcribe` doesn't fit continuous chunks or the streamer callback —
   needs either a persistent connection (WebSocket/SSE) or repeated
   short-lived POSTs per chunk.
4. **Overlap/dedup logic** for stitching consecutive 30s-window
   transcriptions into one coherent running caption line, since Whisper's
   fixed-window architecture means a sliding window will re-transcribe
   overlapping audio each call.

## Verification plan

Completed 2026-08-03 (standalone, isolated from any KDE/hotkey wiring):
model conversion, NPU pipeline load, transcription correctness, NPU-vs-CPU
cross-check, model-size/accuracy benchmark, streaming/perceived-latency
test. All confirmed on real NPU inference, not simulated or assumed.

Still to do once live-captioning architecture (above) is built:
1. Test `ydotool`/overlay-display alternative independent of transcription,
   same reasoning as before — isolate display/injection plumbing from model
   correctness.
2. Wire continuous capture + streaming transcription + overlay together,
   test the full loop manually before touching any KDE shortcut.
3. Repoint the existing `Meta+H` KDE global shortcut (currently Ghostty's
   `new-window`) to start/stop the live-captioning session.
4. Confirm NPU utilization under sustained/repeated real-world use (not just
   the 15-call synthetic benchmark loop), watch for the "unclean shutdown"
   and "hangs" issues other Whisper-on-NPU users have reported upstream (see
   Open items below) under continuous rather than one-shot use.

## Open items (not blocking, for whenever this gets picked up further)

- **Nightly `openvino_genai` is an ongoing dependency risk**, not a one-time
  workaround. Re-check on each new stable OpenVINO release whether it's
  caught up to support this export shape.
- Known upstream NPU rough edges (2026-07-30, still not re-verified against
  the current nightly build): open `openvino.genai` GitHub issues report a
  Whisper-turbo model hanging on NPU and unclean pipeline shutdown on NPU.
  Haven't hit either yet in this spike's short-lived one-shot test loop —
  worth watching for once the live-captioning implementation holds the
  pipeline resident and calls it continuously/repeatedly over a long
  session, a meaningfully different usage pattern than tested so far.
- No visual "recording/captioning in progress" indicator designed yet beyond
  whatever the overlay itself communicates — out of scope until the overlay
  exists.
- Model size is now a **settled** choice (small.en, see benchmark above),
  not an open question — removing this from future "still to decide" lists.

## For a bug report

Two things worth reporting upstream, not yet filed:

1. `huggingface/optimum`: `NORMALIZED_CONFIG_CLASS = X.with_args(...)`
   class-attribute idiom breaks on Python 3.14 due to `functools.partial`
   gaining descriptor support. Reproduction is the 10-line snippet in Bug 1
   above — trivially reproducible outside any OpenVINO/Whisper context, a
   pure Python-version compatibility issue.
2. `openvinotoolkit/openvino.genai`: stable release 2026.2.1's
   `pipeline_static.cpp` Whisper NPU pattern-matcher doesn't recognize the
   current `optimum-intel` export's SDPA attention-mask node shape, while
   the 2026.4.0.0.dev nightly does. Given upstream's own
   `export-requirements.txt`/`deployment-requirements.txt` already pin the
   nightly + an exact `optimum-intel` git commit, this is likely already a
   known internal gap awaiting the next stable release rather than a novel
   finding — worth checking issue tracker before filing.
