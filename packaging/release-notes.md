**Có gì mới trong 2.0.1** (cần server `2.0.2`; cài lên cả TV lẫn điện thoại)
- **Điện thoại thành remote TV:** menu → "Remote <tên TV&gt;": ▲ ▼ ◀ ▶ (giữ để lặp), OK, Quay lại, Màn hình chính TV, Phát / tạm dừng. TV nhận phím như remote thật ở mọi màn hình (màn hình chính, trang web, trình phát, hộp thoại). Chọn ô nhập trên TV là ô gõ chữ hiện trên cùng và bàn phím điện thoại tự bật.
- **TV tự kiểm tra cập nhật** và có nút "Cập nhật" ở màn hình chính; hộp thoại cập nhật bấm được bằng remote (OK = Cập nhật).
- **Duyệt đăng nhập TV một chạm** chạy đúng trên Android (link `torboxstrm://device` trước đó bị bỏ qua).
- **Chẩn đoán giật:** nhật ký ghi mỗi lần phải chờ tải (bao lâu, tốc độ tải, bitrate phim, số giây đệm) và thông số phim khi bắt đầu phát; điện thoại xem được **nhật ký của TV** (menu → "Xem nhật ký <tên TV&gt;", có nút Chép).
- **Bớt dừng vặt khi mạng chậm:** hết đệm thì chờ đủ 3 giây dữ liệu mới phát tiếp, tải trước tới 60 giây.

**Có gì mới trong 2.0.0** (cần server `2.0.1`)
- **Phát trên TV mượt hơn:** TV box giải mã **trực tiếp ra màn hình** (trước đây mỗi khung hình bị chép lại để vẽ bằng GPU, 4K / HEVC dễ giật). Mặc định bật trên TV; đổi ở nút "Giải mã" trên màn hình chính của TV hoặc menu app, mở lại app để áp dụng. Ở chế độ này phụ đề hiện dạng chữ thường.
- **Đăng nhập TV bằng QR, duyệt một chạm:** TV hiện QR ngay ở trang đăng nhập; quét bằng camera điện thoại có app, app tự mở trang xác nhận, bấm **Cho phép** là TV vào.
- **Sửa lỗi app bị thoát** khi quét QR / mở link `torboxstrm://` (ghép TV, mã máy chủ).
- **Thông tin phát** có thêm fps, số khung hình bị rơi và số giây đã tải sẵn, để chẩn đoán giật.
- **iPhone / iPad (thử nghiệm):** file `TorBox-STRM-ios.ipa` chưa ký. Tự cài bằng TrollStore (vĩnh viễn), AltStore / SideStore (Apple ID thường, ký lại 7 ngày một lần) hoặc eSign / chứng chỉ riêng. Ghép TV bằng quét QR; nhật ký nằm trong ứng dụng Tệp → Trên iPhone → TorBox STRM. Cập nhật: tải IPA mới rồi cài đè bằng cùng công cụ.
- **Server 2.0.x:** tab Anime và HHTQ, khám phá JAV theo diễn viên (hot trong tháng, phim mới nhất trước, lọc hãng / thể loại, ＋ thêm nhanh bản TorBox có sẵn). Có ngay trong app khi server cập nhật.

**Có gì mới trong 1.1.5** (cần server `1.7.0-dev.12`)
- **Chọn vai trò khi mở lần đầu:** "Điện thoại / máy tính" hay "TV" (Android). Đổi lại: menu điện thoại → "Dùng máy này làm TV"; trên TV → "Dùng như điện thoại".
- **Gõ chữ cho TV từ điện thoại:** chọn ô nhập trên TV (tìm phim, tài khoản, mật khẩu, mã máy chủ), rồi trên điện thoại mở menu → "Điều khiển / gõ chữ trên TV".
- **Đăng nhập trên TV bằng điện thoại:** trang đăng nhập có nút "📱 Đăng nhập bằng điện thoại"; TV hiện QR, điện thoại quét rồi bấm "Cho phép".
- **TV tự nhận máy chủ** khi điện thoại ghép đôi (không phải gõ địa chỉ, địa chỉ vẫn được ẩn).

**1.1.4** (cần server `1.7.0-dev.11`)
- **Mã máy chủ:** admin vào Cài đặt → Tài khoản → "📱 Mã máy chủ cho app" để lấy mã `TBS1-…` và QR. Người dùng quét QR bằng camera hoặc dán mã thay cho địa chỉ; app sẽ hiện "Máy chủ riêng" thay cho domain ở mọi chỗ, nhật ký cũng che domain.
- **🎲 Ngẫu nhiên** ở tab Phim / Series / JAV (không lẫn nhau, theo bộ lọc đang xem): xúc xắc lăn, rồi tự phát sau 5 giây.
- **Tìm torrent thêm 6 nguồn:** Knaben, torrents-csv, LimeTorrents, RuTor, SubsPlease, Knaben JAV. Bản đã cache trên TorBox vẫn lên đầu và được kiểm nhanh hơn.
- **Tìm bản cả mùa:** lấy thêm gói từ AIOStreams, ghi rõ "Đủ mùa (10/10)" / "Thiếu tập (4/10)" / "Chỉ 1 tập"; tự lấy chỉ chọn gói, không lấy bản lẻ một tập.
- **Phát nhanh hơn:** mở trang phim là tải sẵn link phát và phụ đề; khi tập đang xem qua 70% thì chuẩn bị sẵn tập kế.
- **Kết nối TV:** có nút "Tìm TV trong mạng".
- **Cập nhật:** vẫn kiểm tra được khi GitHub giới hạn lượt hỏi (HTTP 403).

