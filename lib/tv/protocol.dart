import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'tv_input.dart';

/// "Play on TV" over the local network, phone → TV, no cloud relay.
///
/// The TV runs a small HTTP server ([TvReceiver]) and shows a QR code that
/// points at it (`http://<tv-ip>:<port>/pair?c=<code>`). Opening that page on
/// the phone hands `torboxstrm://pair?h=..&p=..&c=..` to the app, which trades
/// the short-lived code for a long random token. From then on the phone sends:
///
/// - `POST /play`  the web page's own `play` bridge message (+ server origin);
///   the TV validates it exactly like the phone would and plays it natively,
///   straight from the server (`/s/` and `/x/` links work without cookies);
/// - `POST /page`  the page's answers (subtitle lists, subtitle text, search);
/// - `POST /cmd`   remote control (play/pause, seek, tracks, next, stop…);
/// - `GET  /poll`  long poll: what the TV's player asks of the page (progress,
///   subtitle requests) plus the player state for the phone's remote screen.
///
/// So the phone's logged-in web page stays the only thing that talks to the
/// server's API; the TV needs no login of its own.
const tvPort = 47800;

/// LAN discovery: the phone broadcasts [discoverPing] to this UDP port; TVs
/// running the app answer with their name and HTTP port. Pairing still needs
/// the code shown on the TV.
const tvDiscoveryPort = 47801;
const discoverPing = 'TORBOXSTRM-DISCOVER-1';
const tvProtocol = 1;

/// Pairing codes are short-lived and single use.
const pairCodeLifetime = Duration(minutes: 5);

String randomToken([int bytes = 24]) {
  final r = Random.secure();
  return base64Url.encode(List<int>.generate(bytes, (_) => r.nextInt(256))).replaceAll('=', '');
}

String randomCode() => (Random.secure().nextInt(900000) + 100000).toString();

/// A pairing link from the TV's QR page: `torboxstrm://pair?h=192.168.1.20&p=47800&c=123456&n=Living room`.
class PairLink {
  const PairLink({required this.host, required this.port, required this.code, this.name = ''});
  final String host;
  final int port;
  final String code;
  final String name;

  static PairLink? parse(String raw) {
    final u = Uri.tryParse(raw.trim());
    if (u == null || u.scheme != 'torboxstrm' || u.host != 'pair') return null;
    final q = u.queryParameters;
    final host = q['h'] ?? '';
    final port = int.tryParse(q['p'] ?? '') ?? tvPort;
    final code = q['c'] ?? '';
    if (!isLanHost(host) || !RegExp(r'^\d{6}$').hasMatch(code) || port <= 0 || port > 65535) return null;
    return PairLink(host: host, port: port, code: code, name: (q['n'] ?? '').trim());
  }

  Uri toUri() =>
      Uri(scheme: 'torboxstrm', host: 'pair', queryParameters: {'h': host, 'p': '$port', 'c': code, 'n': name});
}

/// Only private IPv4 addresses: the TV is reached on the local network, never
/// through a name a web page could steer elsewhere.
bool isLanHost(String host) {
  final parts = host.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((p) => p == null || p < 0 || p > 255)) return false;
  final a = parts[0]!, b = parts[1]!;
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}

/// The TV this phone is paired with.
class PairedTv {
  const PairedTv({required this.host, required this.port, required this.token, required this.name});
  final String host;
  final int port;
  final String token;
  final String name;

  Uri url(String path, [Map<String, String>? query]) =>
      Uri(scheme: 'http', host: host, port: port, path: path, queryParameters: query);

  Map<String, Object?> toJson() => {'host': host, 'port': port, 'token': token, 'name': name};

  static PairedTv? fromJson(Object? j) {
    if (j is! Map) return null;
    final host = j['host'], port = j['port'], token = j['token'], name = j['name'];
    if (host is! String || port is! int || token is! String || !isLanHost(host)) return null;
    return PairedTv(host: host, port: port, token: token, name: name is String ? name : 'TV');
  }

  static const _key = 'paired_tv';

  static Future<PairedTv?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return null;
    try {
      return fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(PairedTv? tv) async {
    final prefs = await SharedPreferences.getInstance();
    if (tv == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, jsonEncode(tv.toJson()));
    }
  }
}

/// One audio/subtitle choice shown on the phone's remote.
class TvTrack {
  const TvTrack(this.id, this.label);
  final String id;
  final String label;

  Map<String, Object?> toJson() => {'id': id, 'label': label};

  static List<TvTrack> list(Object? raw) => [
    if (raw is List)
      for (final t in raw)
        if (t is Map && t['id'] is String) TvTrack(t['id'] as String, (t['label'] as String?) ?? t['id'] as String),
  ];
}

/// What the TV is doing, for the phone's remote screen.
class TvState {
  const TvState({
    this.active = false,
    this.title = '',
    this.subtitle = '',
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.index = 0,
    this.count = 0,
    this.audio = const [],
    this.subtitles = const [],
    this.serverSubtitles = const [],
    this.audioId = '',
    this.subtitleId = '',
    this.serverSubtitleId,
    this.volume = 100,
    this.error,
    this.input,
  });

  /// The text field focused on the TV, if any (phone shows a keyboard for it).
  final TvField? input;

  final bool active;
  final String title;
  final String subtitle;
  final Duration position;
  final Duration duration;
  final bool playing;
  final bool buffering;
  final int index;
  final int count;
  final List<TvTrack> audio;
  final List<TvTrack> subtitles;
  final List<TvTrack> serverSubtitles;
  final String audioId;
  final String subtitleId;
  final String? serverSubtitleId;
  final double volume;
  final String? error;

  Map<String, Object?> toJson() => {
    'active': active,
    'title': title,
    'subtitle': subtitle,
    'pos': position.inMilliseconds,
    'dur': duration.inMilliseconds,
    'playing': playing,
    'buffering': buffering,
    'index': index,
    'count': count,
    'audio': [for (final t in audio) t.toJson()],
    'subs': [for (final t in subtitles) t.toJson()],
    'serverSubs': [for (final t in serverSubtitles) t.toJson()],
    'aid': audioId,
    'sid': subtitleId,
    'serverSid': serverSubtitleId,
    'volume': volume,
    'error': error,
    'input': input?.toJson(),
  };

  static TvState fromJson(Object? j) {
    if (j is! Map) return const TvState();
    int ms(Object? v) => v is num ? v.toInt() : 0;
    String str(Object? v) => v is String ? v : '';
    return TvState(
      active: j['active'] == true,
      title: str(j['title']),
      subtitle: str(j['subtitle']),
      position: Duration(milliseconds: ms(j['pos'])),
      duration: Duration(milliseconds: ms(j['dur'])),
      playing: j['playing'] == true,
      buffering: j['buffering'] == true,
      index: ms(j['index']),
      count: ms(j['count']),
      audio: TvTrack.list(j['audio']),
      subtitles: TvTrack.list(j['subs']),
      serverSubtitles: TvTrack.list(j['serverSubs']),
      audioId: str(j['aid']),
      subtitleId: str(j['sid']),
      serverSubtitleId: j['serverSid'] is String ? j['serverSid'] as String : null,
      volume: j['volume'] is num ? (j['volume'] as num).toDouble() : 100,
      error: j['error'] is String ? j['error'] as String : null,
      input: TvField.fromJson(j['input']),
    );
  }
}
