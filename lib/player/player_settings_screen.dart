import 'dart:io';

import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../util/tv_mode.dart';
import 'pip.dart';
import 'player_settings.dart';
import 'subtitle_style.dart';
import 'tv_playback_prefs.dart';
import 'widgets/subtitle_style_sheet.dart';

/// Settings → Trình phát (after Fladder's player settings page). Changes apply from the next
/// film; [player] (opened from the player) also gets the subtitle style right away.
class PlayerSettingsScreen extends StatefulWidget {
  const PlayerSettingsScreen({super.key, this.player});
  final Player? player;

  static Future<void> open(BuildContext context, {Player? player}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PlayerSettingsScreen(player: player)));

  @override
  State<PlayerSettingsScreen> createState() => _PlayerSettingsScreenState();
}

class _PlayerSettingsScreenState extends State<PlayerSettingsScreen> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((i) => mounted ? setState(() => _version = i.version) : null).ignore();
  }

  Future<void> _set(VoidCallback change) async {
    setState(change);
    await PlayerSettings.save();
  }

  Widget _header(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 6),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );

  Widget _switch(String title, String? subtitle, bool value, ValueChanged<bool> onChanged, {IconData? icon}) =>
      SwitchListTile(
        secondary: icon == null ? null : Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        value: value,
        onChanged: onChanged,
      );

  Widget _choices<T>(
    String title,
    String? subtitle,
    List<(T, String)> items,
    T selected,
    ValueChanged<T> onSelected, {
    IconData? icon,
  }) => ListTile(
    leading: icon == null ? null : Icon(icon),
    title: Text(title),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (subtitle != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(subtitle)),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final (v, label) in items)
              ChoiceChip(label: Text(label), selected: v == selected, onSelected: (_) => onSelected(v)),
          ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final touch = Platform.isAndroid || Platform.isIOS;
    final tv = TvPlaybackPrefs.available;
    return Scaffold(
      appBar: AppBar(title: const Text('Cài đặt trình phát')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _header('Phát'),
          _switch(
            'Tự phát tập kế tiếp',
            'Hết tập thì phát tập sau trong danh sách',
            PlayerSettings.autoNext,
            (v) => _set(() => PlayerSettings.autoNext = v),
            icon: IconsaxPlusLinear.next,
          ),
          _choices(
            'Tua lùi',
            'Nút tua lùi, phím ◀ / J, remote',
            [for (final s in PlayerSettings.seekChoices) (s, '$s giây')],
            PlayerSettings.seekBack,
            (v) => _set(() => PlayerSettings.seekBack = v),
            icon: IconsaxPlusLinear.backward_10_seconds,
          ),
          _choices(
            'Tua tới',
            'Nút tua tới, phím L, nút tua nhanh của remote',
            [for (final s in PlayerSettings.seekChoices) (s, '$s giây')],
            PlayerSettings.seekForward,
            (v) => _set(() => PlayerSettings.seekForward = v),
            icon: IconsaxPlusLinear.forward_10_seconds,
          ),
          _choices(
            'Bộ đệm',
            'Lượng phim tải trước. Lớn hơn: ít dừng chờ mạng nhưng tốn RAM (TV box ít RAM nên để Tự động).',
            [for (final mb in PlayerSettings.bufferChoices) (mb, mb == 0 ? 'Tự động' : '$mb MB')],
            PlayerSettings.bufferMb,
            (v) => _set(() => PlayerSettings.bufferMb = v),
            icon: IconsaxPlusLinear.cpu,
          ),
          _header('Ngôn ngữ'),
          _choices(
            'Âm thanh ưu tiên',
            'Khi file có nhiều rãnh âm thanh',
            PlayerSettings.langChoices,
            PlayerSettings.audioLang,
            (v) => _set(() => PlayerSettings.audioLang = v),
            icon: IconsaxPlusLinear.audio_square,
          ),
          _choices(
            'Phụ đề ưu tiên',
            'Phụ đề trong file được bật theo ngôn ngữ này',
            PlayerSettings.langChoices,
            PlayerSettings.subLang,
            (v) => _set(() => PlayerSettings.subLang = v),
            icon: IconsaxPlusLinear.subtitle,
          ),
          _header('Phụ đề'),
          ListTile(
            leading: const Icon(IconsaxPlusLinear.text),
            title: const Text('Kiểu chữ phụ đề'),
            subtitle: Text(
              'Cỡ ${(SubtitleStyle.current.scale * 100).round()}%'
              '${SubtitleStyle.current.bold ? ' · đậm' : ''}${SubtitleStyle.current.box ? ' · nền tối' : ''}',
            ),
            trailing: const Icon(IconsaxPlusLinear.arrow_right_3),
            onTap: () async {
              await showSubtitleStyleSheet(context, widget.player);
              if (mounted) setState(() {});
            },
          ),
          if (touch && !tv) ...[
            _header('Cử chỉ'),
            _switch(
              'Chạm đúp để tua',
              'Chạm đúp bên trái / phải để tua, giữa để tạm dừng',
              PlayerSettings.doubleTapSeek,
              (v) => _set(() => PlayerSettings.doubleTapSeek = v),
              icon: IconsaxPlusLinear.finger_scan,
            ),
            _switch(
              'Vuốt chỉnh độ sáng / âm lượng',
              'Vuốt dọc nửa trái: độ sáng, nửa phải: âm lượng',
              PlayerSettings.swipeGestures,
              (v) => _set(() => PlayerSettings.swipeGestures = v),
              icon: IconsaxPlusLinear.sun_1,
            ),
            if (Pip.available)
              _switch(
                'Hình trong hình (PiP)',
                'Đang xem mà bấm Home thì phim thu thành cửa sổ nhỏ',
                PlayerSettings.autoPip,
                (v) => _set(() => PlayerSettings.autoPip = v),
                icon: IconsaxPlusLinear.screenmirroring,
              ),
          ],
          if (tv) ...[
            _header('TV'),
            _choices(
              'Trình phát',
              'Media3: giải mã thẳng ra màn hình, mượt trên box yếu. mpv: dùng khi Media3 không phát được.',
              const [(true, 'Media3'), (false, 'mpv')],
              TvPlaybackPrefs.nativePlayer,
              (v) async {
                await TvPlaybackPrefs.setNativePlayer(v);
                setState(() {});
              },
              icon: IconsaxPlusLinear.video_play,
            ),
            if (TvPlaybackPrefs.nativePlayer)
              _switch(
                'Tunneling',
                'Chip TV tự đồng bộ hình và tiếng. Thử khi vẫn giật; tắt nếu mất hình / tiếng.',
                TvPlaybackPrefs.tunneling,
                (v) async {
                  await TvPlaybackPrefs.setTunneling(v);
                  setState(() {});
                },
                icon: IconsaxPlusLinear.flash,
              ),
            _switch(
              'Khớp tần số màn hình',
              'Màn hình chuyển theo phim (24 / 25 / 30 Hz); có thể tối khoảng 1 giây',
              TvPlaybackPrefs.matchFrameRate,
              (v) async {
                await TvPlaybackPrefs.setMatchFrameRate(v);
                setState(() {});
              },
              icon: IconsaxPlusLinear.monitor,
            ),
            if (!TvPlaybackPrefs.nativePlayer)
              _switch(
                'Tương thích (mpv)',
                'Chép từng khung hình; dùng khi phim không lên hình. Mở lại app để áp dụng.',
                TvPlaybackPrefs.compat,
                (v) async {
                  await TvPlaybackPrefs.setCompat(v);
                  setState(() {});
                },
                icon: IconsaxPlusLinear.cpu_setting,
              ),
          ],
          if (!touch || isTvDevice) ...[_header('Phím tắt'), const _Shortcuts()],
          _header('Giới thiệu'),
          ListTile(
            leading: const Icon(IconsaxPlusLinear.info_circle),
            title: const Text('TorBox STRM'),
            subtitle: Text(_version.isEmpty ? '' : 'Phiên bản $_version · trình phát mpv${tv ? ' / Media3' : ''}'),
          ),
        ],
      ),
    );
  }
}

class _Shortcuts extends StatelessWidget {
  const _Shortcuts();

  static const _keys = [
    ('Space / K', 'Phát / tạm dừng'),
    ('← →', 'Tua 5 giây'),
    ('J / L', 'Tua lùi / tới (theo cài đặt)'),
    ('↑ ↓', 'Âm lượng'),
    ('M', 'Tắt / bật tiếng'),
    ('F / F11', 'Toàn màn hình'),
    ('N / P', 'Tập sau / trước'),
    ('PgUp / PgDn', 'Chương trước / sau'),
    ('Z / X', 'Lệch phụ đề −/+ 100 ms'),
    ('S / V', 'Ẩn / hiện phụ đề'),
    ('0 – 9', 'Nhảy tới 0 % – 90 % phim'),
    ('Esc', 'Thoát toàn màn hình / đóng'),
  ];

  @override
  Widget build(BuildContext context) {
    final mono = Theme.of(context).textTheme.labelLarge;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (final (k, what) in _keys)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(width: 120, child: Text(k, style: mono)),
                  Expanded(child: Text(what)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
