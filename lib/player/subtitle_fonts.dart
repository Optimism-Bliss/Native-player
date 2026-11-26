import 'dart:io';

import 'package:flutter/services.dart';
// ignore: implementation_imports
import 'package:media_kit/src/player/native/utils/android_asset_loader.dart';
import 'package:path_provider/path_provider.dart';

import '../util/log.dart';

/// A subtitle typeface bundled with the app (assets/fonts, subset to Latin + Vietnamese, OFL).
class SubtitleFont {
  const SubtitleFont(this.label, this.family, this.regular, this.bold);
  final String label;

  /// Family name libass / mpv `sub-font` looks up.
  final String family;
  final String regular;
  final String? bold;
}

/// Subtitle fonts with proper Vietnamese diacritics. libass on Android cannot see system fonts, and
/// the font media_kit ships (Droid Sans Fallback, a CJK fallback) stacks Vietnamese marks badly.
class SubtitleFonts {
  static const all = [
    SubtitleFont('Be Vietnam Pro', 'Be Vietnam Pro', 'BeVietnamPro-SemiBold.ttf', 'BeVietnamPro-Bold.ttf'),
    SubtitleFont('Roboto', 'Roboto', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf'),
    SubtitleFont('Noto Sans', 'Noto Sans', 'NotoSans-Medium.ttf', 'NotoSans-Bold.ttf'),
    SubtitleFont('Droid Sans (cũ)', 'Droid Sans Fallback', 'DroidSansFallback.ttf', null),
  ];

  static SubtitleFont byFamily(String family) => all.firstWhere((f) => f.family == family, orElse: () => all.first);

  static Iterable<String> get _files sync* {
    for (final f in all) {
      yield f.regular;
      if (f.bold != null) yield f.bold!;
    }
  }

  /// Puts every bundled font where libass looks. Android: next to the font media_kit copies (same
  /// `sub-fonts-dir`), before the player is created. Desktop: a folder in app support, returned so
  /// the caller sets `sub-fonts-dir` (system fonts stay available there too).
  static Future<String?> prepare() async {
    try {
      if (Platform.isAndroid) {
        for (final f in _files) {
          await AndroidAssetLoader.load('flutter_assets/assets/fonts/$f');
        }
        return null;
      }
      final dir = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}sub-fonts');
      await dir.create(recursive: true);
      for (final f in _files) {
        final out = File('${dir.path}${Platform.pathSeparator}$f');
        if (await out.exists()) continue;
        final data = await rootBundle.load('assets/fonts/$f');
        await out.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      }
      return dir.path;
    } catch (e) {
      appLog('subtitle fonts: $e');
      return null;
    }
  }
}
