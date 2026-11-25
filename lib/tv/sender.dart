import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../util/log.dart';
import 'protocol.dart';

class TvError implements Exception {
  const TvError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A TV that answered the LAN discovery broadcast.
class FoundTv {
  const FoundTv(this.host, this.port, this.name);
  final String host;
  final int port;
  final String name;
}

/// Broadcasts on the LAN and collects the TVs that answer within [wait].
Future<List<FoundTv>> discoverTvs({Duration wait = const Duration(milliseconds: 1500)}) async {
  final found = <String, FoundTv>{};
  RawDatagramSocket? udp;
  try {
    udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    udp.broadcastEnabled = true;
    final sock = udp;
    sock.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = sock.receive();
      if (d == null || !isLanHost(d.address.address)) return;
      try {
        final j = jsonDecode(utf8.decode(d.data));
        if (j is Map && j['app'] == 'torbox-strm' && j['port'] is int) {
          final name = j['name'] is String ? j['name'] as String : 'TV';
          found[d.address.address] = FoundTv(d.address.address, j['port'] as int, name);
        }
      } catch (_) {}
    });
    final ping = utf8.encode(discoverPing);
    for (var i = 0; i < 3; i++) {
      sock.send(ping, InternetAddress('255.255.255.255'), tvDiscoveryPort);
      await Future<void>.delayed(Duration(milliseconds: wait.inMilliseconds ~/ 3));
    }
  } catch (e) {
    appLog('tv discovery failed: $e');
  } finally {
    udp?.close();
  }
  return found.values.toList();
}

/// Phone → TV requests (local network, see protocol.dart).
class TvClient {
  TvClient(this.tv);
  final PairedTv tv;
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 4);

  static String get deviceName => Platform.isAndroid ? 'Điện thoại Android' : Platform.localHostname;

  static Future<Object?> _send(
    HttpClient http,
    String method,
    Uri url, {
    Object? body,
    String? token,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      final req = await http.openUrl(method, url).timeout(timeout);
      if (token != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join().timeout(timeout);
      final data = text.isEmpty ? null : jsonDecode(text);
      if (res.statusCode == HttpStatus.unauthorized) {
        throw const TvError('TV không còn nhận điện thoại này — kết nối lại bằng mã QR trên TV.');
      }
      if (res.statusCode != HttpStatus.ok) {
        final msg = data is Map && data['error'] is String ? data['error'] as String : 'TV trả lỗi ${res.statusCode}';
        throw TvError(msg);
      }
      return data;
    } on TvError {
      rethrow;
    } on TimeoutException {
      throw const TvError('TV không phản hồi. TV và điện thoại phải cùng mạng Wi-Fi, app trên TV phải đang mở.');
    } on SocketException {
      throw const TvError('Không kết nối được TV. TV và điện thoại phải cùng mạng Wi-Fi, app trên TV phải đang mở.');
    } on FormatException {
      throw const TvError('TV trả dữ liệu không hợp lệ');
    }
  }

  /// Trades the code shown on the TV for a lasting token.
  static Future<PairedTv> pair(PairLink link) async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final url = Uri(scheme: 'http', host: link.host, port: link.port, path: '/pair');
      final data = await _send(http, 'POST', url, body: {'code': link.code, 'device': deviceName});
      if (data is! Map || data['token'] is! String) throw const TvError('TV trả dữ liệu không hợp lệ');
      final name = data['name'] is String && (data['name'] as String).isNotEmpty ? data['name'] as String : link.name;
      return PairedTv(
        host: link.host,
        port: link.port,
        token: data['token'] as String,
        name: name.isEmpty ? 'TV' : name,
      );
    } finally {
      http.close(force: true);
    }
  }

  Future<Object?> _call(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout}) =>
      _send(
        _http,
        method,
        tv.url(path, query),
        body: body,
        token: tv.token,
        timeout: timeout ?? const Duration(seconds: 8),
      );

  Future<void> play(Uri server, Object raw) =>
      _call('POST', '/play', body: {'server': server.origin, 'msg': raw, 'device': deviceName});

  Future<void> page(Object raw) => _call('POST', '/page', body: {'msg': raw});

  /// Gives the TV this phone's server (as a server code) so it can browse and log in.
  Future<void> setServer(String code) => _call('POST', '/server', body: {'code': code});

  Future<TvState?> command(String action, [Map<String, Object?> extra = const {}]) async {
    final data = await _call('POST', '/cmd', body: {'action': action, ...extra});
    if (data is Map && data['ok'] != true && data['error'] is String) throw TvError(data['error'] as String);
    return data is Map ? TvState.fromJson(data['state']) : null;
  }

  Future<({int seq, List<Map<String, Object?>> events, TvState state})> poll(int after) async {
    final data = await _call('GET', '/poll', query: {'after': '$after'}, timeout: const Duration(seconds: 6));
    if (data is! Map) throw const TvError('TV trả dữ liệu không hợp lệ');
    final events = <Map<String, Object?>>[
      if (data['events'] is List)
        for (final e in data['events'] as List)
          if (e is Map && e['event'] is Map) Map<String, Object?>.from(e['event'] as Map),
    ];
    return (
      seq: data['seq'] is int ? data['seq'] as int : after,
      events: events,
      state: TvState.fromJson(data['state']),
    );
  }

  void close() => _http.close(force: true);
}

/// A playback running on the TV: relays what the TV's player asks of the web
/// page (progress, subtitles) to the page on this phone, and keeps the
/// remote screen's state fresh.
class TvSession {
  TvSession({required this.client, required this.toPage});

  final TvClient client;
  final Future<void> Function(Map<String, Object?> event) toPage;

  final ValueNotifier<TvState> state = ValueNotifier(const TvState(active: true));
  final ValueNotifier<String?> problem = ValueNotifier(null);

  bool _running = false;
  bool get running => _running;
  int _seq = 0;
  bool _seenActive = false;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    var failures = 0;
    DateTime? idleSince;
    while (_running) {
      try {
        final r = await client.poll(_seq);
        failures = 0;
        problem.value = null;
        _seq = r.seq;
        for (final e in r.events) {
          await toPage(e);
        }
        state.value = r.state;
        if (r.state.active) {
          _seenActive = true;
          idleSince = null;
        } else if (_seenActive) {
          // player closed on the TV: keep relaying a moment for the final progress
          idleSince ??= DateTime.now();
          if (DateTime.now().difference(idleSince) > const Duration(seconds: 4)) break;
        }
      } on TvError catch (e) {
        failures++;
        if (failures >= 3) problem.value = e.message;
        await Future<void>.delayed(Duration(seconds: failures.clamp(1, 5)));
      } catch (e) {
        appLog('tv poll: $e');
        failures++;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (failures > 30) break; // ~2 minutes without the TV
    }
    _running = false;
    state.value = const TvState();
  }

  void stop() => _running = false;
}
