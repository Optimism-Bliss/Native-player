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
import '../player/playback_controller.dart';
import '../player/player_screen.dart';
import '../settings.dart';
import '../tv/protocol.dart';
import '../tv/remote_screen.dart';
import '../tv/sender.dart';
import '../util/fullscreen.dart';
import '../util/tv_mode.dart';
import '../update/update_ui.dart';
import '../update/updater.dart';
import '../util/log.dart';
import 'connect_screen.dart';
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
    // Quiet update check shortly after start (GitHub Releases, at most every 6 h).
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (mounted) checkForUpdate(context, automatic: true);
    });
    Updater.currentVersion().then((v) => mounted ? setState(() => _version = v) : null);
    if (_canCast) _initTv();
  }

  // ---------------- Play on TV ----------------

  Future<void> _initTv() async {
    final tv = await PairedTv.load();
    if (mounted) setState(() => _tv = tv);
    if (!Platform.isAndroid) return;
    // pairing links: torboxstrm://pair?... from the TV's QR page
    _intentChannel.setMethodCallHandler((call) async {
      if (call.method == 'link' && call.arguments is String) await _pairFromLink(call.arguments as String);
      return null;
    });
    try {
      final link = await _intentChannel.invokeMethod<String>('initialLink');
      if (link != null) await _pairFromLink(link);
    } catch (e) {
      appLog('initial link: $e');
    }
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

  Future<void> _openRemote() async {
    final session = _tvSession;
    final tv = _tv;
    if (session == null || tv == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TvRemoteScreen(session: session, tvName: tv.name),
      ),
    );
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
      // the web window is the app's face; the player window waits in the taskbar
      // the app window is shown after its first frame; minimizing earlier is undone
      for (var i = 0; i < 50 && !await windowManager.isVisible(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await windowManager.minimize();
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
    await step('script', () async {
      await _web.tryAddUserScript(
        WebViewUserScript(
          source:
              'window.TorBoxStrmApp=Object.freeze({v:$bridgeVersion,platform:${jsonEncode(_platform)},tv:$isTvDevice});',
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
            setState(() => _loadError = e.description.isEmpty ? 'Lỗi tải trang (${e.errorCode})' : e.description);
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

  Future<void> _showLog() async {
    final text = readLogTail();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nhật ký'),
        content: SizedBox(
          width: 720,
          height: 420,
          child: SingleChildScrollView(
            reverse: true,
            child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: '$logFilePath\n$text')),
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
      if (_playerOpen) return {'ok': false, 'error': 'Trình phát đang mở'};
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

  Future<void> _openPlayer(PlayRequest request) async {
    _playerOpen = true;
    // web UI in its own window: bring the player's window to the front
    if (_external) {
      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (e) {
        appLog('focus player window: $e');
      }
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
    // back to the web window
    if (_external && _window!.isOpen.value) {
      try {
        await windowManager.minimize();
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
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ConnectScreen(initial: widget.server)));
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

  Future<void> _showAppMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(widget.server.scheme == 'https' ? IconsaxPlusLinear.lock_1 : IconsaxPlusLinear.unlock),
              title: Text(widget.server.host),
              subtitle: Text(_version.isEmpty ? 'TorBox STRM' : 'TorBox STRM $_version'),
            ),
            const Divider(height: 1),
            for (final (value, icon, label) in const [
              ('reload', IconsaxPlusLinear.refresh, 'Tải lại trang'),
              ('home', IconsaxPlusLinear.home_2, 'Về trang chủ'),
              ('server', IconsaxPlusLinear.global_edit, 'Đổi máy chủ'),
              ('signout', IconsaxPlusLinear.logout, 'Đăng xuất'),
              ('update', IconsaxPlusLinear.refresh_circle, 'Kiểm tra cập nhật'),
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
      case 'quit':
        await SystemNavigatorPop.pop();
      default:
        await _onTvMenu(choice);
    }
  }

  List<Widget> _tvMenuTiles(BuildContext context) => [
    const Divider(height: 1),
    if (_tvSession?.running == true)
      ListTile(
        leading: const Icon(IconsaxPlusLinear.monitor_recorder),
        title: Text('Điều khiển ${_tv?.name ?? 'TV'}'),
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
                                  'Không tải được ${widget.server.host}',
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
              widget.server.host,
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
              if (_tvSession?.running == true)
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
