import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'log.dart';

final class _Rect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

/// Windows only: one app window. The web UI's WebView2 window (desktop_webview_window, class
/// "WebviewWindow") becomes a child of the Flutter window and fills its client area. Playback
/// hides that child, so the player (drawn by Flutter) is simply what the window shows; closing
/// the player shows the page again. No second top-level window, no always-on-top, no z-order
/// fights: minimize, Win+D, Alt+Tab and the taskbar all treat the app as one window.
class WebWindowNative {
  static final DynamicLibrary? _user32 = Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;
  static final DynamicLibrary? _kernel32 = Platform.isWindows ? DynamicLibrary.open('kernel32.dll') : null;

  static final _findWindowEx = _user32!
      .lookupFunction<
        IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
        int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
      >('FindWindowExW');
  static final _threadProcessId = _user32!
      .lookupFunction<Uint32 Function(IntPtr, Pointer<Uint32>), int Function(int, Pointer<Uint32>)>(
        'GetWindowThreadProcessId',
      );
  static final _currentProcessId = _kernel32!.lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');
  static final _showWindow = _user32!.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
    'ShowWindow',
  );
  static final _getLong = _user32!.lookupFunction<IntPtr Function(IntPtr, Int32), int Function(int, int)>(
    'GetWindowLongPtrW',
  );
  static final _setLong = _user32!.lookupFunction<IntPtr Function(IntPtr, Int32, IntPtr), int Function(int, int, int)>(
    'SetWindowLongPtrW',
  );
  static final _setParent = _user32!.lookupFunction<IntPtr Function(IntPtr, IntPtr), int Function(int, int)>(
    'SetParent',
  );
  static final _clientRect = _user32!
      .lookupFunction<Int32 Function(IntPtr, Pointer<_Rect>), int Function(int, Pointer<_Rect>)>('GetClientRect');
  static final _setPos = _user32!
      .lookupFunction<
        Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
        int Function(int, int, int, int, int, int, int)
      >('SetWindowPos');
  static final _isWindow = _user32!.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindow');
  static final _setFocus = _user32!.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('SetFocus');

  static const _swHide = 0;
  static const _swShow = 5;
  static const _gwlStyle = -16;
  static const _gwlExStyle = -20;
  static const _wsChild = 0x40000000;
  static const _wsPopup = 0x80000000;
  static const _wsVisible = 0x10000000;
  static const _wsClipSiblings = 0x04000000;
  static const _wsOverlappedWindow = 0x00CF0000; // caption, sysmenu, thick frame, min/max boxes
  static const _wsMinMax = 0x21000000; // WS_MINIMIZE | WS_MAXIMIZE (opened maximized)
  static const _wsExAppWindow = 0x00040000;
  static const _swpNoZOrder = 0x0004;
  static const _swpNoActivate = 0x0010;
  static const _swpFrameChanged = 0x0020;

  static int _web = 0;
  static int _main = 0;
  static Timer? _fit;
  static int _w = -1, _h = -1;

  /// The page fills the app window (true once [embed] worked).
  static bool get embedded => _web != 0 && _main != 0;

  /// This process's top-level window of [cls], 0 when none.
  static int _find(String cls) {
    final name = cls.toNativeUtf16();
    final pid = calloc<Uint32>();
    try {
      final me = _currentProcessId();
      var h = 0;
      while (true) {
        h = _findWindowEx(0, h, name, nullptr);
        if (h == 0) return 0;
        _threadProcessId(h, pid);
        if (pid.value == me) return h;
      }
    } finally {
      malloc.free(name);
      calloc.free(pid);
    }
  }

  /// Puts the web window inside the app window. Returns false (nothing changed) when either
  /// window cannot be found; the caller keeps the two-window behaviour then.
  static Future<bool> embed() async {
    if (!Platform.isWindows) return false;
    try {
      // the WebView window appears a moment after create(); wait for it
      var web = 0;
      for (var i = 0; i < 40 && web == 0; i++) {
        web = _find('WebviewWindow');
        if (web == 0) await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final main = _find('FLUTTER_RUNNER_WIN32_WINDOW');
      if (web == 0 || main == 0) {
        appLog('single window: not found (web $web, app $main)');
        return false;
      }
      final style = _getLong(web, _gwlStyle);
      _setLong(
        web,
        _gwlStyle,
        (style & ~(_wsPopup | _wsOverlappedWindow | _wsMinMax)) | _wsChild | _wsVisible | _wsClipSiblings,
      );
      _setLong(web, _gwlExStyle, _getLong(web, _gwlExStyle) & ~_wsExAppWindow);
      _setParent(web, main);
      _web = web;
      _main = main;
      _w = _h = -1;
      fit();
      // follow the app window's size (maximize, restore, drag, DPI change)
      _fit?.cancel();
      _fit = Timer.periodic(const Duration(milliseconds: 250), (_) => fit());
      appLog('single window: web page embedded in the app window');
      return true;
    } catch (e) {
      appLog('single window: $e');
      return false;
    }
  }

  /// Sizes the page to the app window's client area.
  static void fit() {
    if (!embedded) return;
    if (_isWindow(_web) == 0) {
      _web = 0;
      _fit?.cancel();
      return;
    }
    final r = calloc<_Rect>();
    try {
      _clientRect(_main, r);
      final w = r.ref.right - r.ref.left, h = r.ref.bottom - r.ref.top;
      if (w == _w && h == _h) return;
      _w = w;
      _h = h;
      if (w <= 0 || h <= 0) return; // minimized
      _setPos(_web, 0, 0, 0, w, h, _swpNoZOrder | _swpNoActivate | _swpFrameChanged);
    } finally {
      calloc.free(r);
    }
  }

  /// Player or app menu on screen: the page steps aside (Flutter draws underneath it).
  static void hidePage() {
    if (embedded) _showWindow(_web, _swHide);
  }

  /// Back to the page, with the keyboard.
  static void showPage() {
    if (!embedded) return;
    _w = _h = -1;
    fit();
    _showWindow(_web, _swShow);
    _setFocus(_web);
  }

  // Two-window fallback (embedding failed): the web window is minimized while the player plays.
  static void minimize() {
    if (embedded || !Platform.isWindows) return;
    final h = _find('WebviewWindow');
    if (h != 0) _showWindow(h, 6);
  }

  static void restore() {
    if (embedded || !Platform.isWindows) return;
    final h = _find('WebviewWindow');
    if (h != 0) _showWindow(h, 9);
  }
}
