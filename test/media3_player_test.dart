import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:torbox_strm_player/player/media3_player.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('torboxstrm/media3');
  final messenger = binding.defaultBinaryMessenger;

  Future<void> fromNative(String method, Object? args) =>
      messenger.handlePlatformMessage(channel.name, channel.codec.encodeMethodCall(MethodCall(method, args)), (_) {});

  test('Media3 as a media_kit backend: open, state, tracks, subtitles, release', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'create' ? true : null;
    });
    final player = Player(platformPlayer: Media3Player(options: {'tunneling': false}));
    await player.open(Media('https://s.example/s/a1', start: const Duration(seconds: 30)));
    final open = calls.firstWhere((c) => c.method == 'open').arguments as Map;
    expect(open['startMs'], 30000);

    final tracks = <Tracks>[];
    final sub = player.stream.tracks.listen(tracks.add);
    await fromNative('state', {
      'position': 45000,
      'duration': 120000,
      'buffered': 80000,
      'playing': true,
      'buffering': false,
      'volume': 100.0,
      'rate': 1.0,
      'width': 1920,
      'height': 800,
      'audio': [
        {'id': '0:0', 'title': null, 'language': 'en', 'codec': 'ac3', 'channels': 6, 'selected': true},
      ],
      'subs': [
        {'id': '1:0', 'title': 'Tiếng Việt', 'language': 'vi', 'codec': 'subrip', 'selected': true},
      ],
      'video': [
        {'id': '2:0', 'codec': 'hevc', 'width': 1920, 'height': 800, 'fps': 23.976, 'selected': true},
      ],
      'subsOff': false,
      'videoDecoder': 'OMX.amlogic.hevc.decoder.awesome',
      'dropped': 3,
      'fps': 23.976,
    });
    await Future<void>.delayed(Duration.zero);
    expect(player.state.position, const Duration(seconds: 45));
    expect(player.state.playing, isTrue);
    expect(player.state.track.audio.id, '0:0');
    expect(player.state.track.subtitle.id, '1:0');
    expect(player.state.tracks.audio.last.channelscount, 6);
    expect(tracks, isNotEmpty);
    final m3 = player.platform as Media3Player;
    expect(await m3.getProperty('hwdec-current'), 'OMX.amlogic.hevc.decoder.awesome');
    expect(await m3.getProperty('frame-drop-count'), '3');

    await player.setSubtitleTrack(SubtitleTrack.no());
    expect(calls.last.method, 'subOff');
    await player.setAudioTrack(const AudioTrack('0:0', null, 'en'));
    expect(calls.last.arguments, {'type': 'audio', 'id': '0:0'});
    await player.setSubtitleTrack(SubtitleTrack.uri('https://s.example/sub/x.srt', title: 'Server', language: 'vi'));
    expect(calls.last.method, 'addSub');
    expect((calls.last.arguments as Map)['mime'], 'application/x-subrip');

    await sub.cancel();
    await player.dispose();
    expect(calls.last.method, 'release');
    messenger.setMockMethodCallHandler(channel, null);
  });
}
