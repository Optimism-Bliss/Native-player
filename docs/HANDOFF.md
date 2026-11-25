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

## 1.1.0

- **Phụ đề tụt khi "Lấp đầy":** libass vẽ phụ đề trong khung hình, nên khi khung bị phóng to và cắt đáy, phụ đề rơi khỏi màn hình. `PlayerScreen._syncFrameCrop()` tính phần đáy bị cắt (tỉ lệ video so với màn hình) và `PlaybackController.setFrameCrop()` đặt `sub-pos` trong vùng còn thấy. Đã kiểm thử trên Linux ở cửa sổ 2,29:1.
- **Phụ đề từ máy:** chip "Từ máy" trong bảng Phụ đề (`file_picker`), nhận .srt/.ass/.ssa/.vtt, tự đoán mã hoá (UTF-8, UTF-16, Latin-1; VNI/TCVN3 chưa chuyển đổi). Gắn với file đang xem, nạp lại sau khi player tự mở lại. Chưa thử trên Android (hộp chọn file của hệ thống).
- **Tốc độ phát:** nút đồng hồ cạnh nút tỉ lệ khung hình, 0.5×–2×, mặc định 1× cho mỗi phiên; mpv giữ cao độ giọng. Đã thử 2× trên Linux.

## Nhánh `dev` (chưa phát hành)

