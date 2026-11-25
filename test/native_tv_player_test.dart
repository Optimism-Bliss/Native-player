import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torbox_strm_player/bridge.dart';
import 'package:torbox_strm_player/player/native_tv_player.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('torboxstrm/native_player');
  final messenger = binding.defaultBinaryMessenger;

  Future<void> fromNative(String method, Object? args) => messenger.handlePlatformMessage(
    channel.name,
    channel.codec.encodeMethodCall(MethodCall(method, args)),
    (_) {},
  );

  test('Media3 player: open, state for the phone remote, commands, progress on close', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'open') return true;
      if (call.method == 'command') {
        if ((call.arguments as Map)['action'] == 'stop') {
          scheduleMicrotask(() => fromNative('closed', {'key': 'a1', 'index': 0, 'position': 61000, 'duration': 120000}));
        }
        return null;
      }
      return null;
    });
    final progress = <(String, Duration)>[];
    final player = NativeTvPlayer(
      request: PlayRequest(
        queue: [QueueItem(key: 'a1', url: Uri.parse('https://s.example/s/a1'), title: 'Phim A')],
        index: 0,
        start: const Duration(seconds: 30),
      ),
      onProgress: (k, p, d) => progress.add((k, p)),
    );
    final done = player.run();
    await Future<void>.delayed(Duration.zero);
    final open = calls.firstWhere((c) => c.method == 'open').arguments as Map;
    expect(open['startMs'], 30000);
    expect((open['queue'] as List).single['url'], 'https://s.example/s/a1');

    await fromNative('state', {
      'key': 'a1',
      'index': 0,
      'position': 45000,
      'duration': 120000,
      'playing': true,
      'buffering': false,
      'volume': 80.0,
      'audio': [
        {'id': '0:0', 'label': 'Tiếng Anh · AC3 · 5.1', 'selected': true, 'server': false},
      ],
      'subs': [
        {'id': '1:0', 'label': 'Tiếng Việt · SRT', 'selected': true, 'server': false},
        {'id': '2:0', 'label': 'srv', 'selected': false, 'server': true},
      ],
      'subsOff': false,
    });
    final st = player.tvState();
    expect(st.active, isTrue);
    expect(st.title, 'Phim A');
    expect(st.position, const Duration(seconds: 45));
    expect(st.audioId, '0:0');
    expect(st.subtitleId, '1:0');
    expect(st.subtitles.map((t) => t.id), ['1:0']); // server tracks are listed separately
    expect(st.volume, 80);

    expect(await player.command({'action': 'seekBy', 'by': -10}), isNull);
    final seek = calls.lastWhere((c) => c.method == 'command').arguments as Map;
    expect(seek['action'], 'seekBy');
    expect(seek['ms'], -10000);

    await player.close();
    await done;
    expect(progress.last, ('a1', const Duration(seconds: 61)));
    messenger.setMockMethodCallHandler(channel, null);
  });
}
