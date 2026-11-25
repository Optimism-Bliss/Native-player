import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../util/tv_mode.dart';

/// How video reaches the screen on Android.
///
/// * GPU (default on phones): mpv decodes with MediaCodec, copies each frame
///   back and draws it with OpenGL, so libass can paint styled subtitles on it.
///   On weak TV boxes the copy of 4K / HEVC frames makes playback stutter.
/// * Direct (default on TVs): MediaCodec renders straight to the screen
///   surface (`vo=mediacodec_embed`), the cheapest path. mpv can no longer
///   draw on the picture, so subtitles are shown as plain text by Flutter.
///
/// The video output is created once per app run, so a change applies after
/// the app is reopened.
class DecodePrefs {
  static const _key = 'player_direct_decode';
  static bool? _saved;

  static Future<void> load() async {
    _saved = (await SharedPreferences.getInstance()).getBool(_key);
  }

  /// Only Android has the direct path.
  static bool get available => Platform.isAndroid;

  static bool get direct => available && (_saved ?? isTvDevice);

  static Future<void> set(bool value) async {
    _saved = value;
    await (await SharedPreferences.getInstance()).setBool(_key, value);
  }
}
