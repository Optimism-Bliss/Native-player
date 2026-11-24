import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../bridge.dart';
import '../util/format.dart';

typedef ProgressCallback = void Function(String key, Duration position, Duration duration);

/// Font libass falls back to on Android, where there is no system fontconfig
/// (same approach and font as Fladder). Covers Vietnamese and CJK.
const libassAndroidFont = 'assets/fonts/DroidSansFallback.ttf';
const libassAndroidFontName = 'Droid Sans Fallback';

/// The single libmpv instance of the app, created on first playback and kept
/// for the app's lifetime (Fladder does the same). Creating and destroying the
/// video output per session is what broke rendering on Linux: tearing down
/// mpv's EGL context races Flutter's raster thread. Between sessions the
/// player is only stopped.
class PlayerHost {
  PlayerHost._(this.player, this.video);

  final Player player;
  final VideoController video;

  /// Track ids mpv actually selected (`aid`/`sid`/`vid`). `player.state.track`
  /// only reports "auto" until the user picks a track, so the UI uses these.
  final ValueNotifier<ActiveTracks> active = ValueNotifier(const ActiveTracks());

  static Future<PlayerHost>? _instance;

  static Future<PlayerHost> get() => _instance ??= _create();

  static Future<PlayerHost> _create() async {
    MediaKit.ensureInitialized();
    final player = Player(
      configuration: const PlayerConfiguration(
        title: 'TorBox STRM',
        libass: true,
        libassAndroidFont: libassAndroidFont,
        libassAndroidFontName: libassAndroidFontName,
        bufferSize: 64 * 1024 * 1024,
        logLevel: MPVLogLevel.warn,
      ),
    );
    final video = VideoController(
      player,
      configuration: const VideoControllerConfiguration(enableHardwareAcceleration: true),
    );
    final host = PlayerHost._(player, video);
    final native = player.platform;
    if (native is NativePlayer) {
      // Same network/cache tuning Fladder uses for direct HTTP playback.
      await native.setProperty('force-seekable', 'yes');
      await native.setProperty('cache', 'yes');
      await native.setProperty('demuxer-max-bytes', '150M');
      await native.setProperty('demuxer-max-back-bytes', '50M');
      await native.setProperty('network-timeout', '60');
      await native.setProperty('stream-buffer-size', '4M');
      // Prefer Vietnamese, then English, for embedded tracks.
      await native.setProperty('slang', 'vi,vie,vn,en,eng');
      await native.setProperty('alang', 'vi,vie,vn,en,eng,ja,jpn');
      if (defaultTargetPlatform == TargetPlatform.android) {
        await native.setProperty('ao', 'audiotrack');
      }
      await native.observeProperty('aid', (v) async => host.active.value = host.active.value.copyWith(audio: v));
      await native.observeProperty('sid', (v) async => host.active.value = host.active.value.copyWith(subtitle: v));
      await native.observeProperty('vid', (v) async => host.active.value = host.active.value.copyWith(video: v));
    }
    return host;
  }
}

/// Player core for one playback session on the shared [PlayerHost].
///
/// It only knows URLs, positions and tracks. It does not know about WebView,
/// the TorBox library model or Jellyfin. The UI listens to [player] streams
/// and to the notifiers below.
/// Messages between the player and the page that opened it. The page does
/// every authenticated call (subtitle list and content, progress).
class PageLink {
  PageLink({required this.incoming, required this.send});

  /// [SubtitleList] and [SubtitleText] sent by the page.
  final Stream<Object> incoming;

  /// Sends an event to `window.TorBoxStrmBridge.event(...)`.
  final Future<void> Function(Map<String, Object?> event) send;
}

class PlaybackController {
  PlaybackController({required this.request, required this.onProgress, this.page});

  final PlayRequest request;
  final ProgressCallback onProgress;
  final PageLink? page;

  /// Subtitles the server offers for the current file (AIOStreams, uploads…).
  final ValueNotifier<List<ServerSubtitle>> serverSubtitles = ValueNotifier(const []);

