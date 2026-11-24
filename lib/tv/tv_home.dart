import 'dart:async';

import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../bridge.dart';
import '../player/playback_controller.dart';
import '../player/player_screen.dart';
import '../screens/browser_screen.dart';
import '../screens/connect_screen.dart';
import '../util/log.dart';
import 'receiver.dart';

/// Android TV start screen: waits for a paired phone ("Play on TV") and shows
/// the QR code to pair one. Browsing on the TV itself stays available.
class TvHome extends StatefulWidget {
  const TvHome({super.key, this.server});
  final Uri? server;

  @override
  State<TvHome> createState() => _TvHomeState();
}

class _TvHomeState extends State<TvHome> {
  late final TvReceiver _rx = TvReceiver(openPlayer: _openPlayer, name: 'TorBox STRM TV');
  bool _playerOpen = false;
  Timer? _addressTimer;

  @override
  void initState() {
    super.initState();
    _rx.start().then((_) => mounted ? setState(() {}) : null);
    // Wi-Fi may come up after the app (or change): keep the QR address right.
    _addressTimer = Timer.periodic(const Duration(seconds: 15), (_) => _rx.refreshAddress());
  }

  @override
  void dispose() {
    _addressTimer?.cancel();
    _rx.stop();
    super.dispose();
  }

  Future<void> _openPlayer(PlayRequest request) async {
    if (!mounted) return;
    // a new title replaces whatever plays now
    if (_playerOpen) {
      await _rx.remote.close?.call();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    if (!mounted) return;
    _playerOpen = true;
    try {
      await Navigator.of(context).push(
        PageRouteBuilder<void>(
          opaque: true,
          transitionDuration: const Duration(milliseconds: 220),
          pageBuilder: (_, _, _) => PlayerScreen(
            request: request,
            remote: _rx.remote,
            page: PageLink(incoming: _rx.pageIn.stream, send: _rx.toPage),
            onProgress: (key, pos, dur) => _rx.toPage({
              'type': 'progress',
              'key': key,
              'pos': pos.inMilliseconds / 1000,
              'dur': dur.inMilliseconds / 1000,
            }),
            onClosed: (key) {
              _rx.toPage({'type': 'closed', 'key': key});
              _rx.playerClosed();
            },
          ),
          transitionsBuilder: (_, anim, _, child) => FadeTransition(opacity: anim, child: child),
        ),
      );
    } catch (e) {
      appLog('tv player: $e');
    } finally {
      _playerOpen = false;
    }
  }

  void _browse() {
    final server = widget.server;
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => server == null ? const ConnectScreen() : BrowserScreen(server: server)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFF0B0D12),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 64, vertical: 40),
          child: ListenableBuilder(
            listenable: Listenable.merge([_rx.code, _rx.address, _rx.lastPhone]),
            builder: (context, _) {
              final qr = _rx.qrUrl;
              final link = _rx.pairLink;
              return Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Phát trên TV', style: text.displaySmall),
                        const SizedBox(height: 16),
                        Text(
                          '1. Mở camera điện thoại, quét mã QR.\n'
                          '2. Bấm "Mở app và kết nối".\n'
                          '3. Trong app, bấm ▶ trên phim rồi chọn "Phát trên TV".',
                          style: text.titleMedium?.copyWith(height: 1.6),
                        ),
                        const SizedBox(height: 16),
                        if (link != null)
                          Text(
                            'Hoặc trong app chọn menu → Kết nối TV, nhập ${link.host}:${link.port} và mã ${link.code}',
                            style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                          )
                        else
                          Text('TV chưa có mạng Wi-Fi / LAN.', style: text.bodyLarge?.copyWith(color: scheme.error)),
                        if (_rx.lastPhone.value != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Đã kết nối: ${_rx.lastPhone.value}',
                            style: text.bodyLarge?.copyWith(color: scheme.primary),
                          ),
                        ],
                        const SizedBox(height: 28),
                        Wrap(
                          spacing: 16,
                          children: [
                            FilledButton.icon(
                              autofocus: true,
                              onPressed: _browse,
                              icon: const Icon(IconsaxPlusLinear.global),
                              label: const Text('Duyệt phim trên TV'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _rx.newCode,
                              icon: const Icon(IconsaxPlusLinear.refresh),
                              label: const Text('Đổi mã'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 48),
                  if (qr != null)
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
                          child: QrImageView(data: qr.toString(), size: 260, backgroundColor: Colors.white),
                        ),
                        const SizedBox(height: 12),
                        Text('Mã: ${_rx.code.value}', style: text.headlineSmall),
                        Text('Đổi sau 5 phút', style: text.bodySmall),
                      ],
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
