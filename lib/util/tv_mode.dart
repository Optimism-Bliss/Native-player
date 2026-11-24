import 'dart:io';

import 'package:flutter/services.dart';

/// True on Android TV / Google TV / TV boxes (set once at start-up): the app
/// is then a "Play on TV" receiver and the player is driven with a D-pad.
bool isTvDevice = false;

Future<void> detectTv() async {
  // developer aid: run the desktop build as a TV receiver
  if (Platform.environment['TORBOXSTRM_TV'] == '1') {
    isTvDevice = true;
    return;
  }
  if (!Platform.isAndroid) return;
  try {
    isTvDevice = await const MethodChannel('torboxstrm/intent').invokeMethod<bool>('isTv') ?? false;
  } catch (_) {
    isTvDevice = false;
  }
}
