import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

/// Completes once main() has shown and focused the desktop window; hiding it
/// earlier is undone by that first show.
final Completer<void> appWindowShown = Completer<void>();

bool get isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Fullscreen for desktop windows; immersive landscape on Android.
class FullscreenHelper {
  static final ValueNotifier<bool> isFullscreen = ValueNotifier(false);

  /// Windows web window mode: the player is full screen over the web window,
  /// so Esc leaves the player instead of shrinking it to a small window.
  static bool escapeClosesPlayer = false;

  static Future<void> set(bool value) async {
    if (isDesktop) {
      await windowManager.setFullScreen(value);
    } else {
      await SystemChrome.setEnabledSystemUIMode(value ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
    }
    isFullscreen.value = value;
  }

  static Future<void> toggle() => set(!isFullscreen.value);

  /// Called when the player opens: phones go immersive + landscape.
  static Future<void> enterPlayer() async {
    if (isDesktop) return;
    await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    await set(true);
  }

  static Future<void> exitPlayer() async {
    if (isDesktop) {
      if (isFullscreen.value) await set(false);
      return;
    }
    await SystemChrome.setPreferredOrientations([]);
    await set(false);
  }
}
