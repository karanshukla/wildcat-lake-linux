#!/usr/bin/env python3
"""Measure the eDP panel's real refresh rate, and what VRR state the kernel thinks it's in.

Nothing in userspace can be trusted to report the panel's actual refresh rate:
KWin's FPS counter measures how often the compositor repaints, not how often the
panel scans out. This talks to DRM directly:

  * DRM_IOCTL_WAIT_VBLANK against a CRTC, timing the real inter-vblank interval.
    That's the hardware vblank interrupt -- userspace can't fake it.
  * DRM_IOCTL_MODE_OBJ_GETPROPERTIES to read the CRTC's VRR_ENABLED and the
    connector's vrr_capable / max bpc, i.e. whether the compositor actually asked
    for adaptive sync on this commit, as opposed to merely being allowed to.

Reading both at once is the point. "Panel pinned at 120Hz" means something very
different depending on whether VRR_ENABLED was 1 or 0 at the time.

Needs root: /dev/dri/card0 is root:video.

    sudo ./vblank_watch.py                  # one-shot VRR property dump
    sudo ./vblank_watch.py --watch 60       # 60s vblank measurement, pipe A
    sudo ./vblank_watch.py --watch 60 --csv /tmp/vb.csv

Deliberately does NOT call DRM_IOCTL_MODE_GETCONNECTOR: with count_modes=0 that
forces a full connector re-probe (EDID re-read / link retrain), which this panel
has a history of not surviving. Connector names come from sysfs instead.
"""

import argparse
import ctypes
import errno
import fcntl
import glob
import os
import sys
import time

DRM_IOCTL_BASE = ord('d')
_IOC_WRITE = 1
_IOC_READ = 2


def _iowr(nr, size):
    return ((_IOC_READ | _IOC_WRITE) << 30) | (size << 16) | (DRM_IOCTL_BASE << 8) | nr


class DrmModeCardRes(ctypes.Structure):
    _fields_ = [
        ("fb_id_ptr", ctypes.c_uint64),
        ("crtc_id_ptr", ctypes.c_uint64),
        ("connector_id_ptr", ctypes.c_uint64),
        ("encoder_id_ptr", ctypes.c_uint64),
        ("count_fbs", ctypes.c_uint32),
        ("count_crtcs", ctypes.c_uint32),
        ("count_connectors", ctypes.c_uint32),
        ("count_encoders", ctypes.c_uint32),
        ("min_width", ctypes.c_uint32),
        ("max_width", ctypes.c_uint32),
        ("min_height", ctypes.c_uint32),
        ("max_height", ctypes.c_uint32),
    ]


class DrmModeObjGetProperties(ctypes.Structure):
    _fields_ = [
        ("props_ptr", ctypes.c_uint64),
        ("prop_values_ptr", ctypes.c_uint64),
        ("count_props", ctypes.c_uint32),
        ("obj_id", ctypes.c_uint32),
        ("obj_type", ctypes.c_uint32),
    ]


class DrmModeGetProperty(ctypes.Structure):
    _fields_ = [
        ("values_ptr", ctypes.c_uint64),
        ("enum_blob_ptr", ctypes.c_uint64),
        ("prop_id", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("name", ctypes.c_char * 32),
        ("count_values", ctypes.c_uint32),
        ("count_enum_blobs", ctypes.c_uint32),
    ]


class DrmWaitVblankRequest(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_uint32),
        ("sequence", ctypes.c_uint32),
        ("signal", ctypes.c_uint64),
    ]


class DrmWaitVblankReply(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_int32),
        ("sequence", ctypes.c_uint32),
        ("tval_sec", ctypes.c_int64),
        ("tval_usec", ctypes.c_int64),
    ]


class DrmWaitVblank(ctypes.Union):
    _fields_ = [("request", DrmWaitVblankRequest), ("reply", DrmWaitVblankReply)]


DRM_IOCTL_MODE_GETRESOURCES = _iowr(0xA0, ctypes.sizeof(DrmModeCardRes))
DRM_IOCTL_MODE_GETPROPERTY = _iowr(0xAA, ctypes.sizeof(DrmModeGetProperty))
DRM_IOCTL_MODE_OBJ_GETPROPERTIES = _iowr(0xB9, ctypes.sizeof(DrmModeObjGetProperties))
DRM_IOCTL_WAIT_VBLANK = _iowr(0x3A, ctypes.sizeof(DrmWaitVblank))

DRM_MODE_OBJECT_CRTC = 0xCCCCCCCC
DRM_MODE_OBJECT_CONNECTOR = 0xC0C0C0C0

_DRM_VBLANK_RELATIVE = 0x1
_DRM_VBLANK_HIGH_CRTC_SHIFT = 1

