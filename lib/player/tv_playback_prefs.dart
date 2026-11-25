import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/log.dart';
import '../util/tv_mode.dart';

/// Playback settings for TV boxes (Android TV only), after mpv-android's setup.
///
/// * Zero-copy decoding (default): `hwdec=mediacodec,mediacodec-copy` with
///   `gpu-context=android`. MediaCodec frames reach the GPU as textures instead
///   of being copied back to RAM every frame, which is what dropped frames on
///   weak boxes (Mi Box S, Mali-450). mpv still draws the picture, so ASS and
///   PGS subtitles stay. mpv falls back to copying when the device has no
///   interop; [compat] forces copying for boxes where zero-copy shows no picture.
/// * Frame-rate matching (off by default): the display switches to the film's
///   rate (24p film on a 24/48 Hz mode) while the player is open. Needs a TV or
///   monitor that accepts those modes; the screen may go dark for about a second.
///
/// The video output is created once per run: [compat] applies after reopening the app.
class TvPlaybackPrefs {
  static const _compatKey = 'tv_compat_decode';
  static const _matchKey = 'tv_match_frame_rate';
  static bool _compat = false;
  static bool _match = false;

  static bool get available => Platform.isAndroid && isTvDevice;
  static bool get compat => _compat;
  static bool get matchFrameRate => available && _match;
  static bool get zeroCopy => available && !_compat;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _compat = p.getBool(_compatKey) ?? false;
    _match = p.getBool(_matchKey) ?? false;
  }

  static Future<void> setCompat(bool v) async {
    _compat = v;
    await (await SharedPreferences.getInstance()).setBool(_compatKey, v);
  }

  static Future<void> setMatchFrameRate(bool v) async {
    _match = v;
    await (await SharedPreferences.getInstance()).setBool(_matchKey, v);
  }

  /// Refresh rate of the display the app draws on (Hz), 0 when unknown.
  static double displayRefreshRate() {
    try {
      final d = WidgetsBinding.instance.platformDispatcher.displays;
      return d.isEmpty ? 0 : d.first.refreshRate;
    } catch (_) {
      return 0;
    }
  }

  static const _channel = MethodChannel('torboxstrm/intent');

  /// Asks Android for a display mode whose refresh rate fits [fps] (0 = back to the
  /// default mode). Returns the refresh rate in use afterwards, or null when nothing changed.
  static Future<double?> requestFrameRate(double fps) async {
    if (!Platform.isAndroid) return null;
    try {
      final r = await _channel.invokeMethod<double>('frameRate', {'fps': fps});
      return r;
    } catch (e) {
      appLog('frame rate: $e');
      return null;
    }
  }
}
