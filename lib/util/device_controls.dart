import 'dart:io';

import 'package:flutter/services.dart';

/// Media volume and window brightness for the player's swipe gestures.
/// Android only (see MainActivity.kt); elsewhere the calls do nothing.
class DeviceControls {
  static const _channel = MethodChannel('torboxstrm/intent');

  static bool get supported => Platform.isAndroid;

  static Future<double> volume() async => await _channel.invokeMethod<double>('getVolume') ?? 0.5;

  static Future<void> setVolume(double value) => _channel.invokeMethod('setVolume', {'value': value});

  static Future<double> brightness() async => await _channel.invokeMethod<double>('getBrightness') ?? 0.5;

  /// null returns control to the system brightness setting.
  static Future<void> setBrightness(double? value) => _channel.invokeMethod('setBrightness', {'value': value});
}
