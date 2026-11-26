import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../bridge.dart';
import '../util/tv_mode.dart';
import 'media3_player.dart';
import 'subtitle_style.dart';
import 'player_settings.dart';
import 'subtitle_fonts.dart';
import 'tv_playback_prefs.dart';
import '../util/log.dart';
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

  /// Android TV with Media3: the picture is under the Flutter surface, there is no texture.
  bool get isMedia3 => player.platform is Media3Player;

  final Player player;
  final VideoController? video;

  /// Track ids mpv actually selected (`aid`/`sid`/`vid`). `player.state.track`
  /// only reports "auto" until the user picks a track, so the UI uses these.
  final ValueNotifier<ActiveTracks> active = ValueNotifier(const ActiveTracks());

  static Future<PlayerHost>? _instance;

  /// Media3 (TV setting): a fresh player per session, released when it ends. libmpv: one shared
  /// instance for the app's lifetime (see above).
  static Future<PlayerHost> get() {
    if (TvPlaybackPrefs.nativePlayer) return _createMedia3();
    return _instance ??= _create();
  }

  static Future<PlayerHost> _createMedia3() async {
    final platform = Media3Player(
      options: {
        'matchFrameRate': TvPlaybackPrefs.matchFrameRate,
        'tunneling': TvPlaybackPrefs.tunneling,
        'bufferMb': PlayerSettings.bufferMb,
        'audioLang': PlayerSettings.audioLang,
        'subLang': PlayerSettings.subLang,
      },
    );
    final player = Player(platformPlayer: platform);
    final host = PlayerHost._(player, null);
    player.stream.track.listen(
      (t) => host.active.value = ActiveTracks(audio: t.audio.id, subtitle: t.subtitle.id, video: t.video.id),
    );
    appLog('player: media3 (picture under the Flutter UI)');
    return host;
  }

  /// The shared player if one was created (quitting must not start libmpv).
  static Future<PlayerHost>? get existing => _instance;

  /// TV decoding mode changed in settings: switch libmpv's decoder in place (takes effect from
  /// the next file), so no app restart is needed.
  static Future<void> applyDecodeMode() async {
    final pending = _instance;
    if (pending == null) return; // not created yet: _create() reads the setting
    final native = (await pending).player.platform;
    if (native is! NativePlayer) return;
    final hwdec = TvPlaybackPrefs.zeroCopy ? 'mediacodec,mediacodec-copy' : 'mediacodec-copy';
    await native.setProperty('hwdec', hwdec);
    appLog('player: decoding -> $hwdec');
  }

  static Future<PlayerHost> _create() async {
    MediaKit.ensureInitialized();
    final fontsDir = await SubtitleFonts.prepare();
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
    final zeroCopy = TvPlaybackPrefs.zeroCopy;
    // media_kit already runs mpv with gpu-context=android / opengl-es; its default hwdec (auto-safe)
    // ends up as mediacodec-copy. Zero-copy asks for mediacodec first, as mpv-android does.
    final video = VideoController(
      player,
      configuration: zeroCopy
          ? const VideoControllerConfiguration(hwdec: 'mediacodec,mediacodec-copy')
          : const VideoControllerConfiguration(enableHardwareAcceleration: true),
    );
    appLog(
      'player: ${zeroCopy ? 'zero-copy decoding (mediacodec)' : 'gpu output'}'
      '${TvPlaybackPrefs.matchFrameRate ? ', frame-rate matching' : ''}',
    );
    final host = PlayerHost._(player, video);
    // libmpv's own warnings and errors (video output, decoder, network) into the app log: a black
    // picture with sound, or a stall, is explained there. Repeats are dropped, at most 300 lines a run.
    var mpvLines = 0;
    String? lastMpv;
    player.stream.log.listen((l) {
      final line = 'mpv ${l.level} ${l.prefix}: ${l.text.trim()}';
      if (line == lastMpv || mpvLines >= 300) return;
      lastMpv = line;
      mpvLines++;
      appLog(line);
    });
    final native = player.platform;
    if (native is NativePlayer && fontsDir != null) await native.setProperty('sub-fonts-dir', fontsDir);
    if (native is NativePlayer) {
      // mpv's disk cache ("Failed to create file cache" on Android and Windows): a folder the app may write to
      try {
        final cacheDir = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}mpv-cache');
        await cacheDir.create(recursive: true);
        await native.setProperty('cache-dir', cacheDir.path);
      } catch (e) {
        appLog('player: cache dir: $e');
      }
    }
    if (native is NativePlayer) {
      // Same network/cache tuning Fladder uses for direct HTTP playback.
      await native.setProperty('force-seekable', 'yes');
      await native.setProperty('cache', 'yes');
      // TV boxes have little RAM (onn 4K: 2 GB, shared with the web page): a smaller cache
      // still holds 30-60 s of 1080p and keeps Android from killing the app
      final mb = PlayerSettings.effectiveBufferMb;
      await native.setProperty('demuxer-max-bytes', '${mb}M');
      await native.setProperty('demuxer-max-back-bytes', '${(mb / 3).round().clamp(8, 160)}M');
      await native.setProperty('network-timeout', '60');
      await native.setProperty('stream-buffer-size', '4M');
      final hz = TvPlaybackPrefs.displayRefreshRate();
      if (hz > 0) await native.setProperty('display-fps-override', hz.toStringAsFixed(3));
      if (isTvDevice) {
        // TV boxes have weak GPUs (Mi Box S: Mali-450): mpv's light rendering, as its "fast" profile.
        // High-quality scalers, debanding and dithering cost GPU time and look the same on a TV.
        for (final (k, v) in const [
          ('scale', 'bilinear'),
          ('dscale', 'bilinear'),
          ('cscale', 'bilinear'),
          ('dither-depth', 'no'),
          ('deband', 'no'),
          ('correct-downscaling', 'no'),
          ('linear-downscaling', 'no'),
          ('sigmoid-upscaling', 'no'),
          ('hdr-compute-peak', 'no'),
        ]) {
          await native.setProperty(k, v);
        }
      }
      // When the cache runs dry, wait for a few seconds of data before playing on: one longer
      // wait instead of a stop every second on a link that is barely fast enough.
      await native.setProperty('cache-pause-wait', '3');
      await native.setProperty('demuxer-readahead-secs', '60');
      // Prefer Vietnamese, then English, for embedded tracks.
      await native.setProperty('slang', PlayerSettings.mpvLangs(PlayerSettings.subLang));
      await native.setProperty('alang', PlayerSettings.mpvLangs(PlayerSettings.audioLang, audio: true));
      if (defaultTargetPlatform == TargetPlatform.android) {
        await native.setProperty('ao', 'audiotrack');
        // DTS-HD Master Audio: decode only its DTS core. The lossless extension is decoded on the
        // CPU and is too heavy for TV boxes with small cores (onn 4K: 4x Cortex-A35), which made
        // picture and sound stutter although the video decoder kept up. Through TV / monitor
        // speakers the core sounds the same.
        await native.setProperty('ad-lavc-o', 'core_only=1');
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

  /// Online subtitle search (OpenSubtitles, SubDL…) for the current file.
  final ValueNotifier<SubtitleSearchState> search = ValueNotifier(const SubtitleSearchState());

  /// Subtitle languages configured on the server, used as search defaults.
  List<String> subtitleLanguages = const ['vi', 'en'];

  /// Shown briefly by the UI ("Đã bật phụ đề …").
  final ValueNotifier<String?> notice = ValueNotifier(null);

  late final PlayerHost _host;
  Player get player => _host.player;
  VideoController? get video => _host.video;
  bool get isMedia3 => _host.isMedia3;
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
      await native.setProperty('sub-visibility', 'yes');
      // settings may have changed since the shared player was created
      final mb = PlayerSettings.effectiveBufferMb;
      await native.setProperty('demuxer-max-bytes', '${mb}M');
      await native.setProperty('demuxer-max-back-bytes', '${(mb / 3).round().clamp(8, 160)}M');
      await native.setProperty('slang', PlayerSettings.mpvLangs(PlayerSettings.subLang));
      await native.setProperty('alang', PlayerSettings.mpvLangs(PlayerSettings.audioLang, audio: true));
    }
    // The shared player keeps its speed; every session starts at 1×.
    await player.setRate(1.0);
    if (native is NativePlayer) {}
    // Controls are visible when the player opens.
    await raiseSubtitles(true);
    await SubtitleStyle.current.apply(player);

    _subs
      ..add(player.stream.position.listen((p) => _lastPosition = p))
      ..add(
        player.stream.duration.listen((d) {
          if (d > Duration.zero) _lastDuration = d;
          if (d > Duration.zero && !_loadedLogged) {
            _loadedLogged = true;
            appLog('play: file opened after $_t');
            if (!_fileLoaded.isCompleted) _fileLoaded.complete(true);
            unawaited(_readChapters());
          }
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
    final reopenLocal = _localKey == item.key ? serverSubtitleId.value : null;
    if (_localKey != item.key) {
      _localKey = item.key;
      localSubtitles.value = const [];
      _localTexts.clear();
    }
    serverSubtitles.value = const [];
    serverSubtitleId.value = null;
    chapterCount.value = 0;
    if (search.value.key != item.key) search.value = const SubtitleSearchState();
    _serverTitle = null;
    _serverTitles.clear();
    // Ask the page for this file's subtitles (list + the one to turn on, the
    // same choice the web player would make) while mpv opens the file; it
    // answers with subs/subText, which wait for the file before loading.
    final link = page;
    if (link != null) unawaited(link.send({'type': 'subs', 'key': item.key}));
    _watch
      ..reset()
      ..start();
    _loadedLogged = _playingLogged = false;
    _waitSince = null;
    _waits = 0;
    if (!_fileLoaded.isCompleted) _fileLoaded.complete(false);
    _fileLoaded = Completer<bool>();
    appLog('play: open "${item.title}"${start > Duration.zero ? ' at ${start.inSeconds}s' : ''}');
    await player.open(Media(item.url.toString(), start: start > Duration.zero ? start : null));
    // Reopened after an error with a device subtitle on: load it again.
    final local = localSubtitles.value.where((l) => l.id == reopenLocal).firstOrNull;
    if (local != null) unawaited(selectLocalSubtitle(local));
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

  /// Time since the current file was opened, for the log (where does startup time go).
  final Stopwatch _watch = Stopwatch();
  bool _loadedLogged = false;

  /// Completes when the file opened by the latest [_open] is loaded (true), or
  /// false when another open replaced it. The shared player still reports the
  /// previous file's duration until then, so it cannot be used as the signal.
  Completer<bool> _fileLoaded = Completer<bool>();
  bool _playingLogged = false;
  String get _t => '${_watch.elapsedMilliseconds} ms';

  /// Start of the current wait for data during playback (not the initial load).
  DateTime? _waitSince;
  int _waits = 0;

  /// libmpv property (or the Media3 equivalent), '' when unknown. Used by the diagnostics overlay.
  Future<String> prop(String name) => _prop(name);

  Future<String> _prop(String name) async {
    final n = player.platform;
    if (n is Media3Player) return n.getProperty(name);
    if (n is! NativePlayer) return '';
    try {
      return await n.getProperty(name);
    } catch (_) {
      return '';
    }
  }

  /// Download speed now, the file's average bitrate and seconds buffered: tells a slow
  /// link (speed below bitrate, cache at 0) from a slow decoder.
  Future<String> _netStats() async {
    final speed = double.tryParse(await _prop('cache-speed')) ?? 0; // bytes/s
    final size = double.tryParse(await _prop('file-size')) ?? 0;
    final dur = double.tryParse(await _prop('duration')) ?? 0;
    final cached = double.tryParse(await _prop('demuxer-cache-duration')) ?? 0;
    final rate = size > 0 && dur > 0 ? size * 8 / dur / 1e6 : 0.0;
    return 'tải ${(speed * 8 / 1e6).toStringAsFixed(1)} Mbit/s · phim ${rate.toStringAsFixed(1)} Mbit/s'
        ' · đệm ${cached.toStringAsFixed(0)} s';
  }

  Future<void> _logStream() async {
    final codec = await _prop('video-codec');
    final w = await _prop('width'), h = await _prop('height');
    final hw = await _prop('hwdec-current');
    appLog('play: ${w}x$h $codec · giải mã ${hw.isEmpty || hw == 'no' ? 'mềm' : hw} · ${await _netStats()}');
  }

  void _onBuffering(bool buffering) {
    _stallTimer?.cancel();
    if (!buffering && !_playingLogged && player.state.duration > Duration.zero) {
      _playingLogged = true;
      appLog('play: picture after $_t');
      unawaited(_logStream());
      unawaited(_matchFrameRate());
    } else if (_playingLogged) {
      if (buffering) {
        _waitSince ??= DateTime.now();
      } else if (_waitSince != null) {
        final ms = DateTime.now().difference(_waitSince!).inMilliseconds;
        _waitSince = null;
        _waits++;
        unawaited(_netStats().then((n) => appLog('play: waited for data $ms ms (lần $_waits) · $n')));
      }
    }
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
    if (hasNext && PlayerSettings.autoNext) next();
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
      appLog('subs: list (${message.list.length}) after $_t');
      serverSubtitles.value = message.list;
      if (message.languages.isNotEmpty) subtitleLanguages = message.languages;
      final prefer = message.byId(message.preferId);
      if (message.autoId == null && prefer != null) _maybeUsePreferred(prefer);
    } else if (message is SubtitleSearch) {
      if (message.key != current.key) return;
      search.value = SubtitleSearchState(
        key: message.key,
        results: message.results,
        note: message.note,
        languages: message.languages,
      );
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
    // Subtitles can only be added once this file (not the previous one) is loaded.
    try {
      if (!await _fileLoaded.future.timeout(const Duration(seconds: 45))) return;
    } on TimeoutException {
      return;
    }
    if (_disposed || generation != _openGeneration) return;
    appLog('subs: "${sub.label}" loaded after $_t');
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

  /// Searches online providers through the page (`/api/subs/search`).
  Future<void> searchOnline(String languages) async {
    final link = page;
    if (link == null) return;
    final key = current.key;
    search.value = SubtitleSearchState(key: key, loading: true, languages: languages);
    await link.send({'type': 'subSearch', 'key': key, 'langs': languages});
    // Providers can be slow; never leave the sheet spinning forever.
    Timer(const Duration(seconds: 40), () {
      if (_disposed) return;
      final now = search.value;
      if (now.loading && now.key == key) {
        search.value = SubtitleSearchState(
          key: key,
          note: 'Không nhận được kết quả, thử lại sau.',
          languages: languages,
        );
      }
    });
  }

  /// Subtitle files picked from the device during this session.
  final ValueNotifier<List<ServerSubtitle>> localSubtitles = ValueNotifier(const []);
  final Map<String, String> _localTexts = {};
  String? _localKey;

  /// Loads a subtitle file from the device (srt/ass/ssa/vtt).
  Future<void> loadLocalSubtitle(String name, List<int> bytes) async {
    final text = decodeSubtitle(bytes);
    final id = 'local:$name';
    _localTexts[id] = text;
    if (!localSubtitles.value.any((s) => s.id == id)) {
      localSubtitles.value = [...localSubtitles.value, ServerSubtitle(id: id, label: name, source: 'Trên máy')];
    }
    await _loadServerSubtitle(SubtitleText(key: current.key, id: id, label: name, text: text));
  }

  Future<void> selectLocalSubtitle(ServerSubtitle sub) async {
    final text = _localTexts[sub.id];
    if (text == null) return;
    await _loadServerSubtitle(SubtitleText(key: current.key, id: sub.id, label: sub.label, text: text));
  }

  /// Picks a server subtitle (the page fetches it and sends it back).
  Future<void> selectServerSubtitle(ServerSubtitle sub) async {
    final link = page;
    if (link == null) return;
    _say('Đang tải phụ đề…');
    await link.send({
      'type': 'subGet',
      'key': current.key,
      'id': sub.id,
      'lang': sub.language ?? '',
      'label': sub.label,
    });
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
    _subtitlesRaised = raised;
    await _applySubtitlePosition();
  }

  bool _subtitlesRaised = true;
  double _hiddenBottom = 0;

  /// Part of the frame (0..0.45 of its height) cut off below the screen in
  /// "fill" mode. libass draws subtitles inside the frame, so without this
  /// they slide off the bottom of the screen when the picture is zoomed.
  Future<void> setFrameCrop(double hiddenBottom) async {
    final v = hiddenBottom.clamp(0.0, 0.45);
    if ((v - _hiddenBottom).abs() < 0.005) return;
    _hiddenBottom = v;
    await _applySubtitlePosition();
  }

  Future<void> _applySubtitlePosition() async {
    if (_disposed) return;
    final native = player.platform;
    if (native is! NativePlayer) return;
    // sub-pos: 100 = bottom edge of the frame. Keep the line inside the
    // visible part, and above the controls while they are shown.
    final visibleBottom = 100 * (1 - _hiddenBottom) - (_hiddenBottom > 0 ? 3 : 0);
    final pos = ((_subtitlesRaised ? visibleBottom - 22 : visibleBottom) - subOffset.value).clamp(0, 100).round();
    await native.setProperty('sub-pos', '$pos');
    // Second (bilingual) line sits just above the main one.
    try {
      await native.setProperty('secondary-sub-pos', '${(pos - 9 * SubtitleStyle.current.scale).clamp(0, 100).round()}');
    } catch (_) {} // older libmpv: no secondary-sub-pos, mpv puts the second line at the top
  }

  /// Manual subtitle height, in % of the frame (positive = higher). Shared by every player
  /// in this run, so it survives episode changes.
  static final ValueNotifier<int> subOffset = ValueNotifier(0);

  Future<void> moveSubtitles(int delta) async {
    subOffset.value = (subOffset.value + delta).clamp(-10, 80);
    await _applySubtitlePosition();
    _say('Vị trí phụ đề: ${subOffset.value >= 0 ? '+' : ''}${subOffset.value}');
  }

  /// Bilingual mode: second subtitle track (mpv secondary-sid), drawn above the main one.
  final ValueNotifier<String> secondarySubtitle = ValueNotifier('no');

  Future<void> setSecondarySubtitle(String id) async {
    final native = player.platform;
    if (native is! NativePlayer || _disposed) {
      return _say('Phụ đề song ngữ cần trình phát mpv');
    }
    await native.setProperty('secondary-sid', id);
    await native.setProperty('secondary-sub-visibility', 'yes');
    secondarySubtitle.value = id;
    await _applySubtitlePosition();
  }

  /// Forced aspect ratio inside mpv (works whatever draws the picture); null = file's own.
  Future<void> setAspectOverride(double? ratio) async {
    final native = player.platform;
    if (native is! NativePlayer || _disposed) return;
    await native.setProperty('video-aspect-override', ratio == null ? 'no' : ratio.toStringAsFixed(4));
  }

  /// Chapters of the current file (MKV / MP4 chapter list); 0 or 1 hides the chapter buttons.
  final ValueNotifier<int> chapterCount = ValueNotifier(0);

  Future<void> _readChapters() async {
    final n = int.tryParse(await _prop('chapters')) ?? 0;
    if (!_disposed) chapterCount.value = n;
  }

  Future<void> _mpv(List<String> cmd) async {
    final native = player.platform;
    if (native is NativePlayer && !_disposed) await native.command(cmd);
    if (native is Media3Player && !_disposed) await native.command(cmd);
  }

  /// Previous / next chapter, with its name in the notice.
  Future<void> chapterStep(int delta) async {
    if (chapterCount.value < 2) return;
    final before = int.tryParse(await _prop('chapter')) ?? 0;
    // "back" within the first seconds of a chapter goes to the previous one, like most players
    await _mpv(['add', 'chapter', '$delta']);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final now = int.tryParse(await _prop('chapter')) ?? before;
    final title = await _prop('chapter-metadata/title');
    _say('Chương ${now + 1}/${chapterCount.value}${title.isNotEmpty ? ': $title' : ''}');
  }

  /// Subtitle timing, ±100 ms per press.
  Future<void> subtitleDelay(double seconds) async {
    if (isMedia3) return _say('Trình phát Media3 chưa chỉnh được lệch phụ đề (đổi sang mpv trong Cài đặt)');
    await _mpv(['add', 'sub-delay', seconds.toStringAsFixed(2)]);
    final d = double.tryParse(await _prop('sub-delay')) ?? 0;
    _say('Lệch phụ đề: ${d >= 0 ? '+' : ''}${(d * 1000).round()} ms');
  }

  Future<void> toggleSubtitles() async {
    await _mpv(['cycle', 'sub-visibility']);
    final on = await _prop('sub-visibility');
    _say(on == 'no' ? 'Đã ẩn phụ đề' : 'Đã hiện phụ đề');
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

  bool _frameRateChanged = false;

  /// Frame-rate matching (TV setting): once the film's rate is known, switch the display to a
  /// fitting mode and pause while it settles (the screen may go dark for about a second).
  Future<void> _matchFrameRate() async {
    // Media3 switches the display itself (Media3Host.kt), waiting for the TV like Fladder
    // phones: 120 Hz screens drop to 60 Hz for video on many ROMs; 24 fps on 60 Hz judders (3:2)
    final phone = Platform.isAndroid && !isTvDevice && PlayerSettings.phoneFrameRate;
    if (!(TvPlaybackPrefs.matchFrameRate || phone) || _disposed || isMedia3) return;
    final fps = double.tryParse(await _prop('container-fps')) ?? double.tryParse(await _prop('estimated-vf-fps')) ?? 0;
    if (fps < 10 || fps > 121) return;
    final before = TvPlaybackPrefs.displayRefreshRate();
    final hz = await TvPlaybackPrefs.requestFrameRate(fps);
    appLog(
      'frame rate: film ${fps.toStringAsFixed(3)} fps, display ${before.toStringAsFixed(2)} -> ${hz?.toStringAsFixed(2) ?? 'unchanged'} Hz',
    );
    if (hz == null || _disposed) return;
    _frameRateChanged = true;
    final n = player.platform;
    if (n is NativePlayer) await n.setProperty('display-fps-override', hz.toStringAsFixed(3));
    // phone panels switch refresh rate seamlessly; TVs re-sync HDMI (dark for a moment)
    if (phone || (hz - before).abs() < 0.01) return;
    final wasPlaying = player.state.playing;
    await player.pause();
    await Future<void>.delayed(const Duration(seconds: 2));
    if (wasPlaying && !_disposed) await player.play();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    if (_frameRateChanged) {
      _frameRateChanged = false;
      final hz = await TvPlaybackPrefs.requestFrameRate(0);
      final n = player.platform;
      if (hz != null && n is NativePlayer) await n.setProperty('display-fps-override', hz.toStringAsFixed(3));
    }
    reportProgress(force: true);
    _disposed = true;
    _progressTimer?.cancel();
    _stallTimer?.cancel();
    _noticeTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    // Stop only: the libmpv instance is reused by the next session.
    if (isMedia3) {
      await player.dispose();
    } else {
      await player.stop();
      await player.setSubtitleTrack(SubtitleTrack.auto());
    }
    index.dispose();
    error.dispose();
    recovering.dispose();
    serverSubtitles.dispose();
    localSubtitles.dispose();
    search.dispose();
    serverSubtitleId.dispose();
    chapterCount.dispose();
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

class SubtitleSearchState {
  const SubtitleSearchState({
    this.key,
    this.loading = false,
    this.results = const [],
    this.note = '',
    this.languages = '',
  });
  final String? key;
  final bool loading;
  final List<ServerSubtitle> results;
  final String note;
  final String languages;

  bool get done => key != null && !loading;
}

/// Subtitle files come in UTF-8 (with or without BOM), UTF-16 or older
/// single-byte encodings; mpv needs UTF-8 text.
String decodeSubtitle(List<int> bytes) {
  if (bytes.length >= 2) {
    final le = bytes[0] == 0xFF && bytes[1] == 0xFE;
    final be = bytes[0] == 0xFE && bytes[1] == 0xFF;
    if (le || be) {
      final units = <int>[];
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        units.add(le ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1]);
      }
      return String.fromCharCodes(units);
    }
  }
  var start = 0;
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) start = 3;
  try {
    return utf8.decode(bytes.sublist(start));
  } on FormatException {
    // Not UTF-8: Latin-1 keeps the bytes; old Vietnamese code pages (VNI,
    // TCVN3) need converting to Unicode before use.
    return latin1.decode(bytes.sublist(start));
  }
}
