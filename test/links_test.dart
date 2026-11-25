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

  test('scanned QR codes become app links', () {
    expect(appLinkFromScan('torboxstrm://device?c=ARXH-AWDZ'), 'torboxstrm://device?c=ARXH-AWDZ');
    expect(appLinkFromScan('https://media.example.com/device?c=arxh-awdz'), 'torboxstrm://device?c=ARXH-AWDZ');
    expect(appLinkFromScan('tbs1-am11-e9g6'), 'torboxstrm://connect?c=TBS1-AM11-E9G6');
    expect(appLinkFromScan('https://example.com/other'), isNull);
    expect(appLinkFromScan('hello'), isNull);
  });
}