# Properties worth reporting. VRR_ENABLED is the one that actually answers
# "did the compositor turn adaptive sync on for this commit".
INTERESTING = ("VRR_ENABLED", "vrr_capable", "max bpc", "Colorspace", "panel orientation")


def sanity_check_struct_sizes():
    """The doc'd, hand-verified values from the 2026-07-26 investigation."""
    assert ctypes.sizeof(DrmModeCardRes) == 64, ctypes.sizeof(DrmModeCardRes)
    assert ctypes.sizeof(DrmModeGetProperty) == 64
    assert ctypes.sizeof(DrmModeObjGetProperties) == 32
    assert ctypes.sizeof(DrmWaitVblank) == 24
    assert DRM_IOCTL_WAIT_VBLANK == 0xC018643A, hex(DRM_IOCTL_WAIT_VBLANK)


def connector_names(card):
    """connector_id -> name, straight from sysfs. No re-probe side effects."""
    out = {}
    for path in glob.glob("/sys/class/drm/%s-*/connector_id" % os.path.basename(card)):
        try:
            with open(path) as fh:
                cid = int(fh.read().strip())
        except (OSError, ValueError):
            continue
        name = os.path.basename(os.path.dirname(path))
        out[cid] = name.split("-", 1)[1] if "-" in name else name
    return out


def crtc_pipes(card):
    """crtc index -> pipe letter, from i915/xe debugfs. Best effort."""
    out = {}
    minor = card[-1] if card[-1].isdigit() else "0"
    for path in sorted(glob.glob("/sys/kernel/debug/dri/%s/crtc-*/i915_pipe" % minor)):
        try:
            with open(path) as fh:
                pipe = fh.read().strip()
            idx = int(os.path.basename(os.path.dirname(path)).split("-")[1])
        except (OSError, ValueError, IndexError):
            continue
        out[idx] = pipe
    return out


def get_resources(fd):
    res = DrmModeCardRes()
    fcntl.ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, res)

    crtcs = (ctypes.c_uint32 * max(res.count_crtcs, 1))()
    conns = (ctypes.c_uint32 * max(res.count_connectors, 1))()
    res.crtc_id_ptr = ctypes.addressof(crtcs)
    res.connector_id_ptr = ctypes.addressof(conns)
    res.count_fbs = 0
    res.count_encoders = 0
    fcntl.ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, res)

    return list(crtcs[: res.count_crtcs]), list(conns[: res.count_connectors])


_PROP_NAMES = {}


def prop_name(fd, prop_id):
    """Memoized: prop ids are stable for the life of the device, and the
    measurement loop polls VRR_ENABLED once per vblank. Without the cache that's
    ~20 extra ioctls per vblank at 120Hz, which perturbs what we're measuring."""
    name = _PROP_NAMES.get(prop_id)
    if name is None:
        prop = DrmModeGetProperty()
        prop.prop_id = prop_id
        fcntl.ioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, prop)
        name = prop.name.decode("utf-8", "replace")
        _PROP_NAMES[prop_id] = name
    return name


def object_properties(fd, obj_id, obj_type):
    """-> {name: value} for one DRM object."""
    req = DrmModeObjGetProperties()
    req.obj_id = obj_id
    req.obj_type = obj_type
    fcntl.ioctl(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, req)

    n = max(req.count_props, 1)
    ids = (ctypes.c_uint32 * n)()
    vals = (ctypes.c_uint64 * n)()
    req.props_ptr = ctypes.addressof(ids)
    req.prop_values_ptr = ctypes.addressof(vals)
    fcntl.ioctl(fd, DRM_IOCTL_MODE_OBJ_GETPROPERTIES, req)

    return {prop_name(fd, ids[i]): vals[i] for i in range(req.count_props)}


def read_vrr_prop(fd, crtc_id):
    """Just VRR_ENABLED, cheap enough to poll in the measurement loop."""
    try:
        return object_properties(fd, crtc_id, DRM_MODE_OBJECT_CRTC).get("VRR_ENABLED")
    except OSError:
        return None


