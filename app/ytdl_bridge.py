"""Bridge between the Swift app and yt-dlp, running in the app's embedded Python.

Swift calls `main(job_path)` with a JSON job file. Results go to `job["result_path"]`
as JSON. During downloads, progress is written to `job["progress_path"]` (Swift polls
it), and the download stops if `job["cancel_path"]` appears.

There is no ffmpeg on iOS, so this module only picks formats the iPhone can handle
natively (H.264 video / AAC audio in MP4 containers) and downloads video and audio as
separate files. The Swift side merges them and writes tags and cover art with
AVFoundation.
"""

import copy
import glob
import importlib
import json
import os
import re
import shutil
import sys
import time
import traceback
import zipfile

MANAGED_PACKAGES = ("yt_dlp", "certifi")
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


# ---------------------------------------------------------------------------
# Helpers


def _write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, default=str)
    os.replace(tmp, path)


def _clean(msg):
    msg = ANSI.sub("", str(msg)).strip()
    if msg.startswith("ERROR: "):
        msg = msg[len("ERROR: "):]
    return msg


def _purge_modules():
    """Forget already-imported copies so a freshly installed yt-dlp is used."""
    for name in list(sys.modules):
        if name.split(".")[0] in MANAGED_PACKAGES:
            del sys.modules[name]
    importlib.invalidate_caches()


def main(job_path):
    with open(job_path, encoding="utf-8") as f:
        job = json.load(f)
    result_path = job["result_path"]
    try:
        action = job["action"]
        if action == "version":
            result = _version()
        elif action == "install":
            result = _install(job)
        elif action == "download":
            result = _download(job)
        else:
            result = {"ok": False, "error": "Unknown action %r" % action}
    except BaseException as e:  # never let an exception escape into the C layer
        result = {
            "ok": False,
            "error": _clean(e) or e.__class__.__name__,
            "traceback": traceback.format_exc()[-4000:],
        }
    _write_json(result_path, result)


# ---------------------------------------------------------------------------
# Installing / updating yt-dlp


def _version():
    try:
        _purge_modules()
        from yt_dlp.version import __version__

        return {"ok": True, "version": __version__}
    except ImportError:
        return {"ok": True, "version": None}


def _install(job):
    target = job["target"]
    os.makedirs(target, exist_ok=True)
    # Clear the previous install, but keep the folder itself (it's on sys.path).
    for entry in os.listdir(target):
        path = os.path.join(target, entry)
        if os.path.isdir(path):
            shutil.rmtree(path, ignore_errors=True)
        else:
            os.remove(path)
    for wheel in job["wheels"]:
        with zipfile.ZipFile(wheel) as z:
            z.extractall(target)
    _purge_modules()
    return _version()


# ---------------------------------------------------------------------------
# Format selection (no ffmpeg available)


def _none(v):
    return v in (None, "none")


def _size(f):
    return f.get("filesize") or f.get("filesize_approx") or 0


def _direct(f):
    return (f.get("protocol") or "https") in ("https", "http")


def _prefer_direct(cands):
    direct = [f for f in cands if _direct(f)]
    return direct or cands


def pick_audio(formats):
    cands = [
        f for f in formats
        if _none(f.get("vcodec")) and not _none(f.get("acodec"))
        and (f.get("ext") == "m4a" or str(f.get("acodec") or "").startswith("mp4a"))
    ]
    cands = _prefer_direct(cands)
    cands.sort(
        key=lambda f: (
            f.get("language_preference") or 0,          # original audio track first
            "drc" not in str(f.get("format_id", "")),   # avoid dynamic-range-compressed copies
            f.get("abr") or f.get("tbr") or 0,
        ),
        reverse=True,
    )
    return cands[0] if cands else None


def _height_ok(f, max_height):
    return not max_height or (f.get("height") or 0) <= max_height


def pick_video(formats, max_height):
    cands = [
        f for f in formats
        if str(f.get("vcodec") or "").startswith("avc1") and _none(f.get("acodec"))
        and f.get("ext") == "mp4" and _height_ok(f, max_height)
    ]
    cands = _prefer_direct(cands)
    cands.sort(key=lambda f: (f.get("height") or 0, f.get("fps") or 0, f.get("tbr") or 0), reverse=True)
    return cands[0] if cands else None


def pick_progressive(formats, max_height):
    cands = [
        f for f in formats
        if str(f.get("vcodec") or "").startswith("avc1") and not _none(f.get("acodec"))
        and f.get("ext") == "mp4" and _height_ok(f, max_height)
    ]
    cands = _prefer_direct(cands)
    cands.sort(key=lambda f: (f.get("height") or 0, f.get("tbr") or 0), reverse=True)
    return cands[0] if cands else None


def select_formats(formats, mode, max_height):
    audio = pick_audio(formats)
    if mode == "audio":
        if audio:
            return [audio]
        prog = pick_progressive(formats, None)  # last resort: audio comes out of an MP4
        return [prog] if prog else []
    video = pick_video(formats, max_height)
    if video and audio:
        return [video, audio]
    prog = pick_progressive(formats, max_height) or pick_progressive(formats, None)
    return [prog] if prog else []


# ---------------------------------------------------------------------------
# Downloading


