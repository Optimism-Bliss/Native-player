import 'dart:async';

import 'package:flutter/services.dart';
import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:material_ui/material_ui.dart';

import '../util/format.dart';
import 'protocol.dart';
import 'sender.dart';
import 'tv_input.dart';

/// Phone remote for what plays on the TV, kept in sync by the session's poll.
class TvRemoteScreen extends StatefulWidget {
  const TvRemoteScreen({super.key, required this.session, required this.tvName});
  final TvSession session;
  final String tvName;

  @override
  State<TvRemoteScreen> createState() => _TvRemoteScreenState();
}

class _TvRemoteScreenState extends State<TvRemoteScreen> {
  /// Slider position while the finger is on it (null = follow the TV).
  double? _drag;

  TvSession get s => widget.session;

  Future<void> _cmd(String action, [Map<String, Object?> extra = const {}]) async {
    try {
      final st = await s.client.command(action, extra);
      if (st != null && mounted) s.state.value = st;
    } on TvError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _pick({
    required String title,
    required List<TvTrack> items,
    required String? selected,
    required void Function(TvTrack) onPick,
    VoidCallback? onOff,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(title, style: Theme.of(context).textTheme.titleMedium),
            ),
            if (onOff != null)
              ListTile(
                dense: true,
                title: const Text('Tắt'),
                trailing: selected == 'no' ? const Icon(IconsaxPlusBold.tick_circle, size: 18) : null,
                onTap: () {
                  Navigator.pop(context);
                  onOff();
                },
              ),
            for (final t in items)
              ListTile(
                dense: true,
                title: Text(t.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: t.id == selected ? const Icon(IconsaxPlusBold.tick_circle, size: 18) : null,
                onTap: () {
                  Navigator.pop(context);
                  onPick(t);
                },
              ),
            if (items.isEmpty) const ListTile(dense: true, title: Text('Không có lựa chọn nào')),
          ],
        ),
      ),
    );
  }

  void _subtitles(TvState st) {
    final all = [
      for (final t in st.subtitles) TvTrack('e:${t.id}', '${t.label} · Trong file'),
      for (final t in st.serverSubtitles) TvTrack('s:${t.id}', t.label),
    ];
    final selected = st.serverSubtitleId != null
        ? 's:${st.serverSubtitleId}'
        : st.subtitleId == 'no' || st.subtitleId.isEmpty
        ? 'no'
        : 'e:${st.subtitleId}';
    _pick(
      title: 'Phụ đề',
      items: all,
      selected: selected,
      onOff: () => _cmd('subOff'),
      onPick: (t) =>
          t.id.startsWith('s:') ? _cmd('serverSub', {'id': t.id.substring(2)}) : _cmd('sub', {'id': t.id.substring(2)}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(IconsaxPlusLinear.monitor, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(widget.tvName, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
      body: SafeArea(
        child: ValueListenableBuilder<TvState>(
          valueListenable: s.state,
          builder: (context, st, _) {
            final dur = st.duration.inMilliseconds.toDouble();
            final pos = (_drag ?? st.position.inMilliseconds.toDouble()).clamp(0.0, dur > 0 ? dur : 1.0);
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              children: [
                ValueListenableBuilder<String?>(
                  valueListenable: s.problem,
                  builder: (context, p, _) => p == null
                      ? const SizedBox.shrink()
                      : Card(
                          color: scheme.errorContainer,
                          child: Padding(padding: const EdgeInsets.all(12), child: Text(p)),
                        ),
                ),
                if (!st.active && !s.running && st.input == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text('TV không phát gì.', style: text.titleMedium, textAlign: TextAlign.center),
                  ),
                // a field is selected on the TV: typing comes first (the phone keyboard opens by itself)
                if (st.input != null) _TvKeyboard(session: s, field: st.input!),
                _RemotePad(onKey: (k) => _cmd('key', {'key': k})),
                const SizedBox(height: 16),
                if (!st.active && st.input == null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      'Chọn một ô nhập trên TV (tìm phim, đăng nhập…) là có thể gõ từ đây.',
                      style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                if (st.active)
                  Text(st.title.isEmpty ? 'Đang mở trên TV…' : st.title, style: text.titleLarge, maxLines: 3),
                if (st.count > 1) Text('${st.index + 1} / ${st.count}', style: text.bodySmall),
                if (st.error != null) Text(st.error!, style: text.bodyMedium?.copyWith(color: scheme.error)),
                const SizedBox(height: 16),
                Slider(
                  value: pos,
                  max: dur > 0 ? dur : 1,
                  onChanged: dur > 0 ? (v) => setState(() => _drag = v) : null,
                  onChangeEnd: (v) {
                    setState(() => _drag = null);
                    _cmd('seek', {'to': v / 1000});
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      Text(formatDuration(Duration(milliseconds: pos.round())), style: text.bodySmall),
                      const Spacer(),
                      if (st.buffering) Text('Đang tải…', style: text.bodySmall),
                      const Spacer(),
                      Text(formatDuration(st.duration), style: text.bodySmall),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      onPressed: st.index > 0 ? () => _cmd('prev') : null,
                      icon: const Icon(IconsaxPlusLinear.previous),
                      tooltip: 'Tập trước',
                    ),
                    IconButton(
                      onPressed: () => _cmd('seekBy', {'by': -10}),
                      icon: const Icon(IconsaxPlusLinear.backward_10_seconds),
                      iconSize: 32,
                      tooltip: '-10 giây',
                    ),
                    IconButton.filledTonal(
                      onPressed: () => _cmd('toggle'),
                      icon: Icon(st.playing ? IconsaxPlusBold.pause : IconsaxPlusBold.play),
                      iconSize: 40,
                      tooltip: st.playing ? 'Tạm dừng' : 'Phát',
                    ),
                    IconButton(
                      onPressed: () => _cmd('seekBy', {'by': 30}),
                      icon: const Icon(IconsaxPlusLinear.forward_10_seconds),
                      iconSize: 32,
                      tooltip: '+30 giây',
                    ),
                    IconButton(
                      onPressed: st.index + 1 < st.count ? () => _cmd('next') : null,
                      icon: const Icon(IconsaxPlusLinear.next),
                      tooltip: 'Tập sau',
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Icon(IconsaxPlusLinear.volume_high, size: 20),
                    Expanded(
                      child: Slider(
                        value: st.volume.clamp(0, 100),
                        max: 100,
                        onChangeEnd: (v) => _cmd('volume', {'value': v}),
                        onChanged: (v) => s.state.value = TvState.fromJson({...st.toJson(), 'volume': v}),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: st.audio.isEmpty
                          ? null
                          : () => _pick(
                              title: 'Âm thanh',
                              items: st.audio,
                              selected: st.audioId,
                              onPick: (t) => _cmd('audio', {'id': t.id}),
                            ),
                      icon: const Icon(IconsaxPlusLinear.audio_square, size: 18),
                      label: const Text('Âm thanh'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _subtitles(st),
                      icon: const Icon(IconsaxPlusLinear.subtitle, size: 18),
                      label: const Text('Phụ đề'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => _cmd('stop'),
                      icon: const Icon(IconsaxPlusLinear.stop_circle, size: 18),
                      label: const Text('Dừng trên TV'),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Types into the text field focused on the TV. Sends the whole text a moment
/// after each change (so corrections and pasted text work the same), and
/// "Gửi" submits like Enter.
class _TvKeyboard extends StatefulWidget {
  const _TvKeyboard({required this.session, required this.field});
  final TvSession session;
  final TvField field;

  @override
  State<_TvKeyboard> createState() => _TvKeyboardState();
}

class _TvKeyboardState extends State<_TvKeyboard> {
  late final TextEditingController _text = TextEditingController(text: widget.field.value);
  Timer? _debounce;
  String? _error;

  @override
  void didUpdateWidget(_TvKeyboard old) {
    super.didUpdateWidget(old);
    // another field got focus on the TV: start from its text
    if (old.field.label != widget.field.label || old.field.kind != widget.field.kind) {
      _text.text = widget.field.value;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  Future<void> _send(String action) async {
    _debounce?.cancel();
    try {
      if (action == 'enter') await widget.session.client.input('set', _text.text);
      await widget.session.client.input(action, _text.text);
      if (mounted && _error != null) setState(() => _error = null);
    } on TvError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.field;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(IconsaxPlusLinear.keyboard, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Gõ trên TV${f.label.isEmpty ? '' : ' · ${f.label}'}',
                    style: Theme.of(context).textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _text,
              autofocus: true,
              obscureText: f.password,
              autocorrect: false,
              keyboardType: switch (f.kind) {
                'email' => TextInputType.emailAddress,
                'url' => TextInputType.url,
                'number' => TextInputType.number,
                _ => TextInputType.text,
              },
              textInputAction: TextInputAction.send,
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 250), () => _send('set'));
              },
              onSubmitted: (_) => _send('enter'),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                isDense: true,
                errorText: _error,
                suffixIcon: IconButton(
                  tooltip: 'Gửi (Enter)',
                  icon: const Icon(IconsaxPlusLinear.send_1),
                  onPressed: () => _send('enter'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The TV remote on the phone: arrows, OK, Back, Home and play/pause. Each key
/// reaches the TV app like its own remote's (start screen, web page, player,
/// dialogs). Holding an arrow repeats it, to scroll long lists.
class _RemotePad extends StatelessWidget {
  const _RemotePad({required this.onKey});
  final void Function(String key) onKey;

  void _press(String key) {
    HapticFeedback.selectionClick();
    onKey(key);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget arrow(String key, IconData icon, String tip) =>
        _RepeatButton(onPress: () => _press(key), icon: icon, tooltip: tip);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
        child: Column(
          children: [
            SizedBox(
              width: 228,
              height: 228,
              child: DecoratedBox(
                decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.surfaceContainerHighest),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Align(alignment: Alignment.topCenter, child: arrow('up', IconsaxPlusBold.arrow_up_2, 'Lên')),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: arrow('down', IconsaxPlusBold.arrow_down_1, 'Xuống'),
                    ),
                    Align(alignment: Alignment.centerLeft, child: arrow('left', IconsaxPlusBold.arrow_left_2, 'Trái')),
                    Align(
                      alignment: Alignment.centerRight,
                      child: arrow('right', IconsaxPlusBold.arrow_right_3, 'Phải'),
                    ),
                    SizedBox(
                      width: 92,
                      height: 92,
                      child: FilledButton(
                        style: FilledButton.styleFrom(shape: const CircleBorder(), padding: EdgeInsets.zero),
                        onPressed: () => _press('ok'),
                        child: const Text('OK', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton.filledTonal(
                  onPressed: () => _press('back'),
                  icon: const Icon(IconsaxPlusLinear.arrow_left),
                  tooltip: 'Quay lại',
                ),
                IconButton.filledTonal(
                  onPressed: () => _press('home'),
                  icon: const Icon(IconsaxPlusLinear.home_2),
                  tooltip: 'Màn hình chính TV',
                ),
                IconButton.filledTonal(
                  onPressed: () => _press('playpause'),
                  icon: const Icon(IconsaxPlusLinear.play_circle),
                  tooltip: 'Phát / tạm dừng',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Arrow key: tap sends once, holding repeats every 150 ms.
class _RepeatButton extends StatefulWidget {
  const _RepeatButton({required this.onPress, required this.icon, required this.tooltip});
  final VoidCallback onPress;
  final IconData icon;
  final String tooltip;

  @override
  State<_RepeatButton> createState() => _RepeatButtonState();
}

class _RepeatButtonState extends State<_RepeatButton> {
  Timer? _repeat;

  void _stop() {
    _repeat?.cancel();
    _repeat = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onLongPressStart: (_) {
      widget.onPress();
      _repeat = Timer.periodic(const Duration(milliseconds: 150), (_) => widget.onPress());
    },
    onLongPressEnd: (_) => _stop(),
    onLongPressCancel: _stop,
    // no tooltip: its own long press would fight the repeat gesture
    child: Semantics(
      label: widget.tooltip,
      button: true,
      child: IconButton(
        onPressed: widget.onPress,
        iconSize: 34,
        padding: const EdgeInsets.all(14),
        icon: Icon(widget.icon),
      ),
    ),
  );
}
