import 'package:flutter_test/flutter_test.dart';
import 'package:torbox_strm_player/update/updater.dart';

void main() {
  test('parses tags and pubspec versions', () {
    expect(parseVersion('v0.4.3'), [0, 4, 3]);
    expect(parseVersion('0.4.3+7'), [0, 4, 3]);
    expect(parseVersion('v1.0.0-beta.2'), [1, 0, 0]);
  });

  test('compares versions numerically', () {
    expect(compareVersions(parseVersion('v0.4.10'), parseVersion('0.4.9')), greaterThan(0));
    expect(compareVersions(parseVersion('v0.4.2'), parseVersion('0.4.2+6')), 0);
    expect(compareVersions(parseVersion('v0.3.9'), parseVersion('0.4.0')), lessThan(0));
    expect(compareVersions(parseVersion('v1'), parseVersion('0.9.9')), greaterThan(0));
  });
}