def _download(job):
    import yt_dlp
    from yt_dlp.utils import DownloadCancelled, DownloadError, parse_bytes

    workdir = job["workdir"]
    progress_path = job["progress_path"]
    cancel_path = job["cancel_path"]
    os.makedirs(workdir, exist_ok=True)

    state = {"phase": "info", "log": []}

    def emit(**kw):
        state.update(kw)
        state["time"] = time.time()
        _write_json(progress_path, state)

    def log(msg):
        msg = _clean(msg)
        if msg:
            state["log"] = (state["log"] + [msg])[-30:]

    def cancelled():
        return os.path.exists(cancel_path)

    class Logger:
        def debug(self, msg):
            if not msg.startswith("[debug] "):
                log(msg)

        def info(self, msg):
            log(msg)

        def warning(self, msg):
            log("WARNING: " + msg)

        def error(self, msg):
            log(msg)

    part_sizes = []
    current = {"index": 0}

    def hook(d):
        if cancelled():
            raise DownloadCancelled()
        status = d.get("status")
        downloaded = d.get("downloaded_bytes") or 0
        total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
        i = current["index"]
        if total and i < len(part_sizes):
            part_sizes[i] = total
        if status == "finished":
            downloaded = total or downloaded
        done_before = sum(part_sizes[:i])
        grand_total = sum(part_sizes)
        overall = (done_before + downloaded) / grand_total if grand_total else None
        emit(
            phase="downloading",
            downloaded=downloaded,
            total=total or None,
            speed=d.get("speed"),
            eta=d.get("eta"),
            overall=min(overall, 1.0) if overall is not None else None,
        )

    base = {
        "quiet": True,
        "noprogress": True,
        "no_color": True,
        "logger": Logger(),
        "progress_hooks": [hook],
        "noplaylist": True,
        "extract_flat": "in_playlist",
        "paths": {"home": workdir, "temp": workdir},
        "cachedir": job.get("cache_dir") or False,
        "overwrites": True,
        "retries": 10,
        "fragment_retries": 10,
        # Anything will do for the info step; the real choice happens below.
        "format": "b/bv*/ba*",
    }
    rate = (job.get("rate_limit") or "").strip()
    if rate:
        limit = parse_bytes(rate)
        if limit:
            base["ratelimit"] = limit

    emit(phase="info")
    try:
        with yt_dlp.YoutubeDL(base) as ydl:
            info = ydl.extract_info(job["url"], download=False)
    except DownloadCancelled:
        return {"ok": False, "cancelled": True}
    except DownloadError as e:
        return {"ok": False, "error": _clean(e), "log": state["log"]}

    if info is None:
        return {"ok": False, "error": "yt-dlp returned no information for this link.", "log": state["log"]}

    # Playlists and channels: hand the list of videos back so Swift can queue them.
    if info.get("_type") in ("playlist", "multi_video"):
        urls = []
        for entry in info.get("entries") or []:
            if not entry:
                continue
            url = entry.get("url") or entry.get("webpage_url")
            if not url and entry.get("id"):
                url = "https://www.youtube.com/watch?v=" + entry["id"]
            if url:
                urls.append(url)
        return {"ok": True, "playlist": urls, "title": info.get("title")}

    meta = {
        "id": info.get("id"),
        "title": info.get("title"),
        "channel": info.get("channel") or info.get("uploader") or info.get("creator"),
        "uploader": info.get("uploader"),
        "duration": info.get("duration"),
        "upload_date": info.get("upload_date"),
        "webpage_url": info.get("webpage_url") or job["url"],
        "description": info.get("description"),
        "view_count": info.get("view_count"),
        "thumbnail": info.get("thumbnail"),
    }
    emit(title=meta["title"], channel=meta["channel"], thumbnail=meta["thumbnail"], duration=meta["duration"])

    selected = select_formats(info.get("formats") or [], job.get("mode", "video"), job.get("max_height"))
    if not selected:
        return {
            "ok": False,
            "error": "YouTube didn't offer a format the iPhone can play (H.264/AAC) for this video. "
                     "Try again later or update yt-dlp in Settings.",
            "log": state["log"],
        }

    part_sizes.extend(_size(f) for f in selected)
    files = []
    for i, f in enumerate(selected):
        if cancelled():
            return {"ok": False, "cancelled": True}
        current["index"] = i
        kind = "audio" if _none(f.get("vcodec")) else "video"
        emit(
            phase="downloading", part=i + 1, part_count=len(selected), part_kind=kind,
            downloaded=0, total=part_sizes[i] or None, speed=None, eta=None,
            height=f.get("height"),
        )
        params = dict(base, format=f["format_id"], outtmpl={"default": "part%d.%%(ext)s" % i})
        params.pop("extract_flat", None)
        try:
            with yt_dlp.YoutubeDL(params) as ydl:
                res = ydl.process_ie_result(copy.deepcopy(info), download=True)
        except DownloadCancelled:
            return {"ok": False, "cancelled": True}
        except DownloadError as e:
            if cancelled():
                return {"ok": False, "cancelled": True}
            return {"ok": False, "error": _clean(e), "log": state["log"]}

        path = None
        for d in (res or {}).get("requested_downloads") or []:
            path = d.get("filepath") or d.get("filename")
        if not path or not os.path.exists(path):
            matches = [p for p in glob.glob(os.path.join(workdir, "part%d.*" % i))
                       if not p.endswith((".part", ".ytdl", ".json"))]
            path = matches[0] if matches else None
        if not path:
            return {"ok": False, "error": "The download finished but its file is missing.", "log": state["log"]}
        has_audio = not _none(f.get("acodec"))
        files.append({"path": path, "kind": kind, "has_audio": has_audio})

    emit(phase="finishing", overall=1.0)
    meta.update({"ok": True, "files": files, "log": state["log"]})
    return meta
