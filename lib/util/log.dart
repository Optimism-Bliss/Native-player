import 'dart:io';

import 'package:flutter/foundation.dart';

import 'fullscreen.dart';

/// Desktop builds have no console, so problems are also written to
/// %LOCALAPPDATA%\TorBoxSTRM\torbox-strm.log (Windows) or
/// ~/.local/state/torbox-strm.log (Linux). Android uses logcat.
String get logFilePath {
  final dir = Platform.isWindows
      ? '${Platform.environment['LOCALAPPDATA']}\\TorBoxSTRM'
      : '${Platform.environment['HOME']}/.local/state';
  return '$dir${Platform.pathSeparator}torbox-strm.log';
}

/// Last [lines] lines of the log file (desktop), for the in-app log viewer.
String readLogTail([int lines = 200]) {
  try {
    final all = File(logFilePath).readAsLinesSync();
    return all.skip(all.length > lines ? all.length - lines : 0).join('\n');
  } catch (e) {
    return 'Chưa có nhật ký ($e)';
  }
}

void appLog(String message) {
  debugPrint(message);
  if (!isDesktop) return;
  try {
    final file = File(logFilePath);
    file.parent.createSync(recursive: true);
    if (file.existsSync() && file.lengthSync() > 512 * 1024) file.deleteSync();
    file.writeAsStringSync('${DateTime.now().toIso8601String()} $message\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}

/// Set at startup when the platform WebView cannot work (e.g. no WebView2
/// runtime on Windows); the browser screen shows it instead of a blank page.
String? webViewProblem;
