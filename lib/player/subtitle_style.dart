import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'media3_player.dart';
import 'subtitle_fonts.dart';

/// How plain subtitles (SRT, VTT, and ASS when overridden) look, kept between sessions.
/// Applied to libmpv: `sub-scale`, `sub-bold`, `sub-color`, `sub-border-*`, `sub-back-color`.
class SubtitleStyle {
  const SubtitleStyle({
    this.scale = 1.0,
    this.bold = true,
    this.color = 0xFFFFFFFF,
    this.boxAlpha = 0,
    this.border = 3,
    this.font = 'Be Vietnam Pro',
  });

  /// Typeface family (SubtitleFonts.all).
  final String font;

  final double scale;
  final bool bold;
  final int color;

  /// Black box behind the text: 0 = none (outline only), 0xB0 = translucent, 0xFF = solid (also hides
  /// subtitles burned into the picture).
  final int boxAlpha;
  bool get box => boxAlpha > 0;

  static const boxChoices = <(int, String)>[(0, 'Không'), (0x99, 'Đen mờ'), (0xFF, 'Đen đặc')];
  final double border;

  static const colors = <(String, int)>[
    ('Trắng', 0xFFFFFFFF),
    ('Vàng', 0xFFFFE14D),
    ('Xanh nhạt', 0xFF9BE7FF),
    ('Xám nhạt', 0xFFD9D9D9),
  ];

  static SubtitleStyle current = const SubtitleStyle();

  SubtitleStyle copyWith({double? scale, bool? bold, int? color, int? boxAlpha, double? border, String? font}) =>
      SubtitleStyle(
        scale: scale ?? this.scale,
        bold: bold ?? this.bold,
        color: color ?? this.color,
        boxAlpha: boxAlpha ?? this.boxAlpha,
        border: border ?? this.border,
        font: font ?? this.font,
      );

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    current = SubtitleStyle(
      scale: (p.getDouble('sub_style_scale') ?? 1.0).clamp(0.5, 2.5),
      bold: p.getBool('sub_style_bold') ?? true,
      color: p.getInt('sub_style_color') ?? 0xFFFFFFFF,
      boxAlpha: p.getInt('sub_style_box_alpha') ?? ((p.getBool('sub_style_box') ?? false) ? 0x99 : 0),
      border: (p.getDouble('sub_style_border') ?? 3).clamp(0, 6),
      font: SubtitleFonts.byFamily(p.getString('sub_style_font') ?? 'Be Vietnam Pro').family,
    );
  }

  Future<void> save() async {
    current = this;
    final p = await SharedPreferences.getInstance();
    await p.setDouble('sub_style_scale', scale);
    await p.setBool('sub_style_bold', bold);
    await p.setInt('sub_style_color', color);
    await p.setInt('sub_style_box_alpha', boxAlpha);
    await p.setDouble('sub_style_border', border);
    await p.setString('sub_style_font', font);
  }

  static String _hex(int argb) {
    final a = (argb >> 24) & 0xFF, r = (argb >> 16) & 0xFF, g = (argb >> 8) & 0xFF, b = argb & 0xFF;
    String h(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
    return '#${h(a)}${h(r)}${h(g)}${h(b)}';
  }

  Future<void> apply(Player player) async {
    final native = player.platform;
    if (native is Media3Player) {
      final f = SubtitleFonts.byFamily(font);
      return native.setSubtitleStyle({
        'scale': scale,
        'bold': bold,
        'color': color,
        'box': box,
        'boxAlpha': boxAlpha,
        'border': border,
        'font': 'flutter_assets/assets/fonts/${f.regular}',
        'fontBold': f.bold == null ? null : 'flutter_assets/assets/fonts/${f.bold}',
      });
    }
    if (native is! NativePlayer) return;
    for (final (k, v) in [
      ('sub-font', SubtitleFonts.byFamily(font).family),
      ('sub-scale', scale.toStringAsFixed(2)),
      ('sub-bold', bold ? 'yes' : 'no'),
      ('sub-color', _hex(color)),
      ('sub-border-size', border.toStringAsFixed(1)),
      // opaque-box: the box takes the back colour (with its alpha) and the border size as padding
      ('sub-border-color', '#FF000000'),
      if (box)
        (
          'sub-border-size',
          // the box hugs the text with the border size as padding: give it room (looked cramped at 3)
          (boxAlpha == 0xFF ? 8.0 : 6.0).toStringAsFixed(1),
        ),
      ('sub-shadow-offset', box ? '0' : '1'),
      ('sub-back-color', box ? '#${boxAlpha.toRadixString(16).padLeft(2, '0').toUpperCase()}000000' : '#00000000'),
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
