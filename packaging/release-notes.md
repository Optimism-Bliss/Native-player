Native TorBox STRM app: browse the TorBox STRM web UI and play in a libmpv player (Fladder-style controls).

**Server:** needs TorBox STRM `1.7.0-dev.5` or later, which carries the in-app player bridge.

**Updates:** the app checks this page for new releases and installs them (Android asks for permission to install apps once). Builds from 0.4.3 on are signed with a fixed release key; if you installed 0.4.0–0.4.2, uninstall it once before installing this version. Older servers still open in the app, but ▶ keeps using external players.

| Platform | File |
| --- | --- |
| Windows 10/11 x64 | `TorBox-STRM-windows-x64-setup.exe` (installer, no admin rights, Start menu shortcut) or `TorBox-STRM-windows-x64-portable.zip` (extract the whole folder, then run `TorBoxSTRM.exe`). Uses the system WebView2 runtime. |
| Linux x64 / arm64 | `TorBox-STRM-linux-*.tar.gz` (needs `libwebkit2gtk-4.1-0` and `libmpv2`, see README-linux.txt) |
| Android 7.0+ | `TorBox-STRM-android-arm64-v8a.apk` for most phones and TV boxes; `armeabi-v7a` for older 32-bit devices |

The Android APKs are signed with a @ANDROID_SIGNING@. Checksums are in `SHA256SUMS.txt`.

Verified end to end on Linux arm64 against a local server (browse, login, play, seek, track switching, next episode, progress sync, error/retry). Windows and Android builds come from CI and still need checking on real devices, including HDR output and hardware decoding.
