import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import '../util/log.dart';

/// Android TV: Media3 ExoPlayer as a media_kit backend.
///
/// The picture is a SurfaceView under the (transparent) Flutter surface in MainActivity
/// (Media3Host.kt), so the hardware composer puts video and controls together: no GPU copy,
/// like Fladder's TV player, while the app's own Flutter player UI (PlayerScreen) drives it
/// exactly like libmpv — same controls, progress bar, track sheets, server subtitles, settings.
///
/// Track ids are `group:track` from Media3's current tracks; [getProperty] answers the few
/// mpv property names the app reads (playback info, chapters, frame rate).
class Media3Player extends PlatformPlayer {
  Media3Player({required Map<String, Object?> options}) : super(configuration: const PlayerConfiguration()) {
    _ensureHandler();
    _active = this;
    _ready = _channel.invokeMethod<bool>('create', options).then((_) {
      if (!completer.isCompleted) completer.complete();
    });
  }

  static const _channel = MethodChannel('torboxstrm/media3');
  static Media3Player? _active;
  static bool _handler = false;
  late final Future<void> _ready;
  bool _disposed = false;
  Map<Object?, Object?> _info = const {};

  static void _ensureHandler() {
    if (_handler) return;
    _handler = true;
    _channel.setMethodCallHandler((call) async {
      final p = _active;
      if (p == null || p._disposed) return;
      switch (call.method) {
        case 'state':
          if (call.arguments is Map) p._onState(call.arguments as Map);
        case 'log':
          appLog('${call.arguments}');
        case 'error':
          final e = '${call.arguments}';
          if (!p.errorController.isClosed) p.errorController.add(e);
      }
    });
  }

  Future<Object?> _call(String method, [Map<String, Object?>? args]) async {
    if (_disposed) return null;
    await _ready;
    try {
      return await _channel.invokeMethod<Object?>(method, args);
    } on PlatformException catch (e) {
      appLog('media3 $method: ${e.message}');
      return null;
    }
  }

  // ---------------- state from Kotlin ----------------

  static Duration _ms(Object? v) => Duration(milliseconds: (v as num?)?.toInt() ?? 0);

  void _onState(Map s) {
    _info = s;
    final position = _ms(s['position']);
    final duration = _ms(s['duration']);
    final buffer = _ms(s['buffered']);
    final playing = s['playing'] == true;
    final buffering = s['buffering'] == true;
    final completed = s['ended'] == true;
    final volume = (s['volume'] as num?)?.toDouble() ?? 100;
    final rate = (s['rate'] as num?)?.toDouble() ?? 1;
    final w = (s['width'] as num?)?.toInt();
    final h = (s['height'] as num?)?.toInt();

    AudioTrack audio(Map t) => AudioTrack(
      '${t['id']}',
      t['title'] as String?,
      t['language'] as String?,
      codec: t['codec'] as String?,
      channelscount: (t['channels'] as num?)?.toInt(),
      isDefault: t['default'] == true,
    );
    SubtitleTrack sub(Map t) => SubtitleTrack(
      '${t['id']}',
      t['title'] as String?,
      t['language'] as String?,
      codec: t['codec'] as String?,
      isDefault: t['default'] == true,
    );
    VideoTrack video(Map t) => VideoTrack(
      '${t['id']}',
      null,
      null,
      codec: t['codec'] as String?,
      w: (t['width'] as num?)?.toInt(),
      h: (t['height'] as num?)?.toInt(),
      fps: (t['fps'] as num?)?.toDouble(),
    );
    List<Map> list(String k) => [
      for (final t in (s[k] as List?) ?? const [])
        if (t is Map) t,
    ];

    final audios = list('audio'), subs = list('subs'), videos = list('video');
    final tracks = Tracks(
      video: [VideoTrack.auto(), VideoTrack.no(), ...videos.map(video)],
      audio: [AudioTrack.auto(), AudioTrack.no(), ...audios.map(audio)],
      subtitle: [SubtitleTrack.auto(), SubtitleTrack.no(), ...subs.map(sub)],
    );
    final selAudio = audios.where((t) => t['selected'] == true).firstOrNull;
    final selSub = subs.where((t) => t['selected'] == true).firstOrNull;
    final selVideo = videos.where((t) => t['selected'] == true).firstOrNull;
    final track = Track(
      video: selVideo == null ? VideoTrack.auto() : video(selVideo),
      audio: selAudio == null ? AudioTrack.auto() : audio(selAudio),
      subtitle: s['subsOff'] == true || selSub == null ? SubtitleTrack.no() : sub(selSub),
    );
    final params = VideoParams(w: w, h: h, dw: w, dh: h);

    state = state.copyWith(
      position: position,
      duration: duration,
      buffer: buffer,
      playing: playing,
      buffering: buffering,
      completed: completed,
      volume: volume,
      rate: rate,
      width: w,
      height: h,
      tracks: tracks,
      track: track,
      videoParams: params,
    );
    if (playingController.isClosed) return;
    positionController.add(position);
    durationController.add(duration);
    bufferController.add(buffer);
    playingController.add(playing);
    bufferingController.add(buffering);
    completedController.add(completed);
    volumeController.add(volume);
    rateController.add(rate);
    widthController.add(w);
    heightController.add(h);
    tracksController.add(tracks);
    trackController.add(track);
    videoParamsController.add(params);
  }