def dump_state(fd, card):
    crtcs, conns = get_resources(fd)
    names = connector_names(card)
    pipes = crtc_pipes(card)

    print("== CRTCs ==")
    for idx, crtc_id in enumerate(crtcs):
        props = object_properties(fd, crtc_id, DRM_MODE_OBJECT_CRTC)
        pipe = pipes.get(idx, "?")
        shown = {k: v for k, v in props.items() if k in INTERESTING}
        vrr = props.get("VRR_ENABLED")
        print("  crtc-%d (id %d, pipe %s): VRR_ENABLED=%s  active=%s" % (
            idx, crtc_id, pipe,
            "<absent>" if vrr is None else vrr,
            props.get("ACTIVE", "?")))
        for k, v in sorted(shown.items()):
            if k != "VRR_ENABLED":
                print("      %s = %s" % (k, v))

    print("== Connectors ==")
    for conn_id in conns:
        props = object_properties(fd, conn_id, DRM_MODE_OBJECT_CONNECTOR)
        name = names.get(conn_id, "id-%d" % conn_id)
        cap = props.get("vrr_capable")
        print("  %s (id %d): vrr_capable=%s" % (
            name, conn_id, "<property absent>" if cap is None else cap))
        for k, v in sorted(props.items()):
            if k in INTERESTING and k != "vrr_capable":
                print("      %s = %s" % (k, v))


def watch(fd, crtc_index, crtc_id, duration, csv_path, interval):
    vbl = DrmWaitVblank()
    vbl_type = _DRM_VBLANK_RELATIVE
    if crtc_index > 0:
        vbl_type |= (crtc_index << _DRM_VBLANK_HIGH_CRTC_SHIFT)

    csv = open(csv_path, "w", buffering=1) if csv_path else None
    if csv:
        csv.write("wall_s,seq,delta_ms,hz,vrr_enabled\n")

    print("Measuring pipe/crtc-%d for %ds. VRR_ENABLED at start: %s"
          % (crtc_index, duration, read_vrr_prop(fd, crtc_id)))
    print("%-8s %-9s %-9s %-9s %-9s %s" % ("elapsed", "mean_hz", "min_hz", "max_hz", "samples", "vrr"))

    started = time.monotonic()
    deadline = started + duration
    prev = None
    window = []
    next_report = started + interval
    errors = 0

    while time.monotonic() < deadline:
        vbl.request.type = vbl_type
        vbl.request.sequence = 1
        vbl.request.signal = 0
        try:
            fcntl.ioctl(fd, DRM_IOCTL_WAIT_VBLANK, vbl)
        except OSError as exc:
            # EINVAL here means the CRTC went inactive (panel DPMS'd off) --
            # that's a result, not a crash. Keep the run alive and say so.
            errors += 1
            if errors in (1, 10) or errors % 100 == 0:
                print("  [vblank ioctl %s x%d -- CRTC likely inactive/off]"
                      % (errno.errorcode.get(exc.errno, exc.errno), errors))
            prev = None
            time.sleep(0.25)
            continue

        now = vbl.reply.tval_sec + vbl.reply.tval_usec / 1e6
        if prev is not None:
            delta = now - prev
            if 0 < delta < 1.0:
                window.append(delta)
                if csv:
                    csv.write("%.6f,%d,%.4f,%.3f,%s\n" % (
                        now, vbl.reply.sequence, delta * 1e3, 1.0 / delta,
                        read_vrr_prop(fd, crtc_id)))
        prev = now

        if time.monotonic() >= next_report:
            elapsed = time.monotonic() - started
            if window:
                mean = sum(window) / len(window)
                print("%-8.1f %-9.2f %-9.2f %-9.2f %-9d %s" % (
                    elapsed, 1.0 / mean, 1.0 / max(window), 1.0 / min(window),
                    len(window), read_vrr_prop(fd, crtc_id)))
            else:
                print("%-8.1f %-9s %-9s %-9s %-9d %s" % (
                    elapsed, "-", "-", "-", 0, read_vrr_prop(fd, crtc_id)))
            window = []
            next_report += interval

    if csv:
        csv.close()
        print("wrote %s" % csv_path)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--card", default="/dev/dri/card0")
    ap.add_argument("--crtc", type=int, default=0,
                    help="CRTC index (0 = pipe A = eDP-1 on this machine)")
    ap.add_argument("--watch", type=float, metavar="SECONDS",
                    help="measure inter-vblank intervals for this long")
    ap.add_argument("--interval", type=float, default=2.0,
                    help="seconds between summary lines (default 2)")
    ap.add_argument("--csv", help="also write per-vblank samples here")
    args = ap.parse_args()

    sanity_check_struct_sizes()

    try:
        fd = os.open(args.card, os.O_RDWR)
    except PermissionError:
        sys.exit("%s needs root (it's root:video). Re-run with sudo." % args.card)

    try:
        dump_state(fd, args.card)
        if args.watch:
            crtcs, _ = get_resources(fd)
            if args.crtc >= len(crtcs):
                sys.exit("no crtc index %d (found %d)" % (args.crtc, len(crtcs)))
            print()
            watch(fd, args.crtc, crtcs[args.crtc], args.watch, args.csv, args.interval)
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
