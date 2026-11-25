import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../bridge.dart';
import '../tv/protocol.dart';
import '../tv/tv_input.dart';
import '../util/format.dart';
import '../util/log.dart';
import 'playback_controller.dart';
import 'tv_playback_prefs.dart';
import 'widgets/track_sheets.dart';

/// Android TV player in its own activity (Media3 ExoPlayer, see NativePlayerActivity.kt),
/// the way Fladder plays on TVs. The picture goes straight from the hardware decoder to the
/// screen, which weak boxes (Mi Box S) handle far better than libmpv drawing with the GPU.
///
/// This side keeps what the Flutter player does around the picture: progress to the phone's
/// page, the server's subtitle list and subtitle text (written to the cache dir and handed to
/// the player), and the phone remote's commands and state.
class NativeTvPlayer {
  NativeTvPlayer({required this.request, required this.onProgress, this.page});

  final PlayRequest request;
  final ProgressCallback onProgress;
  final PageLink? page;

  static const _channel = MethodChannel('torboxstrm/native_player');
  static NativeTvPlayer? _active;
  static bool _handlerSet = false;

  final Completer<void> _closed = Completer<void>();
  Map<Object?, Object?> _state = const {};
  late int _index = request.index;
  List<ServerSubtitle> _serverSubtitles = const [];
  String? _serverSubtitleId;
  StreamSubscription<Object>? _pageSub;
  Timer? _progressTimer;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;

  QueueItem get _current => request.queue[_index.clamp(0, request.queue.length - 1)];

