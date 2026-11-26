import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import '../subtitle_fonts.dart';
import '../subtitle_style.dart';

/// Size, weight, colour and background of subtitles; applied live and kept for next time.
Future<void> showSubtitleStyleSheet(BuildContext context, Player? player) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => _StyleSheet(player: player),
  );
}

class _StyleSheet extends StatefulWidget {
  const _StyleSheet({required this.player});
  final Player? player;

  @override
  State<_StyleSheet> createState() => _StyleSheetState();
}

class _StyleSheetState extends State<_StyleSheet> {
  SubtitleStyle s = SubtitleStyle.current;

  Future<void> _set(SubtitleStyle next) async {
    setState(() => s = next);
    await next.save();
    final p = widget.player;
    if (p != null) await next.apply(p);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Kiểu chữ phụ đề', style: text.titleLarge),
            const SizedBox(height: 4),
            Text('Áp dụng cho SRT / VTT; phụ đề ASS giữ kiểu riêng của nó.', style: text.bodySmall),
            const SizedBox(height: 16),
            const Text('Font chữ'),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in SubtitleFonts.all)
                  ChoiceChip(
                    label: Text(f.label),
                    selected: s.font == f.family,
                    onSelected: (_) => _set(s.copyWith(font: f.family)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('Cỡ chữ: ${(s.scale * 100).round()}%'),
            Slider(
              value: s.scale,
              min: 0.5,
              max: 2.5,
              divisions: 20,
              label: '${(s.scale * 100).round()}%',
              onChanged: (v) => _set(s.copyWith(scale: v)),
            ),
            Text('Viền: ${s.border.toStringAsFixed(1)}'),
            Slider(
              value: s.border,
              min: 0,
              max: 6,
              divisions: 12,
              onChanged: (v) => _set(s.copyWith(border: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Chữ đậm'),
              value: s.bold,
              onChanged: (v) => _set(s.copyWith(bold: v)),
            ),
            const Text('Nền sau chữ'),
            const SizedBox(height: 4),
            Text('Đen đặc che được cả phụ đề in sẵn trong phim', style: text.bodySmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (a, label) in SubtitleStyle.boxChoices)
                  ChoiceChip(
                    label: Text(label),
                    selected: s.boxAlpha == a,
                    onSelected: (_) => _set(s.copyWith(boxAlpha: a)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (name, argb) in SubtitleStyle.colors)
                  ChoiceChip(
                    label: Text(name),
                    avatar: CircleAvatar(backgroundColor: Color(argb), radius: 8),
                    selected: s.color == argb,
                    onSelected: (_) => _set(s.copyWith(color: argb)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: () => _set(const SubtitleStyle()), child: const Text('Mặc định')),
            ),
          ],
        ),
      ),
    );
  }
}
