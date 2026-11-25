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
/// [compat] switches libmpv's hwdec in place (PlayerHost.applyDecodeMode), from the next film.
class TvPlaybackPrefs {
  static const _compatKey = 'tv_compat_decode';
  static const _matchKey = 'tv_match_frame_rate';
  static const _nativeKey = 'tv_native_player';
  static const _tunnelKey = 'tv_tunneling';
  static bool _compat = false;
  static bool _match = false;
  static bool _native = true;
  static bool _tunnel = false;

  /// Media3 player (NativePlayerActivity) instead of libmpv; on by default on TVs.
  static bool get nativePlayer => available && _native;

  /// Tunneled playback (Media3 only): video and audio synced by the TV chip. Smoother on some
  /// boxes, broken on others, so off by default.
  static bool get tunneling => _tunnel;

  static bool get available => Platform.isAndroid && isTvDevice;
  static bool get compat => _compat;
  static bool get matchFrameRate => available && _match;
  static bool get zeroCopy => available && !_compat;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _compat = p.getBool(_compatKey) ?? false;
    _match = p.getBool(_matchKey) ?? false;
    _native = p.getBool(_nativeKey) ?? true;
    _tunnel = p.getBool(_tunnelKey) ?? false;
  }

  static Future<void> setNativePlayer(bool v) async {
    _native = v;
    await (await SharedPreferences.getInstance()).setBool(_nativeKey, v);
  }

  static Future<void> setTunneling(bool v) async {
    _tunnel = v;
    await (await SharedPreferences.getInstance()).setBool(_tunnelKey, v);
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
