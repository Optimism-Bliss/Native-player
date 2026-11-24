import 'dart:io';

import 'package:flutter/foundation.dart';

import 'fullscreen.dart';

/// Desktop builds have no console, so problems are also written to
/// %LOCALAPPDATA%\TorBoxSTRM\torbox-strm.log (Windows) or
/// ~/.local/state/torbox-strm.log (Linux). Android uses logcat.
void appLog(String message) {
  debugPrint(message);
  if (!isDesktop) return;
  try {
    final dir = Platform.isWindows
        ? '${Platform.environment['LOCALAPPDATA']}\\TorBoxSTRM'
        : '${Platform.environment['HOME']}/.local/state';
    Directory(dir).createSync(recursive: true);
    final file = File('$dir${Platform.pathSeparator}torbox-strm.log');
    if (file.existsSync() && file.lengthSync() > 512 * 1024) file.deleteSync();
    file.writeAsStringSync('${DateTime.now().toIso8601String()} $message\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}

/// Set at startup when the platform WebView cannot work (e.g. no WebView2
/// runtime on Windows); the browser screen shows it instead of a blank page.
String? webViewProblem;
