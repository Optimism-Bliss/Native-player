import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import '../../bridge.dart';
import '../../util/format.dart';
import '../media3_player.dart';
import '../playback_controller.dart';
import 'subtitle_style_sheet.dart';

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

const _sourceNames = {'addon': 'Addon', 'aiostreams': 'AIOStreams', 'upload': 'Tải lên', 'online': 'Đã chọn trước'};

String serverSubtitleLabel(ServerSubtitle s) {
  final lang = languageName(s.language);
  return [if (lang.isNotEmpty) lang, s.label].join(' · ');
}

/// Subtitle picker with source chips (like switching providers in the web
/// player): embedded tracks, server subtitles (AIOStreams and other addons,
/// uploads) and online search results (OpenSubtitles, SubDL…).
Future<void> showSubtitleSheet(BuildContext context, PlaybackController c) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _SubtitleSheet(c: c),
  );
}

class _SubtitleSheet extends StatefulWidget {
  const _SubtitleSheet({required this.c});
  final PlaybackController c;

  @override
  State<_SubtitleSheet> createState() => _SubtitleSheetState();
}

class _SubtitleSheetState extends State<_SubtitleSheet> {
  static const _all = '\u0000all';
  static const _file = '\u0000file';
  String _filter = _all;

  PlaybackController get c => widget.c;

  String _sourceOf(ServerSubtitle s) => _sourceNames[s.source] ?? s.source ?? 'Server';

  static const _subtitleExtensions = {'srt', 'ass', 'ssa', 'vtt', 'sub', 'txt'};

  /// Subtitle file from the device (Downloads, a USB drive…).
  Future<void> _pickLocal() async {
    try {
      final files = await FilePicker.pickFiles(dialogTitle: 'Chọn file phụ đề');
      if (files.isEmpty) return;
      final f = files.first;
      final ext = f.name.contains('.') ? f.name.split('.').last.toLowerCase() : '';
      if (!_subtitleExtensions.contains(ext)) {
        c.say('Chỉ hỗ trợ file .srt, .ass, .ssa, .vtt');
        return;
      }
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
        c.say('File phụ đề rỗng hoặc quá lớn');
        return;
      }
      if (mounted) setState(() => _filter = _all);
      await c.loadLocalSubtitle(f.name, bytes);
    } catch (e) {
      c.say('Không mở được file: $e');
    }
  }

  Future<void> _search() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => _LanguagePicker(defaults: c.subtitleLanguages),
    );
    if (picked == null || picked.isEmpty) return;
    if (mounted) setState(() => _filter = _all);
    await c.searchOnline(picked);
  }

  @override
  Widget build(BuildContext context) {
    final player = c.player;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([c.active, c.serverSubtitles, c.serverSubtitleId, c.search, c.localSubtitles]),
      builder: (context, _) {
        final selected = c.active.value.subtitle;
        final serverOn = c.serverSubtitleId.value != null && selected == c.serverSubtitleTrackId;
        final embedded = player.state.tracks.subtitle
            .where((t) => t.id != 'auto' && t.id != 'no' && !c.isServerTrack(t.id))
            .toList();
        final search = c.search.value;
        final server = [
          ...c.localSubtitles.value,
          ...c.serverSubtitles.value,
          ...search.results.where((r) => !c.serverSubtitles.value.any((s) => s.id == r.id)),
        ];
        final sources = <String>{for (final s in server) _sourceOf(s)}.toList();
        bool show(String source) => _filter == _all || _filter == source;

        Widget chip(String label, String value) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ChoiceChip(
            label: Text(label),
            selected: _filter == value,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => setState(() => _filter = value),
          ),
        );

        return _SheetList(
          title: 'Phụ đề',
          icon: IconsaxPlusLinear.subtitle,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                children: [
                  chip('Tất cả', _all),
                  if (embedded.isNotEmpty) chip('Trong file', _file),
                  for (final src in sources) chip(src, src),
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      avatar: const Icon(IconsaxPlusLinear.folder_open, size: 16),
                      label: const Text('Từ máy'),
                      visualDensity: VisualDensity.compact,
                      onPressed: _pickLocal,
                    ),
                  ),
                  ActionChip(
                    avatar: const Icon(IconsaxPlusLinear.search_normal_1, size: 16),
                    label: Text(search.done ? 'Tìm lại' : 'Tìm online'),
                    visualDensity: VisualDensity.compact,
                    onPressed: search.loading ? null : _search,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: ActionChip(
                      avatar: const Icon(IconsaxPlusLinear.text, size: 16),
                      label: const Text('Kiểu chữ'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => showSubtitleStyleSheet(context, c.player),
                    ),
                  ),
                ],
              ),
            ),
            if (search.loading)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(
                  children: [
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 10),
                    Text('Đang tìm phụ đề (${search.languages})…', style: text.bodySmall),
                  ],
                ),
              )
            else if (search.done && (search.note.isNotEmpty || search.results.isEmpty))
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Text(
                  search.results.isEmpty && search.note.isEmpty ? 'Không tìm thấy phụ đề online.' : search.note,
                  style: text.bodySmall,
                ),
              ),
            const SizedBox(height: 4),
            _TrackTile(
              label: 'Tắt',
              selected: selected == 'no',
              onTap: () {
                Navigator.pop(context);
                player.setSubtitleTrack(SubtitleTrack.no());
                c.clearServerSubtitle(off: true);
              },
            ),
            if (_filter == _all || _filter == _file)
              for (final t in embedded)
                _TrackTile(
                  label: subtitleTrackLabel(t),
                  selected: t.id == selected,
                  badge: t.uri ? 'Link' : 'Trong file',
                  onTap: () async {
                    Navigator.pop(context);
                    await player.setSubtitleTrack(t);
                    await c.clearServerSubtitle(off: false);
                    // mpv only shows embedded events demuxed after the switch;
                    // an in-place seek brings back the line that is on screen now.
                    if (!t.uri) await player.seek(player.state.position);
                  },
                ),
            for (final s in server)
              if (show(_sourceOf(s)))
                _TrackTile(
                  label: [
                    serverSubtitleLabel(s),
                    if (s.exactMatch) '✓ đúng bản',
                    if (s.downloads != null) '${s.downloads} lượt tải',
                  ].join(' · '),
                  selected: serverOn && c.serverSubtitleId.value == s.id,
                  badge: s.blocked ? '${_sourceOf(s)} · hết lượt' : _sourceOf(s),
                  onTap: s.blocked
                      ? () {}
                      : () {
                          Navigator.pop(context);
                          s.id.startsWith('local:') ? c.selectLocalSubtitle(s) : c.selectServerSubtitle(s);
                        },
                ),
            const Divider(height: 12),
            _SubtitleTuning(player: player),
          ],
        );
      },
    );
  }
}