  /// Opens the player and completes when it closes.
  Future<void> run() async {
    if (!_handlerSet) {
      _handlerSet = true;
      _channel.setMethodCallHandler((call) async => _active?._onCall(call));
    }
    _active = this;
    _position = request.start;
    _pageSub = page?.incoming.listen(_onPage);
    _progressTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_playing) _report();
    });
    try {
      final ok = await _channel.invokeMethod<bool>('open', {
        'queue': [
          for (final q in request.queue)
            {
              'key': q.key,
              'url': q.url.toString(),
              'title': q.title,
              'subUrl': q.subtitle?.url.toString(),
              'subLabel': q.subtitle?.label,
              'subLang': q.subtitle?.language,
            },
        ],
        'index': request.index,
        'startMs': request.start.inMilliseconds,
        'matchFrameRate': TvPlaybackPrefs.matchFrameRate,
        'tunneling': TvPlaybackPrefs.tunneling,
      });
      if (ok != true) throw StateError('native player did not open');
      _askSubtitles();
      await _closed.future;
    } finally {
      _progressTimer?.cancel();
      await _pageSub?.cancel();
      if (identical(_active, this)) _active = null;
    }
  }

  /// Stops playback (phone's stop, a new title replacing this one).
  Future<void> close() async {
    if (_closed.isCompleted) return;
    await _command({'action': 'stop'});
    await _closed.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () {
        if (!_closed.isCompleted) _closed.complete();
      },
    );
  }

  Future<String?> _command(Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<String>('command', args);
    } on PlatformException catch (e) {
      return e.message ?? 'Lỗi trình phát';
    }
  }

  Future<void> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'state':
        final s = call.arguments;
        if (s is! Map) return;
        _state = s;
        final pos = Duration(milliseconds: (s['position'] as num?)?.toInt() ?? 0);
        final dur = Duration(milliseconds: (s['duration'] as num?)?.toInt() ?? 0);
        final playing = s['playing'] == true;
        _position = pos;
        if (dur > Duration.zero) _duration = dur;
        if (_playing && !playing) _report();
        _playing = playing;
      case 'item':
        final a = call.arguments;
        if (a is! Map) return;
        final i = (a['index'] as num?)?.toInt() ?? _index;
        if (i == _index) return;
        _report(force: true);
        _index = i;
        _position = Duration.zero;
        _duration = Duration.zero;
        _serverSubtitles = const [];
        _serverSubtitleId = null;
        appLog('native player: next "${_current.title}"');
        _askSubtitles();
      case 'log':
        appLog('${call.arguments}');
      case 'closed':
        final a = call.arguments;
        if (a is Map) {
          _position = Duration(milliseconds: (a['position'] as num?)?.toInt() ?? 0);
          final d = (a['duration'] as num?)?.toInt() ?? 0;
          if (d > 0) _duration = Duration(milliseconds: d);
        }
        _report(force: true);
        if (!_closed.isCompleted) _closed.complete();
    }
  }

  void _report({bool force = false}) {
    if (_position < const Duration(seconds: 5) && !force) return;
    if (_position <= Duration.zero) return;
    onProgress(_current.key, _position, _duration);
  }

  // ---------------- server subtitles (through the phone's page) ----------------

  void _askSubtitles() {
    final link = page;
    if (link != null) unawaited(link.send({'type': 'subs', 'key': _current.key}));
  }

  void _onPage(Object message) {
    if (message is SubtitleList) {
      if (message.key != _current.key) return;
      _serverSubtitles = message.list;
      final prefer = message.byId(message.preferId);
      if (message.autoId == null && prefer != null) unawaited(_maybeUsePreferred(prefer));
    } else if (message is SubtitleText) {
      if (message.key != _current.key) return;
      unawaited(_loadServerSubtitle(message));
    }
  }

  /// The suggested addon subtitle, unless the player already picked an embedded one in that language.
  Future<void> _maybeUsePreferred(ServerSubtitle prefer) async {
    final key = _current.key;
    // let the file open and the player choose its own tracks first
    for (var i = 0; i < 45 && ((_state['duration'] as num?) ?? 0) <= 0; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    await Future<void>.delayed(const Duration(seconds: 1));
    if (_closed.isCompleted || key != _current.key || _serverSubtitleId != null) return;
    final chosen = _subs.where((t) => t['selected'] == true).firstOrNull;
    final want = languageName(prefer.language);
    if (chosen != null && want.isNotEmpty && (chosen['label'] as String? ?? '').contains(want)) return;
    await selectServerSubtitle(prefer);
  }

  Future<void> selectServerSubtitle(ServerSubtitle sub) async {
    await page?.send({
      'type': 'subGet',
      'key': _current.key,
      'id': sub.id,
      'lang': sub.language ?? '',
      'label': sub.label,
    });
  }

  Future<void> _loadServerSubtitle(SubtitleText sub) async {
    final text = sub.text;
    final (ext, mime) = text.contains('[Script Info]')
        ? ('ass', 'text/x-ssa')
        : text.trimLeft().startsWith('WEBVTT')
        ? ('vtt', 'text/vtt')
        : ('srt', 'application/x-subrip');
    final dir = Directory('${(await getTemporaryDirectory()).path}/native_subs');
    await dir.create(recursive: true);
    final safe = sub.id.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final file = File('${dir.path}/${safe.length > 80 ? safe.substring(0, 80) : safe}.$ext');
    await file.writeAsString(text);
    final err = await _command({
      'action': 'addSub',
      'path': file.path,
      'id': sub.id,
      'label': sub.label,
      'lang': sub.language,
      'mime': mime,
    });
    if (err != null) {
      appLog('native player: subtitle "${sub.label}": $err');
      return;
    }
    appLog('subs: "${sub.label}" loaded ($ext)');
    _serverSubtitleId = sub.id;
  }

  // ---------------- phone remote ----------------

  List<Map<Object?, Object?>> _list(String name) => [
    for (final t in (_state[name] as List?) ?? const [])
      if (t is Map) t,
  ];
  List<Map<Object?, Object?>> get _subs => _list('subs');

  TvState tvState() {
    final audio = _list('audio');
    final subs = _subs;
    final selectedSub = subs.where((t) => t['selected'] == true).firstOrNull;
    final subsOff = _state['subsOff'] == true || selectedSub == null;
    return TvState(
      active: true,
      title: _current.title,
      position: _position,
      duration: _duration,
      playing: _state['playing'] == true,
      buffering: _state['buffering'] == true,
      index: _index,
      count: request.queue.length,
      audio: [for (final t in audio) TvTrack('${t['id']}', '${t['label']}')],
      subtitles: [
        for (final t in subs)
          if (t['server'] != true) TvTrack('${t['id']}', '${t['label']}'),
      ],
      serverSubtitles: [for (final s in _serverSubtitles) TvTrack(s.id, serverSubtitleLabel(s))],
      audioId: '${audio.where((t) => t['selected'] == true).firstOrNull?['id'] ?? ''}',
      subtitleId: _serverSubtitleId != null && !subsOff
          ? ''
          : subsOff
          ? 'no'
          : '${selectedSub['id']}',
      serverSubtitleId: subsOff ? null : _serverSubtitleId,
      volume: (_state['volume'] as num?)?.toDouble() ?? 100,
      error: _state['error'] as String?,
      input: TvInput.field.value,
    );
  }

  /// A command from the phone remote; null when done, or the reason it failed.
  Future<String?> command(Map<String, Object?> body) async {
    num? n(String k) => body[k] is num ? body[k] as num : null;
    switch (body['action']) {
      case 'toggle' || 'play' || 'pause' || 'next' || 'prev':
        return _command({'action': body['action']});
      case 'seek':
        final to = n('to');
        if (to == null) return 'Thiếu vị trí';
        final err = await _command({'action': 'seek', 'ms': (to * 1000).round()});
        _position = Duration(milliseconds: (to * 1000).round());
        _report(force: true);
        return err;
      case 'seekBy':
        return _command({'action': 'seekBy', 'ms': ((n('by') ?? 0) * 1000).round()});
      case 'volume':
        return _command({'action': 'volume', 'value': (n('value') ?? 100).clamp(0, 100)});
      case 'audio':
        return _command({'action': 'audio', 'id': body['id']});
      case 'sub':
        final err = await _command({'action': 'sub', 'id': body['id']});
        if (err == null) _serverSubtitleId = null;
        return err;
      case 'serverSub':
        final sub = _serverSubtitles.where((x) => x.id == body['id']).firstOrNull;
        if (sub == null) return 'Không có phụ đề này';
        await selectServerSubtitle(sub);
        return null;
      case 'subOff':
        _serverSubtitleId = null;
        await page?.send({'type': 'subOff', 'key': _current.key});
        return _command({'action': 'subOff'});
      default:
        return 'Lệnh không hỗ trợ';
    }
  }
}
