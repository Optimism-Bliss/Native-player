import 'dart:io';

import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:material_ui/material_ui.dart';

import '../bridge.dart';
import '../player/player_screen.dart';
import 'downloads.dart';

String _size(int b) => b <= 0
    ? '?'
    : b >= 1 << 30
    ? '${(b / (1 << 30)).toStringAsFixed(1)} GB'
    : '${(b / (1 << 20)).toStringAsFixed(0)} MB';

/// "Phim đã tải": danh sách tải, tiến độ, tạm dừng / tải tiếp / xoá, phát không cần mạng.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DownloadsScreen()));

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  final _dl = Downloads.instance;

  @override
  void initState() {
    super.initState();
    _dl.load();
  }

  Future<void> _play(DownloadItem it) async {
    if (!await File(it.path).exists()) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Không thấy file — tải lại phim này')));
      return;
    }
    final sub = it.subPath.isNotEmpty && await File(it.subPath).exists()
        ? SubtitleRef(url: Uri.file(it.subPath), label: it.subLabel.isEmpty ? 'Phụ đề' : it.subLabel, language: it.subLang.isEmpty ? null : it.subLang)
        : null;
    // xem gần hết thì phát lại từ đầu
    final resume = it.durationMs > 0 && it.positionMs > it.durationMs * 0.92 ? 0 : it.positionMs;
    final request = PlayRequest(
      queue: [QueueItem(key: 'dl:${it.id}', url: Uri.file(it.path), title: it.title, subtitle: sub)],
      index: 0,
      start: Duration(milliseconds: resume),
    );
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          request: request,
          onProgress: (key, pos, dur) => _dl.setPosition(it.id, pos, dur),
          onClosed: (_) {},
        ),
      ),
    );
  }

  Future<void> _remove(DownloadItem it) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Xoá phim đã tải?'),
        content: Text('${it.title}\n\nXoá file trên máy này (${_size(it.state == DownloadState.done ? it.size : it.received)}). Phim trên máy chủ không bị ảnh hưởng.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Xoá')),
        ],
      ),
    );
    if (ok == true) await _dl.remove(it);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Phim đã tải')),
      body: ListenableBuilder(
        listenable: _dl,
        builder: (context, _) {
          if (_dl.items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Chưa có phim nào.\nTrên trang phim, bấm ⬇ Tải về (tài khoản cần được admin cho phép tải về).',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  '${_dl.items.length} phim · dùng ${_size(_dl.usedBytes)} trên máy · xem được khi không có mạng',
                  style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                ),
              ),
              for (final it in _dl.items) _tile(it, scheme),
            ],
          );
        },
      ),
    );
  }

  Widget _tile(DownloadItem it, ColorScheme scheme) {
    final done = it.state == DownloadState.done;
    final watched = it.durationMs > 0 ? (it.positionMs / it.durationMs).clamp(0.0, 1.0) : 0.0;
    final status = switch (it.state) {
      DownloadState.done => '${_size(it.size)}${watched > 0.02 ? ' · đã xem ${(watched * 100).round()}%' : ''}',
      DownloadState.downloading => 'Đang tải ${_size(it.received)} / ${_size(it.size)} · ${(it.progress * 100).toStringAsFixed(0)}%',
      DownloadState.queued => 'Chờ tải · ${_size(it.size)}',
      DownloadState.paused => 'Tạm dừng ${_size(it.received)} / ${_size(it.size)}',
      DownloadState.error => 'Lỗi: ${it.error}',
    };
    return ListTile(
      onTap: done ? () => _play(it) : null,
      leading: Icon(done ? IconsaxPlusBold.play_circle : IconsaxPlusLinear.document_download, size: 32, color: done ? scheme.primary : null),
      title: Text(it.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(status, style: TextStyle(color: it.state == DownloadState.error ? scheme.error : null)),
          if (!done) Padding(padding: const EdgeInsets.only(top: 4), child: LinearProgressIndicator(value: it.size > 0 ? it.progress : null)),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (it.state == DownloadState.downloading || it.state == DownloadState.queued)
            IconButton(tooltip: 'Tạm dừng', icon: const Icon(IconsaxPlusLinear.pause), onPressed: () => _dl.pause(it)),
          if (it.state == DownloadState.paused || it.state == DownloadState.error)
            IconButton(tooltip: 'Tải tiếp', icon: const Icon(IconsaxPlusLinear.import), onPressed: () => _dl.resume(it)),
          IconButton(tooltip: 'Xoá khỏi máy', icon: const Icon(IconsaxPlusLinear.trash), onPressed: () => _remove(it)),
        ],
      ),
    );
  }
}
