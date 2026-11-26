import 'dart:async';

import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge.dart';
import '../player/playback_controller.dart';
import '../player/player_settings.dart';
import '../player/player_settings_screen.dart';
import '../player/subtitle_style.dart';
import '../player/player_screen.dart';
import '../player/tv_playback_prefs.dart';
import '../screens/role_screen.dart';
import '../update/update_ui.dart';
import '../update/updater.dart';
import '../settings.dart';
import '../util/tv_mode.dart';
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
  late final TvReceiver _rx = TvReceiver(
    openPlayer: _openPlayer,
    name: 'TorBox STRM TV',
    onServer: _setServer,
    onHome: () {
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    },
  );
  late Uri? _server = widget.server;

  Future<void> _setServer(Uri server, String code) async {
    final changed = _server?.origin != server.origin;
    await ServerStore.save(server, viaCode: code);
    if (!mounted) return;
    setState(() => _server = server);
    if (changed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Điện thoại đã gửi máy chủ cho TV. Bấm "Duyệt phim trên TV" để đăng nhập.')),
      );
    }
  }

  bool _playerOpen = false;
  Timer? _addressTimer;
  AppLifecycleListener? _lifecycle;
  String _version = '';

  @override
  void initState() {
    super.initState();
    // the TV start screen checks for updates too (the browser screen is not open on a TV most of the time)
    Updater.currentVersion().then((v) => mounted ? setState(() => _version = v) : null);
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (mounted && !_playerOpen) checkForUpdate(context, automatic: true);
    });
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (mounted && !_playerOpen) checkForUpdate(context, automatic: true);
      },
    );
    _rx.start().then((_) => mounted ? setState(() {}) : null);
    // Wi-Fi may come up after the app (or change): keep the QR address right.
    _addressTimer = Timer.periodic(const Duration(seconds: 15), (_) => _rx.refreshAddress());
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
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

  /// Back to a fresh install: server, paired phones, device role and every setting are cleared,
  /// then the role choice (phone / TV) shows again.
  Future<void> _resetConfig() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(IconsaxPlusLinear.refresh_left_square),
        title: const Text('Đặt lại cấu hình?'),
        content: const Text(
          'Xoá máy chủ, điện thoại đã ghép, vai trò của máy và mọi cài đặt trình phát. '
          'App quay về màn hình chọn vai trò như lúc mới cài.',
        ),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Đặt lại')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    appLog('tv: reset configuration');
    await _rx.stop();
    await (await SharedPreferences.getInstance()).clear();
    await detectTv();
    await TvPlaybackPrefs.load();
    await PlayerSettings.load();
    await SubtitleStyle.load();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute<void>(builder: (_) => const RoleScreen()), (_) => false);
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
                        const SizedBox(height: 8),
                        Text(
                          _server == null
                              ? 'TV chưa có máy chủ: kết nối điện thoại (đã vào máy chủ) là TV nhận luôn.'
                              : 'Máy chủ: ${ServerStore.label(_server!)}. Chọn phim trên điện thoại rồi bấm "Phát trên TV".',
                          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                        ),
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
                          runSpacing: 12,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _resetConfig,
                              icon: const Icon(IconsaxPlusLinear.refresh_left_square),
                              label: const Text('Đặt lại cấu hình'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () async {
                                await PlayerSettingsScreen.open(context);
                                if (mounted) setState(() {});
                              },
                              icon: const Icon(IconsaxPlusLinear.setting_2),
                              label: Text('Cài đặt trình phát (${TvPlaybackPrefs.nativePlayer ? 'Media3' : 'mpv'})'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _rx.newCode,
                              icon: const Icon(IconsaxPlusLinear.refresh),
                              label: const Text('Đổi mã'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => checkForUpdate(context),
                              icon: const Icon(IconsaxPlusLinear.refresh_circle),
                              label: Text(_version.isEmpty ? 'Kiểm tra cập nhật' : 'Cập nhật (đang dùng $_version)'),
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
