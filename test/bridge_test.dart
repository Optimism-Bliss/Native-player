import 'package:flutter_test/flutter_test.dart';
import 'package:torbox_strm_player/bridge.dart';
import 'package:torbox_strm_player/settings.dart';

void main() {
  final https = Uri.parse('https://media.example/');
  final key = 'e139a94889b21075dffda2f876fa2690';

  Map<String, Object?> msg({Object? url, Object? sub, Object? index = 0, Object? v = 1}) => {
    'type': 'play',
    'v': v,
    'queue': [
      {'key': key, 'url': url ?? 'https://media.example/s/$key.mkv', 'title': 'Phim', 'subtitle': sub},
    ],
    'index': index,
    'start': 75.5,
  };

  test('accepts a library play message', () {
    final r = PlayRequest.parse(msg(), https);
    expect(r.queue.single.url.path, '/s/$key.mkv');
    expect(r.start, const Duration(milliseconds: 75500));
  });

  test('accepts addon links and a CDN host for STRM_BASE_URL', () {
    final r = PlayRequest.parse(msg(url: 'https://strm.example/x/$key.mp4'), https);
    expect(r.queue.single.url.host, 'strm.example');
  });

  test('rejects anything that is not a stable playback link', () {
    for (final bad in [
      'https://evil.example/download.exe',
      'https://media.example/s/$key.mkv?token=x',
      'https://user:pw@media.example/s/$key.mkv',
      'file:///etc/passwd',
      'http://media.example/s/$key.mkv', // downgrade from https
      'javascript:alert(1)',
    ]) {
      expect(() => PlayRequest.parse(msg(url: bad), https), throwsFormatException, reason: bad);
    }
  });

  test('rejects wrong version, empty queue and bad index', () {
    expect(() => PlayRequest.parse(msg(v: 2), https), throwsFormatException);
    expect(() => PlayRequest.parse(msg(index: 3), https), throwsFormatException);
    expect(() => PlayRequest.parse({'type': 'play', 'v': 1, 'queue': [], 'index': 0}, https), throwsFormatException);
    expect(() => PlayRequest.parse('play', https), throwsFormatException);
  });

  test('drops subtitles with unsafe URLs but keeps playback', () {
    final r = PlayRequest.parse(msg(sub: {'url': 'file:///tmp/x.srt', 'lang': 'vi'}), https);
    expect(r.queue.single.subtitle, isNull);
    final ok = PlayRequest.parse(
      msg(sub: {'url': 'https://media.example/sub/a.srt', 'lang': 'vi', 'label': 'VI'}),
      https,
    );
    expect(ok.queue.single.subtitle?.language, 'vi');
  });

  test('normalizes server addresses', () {
    expect(ServerStore.normalize('media.example')?.toString(), 'https://media.example/');
    expect(ServerStore.normalize('http://10.0.0.2:8080')?.toString(), 'http://10.0.0.2:8080/');
    expect(ServerStore.normalize('ftp://x'), isNull);
    expect(ServerStore.normalize('https://u:p@x'), isNull);
  });

  test('accepts addon keys', () {
    final r = PlayRequest.parse({
      'type': 'play',
      'v': 1,
      'queue': [
        {'key': 'x:$key', 'url': 'https://media.example/x/$key.mkv', 'title': 'Addon'},
      ],
      'index': 0,
    }, https);
    expect(r.queue.single.key, 'x:$key');
  });

  test('parses subtitle lists and content from the page', () {
    final list = SubtitleList.parse({
      'type': 'subs',
      'key': 'x:$key',
      'list': [
        {'id': 'addon:1', 'lang': 'vi', 'label': 'Vietnamese', 'src': 'AIOStreams'},
        {'id': '', 'label': 'bad'},
        'junk',
      ],
      'auto': '',
      'prefer': 'addon:1',
    });
    expect(list.list.single.source, 'AIOStreams');
    expect(list.autoId, isNull);
    expect(list.byId(list.preferId)?.language, 'vi');

    final text = SubtitleText.parse({
      'key': key,
      'id': 'up:3',
      'format': 'srt',
      'text': '1\n00:00:01,000 --> 00:00:02,000\nXin chào\n',
    });
    expect(text.label, 'Phụ đề');
    expect(() => SubtitleText.parse({'key': key, 'id': 'a', 'format': 'exe', 'text': 'x'}), throwsFormatException);
    expect(() => SubtitleText.parse({'key': 'bad key!', 'id': 'a', 'text': 'x'}), throwsFormatException);
  });
}
