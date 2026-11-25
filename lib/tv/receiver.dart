import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bridge.dart';
import '../connect_code.dart';
import '../player/player_screen.dart';
import '../player/widgets/track_sheets.dart';
import '../util/log.dart';
import 'protocol.dart';
import 'tv_input.dart';

/// Opens the player on the TV for a request from a paired phone.
typedef OpenPlayer = Future<void> Function(PlayRequest request);

/// The TV side of "Play on TV": a small HTTP server on the local network.
/// See protocol.dart for the message flow.
class TvReceiver {
  TvReceiver({required this.openPlayer, required this.name, this.onServer, this.onHome});

  final OpenPlayer openPlayer;

  /// A paired phone told the TV which server it uses (as a server code, so
  /// the TV keeps the address hidden too).
  final Future<void> Function(Uri server, String code)? onServer;
  final String name;

  /// The phone remote's Home key: back to the TV start screen.
  final VoidCallback? onHome;

  /// The open player (set by PlayerScreen), driven by remote commands.
  final PlayerRemote remote = PlayerRemote();

  /// Page answers from the phone, for the player's PageLink.
  final StreamController<Object> pageIn = StreamController.broadcast();

  final ValueNotifier<String> code = ValueNotifier(randomCode());
  final ValueNotifier<String?> address = ValueNotifier(null);

  /// Name of the phone that paired or sent something last.
  final ValueNotifier<String?> lastPhone = ValueNotifier(null);

  HttpServer? _server;
  Timer? _rotate;
  int _failures = 0;
  List<String> _tokens = [];
  Uri? _origin;
  bool _active = false;

  final List<({int seq, Map<String, Object?> event})> _outbox = [];
  int _seq = 0;
  Completer<void>? _wake;

  static const _tokensKey = 'tv_tokens';

