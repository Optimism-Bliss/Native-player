import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'log.dart';

/// `torboxstrm://…` links handed to the app by Android / iOS (QR codes): `pair`
/// (phone ↔ TV) and `connect` (server code). Read once at start-up, then
/// delivered as they arrive; screens take the ones they handle.
class AppLinks {
  static const _channel = MethodChannel('torboxstrm/intent');
  static final StreamController<String> _incoming = StreamController.broadcast();
  static final List<String> _pending = [];

  static Stream<String> get stream => _incoming.stream;

  static Future<void> init() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
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

/// Code in `torboxstrm://device?c=ABCD-EFGH`: the login QR a TV shows when
/// its page runs in the app (the QR holds no server address; the phone uses
/// its own).
String? deviceLoginCode(String raw) {
  final u = Uri.tryParse(raw.trim());
  if (u == null || u.scheme != 'torboxstrm' || u.host != 'device') return null;
  final c = (u.queryParameters['c'] ?? '').toUpperCase();
  return RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}$').hasMatch(c) ? c : null;
}

/// A QR code read by the in-app scanner, as the `torboxstrm://` link the app
/// handles: pairing / server / TV-login links as they are, a TV login page
/// (`https://…/device?c=CODE`) and a bare server code (`TBS1-…`) too. null
/// when it is not one of ours.
String? appLinkFromScan(String raw) {
  final t = raw.trim();
  final u = Uri.tryParse(t);
  if (u != null && u.scheme == 'torboxstrm') return t;
  // the TV start screen's QR: http://<TV LAN address>:<port>/pair?c=<6 digits>
  if (u != null &&
      u.scheme == 'http' &&
      u.path == '/pair' &&
      RegExp(r'^\d{6}$').hasMatch(u.queryParameters['c'] ?? '')) {
    return Uri(
      scheme: 'torboxstrm',
      host: 'pair',
      queryParameters: {'h': u.host, 'p': '${u.hasPort ? u.port : 47800}', 'c': u.queryParameters['c']!, 'n': 'TV'},
    ).toString();
  }
  if (u != null && (u.scheme == 'https' || u.scheme == 'http') && u.path == '/device') {
    final c = deviceLoginCode('torboxstrm://device?c=${u.queryParameters['c'] ?? ''}');
    if (c != null) return 'torboxstrm://device?c=$c';
  }
  if (RegExp(r'^TBS1-[0-9A-Z-]+$', caseSensitive: false).hasMatch(t)) {
    return Uri(scheme: 'torboxstrm', host: 'connect', queryParameters: {'c': t.toUpperCase()}).toString();
  }
  return null;
}