- **Android: trang trong app khác Chrome (khoảng trống lớn, chữ to).** `webview_all_android` tắt thẻ viewport (`setUseWideViewPort(false)`), nên WebView coi trang là trang máy tính và tự phóng chữ (text autosizing): thẻ diễn viên dài ra, để lại khoảng đen. `BrowserScreen._setup()` bật lại viewport và cố định `setTextZoom(100)`. Mỗi trang ghi một dòng `viewport w=… dpr=… font=… safe=…` vào log để so với trình duyệt. Cần xác nhận trên điện thoại.
- **Windows không hiện trang đăng nhập (máy AMD RX 5600 XT, Win 10 IoT LTSC, WebView2 158):** log cho thấy trang đăng nhập tải xong (đo được khổ trang) nhưng cửa sổ vẫn tối. `webview_all_windows` vẽ WebView2 bằng Windows Graphics Capture rồi đưa vào texture Flutter. Trên máy này không có khung hình nào được đưa lên, plugin cũng không báo lỗi. Thêm nữa, WebView2 không áp được khoá origin cho cầu nối JS (`addJavaScriptHandler` trả false), nên cầu nối được đăng ký không kèm khoá và app tự kiểm origin theo URL mà WebView2 báo.
- **Cách sửa: web ở cửa sổ WebView2 riêng** (`lib/screens/web_window.dart`, plugin `desktop_webview_window`, Apache-2.0). Mặc định bật trên Windows; menu → "Hiện web trong cửa sổ app" để quay lại cách nhúng. Cửa sổ này dùng WebView2 thật gắn vào HWND, không qua bước chụp. Lúc tạo tài liệu, app chèn một script tạo `window.TorBoxStrmApp` và `window.webviewAll.callHandler` (chạy qua `window.desktopWebview`, có id để trả kết quả). Sự kiện app → trang đi qua `postMessage('torboxEvent')`, chỉ gửi tới origin của server. Hồ sơ WebView2 nằm ở `%LOCALAPPDATA%\TorBoxSTRM\WebWindow`. Cửa sổ app thu nhỏ khi web mở, hiện ra khi phát, thu nhỏ lại khi đóng player, và hiện lại (có menu) khi đóng cửa sổ web. Liên kết sang site khác mở bằng trình duyệt. Đã kiểm thử trên Linux (`TORBOXSTRM_WEB_WINDOW=1`): đăng nhập, mở series, ▶ mở player trong app, tiến độ lưu về server, đóng player quay lại web, đóng web hiện cửa sổ app. Trên Linux hồ sơ của cửa sổ này không giữ cookie giữa các lần mở; Windows dùng `userDataFolder` nên giữ được. Cần xác nhận trên máy Windows của người dùng.
- **Phát trên TV (MVP Android TV)** — `lib/tv/`:
  - TV (`isTvDevice`, nhận qua `UiModeManager`/leanback trong `MainActivity.kt`) mở `TvHome`: mã QR + mã 6 số (đổi mỗi 5 phút, dùng một lần, sai 5 lần thì đổi), và `TvReceiver`: máy chủ HTTP trong mạng LAN, cổng 47800, chỉ nhận IP mạng nhà.
  - QR là link `http://<ip-tv>:47800/pair?c=…`; camera nào cũng mở được. Trang đó có nút `intent://` mở app trên điện thoại (`torboxstrm://pair?...`, intent filter trong manifest). Hoặc nhập tay: menu → Kết nối TV.
  - Điện thoại đổi mã lấy token ngẫu nhiên 24 byte (`TvClient.pair`). Khi bấm ▶, app hỏi "Phát trên thiết bị này / Phát trên TV".
  - TV nhận **đúng tin nhắn `play` của trang web**, kiểm tra bằng `PlayRequest.parse` như trong app, rồi phát thẳng `/s/` `/x/` từ server (hai đường này không cần cookie). Không đi qua relay, không chiếu màn hình.
  - `PageLink` của player trên TV đi qua điện thoại: TV hỏi trang (phụ đề, tìm phụ đề, tiến độ) → `GET /poll` → điện thoại gọi `TorBoxStrmBridge.event` trên trang của mình → câu trả lời `POST /page` về TV. Vì vậy phụ đề AIOStreams, tìm phụ đề online và lưu tiến độ chạy trên TV mà TV không cần đăng nhập.
  - Điều khiển từ điện thoại (`TvRemoteScreen`): phát/dừng, thanh tua, ±10/30 s, tập trước/sau, âm lượng, âm thanh, phụ đề (trong file + của server), dừng. Trạng thái làm mới mỗi giây.
  - D-pad trên TV (`PlayerScreen._onTvKey`): khi ẩn điều khiển: ◀ ▶ tua 10 s, OK phát/dừng và hiện điều khiển (focus vào nút phát), ▲ ▼ hiện điều khiển. Khi hiện: D-pad di chuyển giữa các nút, OK bấm nút. Back ẩn điều khiển (đang phát) rồi mới thoát. Phím media của remote cũng dùng được.
  - Đã kiểm thử: `test/tv_test.dart` (ghép đôi, sai mã, mã dùng một lần, token lạ, kiểm tra lệnh phát, chuyển tiếp phụ đề, poll). Trên Linux với `TORBOXSTRM_TV=1` (chạy bản desktop như TV) + `curl` đóng vai điện thoại: trang QR, ghép đôi, phát hàng đợi 2 tập từ backend thử, tạm dừng/tua/lùi/đổi âm thanh/tập sau, phím ▶ OK Back, sự kiện `closed`.
  - Chưa kiểm thử: điện thoại thật → TV box thật (camera mở link, intent mở app, Wi-Fi tách khách/AP isolation), focus D-pad trong các bảng chọn track, banner trên launcher TV. Lưu lượng LAN là HTTP không mã hoá (token đi kèm mỗi lệnh); chỉ dùng trong mạng nhà.

## Bản tiếp theo (chưa build): bấm ▶ đến khi có hình mất 15–20 s, phụ đề lâu

Các việc đã gây chậm:
- Link CDN chỉ được xin lúc player mở `/s/`, và mỗi lần đều phải gọi TorBox.
- Trang chờ logo TMDB tối đa 2 s mới gửi lệnh phát.
- `/api/subs` hỏi TorBox (phụ đề trong torrent) rồi mới hỏi AIOStreams (tối đa 8 s), nối tiếp nhau. App chỉ xin danh sách phụ đề sau khi đã mở file.
- Nếu link TorBox chứa API key, chế độ `STREAM_MODE=auto` phục vụ qua proxy VPS. Khi đó mọi lần đọc và tua đều đi qua VPS.

