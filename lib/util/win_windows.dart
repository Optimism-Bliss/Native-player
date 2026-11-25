import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'log.dart';

/// Windows only: the web UI's own window (desktop_webview_window, class
/// "WebviewWindow"). While the player plays it is minimized, so the player
/// window is the only one on screen; z-order tricks (always on top) did not
/// bring the player above it on every PC.
class WebWindowNative {
  static final DynamicLibrary? _user32 = Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;

  static final int Function(Pointer<Utf16>, Pointer<Utf16>) _findWindow = _user32!
      .lookupFunction<IntPtr Function(Pointer<Utf16>, Pointer<Utf16>), int Function(Pointer<Utf16>, Pointer<Utf16>)>(
        'FindWindowW',
      );
  static final int Function(int, int) _showWindow = _user32!
      .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('ShowWindow');

  static const _swMinimize = 6;
  static const _swRestore = 9;

  static int _handle() {
    final cls = 'WebviewWindow'.toNativeUtf16();
    try {
      return _findWindow(cls, nullptr);
    } finally {
      malloc.free(cls);
    }
  }

  static void _show(int cmd, String what) {
    if (!Platform.isWindows) return;
    try {
      final h = _handle();
      if (h == 0) return appLog('web window: not found to $what');
      _showWindow(h, cmd);
    } catch (e) {
      appLog('web window $what: $e');
    }
  }

  static void minimize() => _show(_swMinimize, 'minimize');
  static void restore() => _show(_swRestore, 'restore');
}
