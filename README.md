# TorBox STRM app

App native cho TorBox STRM trên **Android, Windows và Linux**. Người dùng nhập địa chỉ máy chủ, đăng nhập và duyệt thư viện ngay trên giao diện web của TorBox STRM trong app. Bấm ▶ sẽ mở trình phát native dùng **libmpv** (`media_kit`, cùng bản fork mà [Fladder](https://github.com/DonutWare/Fladder) dùng), với giao diện điều khiển theo phong cách Fladder. Video đi thẳng từ TorBox CDN tới thiết bị và được giải mã tại chỗ. Không cần Jellyfin, không chuyển mã trên VPS.

## Luồng hoạt động

```
Màn hình kết nối ──GET /health──▶ máy chủ TorBox STRM
        │
        ▼
WebView (giao diện web, đăng nhập bằng cookie của server)
        │  window.webviewAll.callHandler('torboxStrm', {type:'play', …})
        │  (chỉ origin của máy chủ đã cấu hình, chỉ main frame)
        ▼
Player (libmpv) ──/s/<key>.<ext>──▶ server ──302──▶ TorBox CDN
        │
        └─ TorBoxStrmBridge.event({type:'progress'|'closed'}) ──▶ trang web ──▶ /api/progress
```

- App **không** giữ mật khẩu hay cookie. Đăng nhập, tiến độ xem và phụ đề đều đi qua trang web.
- App chỉ mở link phát ổn định `/s/<key>.<ext>` (thư viện) hoặc `/x/<key>.<ext>` (nguồn addon). Mọi URL khác đều bị từ chối (xem `lib/bridge.dart` và `test/bridge_test.dart`).
- Khi link CDN hết hạn hoặc mạng chập chờn, player mở lại link ổn định ở đúng vị trí đang xem (tự thử 2 lần, sau đó hiện nút "Thử lại").

Phía server cần TorBox STRM `1.7.0-dev.5` trở lên (có cầu nối trình phát trong app và logo TMDB). Với server cũ, app vẫn duyệt được thư viện nhưng nút ▶ vẫn dùng player ngoài.

App tự kiểm tra bản mới trên GitHub Releases của repo này (menu ⋯ / nút Back ở trang đầu → **Kiểm tra cập nhật**).

## Trình phát

- Điều khiển kiểu Fladder: dải mờ trên/dưới, "Kết thúc lúc …", thẻ thông tin (độ phân giải · codec · HDR10/HLG), thanh tiến độ có phần đã tải, nút ±10/30 giây, tập trước/sau, âm lượng, toàn màn hình.
- Chọn audio/phụ đề (track nhúng và phụ đề từ server), chỉnh độ trễ và cỡ chữ phụ đề. libass vẽ mọi định dạng phụ đề, kể cả ASS có style. Phụ đề tự đẩy lên khi bảng điều khiển hiện.
- Desktop: click để phát/dừng, double-click để toàn màn hình. Phím: Space/K, ←/→ ±5 s, J/L −10/+30 s, ↑/↓ âm lượng, M tắt tiếng, F/F11 toàn màn hình, N/P tập sau/trước, Esc thoát.
- Cảm ứng: chạm để hiện/ẩn điều khiển, chạm đúp trái/phải để tua ±10 s.
- Hộp "Thông tin phát" hiện container, codec, pixel format, màu/HDR, giải mã phần cứng. Dùng nó khi kiểm thử trên thiết bị thật.
- Tự chuyển tập kế khi hết tập. Tiến độ được gửi mỗi 15 giây, khi tạm dừng và khi đóng.

## Build

Flutter 3.50.1 (stable).

```sh
flutter pub get
flutter analyze && flutter test

# Linux: cần clang cmake ninja-build pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev libmpv-dev
flutter build linux --release
# Windows (trên Windows)
flutter build windows --release
# Android
flutter build apk --release --split-per-abi
```

GitHub Actions (`.github/workflows/build.yml`) build cả Linux x64/arm64, Windows x64 và Android. Khi đẩy tag `v*`, workflow tạo GitHub Release (prerelease) kèm `SHA256SUMS.txt`. APK được ký bằng khoá release nếu repo có các secret `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`; nếu không có thì ký bằng khoá debug.

## Mã nguồn

| Đường dẫn | Nội dung |
| --- | --- |
| `lib/bridge.dart` | Hợp đồng lệnh giữa web và app, kiểm tra URL |
| `lib/screens/connect_screen.dart` | Nhập và kiểm tra địa chỉ máy chủ |
| `lib/screens/browser_screen.dart` | WebView, cầu nối JS (giới hạn theo origin), chặn điều hướng ra ngoài |
| `lib/player/playback_controller.dart` | Lõi phát: libmpv dùng chung (`PlayerHost`), mở/thử lại, track, tiến độ |
| `lib/player/player_screen.dart` | Màn hình phát và điều khiển kiểu Fladder |
| `lib/player/widgets/` | Thanh tiến độ, bảng chọn track, hộp thông tin |
| `third_party/media_kit_video/` | `media_kit_video` (MIT) từ fork DonutWare, có vá phần dọn EGL trên Linux (xem `docs/HANDOFF.md`) |

Thông tin bàn giao, kết quả kiểm thử và các việc làm sau nằm trong [`docs/HANDOFF.md`](docs/HANDOFF.md).

## Bên thứ ba

- [media_kit](https://github.com/media-kit/media-kit) / [DonutWare fork](https://github.com/DonutWare/media-kit): MIT. libmpv/FFmpeg đi kèm theo giấy phép LGPL/GPL của bản build tương ứng.
- [webview_all](https://pub.dev/packages/webview_all): MIT.
- Phông Rubik (SIL OFL 1.1) và Droid Sans Fallback (Apache 2.0), lấy từ asset của Fladder.
- Giao diện player tham khảo bố cục của Fladder (GPLv3).

## Giấy phép

GPL-3.0, xem [`LICENSE`](LICENSE). `third_party/media_kit_video` giữ giấy phép MIT gốc.