Đã sửa:
- Mở trang chi tiết trong app thì gọi `POST /api/prewarm?key=` (file đang xem dở hoặc tập/bản đầu) và tải sẵn logo. Lúc bấm ▶, trang tải trước `/api/subs`.
- Server chạy hai nguồn phụ đề song song, và ghi log `danh sách phụ đề ms=…`, `mở /s: chuyển thẳng tới CDN ms=…` hoặc `mở /s: qua proxy VPS`.
- App xin phụ đề cùng lúc với lúc mở file. Phụ đề chỉ được nạp khi đúng file mới đã mở (`_fileLoaded`; player dùng chung nên thời lượng của file cũ không dùng làm tín hiệu được). Nhật ký ghi `play: open`, `play: file opened after`, `play: picture after`, `subs: list after`, `subs: … loaded after`.
- Android giờ cũng có mục **Nhật ký** trong menu.
- Trên Linux với TorBox giả: phụ đề về sau 43 ms, `/s` 0 ms, có hình sau 0,9 s.

Cần đo trên máy thật để biết thời gian còn lại nằm ở đâu: TorBox, CDN, proxy, hay mpv tua tới vị trí xem dở trên file MKV lớn.

## Bản tiếp theo: Windows và cập nhật trên Android

- **Windows, cửa sổ web riêng:** cửa sổ app **ẩn hẳn** khi duyệt phim (chỉ còn một cửa sổ trên thanh tác vụ). Bấm ▶ thì hiện lại và **toàn màn hình**; Esc hoặc nút đóng player trả về cửa sổ web (`FullscreenHelper.escapeClosesPlayer`). Lệnh ẩn chờ `appWindowShown` (main() hiện cửa sổ sau khung hình đầu; ẩn trước thời điểm đó sẽ bị hiện lại).
- **Cập nhật:** app tự kiểm tra tối đa 30 phút một lần (trước là 6 giờ), cả khi quay lại app. Trước đây người vừa cập nhật vài giờ trước không thấy bản mới.
- **Menu của app trên điện thoại:** trước chỉ mở bằng Back ở trang đầu. Giờ thêm mục "📱 Ứng dụng (cập nhật, máy chủ, TV)" trong menu tài khoản của trang web (chỉ hiện trong app); trang gửi `{type:'menu'}` qua cầu nối.
- Đã thử trên Linux: mục Ứng dụng mở bảng menu; chế độ cửa sổ web: app ẩn, ▶ toàn màn hình, Esc về cửa sổ web.

## Đo trên điện thoại thật (1.1.3, 2026-11-25)

Có hình sau 2,7 s (tập đang xem dở, đã xin sẵn link) / 6,0 s / 9,8 s (Remux FLAC) / 15,1 s (E03, chưa xin sẵn link). Danh sách phụ đề 3–8 s (chờ AIOStreams). Phụ đề nạp sau 12 s (phải chờ file mở xong). `update check: HTTP 403`: API GitHub giới hạn 60 lượt/giờ cho mỗi IP, mạng di động dùng chung IP.

Đã sửa cho bản sau:
- Cập nhật: khi API trả lỗi, app đọc chuyển hướng của `github.com/<repo>/releases/latest` để lấy tag, rồi tải `releases/download/<tag>/TorBox-STRM-<abi>`. Đã thử với GitHub thật.
- Mở trang phim thì tải sẵn cả danh sách phụ đề (giữ 10 phút), không chỉ link.
- Khi tập đang xem qua 70%, trang xin sẵn link và phụ đề cho tập kế trong hàng đợi.
- Còn cần log server (`mở /s … ms=…`, có `qua proxy VPS` không) để biết 6–15 s còn lại nằm ở TorBox, CDN hay mpv.

## Làm sau

Từ bản rà soát mô tả bàn giao ban đầu:

