import 'dart:async';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// The one TorBox STRM server this app talks to. Credentials are never stored
/// here: login happens in the web UI, which keeps its own session cookie.
class ServerStore {
  static const _key = 'server_url';
  static const _codeKey = 'server_code';

  /// Set when the server was added with a server code: its address is then
  /// never shown (labels, errors, log) — see connect_code.dart.
  static String? code;
  static String? _hiddenHost;

  static bool get hidden => code != null;

  /// What the UI shows for the server: its host, or a neutral name.
  static String label(Uri server) => hidden ? 'Máy chủ riêng' : server.host;

  /// Replaces the hidden server's host in text meant for people (log, errors).
  static String redact(String text) {
    final h = _hiddenHost;
    return h == null || h.isEmpty ? text : text.replaceAll(h, '[máy chủ]');
  }

  static Future<Uri?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    final server = raw == null ? null : normalize(raw);
    code = server == null ? null : prefs.getString(_codeKey);
    _hiddenHost = code == null ? null : server?.host;
    return server;
  }

  /// [viaCode]: the server code the user entered (keeps the address hidden).
  static Future<void> save(Uri server, {String? viaCode}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, server.toString());
    if (viaCode == null) {
      await prefs.remove(_codeKey);
    } else {
      await prefs.setString(_codeKey, viaCode);
    }
    code = viaCode;
    _hiddenHost = viaCode == null ? null : server.host;
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  /// Accepts `media.example`, `https://media.example/`, `http://10.0.0.2:8080`.
  /// Returns scheme + host + port + base path, without query or fragment.
  static Uri? normalize(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    var path = uri.path;
    if (!path.endsWith('/')) path = '$path/';
    return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: path);
  }
}

enum ProbeResult { ok, notTorboxStrm, unreachable, certificate }

/// Checks that the address answers like a TorBox STRM server (`GET /health` → `ok`).
Future<ProbeResult> probeServer(Uri server) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(server.resolve('health')).timeout(const Duration(seconds: 10));
    final res = await req.close().timeout(const Duration(seconds: 10));
    final body = await res.transform(const SystemEncoding().decoder).join().timeout(const Duration(seconds: 5));
    return res.statusCode == 200 && body.trim() == 'ok' ? ProbeResult.ok : ProbeResult.notTorboxStrm;
  } on HandshakeException {
    return ProbeResult.certificate;
  } on TlsException {
    return ProbeResult.certificate;
  } catch (_) {
    return ProbeResult.unreachable;
  } finally {
    client.close(force: true);
  }
}
