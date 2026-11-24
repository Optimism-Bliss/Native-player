import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'package:webview_all_windows/webview_all_windows.dart';

import 'screens/browser_screen.dart';
import 'screens/connect_screen.dart';
import 'settings.dart';
import 'theme.dart';
import 'util/fullscreen.dart';
import 'util/log.dart';

Future<void> main() async {
  runZonedGuarded(_start, (error, stack) => appLog('uncaught: $error\n$stack'));
}

Future<void> _start() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    appLog('flutter: ${details.exceptionAsString()}\n${details.stack}');
  };
  appLog('start ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
  MediaKit.ensureInitialized();
  if (isDesktop) {
    await windowManager.ensureInitialized();
    // Not awaited: the Linux runner only maps the window after Flutter's first
    // frame, so waiting here before runApp() would deadlock.
    unawaited(
      windowManager.waitUntilReadyToShow(
        const WindowOptions(title: 'TorBox STRM', minimumSize: Size(720, 480), size: Size(1280, 800), center: true),
        () async {
          await windowManager.show();
          await windowManager.focus();
        },
      ),
    );
  }
  if (Platform.isWindows) await prepareWindowsWebView();
  final server = await ServerStore.load();
  runApp(TorboxStrmApp(server: server));
}

class TorboxStrmApp extends StatelessWidget {
  const TorboxStrmApp({super.key, this.server});
  final Uri? server;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TorBox STRM',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: server == null ? const ConnectScreen() : BrowserScreen(server: server!),
    );
  }
}

/// WebView2 keeps its profile in a folder we own (not next to the exe, which
/// may be read-only), and a missing runtime is reported instead of a blank page.
Future<void> prepareWindowsWebView() async {
  try {
    final version = await WindowsWebViewController.getWebViewVersion();
    appLog('WebView2 runtime: ${version ?? 'missing'}');
    if (version == null || version.isEmpty) {
      webViewProblem = 'Máy chưa có Microsoft Edge WebView2 Runtime. Tải tại https://go.microsoft.com/fwlink/p/?LinkId=2124703 rồi mở lại app.';
      return;
    }
    final data = '${Platform.environment['LOCALAPPDATA']}\\TorBoxSTRM\\WebView2';
    await WindowsWebViewController.ensureEnvironment(userDataPath: data);
  } catch (e, st) {
    appLog('WebView2 setup failed: $e\n$st');
    webViewProblem = 'Không khởi tạo được WebView2: $e';
  }
}
