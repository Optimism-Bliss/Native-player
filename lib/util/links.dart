import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'log.dart';

/// `torboxstrm://…` links handed to the app by Android (QR codes): `pair`
/// (phone ↔ TV) and `connect` (server code). Read once at start-up, then
/// delivered as they arrive; screens take the ones they handle.
class AppLinks {
  static const _channel = MethodChannel('torboxstrm/intent');
  static final StreamController<String> _incoming = StreamController.broadcast();
  static final List<String> _pending = [];

  static Stream<String> get stream => _incoming.stream;

  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'link' && call.arguments is String) {
        final link = call.arguments as String;
        if (_incoming.hasListener) {
          _incoming.add(link);
        } else {
          _pending.add(link);
        }
      }
      return null;
    });
    try {
      final link = await _channel.invokeMethod<String>('initialLink');
      if (link != null) _pending.add(link);
    } catch (e) {
      appLog('initial link: $e');
    }
  }

  /// Removes and returns the waiting links that [accept] takes.
  static List<String> take(bool Function(String link) accept) {
    final mine = _pending.where(accept).toList();
    _pending.removeWhere(accept);
    return mine;
  }
}