  /// Id of the server subtitle currently shown, and the mpv track ids that
  /// server subtitles were loaded into (hidden from the embedded list).
  final ValueNotifier<String?> serverSubtitleId = ValueNotifier(null);
  final Set<String> _serverTitles = {};
  String? _serverTitle;

  /// Shown briefly by the UI ("Đã bật phụ đề …").
  final ValueNotifier<String?> notice = ValueNotifier(null);

  late final PlayerHost _host;
  Player get player => _host.player;
  VideoController get video => _host.video;
  ValueListenable<ActiveTracks> get active => _host.active;

  /// Index of the item currently playing in [request.queue].
  final ValueNotifier<int> index = ValueNotifier(0);

  /// User-facing error. Playback is stopped while this is non-null.
  final ValueNotifier<String?> error = ValueNotifier(null);

  /// True while the stable link is being reopened (expired CDN link, network change).
  final ValueNotifier<bool> recovering = ValueNotifier(false);

  final List<StreamSubscription<Object?>> _subs = [];
  Timer? _progressTimer;
  Timer? _stallTimer;
  Duration _lastPosition = Duration.zero;
  Duration _lastDuration = Duration.zero;
  int _retries = 0;
  int _openGeneration = 0;
  bool _disposed = false;
  bool _initialized = false;

  bool get initialized => _initialized;

  QueueItem get current => request.queue[index.value];
  bool get hasNext => index.value + 1 < request.queue.length;
  bool get hasPrevious => index.value > 0;

