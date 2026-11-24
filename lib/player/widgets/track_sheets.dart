import 'package:flutter/foundation.dart';
import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import '../../bridge.dart';
import '../../util/format.dart';
import '../playback_controller.dart';

String audioTrackLabel(AudioTrack t) {
  if (t.id == 'auto') return 'Tự động';
  if (t.id == 'no') return 'Tắt';
  final parts = <String>[
    if (languageName(t.language).isNotEmpty) languageName(t.language),
    if ((t.title ?? '').isNotEmpty) t.title!,
    codecLabel(t.codec),
    channelLabel(t.audiochannels ?? t.channelscount),
  ].where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? 'Audio ${t.id}' : parts.join(' · ');
}

String subtitleTrackLabel(SubtitleTrack t) {
  if (t.id == 'auto') return 'Tự động';
  if (t.id == 'no') return 'Tắt';
  final parts = <String>[
    if (languageName(t.language).isNotEmpty) languageName(t.language),
    if ((t.title ?? '').isNotEmpty) t.title!,
    if (!t.uri) codecLabel(t.codec),
  ].where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? 'Phụ đề ${t.id}' : parts.join(' · ');
}

/// Short label for the chip buttons in the control bar.
String shortTrackLabel(String? language, String fallback) {
  final name = languageName(language);
  return name.isNotEmpty ? name : fallback;
}

Future<void> showAudioSheet(BuildContext context, Player player, ValueListenable<ActiveTracks> active) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => ValueListenableBuilder<ActiveTracks>(
      valueListenable: active,
      builder: (context, act, _) {
        final selected = act.audio;
        final tracks = player.state.tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
        return _SheetList(
          title: 'Âm thanh',
          icon: IconsaxPlusLinear.audio_square,
          children: [
            if (tracks.isEmpty) const ListTile(title: Text('File không có track âm thanh')),
            for (final t in tracks)
              _TrackTile(
                label: audioTrackLabel(t),
                selected: t.id == selected,
                badge: t.isDefault == true ? 'Mặc định' : null,
                onTap: () {
                  player.setAudioTrack(t);
                  Navigator.pop(context);
                },
              ),
          ],
        );
      },
    ),
  );
}

const _sourceNames = {'addon': 'Addon', 'aiostreams': 'AIOStreams', 'upload': 'Tải lên', 'online': 'Online'};

String serverSubtitleLabel(ServerSubtitle s) {
  final lang = languageName(s.language);
  return [if (lang.isNotEmpty) lang, s.label].join(' · ');
}

/// Embedded tracks of the file plus the subtitles the server offers
/// (AIOStreams and other addons, uploads, a chosen online subtitle), like the
/// web player's subtitle menu.
Future<void> showSubtitleSheet(BuildContext context, PlaybackController c) {
  final player = c.player;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => ListenableBuilder(
      listenable: Listenable.merge([c.active, c.serverSubtitles, c.serverSubtitleId]),
      builder: (context, _) {
        final selected = c.active.value.subtitle;
        final serverOn = c.serverSubtitleId.value != null && selected == c.serverSubtitleTrackId;
        final embedded = player.state.tracks.subtitle
            .where((t) => t.id != 'auto' && t.id != 'no' && !c.isServerTrack(t.id))
            .toList();
        final server = c.serverSubtitles.value;
        Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(text, style: Theme.of(context).textTheme.labelLarge),
        );
        return _SheetList(
          title: 'Phụ đề',
          icon: IconsaxPlusLinear.subtitle,
          children: [
            _TrackTile(
              label: 'Tắt',
              selected: selected == 'no',
              onTap: () {
                Navigator.pop(context);
                player.setSubtitleTrack(SubtitleTrack.no());
                c.clearServerSubtitle(off: true);
              },
            ),
            if (server.isNotEmpty) header('Từ server'),
            for (final s in server)
              _TrackTile(
                label: serverSubtitleLabel(s),
                selected: serverOn && c.serverSubtitleId.value == s.id,
                badge: _sourceNames[s.source] ?? s.source,
                onTap: () {
                  Navigator.pop(context);
                  c.selectServerSubtitle(s);
                },
              ),
            if (embedded.isNotEmpty) header('Trong file'),
            for (final t in embedded)
              _TrackTile(
                label: subtitleTrackLabel(t),
                selected: t.id == selected,
                badge: t.uri ? 'Link' : (t.isDefault == true ? 'Mặc định' : null),
                onTap: () async {
                  Navigator.pop(context);
                  await player.setSubtitleTrack(t);
                  await c.clearServerSubtitle(off: false);
                  // mpv only shows embedded events demuxed after the switch;
                  // an in-place seek brings back the line that is on screen now.
                  if (!t.uri) await player.seek(player.state.position);
                },
              ),
            const Divider(height: 12),
            _SubtitleTuning(player: player),
          ],
        );
      },
    ),
  );
}

class _SheetList extends StatelessWidget {
  const _SheetList({required this.title, required this.icon, required this.children});
  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  Icon(icon),
                  const SizedBox(width: 12),
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({required this.label, required this.selected, required this.onTap, this.badge});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        minLeadingWidth: 20,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        tileColor: selected ? scheme.primaryContainer.withValues(alpha: 0.6) : null,
        leading: Icon(
          selected ? IconsaxPlusBold.tick_circle : IconsaxPlusLinear.record,
          size: 20,
          color: selected ? scheme.primary : null,
        ),
        // Long addon labels (full release names) stay on one line.
        title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
        trailing: badge == null
            ? null
            : Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(badge!, style: text.labelSmall),
              ),
        onTap: onTap,
      ),
    );
  }
}

