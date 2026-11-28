// Phim tải về máy để xem không cần mạng.
//
// Trang web (chỉ tài khoản được admin cho phép "Tải về") gửi lệnh `download` với link /s của file trên máy chủ; app
// tải từng file một vào thư mục riêng của app, tải tiếp được khi bị ngắt (HTTP Range), lưu danh sách + vị trí xem dở
// vào `index.json`. Phát bằng trình phát của app như phim online, kể cả khi không có mạng.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../util/log.dart';

enum DownloadState { queued, downloading, paused, done, error }

class DownloadItem {
  DownloadItem({
    required this.id,
    required this.title,
    required this.fileName,
    required this.url,
    required this.path,
    this.size = 0,
    this.poster = '',
    this.subUrl = '',
    this.subLabel = '',
    this.subLang = '',
    this.subPath = '',
    this.received = 0,
    this.state = DownloadState.queued,
    this.error = '',
    this.positionMs = 0,
    this.durationMs = 0,
    int? added,
  }) : added = added ?? DateTime.now().millisecondsSinceEpoch;

  /// khoá file trên máy chủ
  final String id;
  final String title;
  final String fileName;
  final String url;
  final String path;
  int size;
  final String poster;
  final String subUrl;
  final String subLabel;
  final String subLang;
  String subPath;
  int received;
  DownloadState state;
  String error;
  int positionMs;
  int durationMs;
  final int added;

  double get progress => size > 0 ? (received / size).clamp(0, 1).toDouble() : 0;

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'fileName': fileName,
    'url': url,
    'path': path,
    'size': size,
    'poster': poster,
    'subUrl': subUrl,
    'subLabel': subLabel,
    'subLang': subLang,
    'subPath': subPath,
    'received': received,
    'state': state.name,
    'error': error,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'added': added,
  };

  static DownloadItem? fromJson(Object? j) {
    if (j is! Map) return null;
    String s(String k) => j[k] is String ? j[k] as String : '';
    int n(String k) => j[k] is num ? (j[k] as num).toInt() : 0;
    if (s('id').isEmpty || s('path').isEmpty) return null;
    return DownloadItem(
      id: s('id'),
      title: s('title'),
      fileName: s('fileName'),
      url: s('url'),
      path: s('path'),
      size: n('size'),
      poster: s('poster'),
      subUrl: s('subUrl'),
      subLabel: s('subLabel'),
      subLang: s('subLang'),
      subPath: s('subPath'),
      received: n('received'),
      state: DownloadState.values.firstWhere((e) => e.name == s('state'), orElse: () => DownloadState.paused),
      error: s('error'),
      positionMs: n('positionMs'),
      durationMs: n('durationMs'),
      added: n('added'),
    );
  }
}

/// Danh sách tải (một bản cho cả app).
class Downloads extends ChangeNotifier {
  Downloads._();
  static final Downloads instance = Downloads._();

  final List<DownloadItem> items = [];
  Directory? _dir;
  bool _loaded = false;
  DownloadItem? _active;
  HttpClient? _client;
  bool _stop = false;
  Timer? _saveTimer;

