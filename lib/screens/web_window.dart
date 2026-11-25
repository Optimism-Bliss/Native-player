import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_all/webview_all.dart' show WebViewJavaScriptCall, WebViewJavaScriptWorld;

import '../bridge.dart';
import '../settings.dart';
import '../util/log.dart';

/// Windows: the web UI in its own native WebView2 window instead of inside the
/// Flutter window. The embedded WebView draws through Windows Graphics
/// Capture, which shows nothing on some PCs (page loads, window stays dark);
/// a native window has no such step. Playback still opens in the app's player.
///
/// The page talks to the app exactly as in the embedded WebView: a script
/// added at document creation provides `window.TorBoxStrmApp` and
/// `window.webviewAll.callHandler`, carried over `window.desktopWebview`.
class WebWindow {
  WebWindow({required this.server, required this.onCall});

  final Uri server;

  /// Same handler as the embedded WebView's bridge.
  final FutureOr<Object?> Function(WebViewJavaScriptCall call) onCall;

  /// Navigations to other sites (opened in the system browser instead).
  void Function(Uri uri)? onExternal;

  final ValueNotifier<bool> isOpen = ValueNotifier(false);
  Webview? _w;

  String get origin => server.origin;

  static const _prefKey = 'web_window';

  /// Separate window by default on Windows; `TORBOXSTRM_WEB_WINDOW=1` tries it elsewhere.
  static Future<bool> enabled() async {
    if (Platform.environment['TORBOXSTRM_WEB_WINDOW'] == '1') return true;
    if (!Platform.isWindows) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefKey) ?? true;
  }

  static Future<void> setEnabled(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKey, on);
  }

  static String get _profile {
    if (Platform.isWindows) return '${Platform.environment['LOCALAPPDATA']}\\TorBoxSTRM\\WebWindow';
    return '${Platform.environment['HOME']}/.local/share/torbox-strm/web-window';
  }

  String _shim() =>
      '''
(() => {
  if (location.origin !== ${jsonEncode(origin)} || window.webviewAll) return;
  const dw = window.desktopWebview;
  if (!dw) return;
  let seq = 0;
  const waiting = new Map();
  dw.addEventListener('torboxReply', (r) => {
    const done = r && waiting.get(r.id);
    if (done) { waiting.delete(r.id); done(r.result); }
  });
  dw.addEventListener('torboxEvent', (e) => {
    if (window.TorBoxStrmBridge) window.TorBoxStrmBridge.event(e);
  });
  Object.defineProperty(window, 'TorBoxStrmApp', {value: Object.freeze({v: $bridgeVersion, platform: ${jsonEncode(Platform.operatingSystem)}})});
  Object.defineProperty(window, 'webviewAll', {value: Object.freeze({
    callHandler(name, msg) {
      const id = ++seq;
      return new Promise((resolve) => {
        waiting.set(id, resolve);
        dw.postMessage('torboxCall', {id, name: String(name), msg});
        setTimeout(() => { if (waiting.delete(id)) resolve({ok: false, error: 'App không phản hồi'}); }, 15000);
      });
    },
  })});
})();
''';

  Future<void> open() async {
    final w = _w;
    if (w != null) {
      await w.launch(server.toString());
      return;
    }
    if (!await WebviewWindow.isWebviewAvailable()) {
      throw StateError('Máy chưa có Microsoft Edge WebView2 Runtime');
    }
    final created = await WebviewWindow.create(
      configuration: CreateConfiguration(
        windowWidth: 1280,
        windowHeight: 800,
        title: 'TorBox STRM',
        // added with a server code: keep the address out of the title bar
        titleBar: TitleBarOptions(showHost: !ServerStore.hidden),
        openMaximized: true,
        brightness: Brightness.dark,
        windows: WindowsWebviewOptions(userDataFolder: _profile, denyCameraAndMicrophone: true),
      ),
    );
    _w = created;
    isOpen.value = true;
    await created.addScriptToExecuteOnDocumentCreated(_shim());
    created.addJavaScriptMessageHandler('torboxCall', _onMessage);
    await created.setOnUrlRequestCallback(_allow);
    created.onLoadError.listen((e) => appLog('web window load error ${e.kind.name}: ${e.description}'));
    unawaited(
      created.onClose.then((_) {
        appLog('web window closed');
        if (identical(_w, created)) {
          _w = null;
          isOpen.value = false;
        }
      }),
    );
    appLog('web window: load $origin');
    await created.launch(server.toString());
  }

  bool _allow(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    if ((scheme == 'http' || scheme == 'https') && uri.origin == origin) return true;
    if (scheme == 'about' || scheme == 'blob' || scheme == 'data') return true;
    if (scheme == 'http' || scheme == 'https') onExternal?.call(uri);
    return false;
  }

  Future<void> _onMessage(JavaScriptMessage m) async {
    final w = _w;
    final data = m.data;
    if (w == null || data is! Map || m.origin != origin) {
      appLog('web window: refused a message from ${m.origin}');
      return;
    }
    final id = data['id'];
    Object? result;
    try {
      result = await onCall(
        WebViewJavaScriptCall(
          arguments: [data['msg']],
          world: WebViewJavaScriptWorld.page,
          cancelled: Completer<void>().future,
          sourceUrl: m.url?.toString() ?? '$origin/',
          sourceOrigin: m.origin,
          isMainFrame: true,
        ),
      );
    } catch (e) {
      result = {'ok': false, 'error': '$e'};
    }
    try {
      await w.postMessage('torboxReply', {'id': id, 'result': result}, targetOrigin: origin);
    } catch (e) {
      appLog('web window reply: $e');
    }
  }

  /// App → page (`window.TorBoxStrmBridge.event`).
  Future<void> send(Map<String, Object?> event) async {
    try {
      await _w?.postMessage('torboxEvent', event, targetOrigin: origin);
    } catch (e) {
      debugPrint('web window event failed: $e');
    }
  }

  Future<void> reload() async => _w?.reload();
  Future<void> back() async => _w?.back();
  Future<void> home() async => _w?.launch(server.toString());

  /// A page of the server, e.g. `logout`.
  Future<void> go(String path) async => _w?.launch(server.resolve(path).toString());

  Future<void> close() async {
    final w = _w;
    _w = null;
    isOpen.value = false;
    await w?.close();
  }
}
