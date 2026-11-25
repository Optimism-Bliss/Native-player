import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// True when this device acts as a TV: a "Play on TV" receiver whose player
/// is driven with a D-pad. Chosen by the user on first start (see
/// role_screen.dart); until then [looksLikeTv] is only the suggestion.
bool isTvDevice = false;

/// What Android says about this device (UI mode television / leanback).
bool looksLikeTv = false;

/// No role saved yet: show the "phone or TV?" question first (Android only).
bool roleUnset = false;

const _roleKey = 'device_role';

Future<void> detectTv() async {
  // developer aid: run the desktop build as a TV receiver
  if (Platform.environment['TORBOXSTRM_TV'] == '1') {
    isTvDevice = true;
    return;
  }
  // developer aid: show the role question on desktop
  if (Platform.environment['TORBOXSTRM_ASK_ROLE'] == '1') {
    final role = (await SharedPreferences.getInstance()).getString(_roleKey);
    roleUnset = role == null;
    isTvDevice = role == 'tv';
    return;
  }
  if (!Platform.isAndroid) return;
  try {
    looksLikeTv = await const MethodChannel('torboxstrm/intent').invokeMethod<bool>('isTv') ?? false;
  } catch (_) {
    looksLikeTv = false;
  }
  final role = (await SharedPreferences.getInstance()).getString(_roleKey);
  roleUnset = role == null;
  isTvDevice = role == null ? looksLikeTv : role == 'tv';
}

/// The display this app draws on, in real pixels, as `{w:…,h:…}` for the web page:
/// it prefers versions that fit the screen (a TV box on a 1080p monitor reports
/// 1920×1080 and gets 1080p instead of a 4K remux). Empty when unknown.
String screenJs() {
  try {
    final displays = WidgetsBinding.instance.platformDispatcher.displays;
    if (displays.isEmpty) return 'null';
    final s = displays.first.size;
    if (s.width <= 0 || s.height <= 0) return 'null';
    return '{w:${s.width.round()},h:${s.height.round()}}';
  } catch (_) {
    return 'null';
  }
}

Future<void> saveRole({required bool tv}) async {
  await (await SharedPreferences.getInstance()).setString(_roleKey, tv ? 'tv' : 'mobile');
  isTvDevice = tv;
  roleUnset = false;
}
