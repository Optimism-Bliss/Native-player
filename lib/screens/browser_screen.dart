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

import '../bridge.dart';
import '../player/playback_controller.dart';
import '../player/player_screen.dart';
import '../settings.dart';
import '../util/fullscreen.dart';
import '../update/update_ui.dart';
import '../update/updater.dart';
import '../util/log.dart';
import 'connect_screen.dart';

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
    _setup();
    // Quiet update check shortly after start (GitHub Releases, at most every 6 h).
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (mounted) checkForUpdate(context, automatic: true);
    });
    Updater.currentVersion().then((v) => mounted ? setState(() => _version = v) : null);
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
      if (!ok) appLog('bridge handler could not be registered with an origin policy');
    });
    await step('script', () async {
      await _web.tryAddUserScript(
        WebViewUserScript(
          source: 'window.TorBoxStrmApp=Object.freeze({v:$bridgeVersion,platform:${jsonEncode(_platform)}});',
        ),
      );
    });
    await step('navigation', () async {
      await _web.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigation,
          onProgress: (p) => mounted ? setState(() => _progress = p) : null,
          onPageStarted: (_) => mounted ? setState(() => _loadError = null) : null,
          onPageFinished: (_) => _logViewport(),
          onWebResourceError: (e) {
            if (e.isForMainFrame == false || !mounted) return;
            appLog('page error ${e.errorCode}: ${e.description}');
            setState(() => _loadError = e.description.isEmpty ? 'Lỗi tải trang (${e.errorCode})' : e.description);
          },
        ),
      );
    });
    try {
      await _web.loadRequest(widget.server);
    } catch (e, st) {
      appLog('webview load failed: $e\n$st');
      if (mounted) setState(() => _loadError = 'Không mở được trang: $e');
    }
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
    _toPlayer.close();
    super.dispose();
  }

  Object? _onBridgeCall(WebViewJavaScriptCall call) {
    // The access policy already enforces origin + main frame natively; check again.
    if (call.isMainFrame != true || call.sourceOrigin != _origin) {
      return {'ok': false, 'error': 'Nguồn lệnh không được phép'};
    }
    final raw = call.arguments.isEmpty ? null : call.arguments.first;
    final type = raw is Map ? raw['type'] : null;
    try {
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
      _openPlayer(request);
      return {'ok': true};
    } on FormatException catch (e) {
      return {'ok': false, 'error': e.message};
    }
  }

  Future<void> _openPlayer(PlayRequest request) async {
    _playerOpen = true;
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
  }

  Future<void> _sendEvent(Map<String, Object?> event) async {
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
          ],
        ),
      ),
    );
    switch (choice) {
      case 'reload':
        await _web.reload();
      case 'home':
        await _web.loadRequest(widget.server);
      case 'server':
        await _changeServer();
      case 'signout':
        await _signOut();
      case 'update':
        if (mounted) await checkForUpdate(context);
      case 'quit':
        await SystemNavigatorPop.pop();
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
                    WebViewWidget(controller: _web),
                    if (_progress < 100)
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
                                      onPressed: () => _web.reload(),
                                      icon: const Icon(IconsaxPlusLinear.refresh),
                                      label: const Text('Thử lại'),
                                    ),
                                    OutlinedButton(onPressed: _changeServer, child: const Text('Đổi máy chủ')),
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

  Widget _toolbar(BuildContext context) {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          IconButton(
            tooltip: 'Quay lại',
            iconSize: 20,
            onPressed: () async {
              if (await _web.canGoBack()) _web.goBack();
            },
            icon: const Icon(IconsaxPlusLinear.arrow_left_1),
          ),
          IconButton(
            tooltip: 'Trang chủ',
            iconSize: 20,
            onPressed: () => _web.loadRequest(widget.server),
            icon: const Icon(IconsaxPlusLinear.home_2),
          ),
          IconButton(
            tooltip: 'Tải lại',
            iconSize: 20,
            onPressed: () => _web.reload(),
            icon: const Icon(IconsaxPlusLinear.refresh),
          ),
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
              _ => null,
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
