# Vendored packages

| Package | Source | Changes |
| --- | --- | --- |
| `media_kit`, `media_kit_libs_video`, `media_kit_libs_{android,ios,macos}_video`, `media_kit_libs_windows_video`, `media_kit_libs_linux` | [DonutWare/media-kit](https://github.com/DonutWare/media-kit) at `05033ed3c7c538b58dfbbd4c29d6dc0479ce7dec` (fork of [media-kit/media-kit](https://github.com/media-kit/media-kit), MIT) | none |
| `media_kit_video` | same commit | Linux texture fix in `linux/texture_gl.cc` |

Kept here so builds do not depend on the fork repository. The prebuilt libmpv / ANGLE binaries are still
downloaded at build time from the media-kit releases (`media-kit/libmpv-android-video-build`, etc.).
Licenses: see each package's `LICENSE`.
