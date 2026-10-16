# yt-dlp Direct

> Personal-use project. Downloading from YouTube may go against YouTube's Terms of Service, so only download what you have the right to keep. Not affiliated with YouTube, yt-dlp, a-Shell or VLC.

**Sister project:** [yt-dlp-ashell-ios](https://github.com/Projectattic/yt-dlp-ashell-ios) is the earlier version, a front end that drives yt-dlp in [a-Shell](https://holzschu.github.io/a-Shell_iOS/) through Shortcuts.

An iPhone app that runs **yt-dlp inside the app**, with no a-Shell, no Shortcuts and no app switching. It shows live download progress, queues several links, and saves tagged MP4/M4A files to its own folder or straight into VLC's.

## First-time setup (on your Mac)

1. **Get Python for iOS.** In Terminal:
   ```
   cd yt-dlp-direct-ios
   bash setup_python.sh
   ```
   This downloads the official Python 3.14 iOS package (BeeWare *Python-Apple-support*, about 37 MB) and places `Python.xcframework` next to the project.
2. **Open `YtDlDirect.xcodeproj`** in Xcode, select the **YtDlDirect** target, go to **Signing & Capabilities**, and pick your Team.
3. **Run it on your iPhone** (⌘R). On first launch the app downloads the latest yt-dlp from PyPI, which takes a few seconds.
4. *(Optional)* **Settings › Download folder › Choose folder…** and pick **On My iPhone › VLC**. Downloads then land directly in VLC, and tapping a file plays it there.

## How it works

```
link ─▶ yt-dlp (embedded Python 3.14)          ─▶ AVFoundation                  ─▶ download folder
        picks iPhone-friendly streams:              joins video + audio,            "Title.mp4" / "Title.m4a"
        H.264 video + AAC audio, downloads them     writes title, artist (channel),
        separately, reports progress                album artist, date, cover art
```

* **No ffmpeg on iOS**, so the app picks streams the iPhone can handle natively and lets Apple's own media framework do the merging and tagging. Nothing is re-encoded. Video tops out at **1080p**, because that's the best H.264 YouTube offers.
* **Progress** comes from yt-dlp's progress hooks. The bridge writes them to a small file, and the app reads it four times a second.
* **Updates:** Settings › Update yt-dlp fetches the newest release from PyPI. No rebuild in Xcode needed.
* **Library details** (titles, channels, upload dates, thumbnails) are kept in the app's own storage, so the download folder only ever contains the media files.
* **Playlists and channels** are expanded, and each video is added to the queue.

## Limits

* iOS pauses apps shortly after you leave them, so keep the app open during long downloads. The screen is kept awake while downloading; you can change this in Settings.
* yt-dlp warns that no JavaScript runtime is available, as it did in a-Shell. Some videos may therefore offer fewer formats. Video falls back to 360p MP4 if YouTube withholds the higher-quality H.264 streams.
* With a free Apple ID, re-run from Xcode every 7 days.

## Share-sheet shortcut (optional)

To send a link from the YouTube app: create a shortcut that receives URLs, **URL Encode** the input, then **Open URLs** with `ytdl-direct://download?url=` followed by the encoded text. Add `&start=1` at the end to start the download immediately.

## Project layout

```
setup_python.sh            fetches Python.xcframework (run once)
app/ytdl_bridge.py         Python side: install/update yt-dlp, pick formats, download, progress
YtDlDirect/
  Python/                  C bridge to the interpreter + Swift wrapper (PythonRuntime)
  Services/                DownloadManager (queue, yt-dlp setup), MediaFinisher (AVFoundation),
                           LibraryStore (folder, metadata), thumbnails, VLC
  Models/, Views/          settings, jobs, library items; Download / Library / Settings screens
```

The "Process Python libraries" build phase copies `app/` and Python's standard library into the app, using the official `Python.xcframework/build/utils.sh`.
