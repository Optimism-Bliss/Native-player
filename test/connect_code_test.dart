import 'package:flutter_test/flutter_test.dart';
import 'package:torbox_strm_player/connect_code.dart';

void main() {
  test('round trip', () {
    for (final u in ['https://media.example.com/', 'http://10.0.0.2:8080/', 'https://example.org:8443/strm/']) {
      final server = Uri.parse(u);
      final code = encodeServerCode(server);
      expect(code, startsWith('TBS1-'));
      expect(code.toLowerCase(), isNot(contains('example')));
      expect(decodeServerCode(code), server, reason: code);
      // lower case, spaces, O/0 and I/1 confusions still read
      expect(decodeServerCode(code.toLowerCase().replaceAll('-', ' ')), server);
    }
  });

  test('shared test vector with the server (src/appcode.rs)', () {
    expect(encodeServerCode(Uri.parse('https://media.example.com/')), vector);
  });

  test('typos are rejected', () {
    final code = encodeServerCode(Uri.parse('https://media.example.com/'));
    final bad = code.replaceRange(code.length - 1, code.length, code.endsWith('A') ? 'B' : 'A');
    expect(decodeServerCode(bad), isNull);
    expect(decodeServerCode('https://media.example.com'), isNull);
    expect(looksLikeServerCode(code), isTrue);
    expect(looksLikeServerCode('media.example.com'), isFalse);
  });

  test('QR link', () {
    final code = encodeServerCode(Uri.parse('https://media.example.com/'));
    expect(codeFromLink(connectLink(code).toString()), code);
    expect(codeFromLink('https://x.y/'), isNull);
  });
}

const vector = 'TBS1-AM11-E9G6-35YK-2AHC-808H-R583-0000-KHEG';