  Future<void> init() async {
    _host = await PlayerHost.get();
    final native = player.platform;
    if (native is NativePlayer) {
      // Per-file subtitle delay must not leak into the next session.
      await native.setProperty('sub-delay', '0');
    }
    // Controls are visible when the player opens.
    await raiseSubtitles(true);

    _subs
      ..add(player.stream.position.listen((p) => _lastPosition = p))
      ..add(
        player.stream.duration.listen((d) {
          if (d > Duration.zero) _lastDuration = d;
        }),
      )
      ..add(
        player.stream.playing.listen((playing) {
          if (!playing) reportProgress();
        }),
      )
      ..add(player.stream.buffering.listen(_onBuffering))
      ..add(player.stream.error.listen(_onError))
      ..add(
        player.stream.completed.listen((done) {
          if (done && error.value == null) _onCompleted();
        }),
      );
    final link = page;
    if (link != null) _subs.add(link.incoming.listen(_onPageMessage));
    _progressTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (player.state.playing) reportProgress();
    });

    index.value = request.index;
    _initialized = true;
    await _open(start: request.start);
  }

  Future<void> _open({Duration start = Duration.zero}) async {
    final generation = ++_openGeneration;
    final item = current;
    error.value = null;
    _lastPosition = start;
    _lastDuration = Duration.zero;
    // The server answers `/s/<key>` with a fresh 302 to the TorBox CDN, so
    // reopening this URL is also how an expired CDN link is renewed.
    // Opening (or reopening after an error) drops every external subtitle
    // track in mpv, so the server subtitle state starts over each time.
    serverSubtitles.value = const [];
    serverSubtitleId.value = null;
    _serverTitle = null;
    _serverTitles.clear();
    await player.open(Media(item.url.toString(), start: start > Duration.zero ? start : null));
    // Ask the page for this file's subtitles (list + the one to turn on, the
    // same choice the web player would make). It answers with subs/subText.
    final link = page;
    if (link != null) unawaited(link.send({'type': 'subs', 'key': item.key}));
    final sub = item.subtitle;
    if (sub == null) return;
    // External subtitles can only be added once the file is loaded.
    try {
      await player.stream.duration.firstWhere((d) => d > Duration.zero).timeout(const Duration(seconds: 45));
    } on TimeoutException {
      return;
    }
    if (_disposed || generation != _openGeneration) return;
    await player.setSubtitleTrack(SubtitleTrack.uri(sub.url.toString(), title: sub.label, language: sub.language));
  }

  void _onBuffering(bool buffering) {
    _stallTimer?.cancel();
    if (!buffering) {
      if (recovering.value) recovering.value = false;
      return;
    }
    // A CDN link that expires mid-stream usually shows up as an endless stall
    // rather than an error. Reopen the stable link at the same position.
    _stallTimer = Timer(const Duration(seconds: 30), () {
      if (player.state.buffering && error.value == null) _recover('stall');
    });
  }

  void _onError(String message) {
    debugPrint('mpv error: $message');
    final lower = message.toLowerCase();
    final fatal =
        lower.contains('failed to open') ||
        lower.contains('loading failed') ||
        lower.contains('http error') ||
        lower.contains('403') ||
        lower.contains('404') ||
        lower.contains('410') ||
        lower.contains('timed out') ||
        lower.contains('network');
    if (!fatal) return;
    if (_retries < 2) {
      _recover(message);
    } else {
      _fail(message);
    }
  }

  Future<void> _recover(String reason) async {
    if (_disposed) return;
    _retries++;
    recovering.value = true;
    debugPrint('reopening ${current.key} at $_lastPosition ($reason)');
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (_disposed) return;
    await _open(start: _lastPosition);
  }

  void _fail(String message) {
    recovering.value = false;
    final lower = message.toLowerCase();
    if (lower.contains('404')) {
      error.value = 'File không còn trên TorBox (404).';
    } else if (lower.contains('403') || lower.contains('410')) {
      error.value = 'Link phát đã hết hạn hoặc bị từ chối.';
    } else if (lower.contains('unrecognized file format') || lower.contains('no video or audio')) {
      error.value = 'Định dạng file này không phát được trên thiết bị.';
    } else if (lower.contains('failed to open') || lower.contains('network') || lower.contains('timed out')) {
      error.value = 'Không mở được link phát. Kiểm tra mạng hoặc thử lại sau ít phút.';
    } else {
      error.value = 'Không phát được: $message';
    }
  }

  Future<void> retry() async {
    _retries = 0;
    await _open(start: _lastPosition);
  }

  void _onCompleted() {
    reportProgress(force: true);
    if (hasNext) next();
  }

  Future<void> playAt(int i) async {
    if (i < 0 || i >= request.queue.length || i == index.value) return;
    reportProgress(force: true);
    _retries = 0;
    index.value = i;
    await _open();
  }

  Future<void> next() => playAt(index.value + 1);
  Future<void> previous() => playAt(index.value - 1);

  void _onPageMessage(Object message) {
    if (_disposed) return;
    if (message is SubtitleList) {
      if (message.key != current.key) return;
      serverSubtitles.value = message.list;
      final prefer = message.byId(message.preferId);
      if (message.autoId == null && prefer != null) _maybeUsePreferred(prefer);
    } else if (message is SubtitleText) {
      if (message.key != current.key) return;
      _loadServerSubtitle(message);
    }
  }

  /// Turns on the suggested addon subtitle unless mpv already picked an
  /// embedded subtitle in the same language (mpv's `slang` runs on load).
  Future<void> _maybeUsePreferred(ServerSubtitle prefer) async {
    final generation = _openGeneration;
    if (player.state.duration <= Duration.zero) {
      try {
        await player.stream.duration.firstWhere((d) => d > Duration.zero).timeout(const Duration(seconds: 45));
      } on TimeoutException {
        return;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (_disposed || generation != _openGeneration || serverSubtitleId.value != null) return;
    final embedded = _host.active.value.subtitleOf(player.state.tracks);
    final want = languageName(prefer.language);
    if (embedded != null && want.isNotEmpty && languageName(embedded.language) == want) return;
    await selectServerSubtitle(prefer);
  }

  Future<void> _loadServerSubtitle(SubtitleText sub) async {
    final generation = _openGeneration;
    // Subtitles can only be added once the file is loaded.
    if (player.state.duration <= Duration.zero) {
      try {
        await player.stream.duration.firstWhere((d) => d > Duration.zero).timeout(const Duration(seconds: 45));
      } on TimeoutException {
        return;
      }
    }
    if (_disposed || generation != _openGeneration) return;
    // Tracks loaded from the server are recognised by their title.
    _serverTitle = sub.label;
    _serverTitles.add(sub.label);
    await player.setSubtitleTrack(SubtitleTrack.data(sub.text, title: sub.label, language: sub.language));
    serverSubtitleId.value = sub.id;
    _say('Đã bật phụ đề: ${sub.label}');
  }

  Timer? _noticeTimer;

  /// Short message in the middle of the player (e.g. picture mode).
  void say(String message) => _say(message);

  void _say(String message) {
    if (_disposed) return;
    notice.value = message;
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(seconds: 3), () {
      if (!_disposed) notice.value = null;
    });
  }

  SubtitleTrack? _trackById(String id) => player.state.tracks.subtitle.where((t) => t.id == id).firstOrNull;

  /// Track id mpv uses for the server subtitle on screen, if any.
  String? get serverSubtitleTrackId {
    final title = _serverTitle;
    if (title == null) return null;
    return player.state.tracks.subtitle.where((t) => t.title == title).lastOrNull?.id;
  }

  bool isServerTrack(String id) => _serverTitles.contains(_trackById(id)?.title);

  /// Picks a server subtitle (the page fetches it and sends it back).
  Future<void> selectServerSubtitle(ServerSubtitle sub) async {
    final link = page;
    if (link == null) return;
    _say('Đang tải phụ đề…');
    await link.send({'type': 'subGet', 'key': current.key, 'id': sub.id, 'lang': sub.language ?? ''});
  }

  /// Embedded track chosen or subtitles turned off: forget the server one.
  Future<void> clearServerSubtitle({required bool off}) async {
    serverSubtitleId.value = null;
    if (off) await page?.send({'type': 'subOff', 'key': current.key});
  }

  /// Lifts subtitles above the control panel while it is visible (Fladder does
  /// the same with its subtitle position calculator). Styled ASS keeps its own
  /// positioning, as mpv only moves it with sub-ass-override.
  Future<void> raiseSubtitles(bool raised) async {
    if (_disposed) return;
    final native = player.platform;
    if (native is NativePlayer) await native.setProperty('sub-pos', raised ? '78' : '100');
  }

  Future<void> seekRelative(Duration delta) async {
    final duration = player.state.duration;
    var target = player.state.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    await player.seek(target);
  }

  /// Sends the position to the web page, which stores it via `/api/progress`.
  void reportProgress({bool force = false}) {
    final pos = _lastPosition;
    final dur = _lastDuration;
    if (pos < const Duration(seconds: 5) && !force) return;
    if (pos <= Duration.zero) return;
    onProgress(current.key, pos, dur);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    reportProgress(force: true);
    _disposed = true;
    _progressTimer?.cancel();
    _stallTimer?.cancel();
    _noticeTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    // Stop only: the libmpv instance is reused by the next session.
    await player.stop();
    await player.setSubtitleTrack(SubtitleTrack.auto());
    index.dispose();
    error.dispose();
    recovering.dispose();
    serverSubtitles.dispose();
    serverSubtitleId.dispose();
    notice.dispose();
  }
}

class ActiveTracks {
  const ActiveTracks({this.audio = 'no', this.subtitle = 'no', this.video = 'no'});
  final String audio;
  final String subtitle;
  final String video;

  ActiveTracks copyWith({String? audio, String? subtitle, String? video}) =>
      ActiveTracks(audio: audio ?? this.audio, subtitle: subtitle ?? this.subtitle, video: video ?? this.video);

  static bool _real(String id) => id != 'no' && id != 'auto' && id.isNotEmpty;

  AudioTrack? audioOf(Tracks t) => _real(audio) ? t.audio.where((x) => x.id == audio).firstOrNull : null;
  SubtitleTrack? subtitleOf(Tracks t) => _real(subtitle) ? t.subtitle.where((x) => x.id == subtitle).firstOrNull : null;
  VideoTrack? videoOf(Tracks t) => _real(video) ? t.video.where((x) => x.id == video).firstOrNull : null;
}