**1.1.3** (cần server `1.7.0-dev.10`)
- **Phát nhanh hơn:** mở trang phim là server xin sẵn link phát; bấm ▶ là phụ đề được tải cùng lúc; server hỏi các nguồn phụ đề song song. Nhật ký ghi thời gian từng bước để đo tiếp trên máy thật.
- **Windows:** khi duyệt phim chỉ còn cửa sổ web; bấm ▶ thì player mở toàn màn hình, Esc quay lại web.
- **Android:** app tự kiểm tra cập nhật 30 phút một lần và mỗi lần quay lại app. Menu của app (cập nhật, máy chủ, kết nối TV, nhật ký) mở được từ nút tài khoản 👤 ▾ trên trang web → "📱 Ứng dụng". Android cũng có mục Nhật ký.

**1.1.2** (cần server `1.7.0-dev.9`)
- **Android TV:** cài cùng APK lên TV box / TV Android (`arm64-v8a`; máy 32-bit dùng `armeabi-v7a`). App trên TV hiện mã QR. Quét bằng camera điện thoại để kết nối, rồi bấm ▶ trên điện thoại và chọn "Phát trên TV". TV phát thẳng từ server, điện thoại thành remote (tua, tập, âm thanh, phụ đề, âm lượng). Remote TV: ◀ ▶ tua, OK phát/dừng, Back thoát. Duyệt phim ngay trên TV thì trang tự bật chế độ TV. TV và điện thoại phải cùng mạng Wi-Fi.
- **Windows:** trang web mở trong cửa sổ WebView2 riêng (sửa lỗi cửa sổ tối, không hiện trang đăng nhập); bấm ▶ thì phát trong app. Menu → "Hiện web trong cửa sổ app" để quay về cách cũ. Có mục **Nhật ký** để gửi log khi gặp lỗi.
- **Chỉ phát trong app:** bỏ nút mở bằng player ngoài, copy link video và playlist .m3u. Trong app mọi nút ▶ mở player của app; trên trình duyệt thì mở player web.
- **Thư viện:** phim/tập đã chọn khi phát từ AIOStreams được gán đúng, không còn rơi vào "Khác" / "Cần xem lại". Phim phát trước đây cũng được sửa lại tự động.
- **Android:** trang trong app hiển thị giống Chrome (hết khoảng trống lớn, chữ không bị phóng to).

Native TorBox STRM app: browse the TorBox STRM web UI and play in a libmpv player (Fladder-style controls).

**Server:** needs TorBox STRM `2.0.2` or later (`1.7.0-dev.12` for the app features before 2.0.0) for everything above (`1.7.0-dev.5`+ for the in-app player).

**Updates:** the app checks this page for new releases and installs them (Android asks for permission to install apps once). Builds from 0.4.3 on are signed with a fixed release key; if you installed 0.4.0–0.4.2, uninstall it once before installing this version.

| Platform | File |
| --- | --- |
| Windows 10/11 x64 | `TorBox-STRM-windows-x64-setup.exe` (installer, no admin rights, Start menu shortcut) or `TorBox-STRM-windows-x64-portable.zip` (extract the whole folder, then run `TorBoxSTRM.exe`). Uses the system WebView2 runtime. |
| Linux x64 / arm64 | `TorBox-STRM-linux-*.tar.gz` (needs `libwebkit2gtk-4.1-0` and `libmpv2`, see README-linux.txt) |
| iPhone / iPad (iOS 15+) | `TorBox-STRM-ios.ipa`: unsigned, install with TrollStore, AltStore, SideStore or your own certificate. Pair a TV by scanning its QR code (iOS blocks LAN discovery). |
| Android 7.0+ | `TorBox-STRM-android-arm64-v8a.apk` for most phones and TV boxes; `armeabi-v7a` for older 32-bit devices |

The Android APKs are signed with a @ANDROID_SIGNING@. Checksums are in `SHA256SUMS.txt`.

Verified end to end on Linux arm64 against a local server (browse, login, play, seek, track switching, next episode, progress sync, error/retry). Windows and Android builds come from CI and still need checking on real devices, including HDR output and hardware decoding.
