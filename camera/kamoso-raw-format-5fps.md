# Camera: kamoso preview/recording is slow (5fps) despite fine quality

**Status:** Workaround available (avoid kamoso for this camera, or cap its
resolution). kamoso itself is unpatched — no in-app format control.
**Component:** `kamoso` (stock Fedora KDE Plasma camera app), UVC webcam
(`2b7e:55c0 Kingcome Integrated_Webcam_FHD`), PipeWire v4l2 source

## Symptom

Camera preview and recorded video in kamoso are noticeably slow/laggy
(looks like ~5fps), but per-frame image quality is fine — no compression
artifacts, no blur. Same webcam in Chrome (WebRTC `getUserMedia`) is fully
smooth 30fps.

## Root cause

`/dev/video0` was negotiated to **1920x1080 raw YUYV (uncompressed)**, and
this camera's firmware hard-caps that mode at **5fps**. Confirmed straight
from the raw USB descriptor (`lsusb -v`, bypassing the driver's summary):
every frame size has exactly one discrete frame interval
(`bFrameIntervalType 1`), and the 1080p raw entry is
`dwDefaultFrameInterval 2000000` (100ns units) = 5fps. MJPG at the identical
1920x1080 resolution is `333333` = 30fps, confirmed live end-to-end with
`ffmpeg -f v4l2 -input_format mjpeg -video_size 1920x1080 -framerate 30 -i
/dev/video0`, sustained ~29-30fps.

No 60fps mode exists on this camera at all — checked exhaustively across
every frame-size descriptor, nothing above 30fps (MJPG) anywhere. If a spec
sheet claims 60fps, the UVC firmware doesn't expose it over USB.

PipeWire itself isn't biased toward the slow format: `pw-dump`'s
`EnumFormat` for this node lists MJPG *first* at every resolution, ahead of
the raw YUY2 entries. The SPA v4l2 plugin (checked via `strings` on
`libspa-v4l2.so`) also exposes no pixel-format-pinning config option, so
there's no PipeWire/WirePlumber-side fix available either.

That leaves the client. kamoso's GStreamer preview pipeline requests raw
video only (no `jpegdec` element in its capability negotiation), so caps
negotiation is restricted to the raw branch before MJPG is ever considered,
and it lands on the highest-resolution raw option: 1920x1080 @ 5fps. Chrome
negotiates MJPG correctly (browsers build a proper caps/jpeg-decode path for
WebRTC), which is why the exact same hardware is smooth there.

## Fix / workaround

No format control exists in kamoso's UI, and this needs an app-side fix,
not a system config change:

- **Use a different app for this camera.** Confirmed working: Chrome (and
  any browser) via `getUserMedia`, full 1080p30. OBS Studio's V4L2 source
  also exposes pixel format directly and can be set to MJPG.
- **Drop kamoso's target resolution to 640x480 or 640x360.** The raw path
  hits a full 30fps at those sizes too (confirmed in the descriptor), just
  lower resolution than 1080p.
- No fix that keeps 1080p in kamoso itself without it (or its underlying
  QtMultimedia/GStreamer pipeline) adding an `image/jpeg` + `jpegdec` branch
  to its capture caps.

## For a bug report

- App: `kamoso` (26.04.3, Fedora 44 KDE Plasma default camera app)
- Camera: `2b7e:55c0 Kingcome Integrated_Webcam_FHD`, `uvcvideo` driver
- Evidence: `/dev/video0` negotiates raw YUYV @ 1920x1080/5fps under
  kamoso; MJPG @ 1920x1080/30fps works fine via direct `ffmpeg`/`v4l2-ctl`
  and via Chrome's WebRTC capture on the same device
- Ask: kamoso (or its capture backend) should include MJPG/`jpegdec` in its
  caps negotiation instead of raw-only, matching what browsers already do
  for this class of UVC webcam