  Future<void> start() async {
    final prefs = await SharedPreferences.getInstance();
    _tokens = prefs.getStringList(_tokensKey) ?? [];
    for (var port = tvPort; port < tvPort + 10 && _server == null; port++) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: false);
      } catch (_) {}
    }
    final server = _server;
    if (server == null) {
      appLog('tv: no free port');
      return;
    }
    server.listen(_handle, onError: (Object e) => appLog('tv server: $e'));
    await _startDiscovery();
    _rotate = Timer.periodic(pairCodeLifetime, (_) => newCode());
    await refreshAddress();
    appLog('tv receiver on ${address.value}');
  }

  int get port => _server?.port ?? tvPort;

  /// The TV's LAN address, for the QR code.
  Future<void> refreshAddress() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      String? pick;
      for (final i in interfaces) {
        for (final a in i.addresses) {
          if (!isLanHost(a.address)) continue;
          // wired / Wi-Fi first, virtual interfaces last
          final preferred = RegExp(r'^(eth|wlan|en|wl)').hasMatch(i.name);
          if (pick == null || preferred) pick = a.address;
        }
      }
      address.value = pick;
    } catch (e) {
      appLog('tv address: $e');
    }
  }

  void newCode() {
    code.value = randomCode();
    _failures = 0;
  }

  PairLink? get pairLink {
    final host = address.value;
    if (host == null) return null;
    return PairLink(host: host, port: port, code: code.value, name: name);
  }

  /// What the QR code holds: a plain http link to this TV, which any camera
  /// app opens; that page hands the pairing link to the phone app.
  Uri? get qrUrl {
    final host = address.value;
    if (host == null) return null;
    return Uri(scheme: 'http', host: host, port: port, path: '/pair', queryParameters: {'c': code.value});
  }

  RawDatagramSocket? _udp;

  /// Answers discovery broadcasts from phones on the LAN (name + port only).
  Future<void> _startDiscovery() async {
    try {
      final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, tvDiscoveryPort, reuseAddress: true);
      _udp = udp;
      udp.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = udp.receive();
        if (d == null || !isLanHost(d.address.address) && d.address.address != '127.0.0.1') return;
        if (utf8.decode(d.data, allowMalformed: true).trim() != discoverPing) return;
        final reply = utf8.encode(jsonEncode({'app': 'torbox-strm', 'v': tvProtocol, 'name': name, 'port': port}));
        udp.send(reply, d.address, d.port);
      });
    } catch (e) {
      appLog('tv discovery unavailable: $e');
    }
  }

  Future<void> stop() async {
    _udp?.close();
    _udp = null;
    _rotate?.cancel();
    await _server?.close(force: true);
    _server = null;
  }

  // ---------------- player side ----------------

  /// Something the TV's player sends to the page (progress, subtitle requests…).
  Future<void> toPage(Map<String, Object?> event) async {
    _outbox.add((seq: ++_seq, event: event));
    if (_outbox.length > 500) _outbox.removeRange(0, _outbox.length - 500);
    _wakePollers();
  }

  void playerClosed() {
    _active = false;
    _wakePollers();
  }

  void _wakePollers() {
    final w = _wake;
    _wake = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  TvState state() {
    final c = remote.controller;
    if (c == null || !c.initialized) return TvState(active: _active, input: TvInput.field.value);
    final p = c.player.state;
    final embedded = [
      for (final t in p.tracks.subtitle)
        if (t.id != 'auto' && t.id != 'no' && !c.isServerTrack(t.id)) TvTrack(t.id, subtitleTrackLabel(t)),
    ];
    return TvState(
      active: true,
      title: c.current.title,
      position: p.position,
      duration: p.duration,
      playing: p.playing,
      buffering: p.buffering,
      index: c.index.value,
      count: c.request.queue.length,
      audio: [
        for (final t in p.tracks.audio)
          if (t.id != 'auto' && t.id != 'no') TvTrack(t.id, audioTrackLabel(t)),
      ],
      subtitles: embedded,
      serverSubtitles: [for (final s in c.serverSubtitles.value) TvTrack(s.id, serverSubtitleLabel(s))],
      audioId: p.track.audio.id,
      subtitleId: c.serverSubtitleId.value != null ? '' : p.track.subtitle.id,
      serverSubtitleId: c.serverSubtitleId.value,
      volume: p.volume,
      error: c.error.value,
      input: TvInput.field.value,
    );
  }

  // ---------------- HTTP ----------------

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      // LAN only, whatever the router forwards
      final from = req.connectionInfo?.remoteAddress.address ?? '';
      if (!isLanHost(from) && from != '127.0.0.1') {
        res.statusCode = HttpStatus.forbidden;
        return;
      }
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/pair') return await _pairPage(req);
      if (req.method == 'GET' && path == '/info') {
        return await _json(res, {'app': 'torbox-strm', 'v': tvProtocol, 'name': name});
      }
      if (req.method == 'POST' && path == '/pair') return await _pair(req);
      if (!_authorized(req)) {
        res.statusCode = HttpStatus.unauthorized;
        return await _json(res, {'error': 'Chưa ghép đôi với TV này'});
      }
      switch ((req.method, path)) {
        case ('POST', '/play'):
          return await _play(req);
        case ('POST', '/input'):
          final body = await _body(req);
          final action = body['action'] is String ? body['action'] as String : 'set';
          final text = body['text'] is String ? body['text'] as String : '';
          final sink = TvInput.sink;
          if (sink == null || text.length > 2000 || !const {'set', 'enter'}.contains(action)) {
            return await _json(res, {'ok': false, 'error': 'Trên TV chưa chọn ô nhập nào'});
          }
          final ok = await sink(action, text);
          return await _json(res, {'ok': ok, 'error': ok ? null : 'Ô nhập trên TV không còn được chọn'});
        case ('POST', '/server'):
          final body = await _body(req);
          final code = body['code'];
          final server = code is String ? decodeServerCode(code) : null;
          if (server == null) throw const FormatException('Mã máy chủ không hợp lệ');
          await onServer?.call(server, encodeServerCode(server));
          return await _json(res, {'ok': true});
        case ('POST', '/page'):
          final body = await _body(req);
          final msg = body['msg'];
          if (msg is Map) {
            final parsed = switch (msg['type']) {
              'subs' => SubtitleList.parse(msg),
              'subText' => SubtitleText.parse(msg),
              'subSearch' => SubtitleSearch.parse(msg),
              _ => null,
            };
            if (parsed != null) pageIn.add(parsed);
          }
          return await _json(res, {'ok': true});
        case ('POST', '/cmd'):
          final body = await _body(req);
          final error = await _command(body);
          return await _json(res, {'ok': error == null, 'error': error, 'state': state().toJson()});
        case ('GET', '/poll'):
          return await _poll(req);
        // the paired phone reads the TV's log (TVs have no easy way to share a file)
        case ('GET', '/log'):
          return await _json(res, {'log': readLogTail(400)});
      }
      res.statusCode = HttpStatus.notFound;
    } on FormatException catch (e) {
      res.statusCode = HttpStatus.badRequest;
      await _json(res, {'error': e.message});
    } catch (e, st) {
      appLog('tv request failed: $e\n$st');
      res.statusCode = HttpStatus.internalServerError;
    } finally {
      await res.close().catchError((_) {});
    }
  }

  bool _authorized(HttpRequest req) {
    final h = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    return h.startsWith('Bearer ') && _tokens.contains(h.substring(7));
  }

  Future<Map<String, Object?>> _body(HttpRequest req) async {
    final bytes = await req.fold<List<int>>(<int>[], (a, b) {
      if (a.length + b.length > 2 * 1024 * 1024) throw const FormatException('Dữ liệu quá lớn');
      return a..addAll(b);
    });
    final v = jsonDecode(utf8.decode(bytes));
    if (v is! Map<String, Object?>) throw const FormatException('Dữ liệu không hợp lệ');
    return v;
  }

  Future<void> _json(HttpResponse res, Object body) async {
    res.headers.contentType = ContentType.json;
    res.headers.set('Cache-Control', 'no-store');
    res.write(jsonEncode(body));
  }

  /// The page a phone's camera opens from the QR code.
  Future<void> _pairPage(HttpRequest req) async {
    final res = req.response;
    final link = pairLink;
    final c = req.uri.queryParameters['c'] ?? '';
    res.headers.contentType = ContentType.html;
    res.headers.set('Cache-Control', 'no-store');
    if (link == null || c != code.value) {
      res.write(_page('Mã đã hết hạn', '<p>Mã trên TV đã đổi. Quét lại mã QR đang hiện trên TV.</p>'));
      return;
    }
    final app = link.toUri().toString();
    final intent =
        'intent://pair?${link.toUri().query}#Intent;scheme=torboxstrm;package=io.github.optimismbliss.torboxstrm;'
        'S.browser_fallback_url=${Uri.encodeComponent('https://github.com/Optimism-Bliss/Native-player/releases')};end';
    res.write(
      _page(
        'Kết nối với ${_esc(name)}',
        '<p>Bấm nút dưới để mở app TorBox STRM trên điện thoại và kết nối với TV.</p>'
            '<p><a class="b" href="${_esc(intent)}">Mở app và kết nối</a></p>'
            '<p class="s">Không mở được? Trong app chọn menu → <b>Kết nối TV</b> rồi nhập '
            '<b>${_esc(link.host)}:${link.port}</b> và mã <b>${_esc(link.code)}</b>.</p>'
            '<p class="s"><a href="${_esc(app)}">Liên kết dự phòng</a></p>',
      ),
    );
  }

  static String _esc(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

  static String _page(String title, String body) =>
      '<!doctype html><html lang="vi"><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1"><title>$title</title>'
      '<style>body{font-family:system-ui,sans-serif;background:#0b0d12;color:#e8e8ee;margin:0;padding:32px 20px;line-height:1.5}'
      'h1{font-size:22px}a{color:#9ab8ff}.b{display:inline-block;background:#3d5afe;color:#fff;padding:14px 22px;'
      'border-radius:12px;text-decoration:none;font-weight:600}.s{color:#9a9aa8;font-size:14px}</style></head>'
      '<body><h1>$title</h1>$body</body></html>';

  Future<void> _pair(HttpRequest req) async {
    final body = await _body(req);
    final given = body['code'];
    if (given is! String || given != code.value) {
      if (++_failures >= 5) newCode();
      req.response.statusCode = HttpStatus.forbidden;
      return _json(req.response, {'error': 'Mã không đúng hoặc đã hết hạn'});
    }
    newCode(); // single use
    final token = randomToken();
    _tokens = [..._tokens, token];
    if (_tokens.length > 8) _tokens = _tokens.sublist(_tokens.length - 8);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_tokensKey, _tokens);
    final device = body['device'];
    lastPhone.value = device is String && device.isNotEmpty ? device : 'Điện thoại';
    appLog('tv: paired with ${lastPhone.value}');
    return _json(req.response, {'token': token, 'name': name});
  }

  Future<void> _play(HttpRequest req) async {
    final body = await _body(req);
    final server = body['server'];
    final origin = server is String ? Uri.tryParse(server) : null;
    if (origin == null || (origin.scheme != 'https' && origin.scheme != 'http') || origin.host.isEmpty) {
      throw const FormatException('Thiếu địa chỉ máy chủ');
    }
    // Same checks as a play message from the web page in the app itself.
    final request = PlayRequest.parse(body['msg'], origin);
    _origin = origin;
    _active = true;
    final device = body['device'];
    if (device is String && device.isNotEmpty) lastPhone.value = device;
    appLog('tv: play ${request.queue[request.index].title}');
    unawaited(openPlayer(request));
    return _json(req.response, {'ok': true});
  }

  Uri? get origin => _origin;

  /// Long poll: page events after `after`, then the player state. Returns at
  /// once when events are waiting, else after at most one second.
  Future<void> _poll(HttpRequest req) async {
    final after = int.tryParse(req.uri.queryParameters['after'] ?? '') ?? 0;
    // the phone restarted its counter (new session): send nothing old
    final since = after > _seq ? _seq : after;
    if (!_outbox.any((e) => e.seq > since)) {
      final w = _wake ??= Completer<void>();
      await w.future.timeout(const Duration(seconds: 1), onTimeout: () {});
    }
    final events = [
      for (final e in _outbox)
        if (e.seq > since) {'seq': e.seq, 'event': e.event},
    ];
    return _json(req.response, {'seq': _seq, 'events': events, 'state': state().toJson()});
  }

  Future<String?> _command(Map<String, Object?> body) async {
    final c = remote.controller;
    final action = body['action'];
    // phone as the TV's remote: works on every screen, playing or not
    if (action == 'key') {
      final key = body['key'];
      if (key == 'home') {
        onHome?.call();
        return null;
      }
      if (!Platform.isAndroid || key is! String) return 'TV không nhận phím này';
      final ok = await const MethodChannel('torboxstrm/intent').invokeMethod<bool>('key', {'key': key}) ?? false;
      return ok ? null : 'TV không nhận phím này';
    }
    if (action == 'stop') {
      await remote.close?.call();
      return null;
    }
    if (c == null || !c.initialized) return 'TV chưa phát gì';
    final p = c.player;
    num? n(String k) => body[k] is num ? body[k] as num : null;
    String? s(String k) => body[k] is String ? body[k] as String : null;
    switch (action) {
      case 'toggle':
        await p.playOrPause();
      case 'play':
        await p.play();
      case 'pause':
        await p.pause();
      case 'seek':
        final to = n('to');
        if (to == null) return 'Thiếu vị trí';
        await p.seek(Duration(milliseconds: (to * 1000).round()));
        c.reportProgress(force: true);
      case 'seekBy':
        await c.seekRelative(Duration(milliseconds: ((n('by') ?? 0) * 1000).round()));
      case 'next':
        if (c.hasNext) await c.next();
      case 'prev':
        if (c.hasPrevious) await c.previous();
      case 'volume':
        await p.setVolume((n('value') ?? 100).toDouble().clamp(0, 100));
      case 'audio':
        final t = p.state.tracks.audio.where((t) => t.id == s('id')).firstOrNull;
        if (t == null) return 'Không có rãnh âm thanh này';
        await p.setAudioTrack(t);
      case 'sub':
        final t = p.state.tracks.subtitle.where((t) => t.id == s('id')).firstOrNull;
        if (t == null) return 'Không có phụ đề này';
        await p.setSubtitleTrack(t);
        await c.clearServerSubtitle(off: false);
        if (!t.uri) await p.seek(p.state.position);
      case 'serverSub':
        final sub = c.serverSubtitles.value.where((x) => x.id == s('id')).firstOrNull;
        if (sub == null) return 'Không có phụ đề này';
        await c.selectServerSubtitle(sub);
      case 'subOff':
        await p.setSubtitleTrack(SubtitleTrack.no());
        await c.clearServerSubtitle(off: true);
      default:
        return 'Lệnh không hỗ trợ';
    }
    return null;
  }
}