  Future<Directory> _folder() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}TorBoxSTRM-downloads');
    if (!await d.exists()) await d.create(recursive: true);
    return _dir = d;
  }

  File _index(Directory d) => File('${d.path}${Platform.pathSeparator}index.json');

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final d = await _folder();
      final f = _index(d);
      if (await f.exists()) {
        final raw = jsonDecode(await f.readAsString());
        if (raw is List) {
          for (final j in raw) {
            final it = DownloadItem.fromJson(j);
            if (it == null) continue;
            // app tắt giữa chừng: chờ người dùng bấm tải tiếp
            if (it.state == DownloadState.downloading || it.state == DownloadState.queued) it.state = DownloadState.paused;
            items.add(it);
          }
        }
      }
    } catch (e) {
      appLog('downloads: load: $e');
    }
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final d = await _folder();
      final f = _index(d);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
      await tmp.rename(f.path);
    } catch (e) {
      appLog('downloads: save: $e');
    }
  }

  void _saveSoon() {
    _saveTimer ??= Timer(const Duration(seconds: 2), () {
      _saveTimer = null;
      unawaited(_save());
    });
  }

  static String _safe(String s) {
    final t = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > 120 ? t.substring(0, 120).trim() : (t.isEmpty ? 'video' : t);
  }

  DownloadItem? byId(String id) {
    for (final it in items) {
      if (it.id == id) return it;
    }
    return null;
  }

  /// Thêm một file (đã có thì tải tiếp nếu đang dừng / lỗi). Trả thông báo cho trang.
  Future<String> add({
    required String id,
    required Uri url,
    required String title,
    required String fileName,
    int size = 0,
    String ext = '',
    String poster = '',
    Uri? subUrl,
    String subLabel = '',
    String subLang = '',
  }) async {
    await load();
    final have = byId(id);
    if (have != null) {
      if (have.state == DownloadState.done) return 'Phim này đã tải về máy';
      have.state = DownloadState.queued;
      have.error = '';
      notifyListeners();
      unawaited(_pump());
      return 'Đang tải tiếp';
    }
    final d = await _folder();
    final e = ext.isNotEmpty ? ext : (fileName.contains('.') ? fileName.split('.').last : 'mkv');
    final base = _safe(title.isNotEmpty ? title : fileName);
    var path = '${d.path}${Platform.pathSeparator}$base.$e';
    for (var i = 2; await File(path).exists() || items.any((x) => x.path == path); i++) {
      path = '${d.path}${Platform.pathSeparator}$base ($i).$e';
    }
    items.insert(
      0,
      DownloadItem(
        id: id,
        title: title,
        fileName: fileName,
        url: url.toString(),
        path: path,
        size: size,
        poster: poster,
        subUrl: subUrl?.toString() ?? '',
        subLabel: subLabel,
        subLang: subLang,
      ),
    );
    notifyListeners();
    await _save();
    unawaited(_pump());
    return 'Đã thêm vào danh sách tải';
  }

  /// Tải lần lượt từng file một.
  Future<void> _pump() async {
    if (_active != null) return;
    while (true) {
      DownloadItem? next;
      for (final it in items.reversed) {
        if (it.state == DownloadState.queued) {
          next = it;
          break;
        }
      }
      if (next == null) return;
      _active = next;
      await _run(next);
      _active = null;
      await _save();
    }
  }

  /// GET có Range, tự đi theo chuyển hướng (/s → CDN), giữ Range ở mọi bước.
  Future<HttpClientResponse> _open(HttpClient c, Uri url, int from) async {
    var u = url;
    for (var i = 0; i < 8; i++) {
      final req = await c.getUrl(u);
      req.followRedirects = false;
      if (from > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
      final res = await req.close();
      if (res.isRedirect || (res.statusCode >= 300 && res.statusCode < 400)) {
        final loc = res.headers.value(HttpHeaders.locationHeader);
        await res.drain<void>();
        if (loc == null) throw const HttpException('chuyển hướng không có địa chỉ');
        u = u.resolve(loc);
        continue;
      }
      return res;
    }
    throw const HttpException('chuyển hướng quá nhiều lần');
  }

  Future<void> _run(DownloadItem it) async {
    it.state = DownloadState.downloading;
    it.error = '';
    _stop = false;
    notifyListeners();
    final c = _client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    final part = File('${it.path}.part');
    try {
      var have = await part.exists() ? await part.length() : 0;
      final res = await _open(c, Uri.parse(it.url), have);
      if (res.statusCode == 416 && it.size > 0 && have >= it.size) {
        await res.drain<void>();
      } else {
        if (res.statusCode == 200 && have > 0) have = 0; // máy chủ không tải tiếp được: tải lại từ đầu
        if (res.statusCode != 200 && res.statusCode != 206) {
          await res.drain<void>();
          throw HttpException('máy chủ trả HTTP ${res.statusCode}');
        }
        if (res.contentLength > 0) it.size = have + res.contentLength;
        it.received = have;
        final sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
        var last = DateTime.now();
        try {
          await for (final chunk in res) {
            if (_stop) break;
            sink.add(chunk);
            it.received += chunk.length;
            final now = DateTime.now();
            if (now.difference(last).inMilliseconds > 500) {
              last = now;
              notifyListeners();
              _saveSoon();
            }
          }
        } finally {
          await sink.flush();
          await sink.close();
        }
        if (_stop) {
          it.state = DownloadState.paused;
          notifyListeners();
          return;
        }
        if (it.size > 0 && it.received < it.size) throw const HttpException('mất kết nối giữa chừng — bấm tải tiếp');
      }
      await part.rename(it.path);
      if (it.size <= 0) it.size = await File(it.path).length();
      it.received = it.size;
      await _fetchSub(c, it);
      it.state = DownloadState.done;
      appLog('downloads: xong ${it.fileName}');
    } catch (e) {
      it.state = _stop ? DownloadState.paused : DownloadState.error;
      it.error = _stop ? '' : e.toString().replaceFirst('HttpException: ', '');
      appLog('downloads: ${it.fileName}: $e');
    } finally {
      c.close(force: true);
      _client = null;
      notifyListeners();
    }
  }

  Future<void> _fetchSub(HttpClient c, DownloadItem it) async {
    if (it.subUrl.isEmpty) return;
    try {
      final res = await _open(c, Uri.parse(it.subUrl), 0);
      if (res.statusCode != 200) {
        await res.drain<void>();
        return;
      }
      final ext = it.subUrl.toLowerCase().contains('.vtt') ? 'vtt' : 'srt';
      final dot = it.path.lastIndexOf('.');
      final p = '${dot > 0 ? it.path.substring(0, dot) : it.path}.${it.subLang.isEmpty ? 'sub' : it.subLang}.$ext';
      await res.pipe(File(p).openWrite());
      it.subPath = p;
    } catch (e) {
      appLog('downloads: phụ đề ${it.fileName}: $e');
    }
  }

  void pause(DownloadItem it) {
    if (identical(_active, it)) {
      _stop = true;
      _client?.close(force: true);
    } else if (it.state == DownloadState.queued) {
      it.state = DownloadState.paused;
      notifyListeners();
      unawaited(_save());
    }
  }

  void resume(DownloadItem it) {
    if (it.state == DownloadState.done || it.state == DownloadState.downloading) return;
    it.state = DownloadState.queued;
    it.error = '';
    notifyListeners();
    unawaited(_pump());
  }

  Future<void> remove(DownloadItem it) async {
    if (identical(_active, it)) {
      _stop = true;
      _client?.close(force: true);
      // chờ vòng tải dừng hẳn rồi mới xoá file
      for (var i = 0; i < 50 && identical(_active, it); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    items.remove(it);
    for (final p in [it.path, '${it.path}.part', it.subPath]) {
      if (p.isEmpty) continue;
      try {
        final f = File(p);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    notifyListeners();
    await _save();
  }

  void setPosition(String id, Duration pos, Duration dur) {
    final it = byId(id);
    if (it == null) return;
    it.positionMs = pos.inMilliseconds;
    if (dur.inMilliseconds > 0) it.durationMs = dur.inMilliseconds;
    _saveSoon();
  }

  int get usedBytes => items.fold(0, (a, it) => a + (it.state == DownloadState.done ? it.size : it.received));
}
