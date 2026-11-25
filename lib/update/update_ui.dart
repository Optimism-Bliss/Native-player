import 'dart:io';

import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../util/log.dart';
import 'updater.dart';

/// Checks GitHub Releases and offers the update. [automatic] runs quietly at
/// startup (at most every 30 minutes, honours "skip this version"); a manual
/// check also says when the app is already up to date.
Future<void> checkForUpdate(BuildContext context, {bool automatic = false}) async {
  final release = await Updater.available(automatic: automatic);
  if (!context.mounted) return;
  if (release == null) {
    if (!automatic) {
      final v = await Updater.currentVersion();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Đang dùng bản mới nhất ($v)')));
    }
    return;
  }
  final current = await Updater.currentVersion();
  if (!context.mounted) return;
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(IconsaxPlusLinear.refresh_circle),
      title: Text('Có bản mới ${release.name}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Bạn đang dùng $current.', style: Theme.of(context).textTheme.bodyMedium),
              if (release.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(release.notes, style: Theme.of(context).textTheme.bodySmall),
              ],
              if (release.asset == null) ...[
                const SizedBox(height: 12),
                Text(
                  Platform.isIOS
                      ? 'Trên iPhone / iPad: tải file TorBox-STRM-ios.ipa ở trang tải rồi cài đè bằng công cụ bạn đã dùng '
                            '(TrollStore, AltStore, SideStore…). Dữ liệu và đăng nhập được giữ nguyên.'
                      : 'Bản này chưa có file cho thiết bị của bạn; mở trang tải để xem.',
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (automatic) TextButton(onPressed: () => Navigator.pop(context, 'skip'), child: const Text('Bỏ qua bản này')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Để sau')),
        FilledButton(
          // focused at once: on a TV the remote's OK updates, arrows reach the other buttons
          autofocus: true,
          onPressed: () => Navigator.pop(context, release.asset == null ? 'page' : 'update'),
          child: Text(release.asset == null ? 'Mở trang tải' : 'Cập nhật'),
        ),
      ],
    ),
  );
  if (!context.mounted) return;
  switch (choice) {
    case 'skip':
      await Updater.skip(release);
    case 'page':
      await launchUrl(release.page, mode: LaunchMode.externalApplication);
    case 'update':
      await _downloadAndInstall(context, release);
  }
}

Future<void> _downloadAndInstall(BuildContext context, AppRelease release) async {
  final progress = ValueNotifier<double?>(null);
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text('Đang tải ${release.name}'),
        content: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (context, p, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: p),
              const SizedBox(height: 8),
              Text(p == null ? 'Đang kết nối…' : '${(p * 100).toStringAsFixed(0)}%'),
            ],
          ),
        ),
      ),
    ),
  );
  try {
    final file = await Updater.download(release.asset!, (p) => progress.value = p);
    navigator.pop();
    final done = await Updater.install(release, file);
    if (Platform.isLinux && done) {
      messenger.showSnackBar(const SnackBar(content: Text('Đã cập nhật. Mở lại app để dùng bản mới.')));
    } else if (Platform.isAndroid && !done) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Hãy cho phép TorBox STRM cài ứng dụng, rồi bấm Cập nhật lần nữa.')),
      );
    }
  } catch (e) {
    appLog('update failed: $e');
    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text('Không cập nhật được: $e')));
  } finally {
    progress.dispose();
  }
}
