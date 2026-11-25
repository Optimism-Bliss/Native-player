import 'dart:io';

import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Phones only (Android / iOS): reads a QR code with the camera inside the app.
/// Some camera apps hand `torboxstrm://` links to the browser instead of the
/// app; scanning here always works. Returns the QR text, or null.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key, this.title = 'Quét mã QR'});
  final String title;

  static bool get available => Platform.isAndroid || Platform.isIOS;

  static Future<String?> scan(BuildContext context, {String title = 'Quét mã QR'}) =>
      Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => QrScanScreen(title: title)));

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _camera = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .whereType<String>()
        .where((s) => s.trim().isNotEmpty)
        .firstOrNull;
    if (raw == null) return;
    _done = true;
    Navigator.of(context).pop(raw.trim());
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Đèn',
            icon: const Icon(IconsaxPlusLinear.flash_1),
            onPressed: () => _camera.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _camera,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  error.errorCode == MobileScannerErrorCode.permissionDenied
                      ? 'App chưa được dùng camera. Cho phép quyền Camera cho TorBox STRM trong Cài đặt rồi mở lại.'
                      : 'Không mở được camera: ${error.errorDetails?.message ?? error.errorCode.name}',
                  textAlign: TextAlign.center,
                  style: text.bodyLarge?.copyWith(color: Colors.white),
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 250,
                height: 250,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 3),
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 48,
            child: Text(
              'Hướng camera vào mã QR trên TV hoặc trang quản trị: ghép TV, đăng nhập TV, mã máy chủ.',
              textAlign: TextAlign.center,
              style: text.bodyLarge?.copyWith(color: Colors.white, shadows: const [Shadow(blurRadius: 4)]),
            ),
          ),
        ],
      ),
    );
  }
}
