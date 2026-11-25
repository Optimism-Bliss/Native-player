import 'package:flutter_test/flutter_test.dart';
import 'package:torbox_strm_player/util/links.dart';

void main() {
  test('TV login QR links', () {
    expect(deviceLoginCode('torboxstrm://device?c=MFQE-MU3W'), 'MFQE-MU3W');
    expect(deviceLoginCode(' torboxstrm://device?c=mfqe-mu3w '), 'MFQE-MU3W');
    expect(deviceLoginCode('torboxstrm://device?c=MFQE'), isNull);
    expect(deviceLoginCode('torboxstrm://device?c=MFQE-MU3W/../x'), isNull);
    expect(deviceLoginCode('https://example.com/device?c=MFQE-MU3W'), isNull);
    expect(deviceLoginCode('torboxstrm://pair?c=123456'), isNull);
  });
}
