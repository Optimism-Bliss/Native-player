import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torbox_strm_player/bridge.dart';
import 'package:torbox_strm_player/connect_code.dart';
import 'package:torbox_strm_player/tv/protocol.dart';
import 'package:torbox_strm_player/tv/receiver.dart';
import 'package:torbox_strm_player/tv/sender.dart';

void main() {
  test('pair links accept only LAN hosts and 6-digit codes', () {
    expect(PairLink.parse('torboxstrm://pair?h=192.168.1.20&p=47800&c=123456&n=TV')?.host, '192.168.1.20');
    expect(PairLink.parse('torboxstrm://pair?h=evil.example&c=123456'), isNull);
    expect(PairLink.parse('torboxstrm://pair?h=8.8.8.8&c=123456'), isNull);
    expect(PairLink.parse('torboxstrm://pair?h=10.0.0.5&c=12'), isNull);
    expect(PairLink.parse('https://pair?h=10.0.0.5&c=123456'), isNull);
    expect(isLanHost('172.16.0.1'), isTrue);
    expect(isLanHost('172.32.0.1'), isFalse);
  });

  test('state survives a JSON round trip', () {
    const s = TvState(
      active: true,
      title: 'Tập 1',
      position: Duration(seconds: 61),
      duration: Duration(minutes: 40),
      playing: true,
      audio: [TvTrack('1', 'Tiếng Anh')],
      serverSubtitleId: 'aio:x',
    );
    final back = TvState.fromJson(s.toJson());
    expect(back.title, 'Tập 1');
    expect(back.position, const Duration(seconds: 61));
    expect(back.audio.single.label, 'Tiếng Anh');
    expect(back.serverSubtitleId, 'aio:x');
  });

  group('receiver over HTTP', () {
    late TvReceiver rx;
    final played = <PlayRequest>[];
    final servers = <Uri>[];
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      rx = TvReceiver(
        openPlayer: (r) async => played.add(r),
        name: 'Test TV',
        onServer: (u, code) async => servers.add(u),
      );
      await rx.start();
    });
    tearDown(() => rx.stop());

    test('a phone finds the TV with the LAN broadcast', () async {
      if (rx.pairLink == null) {
        markTestSkipped('no LAN address in this environment');
        return;
      }
      final found = await discoverTvs();
      if (found.isEmpty) {
        markTestSkipped('broadcasts are not delivered in this environment');
        return;
      }
      expect(found.first.name, 'Test TV');
      expect(found.first.port, rx.port);
    });

    test('pairing, auth, play validation, page relay and poll', () async {
      final link = rx.pairLink;
      if (link == null) {
        markTestSkipped('no LAN address in this environment');
        return;
      }
      // wrong code is refused
      await expectLater(
        TvClient.pair(PairLink(host: link.host, port: link.port, code: '000000')),
        throwsA(isA<TvError>()),
      );
      final tv = await TvClient.pair(link);
      expect(tv.name, 'Test TV');
      // the code is single use
      await expectLater(TvClient.pair(link), throwsA(isA<TvError>()));

      // an unknown token is refused
      final stranger = TvClient(PairedTv(host: tv.host, port: tv.port, token: 'nope', name: 'x'));
      await expectLater(stranger.poll(0), throwsA(isA<TvError>()));
      stranger.close();

      final c = TvClient(tv);
      final server = Uri.parse('https://media.example/');
      // the same checks as a play message inside the app
      await expectLater(c.play(server, {'type': 'play', 'v': bridgeVersion, 'queue': []}), throwsA(isA<TvError>()));
      await c.play(server, {
        'type': 'play',
        'v': bridgeVersion,
        'queue': [
          {'key': 'abcdefgh1234', 'url': 'https://media.example/s/abcdefgh1234.mkv', 'title': 'Phim'},
        ],
        'index': 0,
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(played.single.queue.single.title, 'Phim');

      // page answers reach the player's PageLink
      final got = Completer<Object>();
      final sub = rx.pageIn.stream.listen(got.complete);
      await c.page({'type': 'subs', 'key': 'abcdefgh1234', 'list': [], 'auto': null});
      expect(await got.future.timeout(const Duration(seconds: 2)), isA<SubtitleList>());
      await sub.cancel();

      // what the player sends to the page comes back in the poll
      await rx.toPage({'type': 'progress', 'key': 'abcdefgh1234', 'pos': 12.0, 'dur': 100.0});
      final r = await c.poll(0);
      expect(r.events.single['type'], 'progress');
      expect(r.state.active, isTrue);
      final r2 = await c.poll(r.seq);
      expect(r2.events, isEmpty);

      // the phone hands its server to the TV as a server code
      await c.setServer(encodeServerCode(Uri.parse('https://media.example.com/')));
      expect(servers.single, Uri.parse('https://media.example.com/'));
      await expectLater(c.setServer('TBS1-XXXX'), throwsA(isA<TvError>()));

      // commands need an open player
      await expectLater(c.command('toggle'), throwsA(isA<TvError>()));
      c.close();
    });
  });
}
