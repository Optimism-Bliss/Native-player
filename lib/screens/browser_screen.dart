import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_all/webview_all.dart';
import 'package:webview_all_android/webview_all_android.dart';
import 'package:window_manager/window_manager.dart';

import '../bridge.dart';
import '../player/decode_prefs.dart';
import '../player/playback_controller.dart';
import '../player/player_screen.dart';
import '../connect_code.dart';
import '../settings.dart';
import '../tv/protocol.dart';
import '../tv/remote_screen.dart';
import '../tv/sender.dart';
import '../tv/tv_input.dart';
import '../util/fullscreen.dart';
import '../util/tv_mode.dart';
import '../update/update_ui.dart';
import '../update/updater.dart';
import '../util/links.dart';
import '../util/log.dart';
import 'connect_screen.dart';
import 'role_screen.dart';
import 'web_window.dart';

/// The TorBox STRM web UI inside a WebView. The page itself handles login
/// (session cookie), browsing and search; "▶" buttons call back into the app
/// through the `torboxStrm` handler, which only the server's origin may use.
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key, required this.server});
  final Uri server;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  // Linux (WebKitGTK) keeps cookies only in a named profile; without one the
  // web login is lost on every restart. Android and WebView2 persist by default.
  late final WebViewController _web = WebViewController.fromPlatformCreationParams(
    PlatformWebViewControllerCreationParams(profileName: Platform.isLinux ? 'torbox-strm' : null),
  );
  late final String _origin = widget.server.origin;
  int _progress = 0;
  String? _loadError;
  bool _playerOpen = false;
  String _version = '';
  bool _loaded = false;
  AppLifecycleListener? _lifecycle;

  /// Windows: the web UI runs in its own native window (see web_window.dart).
  WebWindow? _window;
  bool get _external => _window != null;

  /// "Play on TV": the paired TV and the playback running on it (phones / desktop only).
  PairedTv? _tv;
  TvSession? _tvSession;
  bool get _canCast => !isTvDevice;

  static String get _platform => Platform.isAndroid
      ? 'android'
      : Platform.isWindows
      ? 'windows'
      : Platform.isLinux
      ? 'linux'
      : defaultTargetPlatform.name;

  @override
  void initState() {
    super.initState();
    _start();
    // Quiet update check shortly after start and whenever the app comes back
    // to the foreground (GitHub Releases, at most every 30 min).
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (mounted) checkForUpdate(context, automatic: true);
    });
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (mounted && !_playerOpen) checkForUpdate(context, automatic: true);
      },
    );
    Updater.currentVersion().then((v) => mounted ? setState(() => _version = v) : null);
    if (_canCast) _initTv();
  }

  // ---------------- Play on TV ----------------

  Future<void> _initTv() async {
    final tv = await PairedTv.load();
    if (mounted) setState(() => _tv = tv);
    if (!Platform.isAndroid && !Platform.isIOS) return;
    // pairing links (torboxstrm://pair?... from the TV's QR page), server
    // codes (torboxstrm://connect?c=... from the server's QR) and TV logins
    // (torboxstrm://device?c=... from a TV's login page) while running
    _links = AppLinks.stream.listen(_onLink);
    for (final l in AppLinks.take((l) => PairLink.parse(l) != null)) {
      await _pairFromLink(l);
    }
    for (final l in AppLinks.take((l) => deviceLoginCode(l) != null)) {
      await _approveDevice(deviceLoginCode(l)!);
    }
  }

  /// A TV (or another device) shows a login QR: open this server's confirmation
  /// page in the signed-in web view, so approving it is a single tap.
  Future<void> _approveDevice(String code) async {
    if (_external || !mounted) return;
    appLog('device login: opening approval');
    await _web.loadRequest(widget.server.replace(path: '/device', queryParameters: {'c': code}));
  }

  StreamSubscription<String>? _links;

  Future<void> _onLink(String raw) async {
    if (PairLink.parse(raw) != null) return _pairFromLink(raw);
    final device = deviceLoginCode(raw);
    if (device != null) return _approveDevice(device);
    final code = codeFromLink(raw);
    final server = code == null ? null : decodeServerCode(code);
    if (server == null || !mounted) return;
    if (server.origin == widget.server.origin) {
      await ServerStore.save(widget.server, viaCode: code);
      if (mounted) setState(() {});
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Đổi máy chủ?'),
        content: const Text('Mã vừa quét là của một máy chủ khác. Chuyển sang máy chủ đó?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Không')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Chuyển')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ServerStore.save(server, viaCode: code);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => BrowserScreen(server: server)));
  }

  Future<void> _pairFromLink(String raw) async {
    final link = PairLink.parse(raw);
    if (link == null) {
      _snack('Liên kết kết nối TV không hợp lệ');
      return;
    }
    await _pair(link);
  }

  Future<void> _pair(PairLink link) async {
    try {
      final tv = await TvClient.pair(link);
      await PairedTv.save(tv);
      // the TV gets this server too (as a server code: its address stays hidden there)
      final c = TvClient(tv);
      try {
        await c.setServer(ServerStore.code ?? encodeServerCode(widget.server));
      } on TvError catch (e) {
        appLog('send server to TV: ${e.message}');
      } finally {
        c.close();
      }
      if (!mounted) return;
      setState(() => _tv = tv);
      _snack('Đã kết nối ${tv.name}. Bấm ▶ trên phim để chọn "Phát trên TV".');
    } on TvError catch (e) {
      if (mounted) _snack(e.message);
    }
  }

  /// Manual pairing: the address and code shown on the TV.
  Future<void> _pairManually() async {
    final address = TextEditingController(text: _tv == null ? '' : '${_tv!.host}:${_tv!.port}');
    final code = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kết nối TV'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Mở app TorBox STRM trên TV (cùng mạng Wi-Fi), rồi nhập địa chỉ và mã hiện trên TV.'),
            const SizedBox(height: 12),
            _TvFinder(onPick: (tv) => address.text = '${tv.host}:${tv.port}'),
            TextField(
              controller: address,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'Địa chỉ TV', hintText: '192.168.1.20:$tvPort'),
            ),
            TextField(
              controller: code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(labelText: 'Mã 6 số'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Kết nối')),
        ],
      ),
    );
    if (ok != true) return;
    final parts = address.text.trim().split(':');
    final link = PairLink.parse(
      PairLink(
        host: parts.first,
        port: parts.length > 1 ? int.tryParse(parts[1]) ?? tvPort : tvPort,
        code: code.text.trim(),
      ).toUri().toString(),
    );
    if (link == null) {
      _snack('Địa chỉ phải là IP trong mạng nhà (vd 192.168.1.20) và mã gồm 6 số');
      return;
    }
    await _pair(link);
  }

  Future<void> _forgetTv() async {
    _tvSession?.stop();
    await PairedTv.save(null);
    if (mounted) setState(() => _tv = null);
  }

  /// Where to play: this device or the paired TV.
  Future<void> _chooseTarget(PlayRequest request, Object raw) async {
    final tv = _tv!;
    final where = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                request.queue[request.index].title,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ListTile(
              leading: const Icon(IconsaxPlusLinear.mobile),
              title: const Text('Phát trên thiết bị này'),
              onTap: () => Navigator.pop(context, 'here'),
            ),
            ListTile(
              leading: const Icon(IconsaxPlusLinear.monitor),
              title: Text('Phát trên ${tv.name}'),
              onTap: () => Navigator.pop(context, 'tv'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || where == null) return;
    if (where == 'here') {
      if (!_playerOpen) await _openPlayer(request);
      return;
    }
    await _castToTv(tv, raw);
  }

  Future<void> _castToTv(PairedTv tv, Object raw) async {
    final old = _tvSession;
    final session = (old != null && old.running && old.client.tv.token == tv.token)
        ? old
        : TvSession(client: TvClient(tv), toPage: _sendEvent);
    try {
      await session.client.play(widget.server, raw);
    } on TvError catch (e) {
      _snack(e.message);
      return;
    }
    if (old != null && old != session) old.stop();
    _tvSession = session;
    if (!session.running) {
      unawaited(session.start().whenComplete(() => mounted ? setState(() {}) : null));
    }
    if (mounted) setState(() {});
    await _openRemote();
  }

  /// Remote for the paired TV; also when nothing plays there (typing into
  /// the TV's text fields).
  Future<void> _openRemote() async {
    final tv = _tv;
    if (tv == null || !mounted) return;
    var session = _tvSession;
    final own = session == null || !session.running;
    if (own) {
      session = TvSession(client: TvClient(tv), toPage: _sendEvent);
      _tvSession = session;
      unawaited(session.start());
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TvRemoteScreen(session: session!, tvName: tv.name),
      ),
    );
    // opened only for the keyboard: stop polling when nothing plays on the TV
    if (own && !session.state.value.active) session.stop();
  }

  Future<void> _start() async {
    if (isDesktop && await WebWindow.enabled()) {
      await _openWindow();
    } else {
      await _setup();
    }
  }

  Future<void> _openWindow() async {
    var w = _window;
    if (w == null) {
      w = _window = WebWindow(server: widget.server, onCall: _onBridgeCall)
        ..onExternal = (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
      w.isOpen.addListener(_onWindowOpenChanged);
    }
    if (mounted) setState(() => _loadError = null);
    try {
      await w.open();
      _loaded = true;
      FullscreenHelper.escapeClosesPlayer = true;
      // the web window is the app's face; the player window comes back for playback
      // main() shows the app window after its first frame; hiding earlier is undone
      await appWindowShown.future.timeout(const Duration(seconds: 10), onTimeout: () {});
      // hidden, not minimized: one window (the web one) in the taskbar while browsing
      await windowManager.hide();
    } catch (e, st) {
      appLog('web window failed: $e\n$st');
      if (mounted) setState(() => _loadError = 'Không mở được cửa sổ web: $e');
    }
  }

  /// Web window closed: show the app window (menu, reopen, update, log).
  void _onWindowOpenChanged() {
    if (_window?.isOpen.value == false) {
      windowManager.show().then((_) => windowManager.focus()).catchError((_) {});
    }
  }

  Future<void> _reload() async => _external ? _window!.reload() : _web.reload();
  Future<void> _home() async => _external ? _window!.home() : _web.loadRequest(widget.server);
  Future<void> _goBack() async {
    if (_external) return _window!.back();
    if (await _web.canGoBack()) await _web.goBack();
  }

  /// Each step is independent: one unsupported call on a platform must not
  /// stop the page from loading (that left Windows on a blank screen).
  Future<void> _setup() async {
    if (webViewProblem != null) {
      setState(() => _loadError = webViewProblem);
      return;
    }
    Future<void> step(String name, Future<void> Function() run) async {
      try {
        await run();
      } catch (e, st) {
        appLog('webview $name failed: $e\n$st');
      }
    }

    await step('javascript', () => _web.setJavaScriptMode(JavaScriptMode.unrestricted));
    await step('background', () => _web.setBackgroundColor(const Color(0xFF0B0D12)));
    await step('media', () => _web.setMediaPlaybackRequiresUserGesture(false));
    // Android WebView defaults differ from Chrome: the plugin turns the
    // viewport meta tag off (useWideViewPort=false + overview mode, so a page
    // wider than the screen is zoomed out and gains empty margins) and the
    // WebView multiplies all text by the system font scale. Make it lay the
    // page out like the mobile browser does.
    if (Platform.isAndroid) {
      final android = _web.platform as AndroidWebViewController;
      await step('viewport', () => android.setUseWideViewPort(true));
      await step('text zoom', () => android.setTextZoom(100));
    }
    // Handlers and user scripts must be registered before the first load.
    await step('bridge', () async {
      final ok = await _web.addJavaScriptHandler(
        bridgeHandlerName,
        onCall: _onBridgeCall,
        accessPolicy: WebViewJavaScriptAccessPolicy.origins({_origin}),
      );
      if (ok) return;
      // WebView2 (Windows) cannot enforce an origin policy natively, so the
      // handler is refused. Register it without one; _onBridgeCall checks the
      // caller itself (origin from the URL WebView2 reports for the page).
      appLog('bridge: origin policy unsupported here, checking callers in the app');
      final fallback = await _web.addJavaScriptHandler(
        bridgeHandlerName,
        onCall: _onBridgeCall,
        accessPolicy: const WebViewJavaScriptAccessPolicy.unrestricted(),
      );
      if (!fallback) appLog('bridge handler could not be registered');
    });
    if (isTvDevice) {
      // which text field has focus, so a paired phone can type into it (tv_input.dart)
      await step('tv input', () async {
        await _web.tryAddUserScript(const WebViewUserScript(source: _tvFieldScript));
      });
    }
    await step('script', () async {
      await _web.tryAddUserScript(
        WebViewUserScript(
          source:
              'window.TorBoxStrmApp=Object.freeze({v:$bridgeVersion,platform:${jsonEncode(_platform)},tv:$isTvDevice,screen:${screenJs()}});',
        ),
      );
    });
    await step('navigation', () async {
      await _web.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigation,
          onProgress: (p) => mounted ? setState(() => _progress = p) : null,
          onPageStarted: (url) {
            appLog('page started $url');
            // the focused field belonged to the previous page
            if (isTvDevice) TvInput.blur();
            if (mounted) setState(() => _loadError = null);
          },
          onPageFinished: (url) {
            appLog('page finished $url');
            _loaded = true;
            _logViewport();
          },
          onWebResourceError: (e) {
            if (e.isForMainFrame == false || !mounted) return;
            appLog('page error ${e.errorCode}: ${e.description}');
            setState(
              () => _loadError = e.description.isEmpty
                  ? 'Lỗi tải trang (${e.errorCode})'
                  : ServerStore.redact(e.description),
            );
          },
        ),
      );
    });
    // Nothing visible after a while (seen on some Windows PCs): say so instead
    // of leaving an empty window, and point at the log.
    Future<void>.delayed(const Duration(seconds: 20), () {
      if (!mounted || _loaded || _loadError != null) return;
      appLog('page not loaded after 20 s (progress $_progress%)');
      setState(() => _loadError = 'Trang không phản hồi sau 20 giây (tiến độ $_progress%).');
    });
    appLog('load ${widget.server.origin}');
    try {
      await _web.loadRequest(widget.server);
    } catch (e, st) {
      appLog('webview load failed: $e\n$st');
      final busy = '$e'.contains('in use by another process');
      if (mounted) {
        setState(
          () => _loadError = busy
              ? 'App đang mở ở một cửa sổ khác (hoặc chưa tắt hẳn). Đóng cửa sổ đó rồi mở lại.'
              : 'Không mở được trang: $e',
        );
      }
    }
  }

  static String? _originOf(String? url) {
    final u = url == null ? null : Uri.tryParse(url);
    if (u == null || (u.scheme != 'https' && u.scheme != 'http') || u.host.isEmpty) return null;
    return u.origin;
  }

  Future<void> _showLog({String? text, String title = 'Nhật ký', String? path}) async {
    final body = text ?? readLogTail();
    final where = path ?? logFilePath;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 720,
          height: 420,
          child: SingleChildScrollView(
            reverse: true,
            child: SelectableText(body, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: '$where\n$body')),
            child: const Text('Chép'),
          ),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Đóng')),
        ],
      ),
    );
  }

  /// One line in the app log per page: what the page actually sees, to
  /// compare the app with the phone's browser when the layout differs.
  Future<void> _logViewport() async {
    try {
      final r = await _web.runJavaScriptReturningResult(
        "(()=>{const d=document.createElement('div');d.style.cssText='position:fixed;"
        "padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)';"
        "document.body.appendChild(d);const c=getComputedStyle(d);"
        "const s=[c.paddingTop,c.paddingRight,c.paddingBottom,c.paddingLeft].join(' ');d.remove();"
        "return 'w='+innerWidth+' h='+innerHeight+' dpr='+devicePixelRatio+' scroll='+document.documentElement.scrollWidth"
        "+' scale='+(window.visualViewport?visualViewport.scale:1)+' font='+getComputedStyle(document.body).fontSize+' safe='+s})()",
      );
      appLog('viewport $r');
    } catch (e) {
      appLog('viewport metrics failed: $e');
    }
  }

  /// Stay on the configured server; everything else opens in the system browser.
  static const _intentChannel = MethodChannel('torboxstrm/intent');

  /// Stay on the configured server; other web pages open in the system
  /// browser, and player links (intent://, vlc://, mpv-handler://…) open the
  /// external app the user picked in the web UI's "▾" menu.
  NavigationDecision _onNavigation(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.prevent;
    final scheme = uri.scheme.toLowerCase();
    if ((scheme == 'http' || scheme == 'https') && uri.origin == _origin) {
      return NavigationDecision.navigate;
    }
    if (scheme == 'about' || scheme == 'blob' || scheme == 'data') return NavigationDecision.navigate;
    if (!request.isMainFrame) return NavigationDecision.prevent;
    if (scheme == 'http' || scheme == 'https') {
      launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (scheme == 'javascript' || scheme == 'file' || scheme == 'content') {
      // never handed to the system
    } else if (scheme == 'intent') {
      if (Platform.isAndroid) _openIntent(request.url);
    } else {
      _openExternal(uri);
    }
    return NavigationDecision.prevent;
  }

  Future<void> _openIntent(String url) async {
    try {
      final ok = await _intentChannel.invokeMethod<bool>('open', {'uri': url}) ?? false;
      if (!ok && mounted) _snack('Máy chưa cài app này');
    } catch (e) {
      appLog('intent failed: $e');
    }
  }

  Future<void> _openExternal(Uri uri) async {
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) _snack('Không có app nào mở được liên kết ${uri.scheme}://');
    } catch (e) {
      if (mounted) _snack('Không có app nào mở được liên kết ${uri.scheme}://');
    }
  }

  void _snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// Subtitle lists and content from the page, for the open player.
  final StreamController<Object> _toPlayer = StreamController.broadcast();

  @override
  void dispose() {
    if (isTvDevice) TvInput.blur();
    _links?.cancel();
    _lifecycle?.dispose();
    _window?.isOpen.removeListener(_onWindowOpenChanged);
    _window?.close();
    _toPlayer.close();
    super.dispose();
  }

  Object? _onBridgeCall(WebViewJavaScriptCall call) {
    // Native access policy where the platform has one; always checked here too.
    final origin = call.sourceOrigin ?? _originOf(call.sourceUrl);
    if (call.isMainFrame != true || origin != _origin) {
      appLog('bridge: refused a call from ${origin ?? 'an unknown page'}');
      return {'ok': false, 'error': 'Nguồn lệnh không được phép'};
    }
    final raw = call.arguments.isEmpty ? null : call.arguments.first;
    final type = raw is Map ? raw['type'] : null;
    try {
      // the page answers the player that asked: the TV's while it plays there
      final tv = _tvSession;
      if (!_playerOpen && tv != null && tv.running && (type == 'subs' || type == 'subText' || type == 'subSearch')) {
        tv.client.page(raw!).catchError((Object e) => appLog('tv page relay: $e'));
        return {'ok': true};
      }
      if (type == 'tvField' && isTvDevice) {
        final f = raw is Map && raw['active'] == true ? TvField.fromJson(raw) : null;
        if (f == null) {
          TvInput.blur();
        } else {
          TvInput.focus(f, (action, text) async {
            final r = await _web.runJavaScriptReturningResult(
              'window.__tbsInput?window.__tbsInput(${jsonEncode(action)},${jsonEncode(text)}):false',
            );
            return r == true || r.toString() == 'true' || r.toString() == '1';
          });
        }
        return {'ok': true};
      }
      if (type == 'menu') {
        _openMenuFromPage();
        return {'ok': true};
      }
      switch (type) {
        case 'subs':
          _toPlayer.add(SubtitleList.parse(raw as Map));
          return {'ok': true};
        case 'subText':
          _toPlayer.add(SubtitleText.parse(raw as Map));
          return {'ok': true};
        case 'subSearch':
          _toPlayer.add(SubtitleSearch.parse(raw as Map));
          return {'ok': true};
      }
      final request = PlayRequest.parse(raw, widget.server);
      if (_playerOpen) {
        // Windows: the player may sit behind the web window; bring it back instead of refusing
        if (_external) unawaited(_raisePlayerWindow());
        return {'ok': false, 'error': 'Trình phát đang mở'};
      }
      if (_canCast && _tv != null) {
        _chooseTarget(request, raw!);
      } else {
        _openPlayer(request);
      }
      return {'ok': true};
    } on FormatException catch (e) {
      return {'ok': false, 'error': e.message};
    }
  }

  /// Web UI in its own window (Windows): the app window plays. Windows does not
  /// let a hidden window simply take the foreground, so it stays above the web
  /// window (always on top) while the player is open, in full screen.
  Future<void> _raisePlayerWindow() async {
    try {
      await windowManager.show();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.focus();
      await FullscreenHelper.set(true);
    } catch (e) {
      appLog('raise player window: $e');
    }
  }

  Future<void> _openPlayer(PlayRequest request) async {
    _playerOpen = true;
    if (_external) {
      await _raisePlayerWindow();
      if (!mounted) return;
    }
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, _, _) => PlayerScreen(
          request: request,
          page: PageLink(incoming: _toPlayer.stream, send: _sendEvent),
          onProgress: (key, pos, dur) => _sendEvent({
            'type': 'progress',
            'key': key,
            'pos': pos.inMilliseconds / 1000,
            'dur': dur.inMilliseconds / 1000,
          }),
          onClosed: (key) => _sendEvent({'type': 'closed', 'key': key}),
        ),
        transitionsBuilder: (_, anim, _, child) => FadeTransition(opacity: anim, child: child),
      ),
    );
    _playerOpen = false;
    if (_external) {
      try {
        await windowManager.setAlwaysOnTop(false);
        // back to the web window (PlayerScreen already left fullscreen)
        if (_window!.isOpen.value) await windowManager.hide();
      } catch (_) {}
    }
  }

  Future<void> _sendEvent(Map<String, Object?> event) async {
    if (_external) return _window!.send(event);
    try {
      await _web.runJavaScript('window.TorBoxStrmBridge&&window.TorBoxStrmBridge.event(${jsonEncode(event)})');
    } catch (e) {
      debugPrint('bridge event failed: $e');
    }
  }

  Future<void> _changeServer() async {
    await ServerStore.clear();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ConnectScreen(initial: widget.server, initialCode: ServerStore.code),
      ),
    );
  }

  Future<void> _signOut() async {
    if (_external) {
      if (!_window!.isOpen.value) await _window!.open();
      // the server clears its session cookie and shows the login page
      return _window!.go('logout');
    }
    await WebViewCookieManager().clearCookies();
    await _web.clearLocalStorage();
    await _web.loadRequest(widget.server);
  }

  /// Android: Back walks the page history; on the first page it opens the
  /// app menu (reload, change server, sign out, quit) instead of leaving.
  Future<void> _onBack() async {
    if (await _web.canGoBack()) {
      await _web.goBack();
    } else if (mounted) {
      await _showAppMenu();
    }
  }

  /// "📱 Ứng dụng" in the page's account menu: phones have no toolbar, and
  /// in the Windows web window the app window is hidden.
  Future<void> _openMenuFromPage() async {
    if (_external) {
      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
    }
    if (mounted) await _showAppMenu();
    // menu done: back to the web window only, no empty app window left behind it
    if (_external && !_playerOpen && (_window?.isOpen.value ?? false)) {
      try {
        await windowManager.hide();
      } catch (_) {}
    }
  }

  Future<void> _showAppMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(widget.server.scheme == 'https' ? IconsaxPlusLinear.lock_1 : IconsaxPlusLinear.unlock),
              title: Text(ServerStore.label(widget.server)),
              subtitle: Text(_version.isEmpty ? 'TorBox STRM' : 'TorBox STRM $_version'),
            ),
            const Divider(height: 1),
            for (final (value, icon, label) in [
              ('reload', IconsaxPlusLinear.refresh, 'Tải lại trang'),
              ('home', IconsaxPlusLinear.home_2, 'Về trang chủ'),
              ('server', IconsaxPlusLinear.global_edit, 'Đổi máy chủ'),
              ('signout', IconsaxPlusLinear.logout, 'Đăng xuất'),
              ('update', IconsaxPlusLinear.refresh_circle, 'Kiểm tra cập nhật'),
              ('log', IconsaxPlusLinear.document_text, 'Nhật ký'),
              if (Platform.isAndroid) ('role', IconsaxPlusLinear.monitor_mobbile, 'Dùng máy này làm TV'),
              if (DecodePrefs.available)
                (
                  'decode',
                  IconsaxPlusLinear.cpu,
                  DecodePrefs.direct ? 'Giải mã: trực tiếp (đổi sang GPU)' : 'Giải mã: GPU (đổi sang trực tiếp)',
                ),
              ('quit', IconsaxPlusLinear.close_circle, 'Thoát app'),
            ])
              ListTile(leading: Icon(icon), title: Text(label), onTap: () => Navigator.pop(context, value)),
            if (_canCast) ..._tvMenuTiles(context),
          ],
        ),
      ),
    );
    switch (choice) {
      case 'reload':
        await _reload();
      case 'home':
        await _home();
      case 'server':
        await _changeServer();
      case 'signout':
        await _signOut();
      case 'update':
        if (mounted) await checkForUpdate(context);
      case 'log':
        await _showLog();
      case 'role':
        await saveRole(tv: true);
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute<void>(builder: (_) => RoleScreen.homeFor(widget.server)),
            (_) => false,
          );
        }
      case 'decode':
        await DecodePrefs.set(!DecodePrefs.direct);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                DecodePrefs.direct
                    ? 'Giải mã trực tiếp: mượt hơn trên TV box, phụ đề hiện dạng chữ thường. Mở lại app để áp dụng.'
                    : 'Giải mã qua GPU: phụ đề ASS đủ kiểu chữ. Mở lại app để áp dụng.',
              ),
            ),
          );
        }
      case 'quit':
        await SystemNavigatorPop.pop();
      default:
        await _onTvMenu(choice);
    }
  }

  List<Widget> _tvMenuTiles(BuildContext context) => [
    const Divider(height: 1),
    if (_tv != null)
      ListTile(
        leading: const Icon(IconsaxPlusLinear.monitor_recorder),
        title: Text('Remote ${_tv?.name ?? 'TV'} (điều khiển, gõ chữ)'),
        onTap: () => Navigator.pop(context, 'tv-remote'),
      ),
    ListTile(
      leading: const Icon(IconsaxPlusLinear.monitor),
      title: Text(_tv == null ? 'Kết nối TV' : 'Kết nối TV khác'),
      subtitle: _tv == null ? null : Text('Đang dùng: ${_tv!.name} (${_tv!.host})'),
      onTap: () => Navigator.pop(context, 'tv-pair'),
    ),
    if (_tv != null)
      ListTile(
        leading: const Icon(IconsaxPlusLinear.document_text),
        title: Text('Xem nhật ký ${_tv?.name ?? 'TV'}'),
        onTap: () => Navigator.pop(context, 'tv-log'),
      ),
    if (_tv != null)
      ListTile(
        leading: const Icon(IconsaxPlusLinear.monitor_mobbile),
        title: const Text('Ngắt kết nối TV'),
        onTap: () => Navigator.pop(context, 'tv-forget'),
      ),
  ];

  Future<void> _onTvMenu(String? choice) async {
    switch (choice) {
      case 'tv-remote':
        await _openRemote();
      case 'tv-pair':
        await _pairManually();
      case 'tv-forget':
        await _forgetTv();
      case 'tv-log':
        await _showTvLog();
    }
  }

  Future<void> _showTvLog() async {
    final tv = _tv;
    if (tv == null) return;
    final client = TvClient(tv);
    try {
      final text = await client.log();
      if (!mounted) return;
      await _showLog(
        text: text.isEmpty ? 'TV chưa có nhật ký.' : text,
        title: 'Nhật ký ${tv.name}',
        path: 'TV ${tv.name}',
      );
    } on TvError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        // Same colour as the web UI header, so the status bar area blends in.
        backgroundColor: const Color(0xFF0B0D12),
        body: SafeArea(
          child: Column(
            children: [
              // Desktop keeps a compact navigation bar (no system Back button there);
              // on phones the page's own header is the only chrome.
              if (isDesktop) _toolbar(context),
              Expanded(
                child: Stack(
                  children: [
                    if (_external) _windowPanel(context) else _webView(),
                    if (!_external && _progress < 100)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: LinearProgressIndicator(value: _progress / 100, minHeight: 2),
                      ),
                    if (_loadError != null)
                      ColoredBox(
                        color: scheme.surface,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(IconsaxPlusLinear.wifi_square, size: 48, color: scheme.error),
                                const SizedBox(height: 12),
                                Text(
                                  'Không tải được ${ServerStore.label(widget.server)}',
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 4),
                                Text(_loadError!, textAlign: TextAlign.center),
                                const SizedBox(height: 16),
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    FilledButton.icon(
                                      onPressed: _external ? _openWindow : () => _web.reload(),
                                      icon: const Icon(IconsaxPlusLinear.refresh),
                                      label: const Text('Thử lại'),
                                    ),
                                    OutlinedButton(onPressed: _changeServer, child: const Text('Đổi máy chủ')),
                                    if (isDesktop) TextButton(onPressed: _showLog, child: const Text('Nhật ký')),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// On a TV the remote's arrows and OK belong to the page (its own TV mode
  /// moves focus between cards); Flutter's default shortcuts would take them
  /// for widget focus traversal instead. DoNothingAndStopPropagationIntent
  /// leaves the key unhandled, so it reaches the WebView.
  Widget _webView() {
    final view = WebViewWidget(controller: _web);
    if (!isTvDevice) return view;
    const pass = DoNothingAndStopPropagationIntent();
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowUp): pass,
        SingleActivator(LogicalKeyboardKey.arrowDown): pass,
        SingleActivator(LogicalKeyboardKey.arrowLeft): pass,
        SingleActivator(LogicalKeyboardKey.arrowRight): pass,
        SingleActivator(LogicalKeyboardKey.select): pass,
        SingleActivator(LogicalKeyboardKey.enter): pass,
      },
      child: view,
    );
  }

  /// Main window while the web UI is in its own window.
  Widget _windowPanel(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ValueListenableBuilder<bool>(
      valueListenable: _window!.isOpen,
      builder: (context, open, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(IconsaxPlusLinear.global, size: 48, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text(open ? 'Trang web đang mở ở cửa sổ riêng' : 'Cửa sổ web đã đóng', style: text.titleLarge),
              const SizedBox(height: 8),
              Text(
                'Duyệt phim trong cửa sổ đó. Bấm ▶ trên phim thì trình phát mở ở cửa sổ này.',
                style: text.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _openWindow,
                icon: const Icon(IconsaxPlusLinear.export_3),
                label: Text(open ? 'Về trang chủ' : 'Mở lại cửa sổ web'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          IconButton(
            tooltip: 'Quay lại',
            iconSize: 20,
            onPressed: _goBack,
            icon: const Icon(IconsaxPlusLinear.arrow_left_1),
          ),
          IconButton(tooltip: 'Trang chủ', iconSize: 20, onPressed: _home, icon: const Icon(IconsaxPlusLinear.home_2)),
          IconButton(tooltip: 'Tải lại', iconSize: 20, onPressed: _reload, icon: const Icon(IconsaxPlusLinear.refresh)),
          const SizedBox(width: 8),
          Icon(widget.server.scheme == 'https' ? IconsaxPlusLinear.lock_1 : IconsaxPlusLinear.unlock, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              ServerStore.label(widget.server),
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Tuỳ chọn',
            icon: const Icon(IconsaxPlusLinear.more, size: 20),
            onSelected: (v) => switch (v) {
              'signout' => _signOut(),
              'server' => _changeServer(),
              'update' => checkForUpdate(context),
              'log' => _showLog(),
              'web-window' => WebWindow.setEnabled(!_external).then((_) => _snack('Đã lưu — mở lại app để áp dụng')),
              _ => _onTvMenu(v),
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'signout',
                child: ListTile(leading: Icon(IconsaxPlusLinear.logout), title: Text('Đăng xuất')),
              ),
              const PopupMenuItem(
                value: 'server',
                child: ListTile(leading: Icon(IconsaxPlusLinear.global_edit), title: Text('Đổi máy chủ')),
              ),
              PopupMenuItem(
                value: 'update',
                child: ListTile(
                  leading: const Icon(IconsaxPlusLinear.refresh_circle),
                  title: const Text('Kiểm tra cập nhật'),
                  subtitle: _version.isEmpty ? null : Text('Bản $_version'),
                ),
              ),
              if (_tv != null)
                const PopupMenuItem(
                  value: 'tv-remote',
                  child: ListTile(leading: Icon(IconsaxPlusLinear.monitor_recorder), title: Text('Điều khiển TV')),
                ),
              PopupMenuItem(
                value: 'tv-pair',
                child: ListTile(
                  leading: const Icon(IconsaxPlusLinear.monitor),
                  title: Text(_tv == null ? 'Kết nối TV' : 'Kết nối TV khác'),
                ),
              ),
              if (_tv != null)
                const PopupMenuItem(
                  value: 'tv-forget',
                  child: ListTile(leading: Icon(IconsaxPlusLinear.monitor_mobbile), title: Text('Ngắt kết nối TV')),
                ),
              if (Platform.isWindows)
                PopupMenuItem(
                  value: 'web-window',
                  child: ListTile(
                    leading: const Icon(IconsaxPlusLinear.export_3),
                    title: Text(_external ? 'Hiện web trong cửa sổ app' : 'Mở web ở cửa sổ riêng'),
                    subtitle: const Text('Áp dụng khi mở lại app'),
                  ),
                ),
              const PopupMenuItem(
                value: 'log',
                child: ListTile(leading: Icon(IconsaxPlusLinear.document_text), title: Text('Nhật ký')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Leaves the app on Android when the WebView has no history left.
class SystemNavigatorPop {
  static Future<void> pop() async {
    if (Platform.isAndroid) {
      await const MethodChannel('flutter/platform').invokeMethod<void>('SystemNavigator.pop');
    }
  }
}

/// "Tìm TV trong mạng": lists TVs answering the LAN broadcast; tapping one
/// fills in its address (the code on the TV is still needed).
class _TvFinder extends StatefulWidget {
  const _TvFinder({required this.onPick});
  final ValueChanged<FoundTv> onPick;

  @override
  State<_TvFinder> createState() => _TvFinderState();
}

class _TvFinderState extends State<_TvFinder> {
  bool _busy = false;
  List<FoundTv>? _found;

  Future<void> _scan() async {
    setState(() => _busy = true);
    final found = await discoverTvs();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _found = found;
    });
    if (found.length == 1) widget.onPick(found.first);
  }

  @override
  Widget build(BuildContext context) {
    final found = _found;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          onPressed: _busy ? null : _scan,
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(IconsaxPlusLinear.search_normal_1, size: 18),
          label: const Text('Tìm TV trong mạng'),
        ),
        if (found != null && found.isEmpty)
          const Text('Không thấy TV nào. TV phải đang mở app, cùng mạng Wi-Fi.', style: TextStyle(fontSize: 12)),
        for (final tv in found ?? const <FoundTv>[])
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(IconsaxPlusLinear.monitor, size: 20),
            title: Text(tv.name),
            subtitle: Text('${tv.host}:${tv.port}'),
            onTap: () => widget.onPick(tv),
          ),
      ],
    );
  }
}

/// TV only: reports the focused text field to the app (bridge message
/// `tvField`) and lets the app type into it (`window.__tbsInput`). Values are
/// set through the native setter and announced with input/change events, so
/// the page sees them like typing.
const _tvFieldScript = r'''
(() => {
  if (window.__tbsInput) return;
  const typed = (el) => el && ((el.tagName === 'INPUT' && !['checkbox','radio','button','submit','reset','range','color','file','hidden','image'].includes(el.type)) || el.tagName === 'TEXTAREA' || el.isContentEditable);
  const send = (msg) => { try { window.webviewAll && window.webviewAll.callHandler('torboxStrm', msg); } catch (_) {} };
  const label = (el) => ((el.labels && el.labels[0] && el.labels[0].innerText) || el.getAttribute('aria-label') || el.placeholder || el.name || '').trim().slice(0, 80);
  const report = (el) => typed(el)
    ? send({type: 'tvField', active: true, kind: el.type || 'text', label: label(el), value: el.type === 'password' ? '' : String(el.value || '').slice(0, 500)})
    : send({type: 'tvField', active: false});
  document.addEventListener('focusin', (e) => report(e.target), true);
  document.addEventListener('focusout', () => setTimeout(() => report(document.activeElement), 80), true);
  window.__tbsInput = (action, text) => {
    const el = document.activeElement;
    if (!typed(el)) return false;
    if (action === 'set') {
      const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
      setter.call(el, text);
      el.dispatchEvent(new Event('input', {bubbles: true}));
      el.dispatchEvent(new Event('change', {bubbles: true}));
    } else if (action === 'enter') {
      const ev = new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true});
      const handled = !el.dispatchEvent(ev);
      if (!handled && el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
    }
    return true;
  };
})();
''';