  /// Ids the app treats as "real" tracks (for its ActiveTracks).
  String get selectedAudioId => state.track.audio.id;
  String get selectedSubtitleId => state.track.subtitle.id;
  String get selectedVideoId => state.track.video.id;

  /// The few mpv property names the app reads, answered from Media3's state.
  Future<String> getProperty(String name) async {
    String s(String k) => _info[k] == null ? '' : '${_info[k]}';
    return switch (name) {
      'hwdec-current' => s('videoDecoder'),
      'current-vo' => 'Media3 SurfaceView',
      'file-format' => s('container'),
      'frame-drop-count' => s('dropped'),
      'decoder-frame-drop-count' => '0',
      'estimated-vf-fps' || 'container-fps' => s('fps'),
      'demuxer-cache-duration' => '${((_info['buffered'] as num? ?? 0) - (_info['position'] as num? ?? 0)) / 1000}',
      'sub-visibility' => _info['subsOff'] == true ? 'no' : 'yes',
      _ => '',
    };
  }

  // ---------------- media_kit API ----------------

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is! Media) throw UnsupportedError('Media3: one file at a time');
    await _call('open', {'url': playable.uri, 'startMs': playable.start?.inMilliseconds ?? 0, 'play': play});
  }

  @override
  Future<void> stop() async => _call('stop');

  @override
  Future<void> play() async => _call('play');

  @override
  Future<void> pause() async => _call('pause');

  @override
  Future<void> playOrPause() async => state.playing ? pause() : play();

  @override
  Future<void> seek(Duration duration) async {
    // the progress bar reads state.position right away
    state = state.copyWith(position: duration);
    if (!positionController.isClosed) positionController.add(duration);
    await _call('seek', {'ms': duration.inMilliseconds});
  }

  @override
  Future<void> setVolume(double volume) async => _call('volume', {'value': volume});

  @override
  Future<void> setRate(double rate) async => _call('rate', {'value': rate});

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  Future<void> setPlaylistMode(PlaylistMode playlistMode) async {}

  @override
  Future<void> setShuffle(bool shuffle) async {}

  @override
  Future<void> setAudioDevice(AudioDevice audioDevice) async {}

  @override
  Future<void> setVideoTrack(VideoTrack track) async {}

  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    if (track.id == 'auto' || track.id == 'no') return;
    await _call('track', {'type': 'audio', 'id': track.id});
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    if (track.id == 'no') {
      await _call('subOff');
    } else if (track.id == 'auto') {
      await _call('subAuto');
    } else if (track.uri) {
      await _call('addSub', {'uri': track.id, 'label': track.title, 'lang': track.language, 'mime': _mime(track.id)});
    } else if (track.data) {
      final text = track.id;
      final (ext, mime) = text.contains('[Script Info]')
          ? ('ass', 'text/x-ssa')
          : text.trimLeft().startsWith('WEBVTT')
          ? ('vtt', 'text/vtt')
          : ('srt', 'application/x-subrip');
      final dir = Directory('${(await getTemporaryDirectory()).path}/media3_subs');
      await dir.create(recursive: true);
      final file = File('${dir.path}/${DateTime.now().microsecondsSinceEpoch}.$ext');
      await file.writeAsString(text);
      await _call('addSub', {'uri': file.uri.toString(), 'label': track.title, 'lang': track.language, 'mime': mime});
    } else {
      await _call('track', {'type': 'text', 'id': track.id});
    }
  }

  static String _mime(String url) {
    final p = url.toLowerCase().split('?').first;
    if (p.endsWith('.ass') || p.endsWith('.ssa')) return 'text/x-ssa';
    if (p.endsWith('.vtt')) return 'text/vtt';
    return 'application/x-subrip';
  }

  /// mpv commands the app sends (subtitle visibility); others are not available in Media3.
  Future<bool> command(List<String> cmd) async {
    if (cmd.length >= 2 && cmd[0] == 'cycle' && cmd[1] == 'sub-visibility') {
      await _call(_info['subsOff'] == true ? 'subAuto' : 'subOff');
      return true;
    }
    return false;
  }

  /// Picture mode: 'fit' (contain), 'fill' (stretch), 'zoom' (cover).
  Future<void> setFit(String mode) async => _call('fit', {'mode': mode});

  /// Subtitle look for SRT / VTT (ASS keeps its own style).
  Future<void> setSubtitleStyle(Map<String, Object?> style) async => _call('subStyle', style);

  @override
  Future<Uint8List?> screenshot({String? format = 'image/jpeg', bool includeLibassSubtitles = false}) async => null;

  @override
  Future<int> get handle async => 0;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await _call('release');
    _disposed = true;
    if (identical(_active, this)) _active = null;
    await super.dispose();
  }
}