1. **Cache link CDN theo key trong khi `FORWARD_CLIENT_IP` mặc định bật.** Nếu TorBox khoá link theo IP, người xem thứ hai trong thời gian TTL sẽ nhận link tạo cho IP của người đầu. Cần thử trên hai mạng; nếu đúng là khoá theo IP thì cache theo key + IP. Liên quan: khi CDN trả 403 giữa chừng, app mở lại `/s/…` nhưng server có thể trả lại đúng link cũ đang còn trong cache (`LINK_CACHE_TTL_SECS`, mặc định 1800 giây). Server nên bỏ link khỏi cache khi client mở lại ngay sau lỗi, hoặc app nên dùng `/api/v1/playback/resolve` của nhánh `native-player-api`.
2. **Trường hợp chưa đặt `WEB_PASSWORD`.** Bản cũ trả 403 "Web UI đang tắt"; màn hình kết nối nên báo rõ trường hợp này. (Bản `develop` đăng nhập bằng form, cần kiểm tra lại hành vi.)
3. **Server chạy bản cũ.** Server cần bản có cầu nối (`1.7.0-dev.5`+); bản cũ hơn vẫn duyệt được nhưng ▶ mở player ngoài.
4. **Nút player trong `ui.html`/`ui-core.js`.** Đã gộp vào cơ chế `PLAYERS` của `develop`: app tự dựng URL từ dữ liệu của trang, nhưng chỉ chấp nhận `/s/…` và `/x/…` (không tin URL tuỳ ý). Nhánh `torbox-player-android-link` thêm "TorBox Player" (intent Android) cho trình duyệt; cần thống nhất tên package với app này (`io.github.optimismbliss.torboxstrm`).

Thêm:

5. Ký APK bằng khoá release (thêm secrets) và cân nhắc gói Linux (AppImage/Flatpak có sẵn WebKitGTK) cùng bộ cài Windows.
6. Android TV: đã có "Phát trên TV", tìm TV trong LAN (UDP 47801: điện thoại phát `TORBOXSTRM-DISCOVER-1`, TV trả tên + cổng; vẫn cần mã 6 số trên TV), D-pad trên trang web (chế độ TV của trang + phím đi thẳng xuống WebView). Còn cần thử trên TV box thật.
7. Kiểm thử theo thiết bị (máy/GPU/màn hình): H.264 SDR, HEVC Main10/HDR10, MKV nhiều audio/phụ đề, AV1, HLG, Dolby Vision, ASS/PGS. Phân biệt "giải mã được" với "xuất đúng HDR".
8. Nút ▶ trên web bị trùng: nút tròn ▶ và "▶ Phát" đều mở player trong app.
9. **Desktop chỉ nên chạy một instance.** Mở app lần hai trên Linux thì WebView trắng ("named profile is in use by another process"); Windows có thể tương tự. Linux: bỏ `G_APPLICATION_NON_UNIQUE` và cho `activate` đưa cửa sổ cũ lên; Windows: mutex + chuyển tiếp sang cửa sổ đang chạy. Làm cùng phần deep link.
10. ~~Tìm phụ đề online trong player~~: đã có (chip "Tìm online" trong bảng Phụ đề, server ≥ 1.7.0-dev.7).
11. **Linux: menu nổi bị WebView che.** WebKitGTK vẽ đè lên lớp Flutter (menu "⋯", hộp thoại cập nhật hiện sau WebView nhưng có thể bị che một phần). Cân nhắc ẩn WebView (Offstage) khi mở menu/hộp thoại, hoặc dùng route riêng.
12. **Windows chưa được kiểm thử trên máy thật.** Bản 0.4.3 đặt thư mục dữ liệu WebView2 trong `%LOCALAPPDATA%\TorBoxSTRM\WebView2`, báo lỗi rõ khi thiếu WebView2 Runtime và ghi log từng bước vào `%LOCALAPPDATA%\TorBoxSTRM\torbox-strm.log`. Nếu vẫn không tải được trang đăng nhập, đọc log đó.
13. **4K hiển thị nhỏ** (báo từ máy thật, chưa tái hiện): đã thêm chế độ khung hình (Vừa/Lấp đầy/Kéo giãn/16:9/21:9/4:3, chụm ngón trên cảm ứng). Nếu khung hình vẫn nhỏ ở chế độ "Vừa màn hình", cần ảnh chụp + hộp "Thông tin phát" để kiểm tra texture của media_kit trên thiết bị đó.
