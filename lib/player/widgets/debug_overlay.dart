import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../media3_player.dart';
import '../playback_controller.dart';
import '../tv_playback_prefs.dart';

/// Diagnostics on top of the picture (Cài đặt trình phát → Chẩn đoán): backend, decoder, frames,
/// buffer, download speed and the app's memory, refreshed every second. Off by default.
class DebugOverlay extends StatefulWidget {
  const DebugOverlay({super.key, required this.c});
  final PlaybackController c;

  @override
  State<DebugOverlay> createState() => _DebugOverlayState();
}

class _DebugOverlayState extends State<DebugOverlay> {
  Timer? _timer;
  List<(String, String)> _rows = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static String _hw(String v) => v == 'no' ? 'giải mã mềm' : v;

  Future<void> _refresh() async {
    final c = widget.c;
    if (!c.initialized) return;
    Future<String> p(String n) => c.prop(n);
    final s = c.player.state;
    final media3 = c.player.platform is Media3Player;
    final fps = double.tryParse(await p('estimated-vf-fps'));
    final cache = double.tryParse(await p('demuxer-cache-duration'));
    final speed = double.tryParse(await p('cache-speed'));
    final vbr = double.tryParse(await p('video-bitrate'));
    final rows = <(String, String)>[
      ('Trình phát', media3 ? 'Media3 (ExoPlayer)' : 'mpv (libmpv)'),
      ('Giải mã', [_hw(await p('hwdec-current')), await p('video-codec')].where((x) => x.isNotEmpty).join(' · ')),
      ('Hình', '${s.width ?? '?'}×${s.height ?? '?'}${fps != null ? ' · ${fps.toStringAsFixed(2)} fps' : ''}'),
      (
        'Màn hình',
        [
          '${TvPlaybackPrefs.displayRefreshRate().toStringAsFixed(0)} Hz',
          if ((await p('display-fps')).isNotEmpty)
            'mpv ${double.tryParse(await p('display-fps'))?.toStringAsFixed(1) ?? ''}',
        ].join(' · '),
      ),
      ('Rơi khung', '${await p('frame-drop-count')} hiển thị · ${await p('decoder-frame-drop-count')} giải mã'),
      ('Bộ đệm', cache == null ? '—' : '${cache.toStringAsFixed(1)} s${s.buffering ? ' · đang chờ' : ''}'),
      if (speed != null) ('Tải', '${(speed * 8 / 1e6).toStringAsFixed(1)} Mbit/s'),
      if (vbr != null && vbr > 0) ('Bitrate phim', '${(vbr / 1e6).toStringAsFixed(1)} Mbit/s'),
      ('Âm thanh', await p('audio-codec-name')),
      (
        'RAM app',
        '${(ProcessInfo.currentRss / 1048576).round()} MB (đỉnh ${(ProcessInfo.maxRss / 1048576).round()} MB)',
      ),
      ('Vị trí', '${s.position.inSeconds}/${s.duration.inSeconds} s · ${s.rate}×'),
    ];
    if (!mounted) return;
    setState(
      () => _rows = [
        for (final r in rows)
          if (r.$2.isNotEmpty) r,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.35, color: Colors.white);
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: Alignment.topLeft,
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 140, 12, 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.62),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (k, v) in _rows)
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${k.padRight(13)} ',
                          style: style.copyWith(color: Colors.white70),
                        ),
                        TextSpan(text: v),
                      ],
                    ),
                    style: style,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
