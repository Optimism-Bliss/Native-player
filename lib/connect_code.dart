import 'dart:convert';

/// Server code ("mã máy chủ"): lets someone connect the app without being
/// told the server's address, and lets the app keep that address out of
/// sight afterwards.
///
/// `TBS1-XXXX-XXXX-…` is Crockford base32 of
/// `[version=1][address text][CRC-16/CCITT of the first two parts]`,
/// XOR-ed with a fixed key. The address text is the host, `:port` when not
/// the default, the base path when not `/`, and an `h:` prefix for plain
/// http. The XOR only keeps the address from being readable at a glance; it
/// is not encryption (the app must be able to read it, and its source is
/// public). The server builds the same code (src/appcode.rs).
const _key = 'TorBoxSTRM-app-code';
const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const codePrefix = 'TBS1';

int _crc16(List<int> data) {
  var crc = 0xFFFF;
  for (final b in data) {
    crc ^= b << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

List<int> _xor(List<int> data) {
  final k = utf8.encode(_key);
  return [for (var i = 0; i < data.length; i++) data[i] ^ k[i % k.length]];
}

String _base32(List<int> data) {
  final out = StringBuffer();
  var buffer = 0, bits = 0;
  for (final b in data) {
    buffer = (buffer << 8) | b;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.write(_alphabet[(buffer >> bits) & 31]);
    }
  }
  if (bits > 0) out.write(_alphabet[(buffer << (5 - bits)) & 31]);
  return out.toString();
}

List<int>? _unbase32(String s) {
  final out = <int>[];
  var buffer = 0, bits = 0;
  for (final ch in s.split('')) {
    final v = _alphabet.indexOf(ch);
    if (v < 0) return null;
    buffer = (buffer << 5) | v;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xFF);
    }
  }
  return out;
}

/// The code for a server address (https://host[:port][/base/]).
String encodeServerCode(Uri server) {
  var text = server.host;
  if (server.hasPort && server.port != (server.scheme == 'http' ? 80 : 443)) text += ':${server.port}';
  final path = server.path.endsWith('/') ? server.path.substring(0, server.path.length - 1) : server.path;
  if (path.isNotEmpty) text += path;
  if (server.scheme == 'http') text = 'h:$text';
  final plain = [1, ...utf8.encode(text)];
  final crc = _crc16(plain);
  final raw = _base32(_xor([...plain, crc >> 8, crc & 0xFF]));
  final groups = [for (var i = 0; i < raw.length; i += 4) raw.substring(i, i + 4 > raw.length ? raw.length : i + 4)];
  return '$codePrefix-${groups.join('-')}';
}

/// Whether the text looks like a server code (so the connect screen treats it as one).
bool looksLikeServerCode(String input) =>
    input.trim().toUpperCase().replaceAll(' ', '').startsWith('$codePrefix-') ||
    input.trim().toUpperCase().startsWith(codePrefix) && !input.contains('.') && !input.contains('/');

/// The server address in a code, or null when the code is mistyped.
Uri? decodeServerCode(String input) {
  var s = input.trim().toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
  if (!s.startsWith(codePrefix)) return null;
  s = s.substring(codePrefix.length).replaceAll('O', '0').replaceAll(RegExp('[IL]'), '1');
  final data = _unbase32(s);
  if (data == null || data.length < 4) return null;
  final plain = _xor(data);
  final body = plain.sublist(0, plain.length - 2);
  final crc = (plain[plain.length - 2] << 8) | plain[plain.length - 1];
  if (_crc16(body) != crc || body.first != 1) return null;
  String text;
  try {
    text = utf8.decode(body.sublist(1));
  } catch (_) {
    return null;
  }
  final http = text.startsWith('h:');
  if (http) text = text.substring(2);
  final uri = Uri.tryParse('${http ? 'http' : 'https'}://$text');
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null, path: path);
}

/// `torboxstrm://connect?c=<code>` — what the server's QR code holds.
Uri connectLink(String code) => Uri(scheme: 'torboxstrm', host: 'connect', queryParameters: {'c': code});

String? codeFromLink(String raw) {
  final u = Uri.tryParse(raw);
  if (u == null || u.scheme != 'torboxstrm' || u.host != 'connect') return null;
  return u.queryParameters['c'];
}
