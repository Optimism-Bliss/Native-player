import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How plain subtitles (SRT, VTT, and ASS when overridden) look, kept between sessions.
/// Applied to libmpv: `sub-scale`, `sub-bold`, `sub-color`, `sub-border-*`, `sub-back-color`.
class SubtitleStyle {
  const SubtitleStyle({this.scale = 1.0, this.bold = true, this.color = 0xFFFFFFFF, this.box = false, this.border = 3});

  final double scale;
  final bool bold;
  final int color;

  /// Dark box behind the text instead of only an outline (easier to read on bright scenes).
  final bool box;
  final double border;

  static const colors = <(String, int)>[
    ('Trắng', 0xFFFFFFFF),
    ('Vàng', 0xFFFFE14D),
    ('Xanh nhạt', 0xFF9BE7FF),
    ('Xám nhạt', 0xFFD9D9D9),
  ];

  static SubtitleStyle current = const SubtitleStyle();

  SubtitleStyle copyWith({double? scale, bool? bold, int? color, bool? box, double? border}) => SubtitleStyle(
    scale: scale ?? this.scale,
    bold: bold ?? this.bold,
    color: color ?? this.color,
    box: box ?? this.box,
    border: border ?? this.border,
  );

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    current = SubtitleStyle(
      scale: (p.getDouble('sub_style_scale') ?? 1.0).clamp(0.5, 2.5),
      bold: p.getBool('sub_style_bold') ?? true,
      color: p.getInt('sub_style_color') ?? 0xFFFFFFFF,
      box: p.getBool('sub_style_box') ?? false,
      border: (p.getDouble('sub_style_border') ?? 3).clamp(0, 6),
    );
  }

  Future<void> save() async {
    current = this;
    final p = await SharedPreferences.getInstance();
    await p.setDouble('sub_style_scale', scale);
    await p.setBool('sub_style_bold', bold);
    await p.setInt('sub_style_color', color);
    await p.setBool('sub_style_box', box);
    await p.setDouble('sub_style_border', border);
  }

  static String _hex(int argb) {
    final a = (argb >> 24) & 0xFF, r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
    String h(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
    return '#${h(a)}${h(r)}${h(g)}${h(b)}';
  }

  Future<void> apply(Player player) async {
    final native = player.platform;
    if (native is! NativePlayer) return;
    for (final (k, v) in [
      ('sub-scale', scale.toStringAsFixed(2)),
      ('sub-bold', bold ? 'yes' : 'no'),
      ('sub-color', _hex(color)),
      ('sub-border-color', '#FF000000'),
      ('sub-border-size', border.toStringAsFixed(1)),
      ('sub-shadow-offset', box ? '0' : '1'),
      ('sub-back-color', box ? '#B0000000' : '#00000000'),
      ('sub-border-style', box ? 'opaque-box' : 'outline-and-shadow'),
    ]) {
      try {
        await native.setProperty(k, v);
      } catch (_) {
        // older libmpv without sub-border-style: the rest still applies
      }
    }
  }
}
