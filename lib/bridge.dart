// Contract between the TorBox STRM web UI and this app.
//
// The page calls `window.webviewAll.callHandler('torboxStrm', message)`; the
// handler is registered with an origin policy so only the configured server's
// main frame can reach it. Everything that arrives here is still validated:
// the app only opens the server's stable playback links (`/s/<key>.<ext>` for
// library files, `/x/<key>.<ext>` for addon sources), never arbitrary URLs.
//
// Messages back to the page go through `window.TorBoxStrmBridge.event(...)`.

const bridgeHandlerName = 'torboxStrm';
const bridgeVersion = 1;

// Library keys are 32 hex chars; addon sources use `x:<key>`.
final _keyPattern = RegExp(r'^[A-Za-z0-9_:.-]{8,160}$');

bool isValidKey(Object? key) => key is String && _keyPattern.hasMatch(key);
final _playPathPattern = RegExp(r'^/(s|x)/[A-Za-z0-9_-]{8,128}(\.[A-Za-z0-9]{1,8})?$');

class SubtitleRef {
  const SubtitleRef({required this.url, required this.label, this.language});
  final Uri url;
  final String label;
  final String? language;
}

class QueueItem {
  const QueueItem({required this.key, required this.url, required this.title, this.subtitle});
  final String key;
  final Uri url;
  final String title;
  final SubtitleRef? subtitle;
}

class PlayRequest {
  const PlayRequest({required this.queue, required this.index, required this.start, this.logo});
  final List<QueueItem> queue;
  final int index;
  final Duration start;

  /// Title logo (TMDB image) shown in the player's top bar.
  final Uri? logo;

  /// Parses and validates a `play` message. Throws [FormatException] with a
  /// user-facing (Vietnamese) reason when the message must be rejected.
  static PlayRequest parse(Object? raw, Uri server) {
    if (raw is! Map) throw const FormatException('Lệnh phát không hợp lệ');
    if (raw['type'] != 'play') throw const FormatException('Lệnh không được hỗ trợ');
    if (raw['v'] != bridgeVersion) {
      throw const FormatException('Phiên bản web và app không khớp, hãy cập nhật app');
    }
    final queueRaw = raw['queue'];
    if (queueRaw is! List || queueRaw.isEmpty || queueRaw.length > 2000) {
      throw const FormatException('Danh sách phát trống');
    }
    final queue = [for (final item in queueRaw) _item(item, server)];
    final index = raw['index'];
    if (index is! int || index < 0 || index >= queue.length) {
      throw const FormatException('Vị trí trong danh sách phát không hợp lệ');
    }
    final start = raw['start'];
    final seconds = start is num && start.isFinite && start > 0 ? start.toDouble() : 0.0;
    final logo = _httpUrl(raw['logo'], server);
    return PlayRequest(
      queue: queue,
      index: index,
      start: Duration(milliseconds: (seconds * 1000).round()),
      logo: logo != null && logo.scheme == 'https' ? logo : null,
    );
  }

  static QueueItem _item(Object? raw, Uri server) {
    if (raw is! Map) throw const FormatException('Mục phát không hợp lệ');
    final key = raw['key'];
    if (key is! String || !isValidKey(key)) {
      throw const FormatException('Khoá file không hợp lệ');
    }
    final url = _httpUrl(raw['url'], server);
    if (url == null || !_playPathPattern.hasMatch(url.path) || url.hasQuery || url.hasFragment) {
      throw const FormatException('Link phát không thuộc TorBox STRM');
    }
    final title = raw['title'];
    SubtitleRef? subtitle;
    final sub = raw['subtitle'];
    if (sub is Map) {
      final subUrl = _httpUrl(sub['url'], server);
      if (subUrl != null) {
        final label = sub['label'];
        final lang = sub['lang'];
        subtitle = SubtitleRef(
          url: subUrl,
          label: label is String && label.isNotEmpty ? _clip(label, 80) : 'Phụ đề',
          language: lang is String && lang.isNotEmpty ? _clip(lang, 16) : null,
        );
      }
    }
    return QueueItem(
      key: key,
      url: url,
      title: title is String && title.trim().isNotEmpty ? _clip(title.trim(), 200) : 'TorBox STRM',
      subtitle: subtitle,
    );
  }

