import 'dart:io';

import 'package:flutter/services.dart';
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

Future<void> saveRole({required bool tv}) async {
  await (await SharedPreferences.getInstance()).setString(_roleKey, tv ? 'tv' : 'mobile');
  isTvDevice = tv;
  roleUnset = false;
}
