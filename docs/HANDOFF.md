# Bàn giao: TorBox STRM app (libmpv)

Cập nhật: 2026-11-24.

## Trạng thái

- App Flutter cho Android, Windows và Linux: màn hình kết nối → WebView giao diện TorBox STRM → player libmpv kiểu Fladder.
- Server: TorBox STRM `1.7.0-dev.5` trở lên (repo server private). Phía web: cầu nối trong `src/ui-core.js` và endpoint `/api/logo` (logo TMDB).
- Tự cập nhật: app đọc GitHub Releases của repo public này (`lib/update/`). Android tải APK và mở trình cài; Windows chạy bộ cài im lặng rồi mở lại app; Linux giải nén đè lên thư mục app nếu ghi được, nếu không thì mở trang release.
- Ký APK: CI ký bằng khoá release lấy từ secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. Mất khoá này thì không cập nhật đè được nữa; người dùng phải gỡ cài lại.

## Cầu nối web ↔ app

App đăng ký handler `torboxStrm` với `WebViewJavaScriptAccessPolicy.origins({origin máy chủ})`, chỉ nhận lời gọi từ main frame, và chèn `window.TorBoxStrmApp = {v:1, platform}` lúc trang bắt đầu tải.

Web → app:

```js
await window.webviewAll.callHandler('torboxStrm', {
  type: 'play', v: 1, index: 0, start: 1234.5,
  queue: [{ key, url: 'https://…/s/<key>.mkv', title, subtitle: {url, lang, label} | null }]
})  // → {ok: true} | {ok: false, error}
```

Phụ đề: khi mở mỗi file, app gửi `{type:'subs', key}`; trang gọi `/api/subs` rồi trả `torboxStrm({type:'subs', key, list, auto, prefer})` và nội dung `torboxStrm({type:'subText', key, id, lang, label, format, text})` (lấy qua `/api/subs/get` bằng phiên của trang). App chọn phụ đề server bằng `{type:'subGet', key, id, lang, label}`, tắt bằng `{type:'subOff', key}`. Tìm online: app gửi `{type:'subSearch', key, langs}`, trang gọi `/api/subs/search` và trả `torboxStrm({type:'subSearch', key, results:[{id,lang,label,src,match,downloads,blocked}], note, langs})`. `auto` theo đúng logic của ArtPlayer (đã chọn → tải lên → điểm ≥ 2); `prefer` là phụ đề addon đúng ngôn ngữ ưu tiên, app chỉ bật khi file không có phụ đề nhúng ngôn ngữ đó.

App → web: `window.TorBoxStrmBridge.event({type:'progress', key, pos, dur})` mỗi 15 giây, khi tạm dừng và khi đóng; `{type:'closed', key}` khi rời player. Trang tự gọi `/api/progress` bằng phiên đăng nhập của nó.

Khi chạy trong app, trang thêm lựa chọn "Trình phát trong app" và đặt nó làm mặc định. Mọi lệnh `play(idx)` của thư viện (kể cả nguồn addon, `/x/…`) đều chuyển sang app.

## Đã kiểm thử (Linux arm64, Xvfb, backend `develop` + TorBox API giả)

| Bước | Kết quả |
| --- | --- |
| Địa chỉ sai (không có `/health`) | Báo "không phải TorBox STRM" |
| Kết nối, đăng nhập bằng form web, khởi động lại app vẫn còn đăng nhập | OK (Linux cần profile WebKit có tên để lưu cookie) |
| Phát tập HEVC 10-bit HDR10 qua `/s/` → `requestdl` → CDN (206) | OK, thẻ "1080p · HEVC · HDR10" |
| Phim H.264, 2 audio, SRT tiếng Việt và ASS nhúng | SRT tự chọn theo `slang`, có dấu đầy đủ; ASS hiện đúng style qua libass |
| Tua bằng phím, chỉ báo ±, tập kế, tự sang tập khi hết | OK |
| Tiến độ về server | `/api/progress` lưu cho từng tập, trang hiện thanh tiến độ |
| Đóng/mở player nhiều lần | OK sau khi chuyển sang player dùng chung (xem bên dưới) |
| CDN không phản hồi | Thử lại 2 lần → bảng lỗi → "Thử lại" phát tiếp |

Chưa kiểm thử: Windows và Android trên máy thật, âm thanh (VPS không có thiết bị âm thanh), HDR/tone mapping trên màn hình thật, giải mã phần cứng (llvmpipe), mất mạng giữa chừng trên Wi-Fi/4G.

## Vấn đề đã gặp và cách xử lý

1. **Linux: app không hiện cửa sổ khi không có desktop session.** Portal `org.freedesktop.portal.Desktop` treo, khiến GTK/Flutter kẹt trước khung hình đầu. Đây là lỗi môi trường. Khi test headless, chạy app bằng `dbus-run-session -- ./torbox_strm_player`.
2. **Linux: `window_manager` deadlock.** Runner Linux chỉ hiện cửa sổ sau khung hình đầu, nên `main()` không được `await waitUntilReadyToShow` trước `runApp`.
3. **Linux: đóng player làm crash hoặc đứng hình.** Khi huỷ video output, context EGL của mpv đang được luồng raster giữ (`EGL_BAD_ACCESS`). Bản gốc thì libepoxy abort ở `eglDestroyImageKHR`; vá chỗ đó thì Flutter lại ngừng vẽ. Cách xử lý:
   - App giữ **một** `Player`/`VideoController` cho cả vòng đời (`PlayerHost`, giống Fladder); khi đóng chỉ `stop()`.
   - `third_party/media_kit_video` vá `video_output.cc`/`texture_gl.cc`: dọn tài nguyên GL của mpv trong context của mpv, gọi `eglDestroyImageKHR` qua `eglGetProcAddress`, và luôn trả lại context cũ hoặc gỡ context. Phần này giờ chỉ chạy khi thoát app.
   - Nên báo lỗi này lên `DonutWare/media-kit`.