  /// http(s) only, no embedded credentials, and no downgrade to plain HTTP
  /// when the server itself is served over HTTPS.
  static Uri? _httpUrl(Object? raw, Uri server) {
    if (raw is! String || raw.length > 4096) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
    if (uri.scheme == 'https') return uri;
    if (uri.scheme == 'http' && server.scheme == 'http') return uri;
    return null;
  }

  static String _clip(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';
}

/// One subtitle the server offers for a file (`/api/subs`: uploads, addon
/// subtitles such as AIOStreams, a previously chosen online subtitle).
class ServerSubtitle {
  const ServerSubtitle({
    required this.id,
    required this.label,
    this.language,
    this.source,
    this.exactMatch = false,
    this.downloads,
    this.blocked = false,
  });
  final String id;
  final String label;
  final String? language;
  final String? source;

  /// Online search only: matches this exact release (moviehash), download
  /// count, and whether the provider is out of quota right now.
  final bool exactMatch;
  final int? downloads;
  final bool blocked;

  static ServerSubtitle? parse(Object? e) {
    if (e is! Map) return null;
    final id = e['id'];
    if (id is! String || id.isEmpty || id.length > 300) return null;
    final label = e['label'];
    final lang = e['lang'];
    final src = e['src'];
    final downloads = e['downloads'];
    return ServerSubtitle(
      id: id,
      label: label is String && label.isNotEmpty ? _clip(label, 90) : id,
      language: lang is String && lang.isNotEmpty ? _clip(lang, 16) : null,
      source: src is String && src.isNotEmpty ? _clip(src, 32) : null,
      exactMatch: e['match'] == true,
      downloads: downloads is num ? downloads.toInt() : null,
      blocked: e['blocked'] == true,
    );
  }
}

/// `{type:'subSearch', v:1, key, results, note, langs}`: online search results.
class SubtitleSearch {
  const SubtitleSearch({required this.key, required this.results, this.note = '', this.languages = ''});
  final String key;
  final List<ServerSubtitle> results;
  final String note;
  final String languages;

  static SubtitleSearch parse(Map raw) {
    final key = raw['key'];
    if (!isValidKey(key)) throw const FormatException('Khoá file không hợp lệ');
    final results = raw['results'];
    final note = raw['note'];
    final langs = raw['langs'];
    return SubtitleSearch(
      key: key as String,
      results: [if (results is List) ...results.take(150).map(ServerSubtitle.parse).nonNulls],
      note: note is String ? _clip(note, 300) : '',
      languages: langs is String ? _clip(langs, 60) : '',
    );
  }
}

/// `{type:'subs', v:1, key, list:[{id,lang,label,src}], auto}` from the page.
class SubtitleList {
  const SubtitleList({required this.key, required this.list, this.autoId, this.preferId, this.languages = const []});

  /// Subtitle languages configured on the server (search defaults), e.g. vi, en.
  final List<String> languages;
  final String key;
  final List<ServerSubtitle> list;

  /// What the web player would turn on (saved choice or upload).
  final String? autoId;

  /// Addon subtitle in the preferred language, used when the file has no
  /// embedded subtitle in that language.
  final String? preferId;

  ServerSubtitle? byId(String? id) => id == null ? null : list.where((s) => s.id == id).firstOrNull;

  static SubtitleList parse(Map raw) {
    final key = raw['key'];
    if (!isValidKey(key)) throw const FormatException('Khoá file không hợp lệ');
    final rawList = raw['list'];
    final list = [if (rawList is List) ...rawList.take(200).map(ServerSubtitle.parse).nonNulls];
    final langs = raw['langs'];
    final auto = raw['auto'];
    final prefer = raw['prefer'];
    return SubtitleList(
      key: key as String,
      list: list,
      autoId: auto is String && auto.isNotEmpty ? auto : null,
      preferId: prefer is String && prefer.isNotEmpty ? prefer : null,
      languages: [
        if (langs is List)
          for (final l in langs.take(20))
            if (l is String && l.isNotEmpty && l.length <= 8) l,
      ],
    );
  }
}

/// `{type:'subText', v:1, key, id, lang, label, format, text}`: subtitle
/// content fetched by the page with its own session (`/api/subs/get`).
class SubtitleText {
  const SubtitleText({required this.key, required this.id, required this.label, required this.text, this.language});
  final String key;
  final String id;
  final String label;
  final String text;
  final String? language;

