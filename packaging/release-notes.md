**Có gì mới trong 2.2.2**
- **Font phụ đề hợp tiếng Việt:** mặc định chuyển sang **Be Vietnam Pro** (dấu đặt gọn, dễ đọc); đổi được Roboto / Noto Sans / Droid Sans (cũ) trong bảng Kiểu chữ phụ đề (nút **T** hoặc "Kiểu chữ" trong bảng phụ đề). Áp dụng cả điện thoại, máy tính và TV.
- **Điện thoại: khớp tần số màn hình** — phim 24 fps chạy ở 120 Hz, 30 fps ở 60 Hz, tránh giật đều khi máy tự hạ về 60 Hz. Tắt được trong Cài đặt trình phát.
- **Thông tin chẩn đoán** (mặc định tắt): Cài đặt trình phát → Chẩn đoán, hoặc phím **D** — trình phát, bộ giải mã, tần số màn hình, khung hình rơi, bộ đệm, tốc độ tải, RAM.
- Bỏ nút ⋯ trùng trên trình phát: bấm nhãn "1080p · HEVC" để xem thông tin phát.

**Có gì mới trong 2.2.1** (gồm cả 2.2.0)
- **TV: trình phát Media3 dùng chung giao diện với điện thoại / PC.** Hình đi thẳng từ chip giải mã ra màn hình (không qua GPU), giao diện điều khiển của app phủ lên trên: thanh tiến trình tua bằng remote, bảng phụ đề / âm thanh, phụ đề server, tìm phụ đề online, **đổi khung hình** (vừa / lấp đầy / kéo giãn), tốc độ, cài đặt, thông tin phát. Media3 chưa có lệch phụ đề và chương phim (chọn "mpv" trong Cài đặt trình phát nếu cần).
- **TV chỉ còn nhận phim từ điện thoại:** bỏ duyệt phim trên TV (khó dùng bằng remote trên box yếu). Chọn phim trên điện thoại rồi bấm "Phát trên TV"; TV không cần đăng nhập.
- **TV: nút "Đặt lại cấu hình"** (thay "Dùng như điện thoại"): xoá máy chủ, điện thoại đã ghép, vai trò máy và cài đặt, quay về màn hình chọn vai trò.
- **TV: lệnh phát mới luôn mở được phim** (trước đây có lúc bị bỏ qua khi trình phát cũ chưa đóng hẳn).
- **Điện thoại: nút Back / vuốt cạnh:** đang mở chi tiết phim, trình phát hay hộp thoại thì đóng nó; ở **Trang chủ** thì hiện bảng chọn; ở các tab khác (Phim, Shows, Khám phá…) thì quay lại.
- **Trình phát trên TV:** Back lần 1 hiện thanh thông tin / điều khiển, lần 2 thì thoát.
- App không tự cập nhật lên bản thử (pre-release).

**Có gì mới trong 2.1.1**
- **Cài đặt trình phát** (học theo Fladder): menu app → "Cài đặt trình phát", nút ⚙ khi đang xem, hoặc nút trên màn hình chính TV. Gồm: tự phát tập kế, bước tua lùi / tới (5–60 giây), bộ đệm, ngôn ngữ âm thanh / phụ đề ưu tiên, kiểu chữ phụ đề, cử chỉ chạm đúp / vuốt, PiP, tuỳ chọn TV (Media3 / mpv, tunneling, khớp tần số, tương thích) và bảng phím tắt.
- **TV: đổi chế độ giải mã không cần mở lại app** — áp dụng từ phim tiếp theo.

**Có gì mới trong 2.1.0** (bản lớn trình phát, học theo Fladder; gồm cả 2.0.5 chưa phát hành)
- **TV: trình phát mới Media3** (như Fladder trên Android TV): hình đi thẳng từ chip giải mã ra màn hình, không qua GPU — mượt hơn hẳn trên box yếu (Mi Box S). Âm thanh DTS / TrueHD box không tự giải mã được thì dùng FFmpeg; phụ đề ASS vẽ bằng libass; phụ đề từ server vẫn tự bật như trước. Remote: ◀ ▶ tua 10 giây (giữ: 30 giây), OK / ▲ ▼ hiện thanh điều khiển, Back ẩn thanh rồi thoát. Màn hình chính TV có nút **"Trình phát: Media3 / mpv"** để quay về mpv nếu phim nào không phát được, và **"Tunneling"** (thử khi vẫn giật).
- **TV: khớp tần số màn hình** chờ TV chuyển chế độ xong mới phát tiếp, và trả lại tần số cũ trước khi đóng trình phát (tránh màn đen ở loa / amply HDMI).
- **Windows: một cửa sổ duy nhất.** Trang web nằm trong cửa sổ app; bấm ▶ thì phim phát ngay trong cửa sổ đó (toàn màn hình), đóng phim là trang hiện lại. Hết cảnh trình phát nằm sau, cửa sổ "đứng hình", Win+D không ẩn được. Esc lần đầu thoát toàn màn hình, lần hai đóng phim.
- **Chương phim:** nút chương trước / sau (phím PgUp / PgDn) khi file có chương, kèm tên chương.
- **Phím tắt phụ đề:** Z / X lệch phụ đề ∓100 ms, S hoặc V ẩn / hiện phụ đề, phím số 0–9 nhảy tới 0 %–90 % phim.
- **Kiểu chữ phụ đề:** nút **T** (hoặc "Kiểu chữ" trong bảng phụ đề trên điện thoại): cỡ chữ, viền, chữ đậm, màu (trắng / vàng / xanh nhạt / xám), nền tối sau chữ. Lưu cho lần sau.
- **Điện thoại Android: hình trong hình (PiP).** Đang xem mà bấm Home là phim thu thành cửa sổ nhỏ; vuốt bỏ cửa sổ nhỏ thì phim tạm dừng.

