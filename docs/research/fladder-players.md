# Nghiên cứu: Fladder (DonutWare/Fladder, nhánh develop, v0.12.1) chơi video trên Windows và Android TV thế nào

Mục tiêu: hiểu vì sao Fladder không gặp các lỗi của TorBox STRM (Windows: trình phát nằm sau / đọng hình / treo;
TV box: rơi khung, phụ đề) và nên học gì. Fladder là GPL-3.0 như app này.

## 1. Khác biệt gốc rễ

| | Fladder | TorBox STRM |
| --- | --- | --- |
| Giao diện | **Flutter thuần** (gọi API Jellyfin) | **Trang web của server** trong WebView |
| Windows | Một cửa sổ Flutter; trình phát là một màn hình trong cùng cửa sổ | WebView2 nhúng bị đen trên card AMD → cửa sổ WebView2 riêng + cửa sổ Flutter cho trình phát → phải ẩn/hiện/ghim/toàn màn hình qua lại |
| Android TV | **Trình phát native**: Activity riêng dùng Media3/ExoPlayer | libmpv (media_kit) vẽ vào texture Flutter |

Fladder không có bài toán "hai cửa sổ" vì giao diện không phải web.

## 2. Windows

- Trình phát mặc định: **libmpv (media_kit)**, có thêm **libMDK (fvp)** để chọn (`lib/models/settings/video_player_settings.dart`, `PlayerOptions`).
- Toàn màn hình chỉ là `windowManager.setFullScreen` trên chính cửa sổ đó (`lib/widgets/full_screen_helpers/full_screen_helper_desktop.dart`); không ẩn/hiện, không always-on-top.
- Thanh tiêu đề tự vẽ (`TitleBarStyle.hidden`, `lib/util/window_helper.dart`); nhớ kích thước cửa sổ.
- **Nhiều cửa sổ thật** bằng `desktop_multi_window` (mỗi cửa sổ một Flutter engine riêng, tham số `--newWindow`), media session gộp cho mọi cửa sổ (`lib/wrappers/multi_window_media_session.dart`).
- **Phím media / bảng điều khiển media của Windows** qua `smtc_windows` (SMTC).
- **Chế độ HTPC** (`--htpc`): mở toàn màn hình, giao diện điều khiển bằng remote/phím.

Bài học cho app này: lỗi Windows nằm ở kiến trúc hai cửa sổ, không ở trình phát. Hai hướng:
1. **Một cửa sổ**: cửa sổ WebView2 gắn làm **cửa sổ con** (Win32 `SetParent`) của cửa sổ Flutter; bấm ▶ thì ẩn cửa sổ con, trình phát vẽ trong cùng cửa sổ; không đổi kích thước/ghim/ẩn cửa sổ chính.
2. **Cửa sổ trình phát tạo mới mỗi lần phát** bằng `desktop_multi_window` (như Fladder mở cửa sổ mới): cửa sổ mới tạo luôn được Windows đưa lên trước, đóng là huỷ; không dùng lại cửa sổ ẩn.
Thêm SMTC (phím media) là tính năng nhỏ, đáng làm.

## 3. Android TV

- Chế độ leanback (TV) **bắt buộc trình phát native** (`PlayerOptions.available` → `{nativePlayer}`); điện thoại chọn được MPV / MDK / Native.
- `VideoPlayerActivity` (Activity riêng, giao diện Jetpack Compose) + `player/ExoPlayer.kt`:
  - **Media3 1.11** ExoPlayer, video vẽ thẳng ra Surface (không chép khung, không qua GPU của Flutter).
  - **`org.jellyfin.media3:media3-ffmpeg-decoder`**: giải mã DTS / TrueHD / AC3 khi máy không có decoder (`EXTENSION_RENDERER_MODE_ON`, `setEnableDecoderFallback(true)`).
  - **`io.github.peerless2012:ass-media`**: libass cho ExoPlayer (`buildWithAssSupport`, `AssRenderType.CUES`) → phụ đề ASS đủ kiểu chữ; PGS ExoPlayer hỗ trợ sẵn.
  - Audio offload bật; **tunneling** là tuỳ chọn; chế độ ít tài nguyên giảm bộ đệm (`DefaultLoadControl.setTargetBufferBytes`).
  - **Khớp tần số màn hình** (`utility/RefreshRateHelper.kt`): chọn mode theo độ phân giải + fps, **chờ màn hình đổi xong** (lắng nghe DisplayManager, có hạn giờ) rồi mới phát; khôi phục mode cũ **trước khi Activity đóng** (tránh mất tiếng passthrough).
  - Giữ màn hình sáng khi đang phát; điều khiển D-pad riêng (`utility/KeyHandler.kt`).
- Giao tiếp Flutter ↔ native bằng **pigeon** (`lib/src/video_player_helper.g.dart`, `lib/wrappers/players/native_player.dart`).
- Mã Kotlin của Fladder ~9.000 dòng (cả giao diện Compose của trình phát).

Bài học cho app này (Mi Box S: rơi khung với libmpv, giải mã trực tiếp mất hình trên ROM mod, phụ đề):
ExoPlayer vẽ thẳng ra Surface bằng đường mà mọi TV box đều được tối ưu (Netflix/YouTube dùng cùng đường) nên mượt
trên GPU yếu, vẫn có ASS (ass-media) và PGS, giải mã DTS/TrueHD bằng ffmpeg extension, khớp tần số chuẩn.

## 4. Đề xuất

1. **Windows**: làm hướng "một cửa sổ" (2.1); nếu SetParent không ổn trên máy thật thì hướng `desktop_multi_window` (2.2). Thêm SMTC.
2. **Android TV**: trình phát native Media3 riêng cho TV (giữ libmpv cho điện thoại/desktop), theo mẫu Fladder:
   ExoPlayer + ffmpeg audio + ass-media + khớp tần số + tunneling tuỳ chọn; giao diện điều khiển D-pad tối giản
   (tua, tập kế, âm thanh, phụ đề, thông tin); nối với phần hiện có: phụ đề từ server (SubtitleConfiguration),
   tiến độ xem, tập kế, remote từ điện thoại (TvReceiver gọi vào trình phát native qua MethodChannel/pigeon).
   Việc lớn (ước 1.500–3.000 dòng Kotlin + Dart), làm trên nhánh riêng, bật bằng tuỳ chọn "Trình phát TV: Native / MPV".