  static const _formats = {'srt', 'ass', 'ssa', 'vtt', 'webvtt', 'sub'};

  static SubtitleText parse(Map raw) {
    final key = raw['key'];
    final id = raw['id'];
    final text = raw['text'];
    final format = raw['format'];
    if (!isValidKey(key)) throw const FormatException('Khoá file không hợp lệ');
    if (id is! String || id.isEmpty) throw const FormatException('Phụ đề không hợp lệ');
    if (text is! String || text.isEmpty || text.length > 8 * 1024 * 1024) {
      throw const FormatException('Phụ đề rỗng hoặc quá lớn');
    }
    if (format is String && format.isNotEmpty && !_formats.contains(format.toLowerCase())) {
      throw const FormatException('Định dạng phụ đề không hỗ trợ');
    }
    final label = raw['label'];
    final lang = raw['lang'];
    return SubtitleText(
      key: key as String,
      id: id,
      label: label is String && label.isNotEmpty ? _clip(label, 80) : 'Phụ đề',
      text: text,
      language: lang is String && lang.isNotEmpty ? _clip(lang, 16) : null,
    );
  }
}

String _clip(String s, int max) => s.length <= max ? s : '${s.substring(0, max)}…';

/// One other version / source of the file being played (`{type:'alts'}` from the page).
class AltOption {
  const AltOption({required this.label, this.url, this.token, this.cached = true, this.library = false});
  final String label;

  /// Library version: played directly (`/s/<key>`).
  final Uri? url;

  /// Addon stream: the page turns it into a link (`/api/sources/select`).
  final String? token;
  final bool cached;
  final bool library;

  static AltOption? parse(Object? raw, {required bool library}) {
    if (raw is! Map) return null;
    final label = raw['label'];
    if (label is! String || label.isEmpty) return null;
    final url = raw['url'] is String ? Uri.tryParse(raw['url'] as String) : null;
    final token = raw['token'] is String ? raw['token'] as String : null;
    if (library && (url == null || !(url.isScheme('http') || url.isScheme('https')))) return null;
    if (!library && (token == null || token.isEmpty || token.length > 4000)) return null;
    return AltOption(label: _clip(label, 200), url: url, token: token, cached: raw['cached'] != false, library: library);
  }
}

/// `{type:'alts', v:1, key, library:[{label,url}], streams:[{label,token,cached}], message}`.
class Alternatives {
  const Alternatives({required this.key, this.library = const [], this.streams = const [], this.message = ''});
  final String key;
  final List<AltOption> library;
  final List<AltOption> streams;
  final String message;

  static Alternatives parse(Map raw) {
    final key = raw['key'];
    if (!isValidKey(key)) throw const FormatException('Khoá file không hợp lệ');
    List<AltOption> list(Object? v, bool lib) =>
        [if (v is List) ...v.take(40).map((x) => AltOption.parse(x, library: lib)).nonNulls];
    final m = raw['message'];
    return Alternatives(
      key: key as String,
      library: list(raw['library'], true),
      streams: list(raw['streams'], false),
      message: m is String ? _clip(m, 300) : '',
    );
  }
}

/// `{type:'altUrl', v:1, key, url, label, error}`: the link for an addon stream the player picked.
class AltUrl {
  const AltUrl({required this.key, this.url, this.label = '', this.error = ''});
  final String key;
  final Uri? url;
  final String label;
  final String error;

  static AltUrl parse(Map raw) {
    final key = raw['key'];
    if (!isValidKey(key)) throw const FormatException('Khoá file không hợp lệ');
    final u = raw['url'] is String ? Uri.tryParse(raw['url'] as String) : null;
    final ok = u != null && (u.isScheme('http') || u.isScheme('https'));
    return AltUrl(
      key: key as String,
      url: ok ? u : null,
      label: raw['label'] is String ? _clip(raw['label'] as String, 200) : '',
      error: raw['error'] is String ? _clip(raw['error'] as String, 300) : (ok ? '' : 'Không nhận được link'),
    );
  }
}
