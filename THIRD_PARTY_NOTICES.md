# Third-party software

colorful is distributed under GPL-3.0-or-later. Binary packages also contain
or dynamically load third-party components under their own licenses.

- Qt 6 — LGPL-3.0/GPL-3.0/commercial; <https://www.qt.io/licensing>
- libmpv/mpv — GPL-2.0-or-later for distributed desktop builds;
  <https://github.com/mpv-player/mpv>
- FFmpeg and ffprobe — GPL-3.0-or-later for distributed desktop builds;
  Linux binaries are produced by BtbN/FFmpeg-Builds;
  <https://ffmpeg.org/>, <https://github.com/BtbN/FFmpeg-Builds>
- yt-dlp — Unlicense; <https://github.com/yt-dlp/yt-dlp>
- SQLite — public domain; <https://sqlite.org/copyright.html>
- Nunito — SIL Open Font License 1.1; the license is embedded with the font
  and available at `assets/fonts/OFL.txt` in the source tree.
- Rust and JavaScript dependencies retain the licenses declared by their
  respective packages.

Exact dependency versions and build provenance should be recorded alongside
each public release. The corresponding colorful source is the Git commit named
in the application's About page. A public release must also preserve the
source-availability obligations of the exact mpv/FFmpeg binaries it ships.