/// Languages to search, defaulting to the server's subtitle languages.
class _LanguagePicker extends StatefulWidget {
  const _LanguagePicker({required this.defaults});
  final List<String> defaults;

  @override
  State<_LanguagePicker> createState() => _LanguagePickerState();
}

class _LanguagePickerState extends State<_LanguagePicker> {
  static const _common = ['vi', 'en', 'ja', 'ko', 'zh', 'th', 'fr', 'es', 'de'];
  late final Set<String> _picked = {...widget.defaults};

  @override
  Widget build(BuildContext context) {
    final all = {...widget.defaults, ..._common}.toList();
    return AlertDialog(
      title: const Text('Tìm phụ đề online'),
      content: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final l in all)
            FilterChip(
              label: Text(languageName(l).isEmpty ? l : languageName(l)),
              selected: _picked.contains(l),
              onSelected: (on) => setState(() => on ? _picked.add(l) : _picked.remove(l)),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Huỷ')),
        FilledButton(
          onPressed: _picked.isEmpty ? null : () => Navigator.pop(context, all.where(_picked.contains).join(',')),
          child: const Text('Tìm'),
        ),
      ],
    );
  }
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
  final media3 = player.platform is Media3Player ? player.platform as Media3Player : null;
  Future<String> prop(String name) async {
    try {
      if (media3 != null) return await media3.getProperty(name);
      return await native?.getProperty(name) ?? '';
    } catch (_) {
      return '';
    }
  }

  final hwdec = await prop('hwdec-current');
  final vo = await prop('current-vo');
  final container = await prop('file-format');
  final drops = await prop('frame-drop-count');
  final decoderDrops = await prop('decoder-frame-drop-count');
  final fps = double.tryParse(await prop('estimated-vf-fps'));
  final cache = double.tryParse(await prop('demuxer-cache-duration'));
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
    (
      'Khung hình',
      [
        if (fps != null) '${fps.toStringAsFixed(1)} fps',
        'rơi ${drops.isEmpty ? '0' : drops} (hiển thị) / ${decoderDrops.isEmpty ? '0' : decoderDrops} (giải mã)',
      ].join(' · '),
    ),
    ('Bộ đệm', cache == null ? '' : '${cache.toStringAsFixed(0)} giây'),
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