/// Subtitle delay and size, applied through mpv properties so they also work
/// for libass-rendered ASS tracks.
class _SubtitleTuning extends StatefulWidget {
  const _SubtitleTuning({required this.player});
  final Player player;

  @override
  State<_SubtitleTuning> createState() => _SubtitleTuningState();
}

class _SubtitleTuningState extends State<_SubtitleTuning> {
  double _delay = 0;
  double _scale = 1;

  NativePlayer? get _native => widget.player.platform is NativePlayer ? widget.player.platform as NativePlayer : null;

  @override
  void initState() {
    super.initState();
    () async {
      final n = _native;
      if (n == null) return;
      final d = double.tryParse(await n.getProperty('sub-delay')) ?? 0;
      final s = double.tryParse(await n.getProperty('sub-scale')) ?? 1;
      if (mounted) {
        setState(() {
          _delay = d;
          _scale = s;
        });
      }
    }();
  }

  Future<void> _setDelay(double v) async {
    setState(() => _delay = double.parse(v.toStringAsFixed(1)));
    await _native?.setProperty('sub-delay', _delay.toStringAsFixed(1));
  }

  Future<void> _setScale(double v) async {
    setState(() => _scale = v);
    await _native?.setProperty('sub-scale', v.toStringAsFixed(2));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    const compact = VisualDensity.compact;
    // Delay and size share one row on wide screens (landscape phones, desktop).
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Wrap(
        spacing: 24,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Độ trễ', style: text.bodyMedium),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                visualDensity: compact,
                iconSize: 18,
                onPressed: () => _setDelay(_delay - 0.1),
                icon: const Icon(IconsaxPlusLinear.minus),
              ),
              SizedBox(
                width: 64,
                child: Text(
                  '${_delay >= 0 ? '+' : ''}${_delay.toStringAsFixed(1)} s',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium,
                ),
              ),
              IconButton.filledTonal(
                visualDensity: compact,
                iconSize: 18,
                onPressed: () => _setDelay(_delay + 0.1),
                icon: const Icon(IconsaxPlusLinear.add),
              ),
              IconButton(
                visualDensity: compact,
                iconSize: 18,
                onPressed: () => _setDelay(0),
                tooltip: 'Đặt lại',
                icon: const Icon(IconsaxPlusLinear.refresh),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Cỡ chữ', style: text.bodyMedium),
              SizedBox(
                width: 180,
                child: Slider(
                  value: _scale,
                  min: 0.5,
                  max: 2.0,
                  divisions: 15,
                  label: '${(_scale * 100).round()}%',
                  onChanged: _setScale,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> showPlaybackInfo(BuildContext context, Player player, ActiveTracks active) async {
  final native = player.platform is NativePlayer ? player.platform as NativePlayer : null;
  Future<String> prop(String name) async {
    try {
      return await native?.getProperty(name) ?? '';
    } catch (_) {
      return '';
    }
  }

  final hwdec = await prop('hwdec-current');
  final vo = await prop('current-vo');
  final container = await prop('file-format');
  if (!context.mounted) return;
  final v = player.state.videoParams;
  final tracks = player.state.tracks;
  final videoTrack = active.videoOf(tracks);
  final audioTrack = active.audioOf(tracks);
  final subTrack = active.subtitleOf(tracks);
  final rows = <(String, String)>[
    ('Container', container),
    (
      'Video',
      [
        codecLabel(videoTrack?.codec),
        resolutionLabel(v.w, v.h),
        if (v.w != null) '${v.w}×${v.h}',
      ].where((s) => s.isNotEmpty).join(' · '),
    ),
    ('Pixel format', [v.pixelformat, v.hwPixelformat].whereType<String>().where((s) => s.isNotEmpty).join(' / ')),
    ('Màu', [v.primaries, v.gamma, v.colormatrix].whereType<String>().join(' · ')),
    ('Tín hiệu HDR', hdrLabel(v.primaries, v.gamma).isEmpty ? 'SDR' : hdrLabel(v.primaries, v.gamma)),
    ('Giải mã phần cứng', hwdec.isEmpty || hwdec == 'no' ? 'Không (giải mã mềm)' : hwdec),
    ('Video output', vo),
    ('Âm thanh', audioTrack == null ? 'Không có' : audioTrackLabel(audioTrack)),
    ('Phụ đề', subTrack == null ? 'Tắt' : subtitleTrackLabel(subTrack)),
  ];
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(IconsaxPlusLinear.info_circle),
      title: const Text('Thông tin phát'),
      // Scrollable: in landscape on phones the dialog is taller than the screen.
      scrollable: true,
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (k, val) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 170, child: Text(k, style: Theme.of(context).textTheme.labelLarge)),
                    const SizedBox(width: 8),
                    Expanded(child: SelectableText(val.isEmpty ? '—' : val)),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Text(
              'Tín hiệu HDR chỉ cho biết nguồn mang gì, không có nghĩa màn hình đang xuất HDR.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Đóng'))],
    ),
  );
}