4. **Phụ đề nhúng không hiện ngay khi đổi track giữa chừng.** mpv chỉ hiện sự kiện được đọc sau thời điểm đổi. App tua tại chỗ một lần sau khi đổi track nhúng.

## Cử chỉ (cảm ứng)

Chạm: hiện/ẩn điều khiển. Chạm đúp trái/phải: ±10 giây, giữa: phát/dừng. Vuốt dọc nửa trái: độ sáng (chỉ cửa sổ app, trả lại khi thoát player); nửa phải: âm lượng media. Hai ngón: chụm để Lấp đầy / Vừa màn hình. Âm lượng và độ sáng dùng code Android riêng trong `MainActivity.kt` (kênh `torboxstrm/intent`), không dùng plugin: `volume_controller` làm sập app trên Linux không có thiết bị âm thanh. Chưa kiểm thử trên máy thật.

## Làm sau

Từ bản rà soát mô tả bàn giao ban đầu:

1. **Cache link CDN theo key trong khi `FORWARD_CLIENT_IP` mặc định bật.** Nếu TorBox khoá link theo IP, người xem thứ hai trong thời gian TTL sẽ nhận link tạo cho IP của người đầu. Cần thử trên hai mạng; nếu đúng là khoá theo IP thì cache theo key + IP. Liên quan: khi CDN trả 403 giữa chừng, app mở lại `/s/…` nhưng server có thể trả lại đúng link cũ đang còn trong cache (`LINK_CACHE_TTL_SECS`, mặc định 1800 giây). Server nên bỏ link khỏi cache khi client mở lại ngay sau lỗi, hoặc app nên dùng `/api/v1/playback/resolve` của nhánh `native-player-api`.
2. **Trường hợp chưa đặt `WEB_PASSWORD`.** Bản cũ trả 403 "Web UI đang tắt"; màn hình kết nối nên báo rõ trường hợp này. (Bản `develop` đăng nhập bằng form, cần kiểm tra lại hành vi.)
3. **Server chạy bản cũ.** Server cần bản có cầu nối (`1.7.0-dev.5`+); bản cũ hơn vẫn duyệt được nhưng ▶ mở player ngoài.
4. **Nút player trong `ui.html`/`ui-core.js`.** Đã gộp vào cơ chế `PLAYERS` của `develop`: app tự dựng URL từ dữ liệu của trang, nhưng chỉ chấp nhận `/s/…` và `/x/…` (không tin URL tuỳ ý). Nhánh `torbox-player-android-link` thêm "TorBox Player" (intent Android) cho trình duyệt; cần thống nhất tên package với app này (`io.github.optimismbliss.torboxstrm`).

Thêm:

5. Ký APK bằng khoá release (thêm secrets) và cân nhắc gói Linux (AppImage/Flatpak có sẵn WebKitGTK) cùng bộ cài Windows.
6. Android TV: điều hướng bằng remote, banner, `LEANBACK_LAUNCHER`.
7. Kiểm thử theo thiết bị (máy/GPU/màn hình): H.264 SDR, HEVC Main10/HDR10, MKV nhiều audio/phụ đề, AV1, HLG, Dolby Vision, ASS/PGS. Phân biệt "giải mã được" với "xuất đúng HDR".
8. Nút ▶ trên web bị trùng: nút tròn ▶ và "▶ Phát" đều mở player trong app.
9. **Desktop chỉ nên chạy một instance.** Mở app lần hai trên Linux thì WebView trắng ("named profile is in use by another process"); Windows có thể tương tự. Linux: bỏ `G_APPLICATION_NON_UNIQUE` và cho `activate` đưa cửa sổ cũ lên; Windows: mutex + chuyển tiếp sang cửa sổ đang chạy. Làm cùng phần deep link.
10. ~~Tìm phụ đề online trong player~~: đã có (chip "Tìm online" trong bảng Phụ đề, server ≥ 1.7.0-dev.7).
11. **Linux: menu nổi bị WebView che.** WebKitGTK vẽ đè lên lớp Flutter (menu "⋯", hộp thoại cập nhật hiện sau WebView nhưng có thể bị che một phần). Cân nhắc ẩn WebView (Offstage) khi mở menu/hộp thoại, hoặc dùng route riêng.
12. **Windows chưa được kiểm thử trên máy thật.** Bản 0.4.3 đặt thư mục dữ liệu WebView2 trong `%LOCALAPPDATA%\TorBoxSTRM\WebView2`, báo lỗi rõ khi thiếu WebView2 Runtime và ghi log từng bước vào `%LOCALAPPDATA%\TorBoxSTRM\torbox-strm.log`. Nếu vẫn không tải được trang đăng nhập, đọc log đó.
13. **4K hiển thị nhỏ** (báo từ máy thật, chưa tái hiện): đã thêm chế độ khung hình (Vừa/Lấp đầy/Kéo giãn/16:9/21:9/4:3, chụm ngón trên cảm ứng). Nếu khung hình vẫn nhỏ ở chế độ "Vừa màn hình", cần ảnh chụp + hộp "Thông tin phát" để kiểm tra texture của media_kit trên thiết bị đó.