**Có gì mới trong 2.0.5**
- **Phát mượt hơn trên TV box** (học theo mpv-android): giải mã không chép từng khung hình (khung hình đi thẳng vào GPU, phụ đề ASS / PGS vẫn hiện) và vẽ hình nhẹ (bộ phóng hình đơn giản, bỏ khử viền màu / dithering) cho GPU yếu như Mi Box S. Nếu phim không lên hình: màn hình chính TV → "Tương thích: bật" rồi mở lại app.
- **Khớp tần số màn hình** (tuỳ chọn, màn hình chính TV): màn hình chuyển theo phim (24 / 25 / 30 Hz) khi phát, hết giật đều; màn hình có thể tối khoảng 1 giây khi chuyển. Cần TV / màn hình nhận được các chế độ đó.
- **Bỏ chế độ "giải mã trực tiếp"** (không lên hình trên một số box).
- **Quét QR trong app** đọc được QR ghép TV ở màn hình chính TV.
- **Menu app cuộn được**, phần TV (Remote, Xem nhật ký TV) lên đầu.
- **Nhật ký** ghi thêm cảnh báo / lỗi của trình phát (libmpv) để chẩn đoán màn hình đen, giật.

**Có gì mới trong 2.0.4**
- **Windows:** bấm ▶ thì cửa sổ duyệt phim tự thu nhỏ xuống thanh tác vụ để trình phát hiện ra ngay (trước đây trình phát nằm phía sau, phải đóng cửa sổ web mới thấy); đóng trình phát thì cửa sổ web hiện lại.
- **Windows:** thanh tiêu đề cửa sổ web không còn hiện địa chỉ máy chủ.
- **Icon mới** (nút ▶ đỏ TorBox STRM) cho Windows và Android thay cho logo Flutter.
- **Cập nhật:** nếu bản mới đang được tải lên GitHub, app báo thử lại sau 1–2 phút thay vì "HTTP 404". TV box 32-bit (như onn 4K) dùng file `armeabi-v7a`; app tự chọn đúng file khi cập nhật.

**Có gì mới trong 2.0.3**
- **Quét QR ngay trong app** (điện thoại): menu → "Quét mã QR", hoặc nút quét ở màn hình nhập máy chủ. Đọc QR ghép TV, QR đăng nhập TV và mã máy chủ; dùng khi camera của máy mở link `torboxstrm://` bằng trình duyệt. Lần đầu app xin quyền camera.
- **Sửa link đăng nhập TV** (`torboxstrm://device`) không mở được app trên Android.
- **Phụ đề ở chế độ giải mã trực tiếp (TV):** app tự vẽ phụ đề trên cùng (chữ trắng viền đen); phụ đề dạng ảnh (PGS / VobSub) có thông báo thay vì không hiện gì.
- **Remote trên điện thoại tự kết nối lại** khi bật màn hình hoặc bấm phím.
- **Windows:** trình phát luôn hiện trên cửa sổ web khi bấm ▶ (trước đây nằm phía sau); đóng menu app không còn để lại cửa sổ trống.
- **TV box ít RAM:** bộ đệm phát trên TV giảm còn 64 MB để Android không tắt app; nhật ký ghi RAM còn trống và lý do lần chạy trước bị tắt (thiếu RAM, crash…).

**Có gì mới trong 2.0.2** (tự chọn bản theo màn hình cần server `2.0.3-dev` trở lên)
- **Tua bằng remote trên thanh tiến trình:** ▲ ▼ di chuyển lên thanh tiến trình, ◀ ▶ tua xem trước (giờ hiện trên thanh, giữ phím thì tua 10 giây → 30 giây → 1 phút), bấm OK hoặc dừng tay là nhảy tới đó.
- **TV box giải mã nhẹ hơn:** âm thanh DTS-HD Master Audio chỉ giải mã phần lõi DTS (phần lossless chạy bằng CPU, quá nặng với box như onn 4K và làm giật cả hình); nghe qua loa TV không khác.
- **Tự chọn bản vừa màn hình:** app báo độ phân giải màn hình cho trang web; TV box nối màn 1080p ưu tiên bản 1080p thay vì 4K, màn 4K vẫn ưu tiên 4K.

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
| Android 7.0+ | `TorBox-STRM-android-arm64-v8a.apk` for most phones; `armeabi-v7a` for 32-bit Android (many TV boxes such as onn 4K, older phones). The app picks the right one when it updates itself |

The Android APKs are signed with a @ANDROID_SIGNING@. Checksums are in `SHA256SUMS.txt`.

Verified end to end on Linux arm64 against a local server (browse, login, play, seek, track switching, next episode, progress sync, error/retry). Windows and Android builds come from CI and still need checking on real devices, including HDR output and hardware decoding.
