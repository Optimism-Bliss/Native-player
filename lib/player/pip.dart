import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../util/tv_mode.dart';

/// Android phones and tablets: picture-in-picture while a film plays (Home / recent apps
/// shrink the video into a small window, like most video apps).
class Pip {
  static const _channel = MethodChannel('torboxstrm/pip');

  static bool get available => Platform.isAndroid && !isTvDevice;

  /// True while the app is shown as the small window.
  static final ValueNotifier<bool> active = ValueNotifier(false);

  /// Called when the user closes the small window (playback should stop).
  static VoidCallback? onDismissed;
  static bool _handler = false;

  static void _listen() {
    if (_handler) return;
    _handler = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'pip') return;
      final a = call.arguments;
      if (a is! Map) return;
      active.value = a['on'] == true;
      if (a['dismissed'] == true) onDismissed?.call();
    });
  }

  /// Playing: allow the small window, with the video's shape.
  static Future<void> arm(bool on, {int width = 16, int height = 9}) async {
    if (!available) return;
    _listen();
    try {
      await _channel.invokeMethod<bool>('arm', {'on': on, 'w': width, 'h': height});
    } catch (_) {}
  }

  static Future<bool> enter() async {
    if (!available) return false;
    _listen();
    try {
      return await _channel.invokeMethod<bool>('enter') ?? false;
    } catch (_) {
      return false;
    }
  }
}
