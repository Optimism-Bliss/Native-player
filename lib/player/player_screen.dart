import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:iconsax_plus/iconsax_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../bridge.dart';
import '../util/device_controls.dart';
import '../util/format.dart';
import '../util/fullscreen.dart';
import '../util/log.dart';
import '../util/tv_mode.dart';
import 'playback_controller.dart';
import 'widgets/progress_bar.dart';
import 'widgets/track_sheets.dart';

/// Full-screen player. Layout and interactions follow Fladder's DesktopControls:
/// gradient top bar with the title, a bottom panel with progress, info chips,
/// track buttons and a large tonal play button; mouse hover reveals controls,
/// touch uses tap / double-tap-to-seek.
/// Lets something outside the screen (the TV receiver) drive the open player.
class PlayerRemote {
  PlaybackController? controller;
  Future<void> Function()? close;
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.request,
    required this.onProgress,
    required this.onClosed,
    this.page,
    this.remote,
  });

  final PageLink? page;
  final PlayerRemote? remote;

  final PlayRequest request;
  final ProgressCallback onProgress;
  final ValueChanged<String> onClosed;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final PlaybackController c = PlaybackController(
    request: widget.request,
    onProgress: widget.onProgress,
    page: widget.page,
  );
  late final Future<void> _ready = c.init();
  final FocusNode _focus = FocusNode();
  final FocusNode _playFocus = FocusNode(debugLabel: 'play');

  bool _overlay = true;
  Timer? _hideTimer;
  bool _closing = false;

  /// Desktop: the video texture is taken out of the tree while the window
  /// changes size (fullscreen on/off, closing). Resizing the Windows window
  /// while libmpv keeps drawing into the texture froze the whole app
  /// ("Not Responding", last frame stuck, stream still downloading).
  bool _videoVisible = true;
  bool _resizing = false;
  ({bool forward, int seconds})? _seekFlash;
  Timer? _seekFlashTimer;
  double? _volumeBeforeMute;

  /// Picture mode, kept for the next sessions (like most players).
  static VideoFit _fitMode = VideoFit.contain;
  VideoFit get _fit => _fitMode;
  set _fit(VideoFit v) => setState(() => _fitMode = v);
  double _pinchStart = 1;

  // One-finger vertical swipes (touch): left half = brightness, right half = volume.
  String? _swipeSide;
  double _swipeValue = 0;
  bool _swipeIsPinch = false;
  final ValueNotifier<({bool brightness, double value})?> _level = ValueNotifier(null);
  Timer? _levelTimer;
  bool _brightnessChanged = false;

  bool get _touch => !isDesktop;

  @override
  void initState() {
    super.initState();
    FullscreenHelper.enterPlayer();
    _restartHideTimer();
    widget.remote
      ?..controller = c
      ..close = _close;
    // Resumed from elsewhere (TV remote, phone): let the controls fade again.
    _ready.then((_) {
      if (!mounted) return;
      _playingSub = c.player.stream.playing.listen((playing) {
        if (playing && _overlay) _restartHideTimer();
      });
    }, onError: (_) {});
  }

  StreamSubscription<bool>? _playingSub;

  @override
  void dispose() {
    if (widget.remote?.controller == c) {
      widget.remote!
        ..controller = null
        ..close = null;
    }
    _playFocus.dispose();
    _playingSub?.cancel();
    _hideTimer?.cancel();
    _seekFlashTimer?.cancel();
    _focus.dispose();
    _levelTimer?.cancel();
    _paramsSub?.cancel();
    _level.dispose();
    // Brightness was only changed for this screen: hand it back to the system.
    if (_brightnessChanged) DeviceControls.setBrightness(null).catchError((_) {});
    if (!_closing) FullscreenHelper.exitPlayer();
    // Final progress is reported inside c.dispose(); then tell the page.
    _ready.then((_) async {
      final key = c.current.key;
      await c.dispose();
      widget.onClosed(key);
    }, onError: (Object e) => debugPrint('player init failed: $e'));
    super.dispose();
  }

  void _restartHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || !c.initialized) return;
      if (c.player.state.playing) _setOverlay(false);
    });
  }

  void _showOverlay([bool show = true]) {
    if (_overlay != show) _setOverlay(show);
    if (show) _restartHideTimer();
  }

  void _setOverlay(bool show) {
    setState(() => _overlay = show);
    // TV: hidden controls must not keep the D-pad focus
    if (!show && isTvDevice && _focus.canRequestFocus) _focus.requestFocus();
    if (c.initialized) c.raiseSubtitles(show);
  }

  /// Leave the player right away; libmpv is torn down in [dispose] after the
  /// route is gone, so no widget is still listening to the controller.
  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    appLog('player: close (fullscreen ${FullscreenHelper.isFullscreen.value})');
    if (isDesktop) {
      await _dropVideo();
      try {
        await c.player.pause().timeout(const Duration(seconds: 2));
      } catch (_) {}
      // Windows web window mode: the app window goes away anyway, so hide it
      // first; leaving fullscreen then happens on a hidden window.
      if (FullscreenHelper.escapeClosesPlayer) {
        try {
          await windowManager.hide();
        } catch (e) {
          appLog('player: hide window: $e');
        }
      }
    }
    await FullscreenHelper.exitPlayer();
    if (mounted) Navigator.of(context).pop();
  }

  /// Takes the video texture out of the tree and waits until a frame without
  /// it has been drawn.
  Future<void> _dropVideo() async {
    if (!mounted || !_videoVisible) return;
    setState(() => _videoVisible = false);
    // a hidden or minimized window draws no frame: do not wait forever
    await WidgetsBinding.instance.endOfFrame.timeout(const Duration(milliseconds: 500), onTimeout: () {});
  }

  /// Fullscreen on/off from the player (button, F/F11, double click).
  /// Windows web window mode: the player is fullscreen only (it sits over the
  /// minimized web window); a small player window there makes no sense.
  Future<void> _toggleFullscreen() async {
    if (isDesktop && FullscreenHelper.escapeClosesPlayer) return;
    if (!isDesktop) return FullscreenHelper.toggle();
    if (_resizing || _closing) return;
    _resizing = true;
    final to = !FullscreenHelper.isFullscreen.value;
    appLog('player: fullscreen -> $to');
    try {
      await _dropVideo();
      await FullscreenHelper.set(to);
      // let the window settle at its new size before the texture comes back
      await Future<void>.delayed(const Duration(milliseconds: 250));
    } catch (e) {
      appLog('player: fullscreen: $e');
    } finally {
      _resizing = false;
      if (mounted && !_closing) setState(() => _videoVisible = true);
    }
  }

  Future<void> _onScaleStart(ScaleStartDetails d) async {
    _pinchStart = 1;
    _swipeIsPinch = d.pointerCount > 1;
    _swipeSide = null;
    final size = MediaQuery.sizeOf(context);
    final y = d.localFocalPoint.dy;
    // Leave the screen edges to the system gestures (status/navigation bars).
    if (_swipeIsPinch || !DeviceControls.supported || y < size.height * 0.08 || y > size.height * 0.92) return;
    final side = d.localFocalPoint.dx < size.width / 2 ? 'brightness' : 'volume';
    try {
      _swipeValue = side == 'brightness' ? await DeviceControls.brightness() : await DeviceControls.volume();
      _swipeSide = side;
    } catch (e) {
      debugPrint('swipe $side unavailable: $e');
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount > 1 || _swipeIsPinch) {
      _swipeIsPinch = true;
      _pinchStart = d.scale;
      return;
    }
    final side = _swipeSide;
    if (side == null || d.focalPointDelta.dy.abs() < d.focalPointDelta.dx.abs()) return;
    // A swipe over ~70% of the screen height covers the whole range.
    _swipeValue = (_swipeValue - d.focalPointDelta.dy / (MediaQuery.sizeOf(context).height * 0.7)).clamp(0.0, 1.0);
    final brightness = side == 'brightness';
    if (brightness) {
      _brightnessChanged = true;
      DeviceControls.setBrightness(_swipeValue).catchError((_) {});
    } else {
      DeviceControls.setVolume(_swipeValue).catchError((_) {});
    }
    _level.value = (brightness: brightness, value: _swipeValue);
    _levelTimer?.cancel();
    _levelTimer = Timer(const Duration(milliseconds: 900), () => _level.value = null);
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_swipeIsPinch) {
      if (_pinchStart > 1.15 && _fit != VideoFit.cover) {
        _fit = VideoFit.cover;
        c.say(VideoFit.cover.label);
      } else if (_pinchStart < 0.87 && _fit != VideoFit.contain) {
        _fit = VideoFit.contain;
        c.say(VideoFit.contain.label);
      }
    }
    _swipeIsPinch = false;
    _swipeSide = null;
  }

  /// Vertical level bar shown while swiping, like Fladder's indicators.
  Widget _levelIndicator() {
    return ValueListenableBuilder<({bool brightness, double value})?>(
      valueListenable: _level,
      builder: (context, level, _) {
        final scheme = Theme.of(context).colorScheme;
        return IgnorePointer(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: level == null ? 0 : 1,
            child: level == null
                ? const SizedBox.shrink()
                : Align(
                    alignment: level.brightness ? const Alignment(-0.8, 0) : const Alignment(0.8, 0),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              level.brightness
                                  ? IconsaxPlusBold.sun_1
                                  : level.value == 0
                                  ? IconsaxPlusBold.volume_cross
                                  : IconsaxPlusBold.volume_high,
                              size: 22,
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              height: 140,
                              width: 8,
                              child: RotatedBox(
                                quarterTurns: 3,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: LinearProgressIndicator(
                                    value: level.value,
                                    backgroundColor: scheme.onSurface.withValues(alpha: 0.2),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text('${(level.value * 100).round()}', style: Theme.of(context).textTheme.labelLarge),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
        );
      },
    );
  }

  static const _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
  static String _rateLabel(double r) => r == r.roundToDouble() ? r.toStringAsFixed(0) : '$r';

  /// Playback speed via mpv (pitch is kept by mpv's audio-pitch-correction).
  Future<void> _pickSpeed() async {
    _restartHideTimer();
    final current = c.player.state.rate;
    final picked = await showModalBottomSheet<double>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Tốc độ phát', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final r in _rates)
                    ChoiceChip(
                      label: Text(r == 1 ? '1× (bình thường)' : '${_rateLabel(r)}×'),
                      selected: (current - r).abs() < 0.01,
                      onSelected: (_) => Navigator.pop(context, r),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) {
      await c.player.setRate(picked);
      c.say('Tốc độ ${_rateLabel(picked)}×');
    }
  }

  Future<void> _pickFit() async {
    _restartHideTimer();
    final picked = await showModalBottomSheet<VideoFit>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text('Tỉ lệ khung hình', style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final f in VideoFit.values)
              ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                selected: f == _fit,
                leading: Icon(f == _fit ? IconsaxPlusBold.tick_circle : IconsaxPlusLinear.record, size: 20),
                title: Text(f.label),
                subtitle: Text(f.hint),
                onTap: () => Navigator.pop(context, f),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) _fit = picked;
  }

  void _flashSeek(bool forward, int seconds) {
    _seekFlashTimer?.cancel();
    final previous = _seekFlash;
    final total = previous != null && previous.forward == forward ? previous.seconds + seconds : seconds;
    setState(() => _seekFlash = (forward: forward, seconds: total));
    _seekFlashTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekFlash = null);
    });
  }

  void _seek(int seconds) {
    c.seekRelative(Duration(seconds: seconds));
    _flashSeek(seconds > 0, seconds.abs());
  }

  Future<void> _setVolume(double v) => c.player.setVolume(v.clamp(0, 100));

  void _toggleMute() {
    final vol = c.player.state.volume;
    if (vol > 0) {
      _volumeBeforeMute = vol;
      _setVolume(0);
    } else {
      _setVolume(_volumeBeforeMute ?? 100);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final repeat = event is KeyRepeatEvent;
    void act(VoidCallback f) {
      f();
      _showOverlay();
    }

    if (isTvDevice) {
      final r = _onTvKey(key, repeat);
      if (r != null) return r;
    }

    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK || key == LogicalKeyboardKey.mediaPlayPause) {
      if (!repeat) act(c.player.playOrPause);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      act(() => _seek(-5));
    } else if (key == LogicalKeyboardKey.arrowRight) {
      act(() => _seek(5));
    } else if (key == LogicalKeyboardKey.keyJ) {
      act(() => _seek(-10));
    } else if (key == LogicalKeyboardKey.keyL) {
      act(() => _seek(30));
    } else if (key == LogicalKeyboardKey.arrowUp) {
      act(() => _setVolume(c.player.state.volume + 5));
    } else if (key == LogicalKeyboardKey.arrowDown) {
      act(() => _setVolume(c.player.state.volume - 5));
    } else if (key == LogicalKeyboardKey.keyM) {
      if (!repeat) act(_toggleMute);
    } else if (key == LogicalKeyboardKey.keyF || key == LogicalKeyboardKey.f11) {
      if (!repeat) _toggleFullscreen();
    } else if (key == LogicalKeyboardKey.keyN && !repeat) {
      if (c.hasNext) act(c.next);
    } else if (key == LogicalKeyboardKey.keyP && !repeat) {
      if (c.hasPrevious) act(c.previous);
    } else if (key == LogicalKeyboardKey.escape) {
      if (FullscreenHelper.isFullscreen.value && isDesktop && !FullscreenHelper.escapeClosesPlayer) {
        FullscreenHelper.set(false);
      } else {
        _close();
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  static final _select = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.gameButtonA,
  };
  static final _arrows = {
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
  };

  /// TV remote. Controls hidden: ◀ ▶ seek 10 s, OK / ▲ ▼ show the controls with
  /// the play button focused. Controls shown: the D-pad moves between buttons
  /// and OK presses the focused one. Back hides the controls first. null = not
  /// a TV-specific key (fall through to the common keys).
  KeyEventResult? _onTvKey(LogicalKeyboardKey key, bool repeat) {
    if (key == LogicalKeyboardKey.mediaFastForward) {
      _seek(30);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaRewind) {
      _seek(-10);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext) {
      if (!repeat && c.hasNext) c.next();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      if (!repeat && c.hasPrevious) c.previous();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlay) {
      c.player.play();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPause) {
      c.player.pause();
      return KeyEventResult.handled;
    }
    final navigable = _arrows.contains(key) || _select.contains(key);
    if (!navigable) return null;
    if (_overlay) {
      _restartHideTimer();
      // nothing focused yet: start on the play button
      if (FocusManager.instance.primaryFocus == _focus) {
        _playFocus.requestFocus();
        return KeyEventResult.handled;
      }
      // let focus traversal / the focused button handle it
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _seek(-10);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _seek(10);
    } else if (!repeat) {
      if (_select.contains(key)) c.player.playOrPause();
      _showOverlay();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _overlay) _playFocus.requestFocus();
      });
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (isTvDevice && _overlay && c.initialized && c.player.state.playing) {
          _setOverlay(false);
          return;
        }
        _close();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: FutureBuilder<void>(
          future: _ready,
          builder: (context, snap) {
            if (snap.hasError) {
              return _ErrorPanel(message: 'Không khởi tạo được trình phát: ${snap.error}', onClose: _close);
            }
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            return Focus(autofocus: true, focusNode: _focus, onKeyEvent: _onKey, child: _buildPlayer(context));
          },
        ),
      ),
    );
  }

  StreamSubscription<VideoParams>? _paramsSub;

  /// In "fill" mode the frame is wider/taller than the screen; tell the
  /// controller how much of it is cut off below so subtitles stay visible.
  void _syncFrameCrop() {
    if (!mounted || !c.initialized) return;
    final screen = MediaQuery.sizeOf(context);
    final v = c.player.state.videoParams;
    final w = (v.dw ?? v.w ?? 0).toDouble();
    final h = (v.dh ?? v.h ?? 0).toDouble();
    var hidden = 0.0;
    if (_fit == VideoFit.cover && w > 0 && h > 0 && screen.width > 0 && screen.height > 0) {
      final videoAspect = (v.aspect != null && v.aspect! > 0) ? v.aspect! : w / h;
      final screenAspect = screen.width / screen.height;
      // Video narrower than the screen: width fills, top and bottom are cut.
      if (videoAspect < screenAspect) hidden = (1 - videoAspect / screenAspect) / 2;
    }
    c.setFrameCrop(hidden);
  }

  Widget _buildPlayer(BuildContext context) {
    _paramsSub ??= c.player.stream.videoParams.listen((_) => _syncFrameCrop());
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncFrameCrop());
    return MouseRegion(
      cursor: _overlay ? SystemMouseCursors.basic : SystemMouseCursors.none,
      onHover: _touch ? null : (_) => _showOverlay(),
      onExit: _touch ? null : (_) => _showOverlay(false),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_videoVisible)
            Video(
              controller: c.video,
              controls: NoVideoControls,
              fill: Colors.black,
              fit: _fit.boxFit,
              aspectRatio: _fit.aspectRatio,
              // libass renders every subtitle format inside mpv (styled ASS included).
              subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
            )
          else
            const ColoredBox(color: Colors.black),
          _gestureLayer(),
          _centerStatus(),
          IgnorePointer(
            ignoring: !_overlay,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 350),
              opacity: _overlay ? 1 : 0,
              child: Column(children: [_topBar(context), const Spacer(), _bottomPanel(context)]),
            ),
          ),
          _seekIndicator(),
          if (_touch) _levelIndicator(),
          ValueListenableBuilder<String?>(
            valueListenable: c.notice,
            builder: (context, message, _) => IgnorePointer(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: message == null ? 0 : 1,
                child: Align(
                  alignment: const Alignment(0, -0.6),
                  child: message == null
                      ? const SizedBox.shrink()
                      : Card(
                          shape: const StadiumBorder(),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                            child: Text(message, style: Theme.of(context).textTheme.titleSmall),
                          ),
                        ),
                ),
              ),
            ),
          ),
          ValueListenableBuilder<String?>(
            valueListenable: c.error,
            builder: (context, err, _) => err == null
                ? const SizedBox.shrink()
                : _ErrorPanel(message: err, onRetry: c.retry, onClose: _close, onNext: c.hasNext ? c.next : null),
          ),
        ],
      ),
    );
  }

  Widget _gestureLayer() {
    if (_touch) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _showOverlay(!_overlay),
        onDoubleTapDown: (d) {
          final width = MediaQuery.sizeOf(context).width;
          final x = d.localPosition.dx;
          if (x < width * 0.4) {
            _seek(-10);
          } else if (x > width * 0.6) {
            _seek(10);
          } else {
            c.player.playOrPause();
          }
        },
        onDoubleTap: () {},
        // One recognizer for both: Flutter does not combine drag and scale.
        // Two fingers pinch (fill/fit), one finger swiping vertically sets
        // brightness (left half) or volume (right half).
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onScaleEnd: _onScaleEnd,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        c.player.playOrPause();
        _showOverlay();
        _focus.requestFocus();
      },
      onDoubleTap: _toggleFullscreen,
    );
  }

  Widget _centerStatus() {
    return IgnorePointer(
      ignoring: _touch,
      child: StreamBuilder<bool>(
        stream: c.player.stream.buffering,
        initialData: c.player.state.buffering,
        builder: (context, buffering) => StreamBuilder<bool>(
          stream: c.player.stream.playing,
          initialData: c.player.state.playing,
          builder: (context, playing) {
            final isBuffering = buffering.data ?? false;
            final isPlaying = playing.data ?? false;
            return Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (isBuffering)
                    ValueListenableBuilder<bool>(
                      valueListenable: c.recovering,
                      builder: (context, recovering, _) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: 64, height: 64, child: CircularProgressIndicator(strokeWidth: 5)),
                          if (recovering) ...[
                            const SizedBox(height: 16),
                            Text('Đang lấy lại link phát…', style: Theme.of(context).textTheme.titleMedium),
                          ],
                        ],
                      ),
                    ),
                  if (!_touch)
                    AnimatedScale(
                      scale: isPlaying || isBuffering ? 0 : 1,
                      curve: Curves.easeInOutCubicEmphasized,
                      duration: const Duration(milliseconds: 250),
                      child: IconButton.outlined(
                        onPressed: c.player.play,
                        isSelected: true,
                        iconSize: 65,
                        tooltip: 'Tiếp tục phát',
                        icon: const Icon(IconsaxPlusBold.play),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _seekIndicator() {
    final flash = _seekFlash;
    return IgnorePointer(
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: flash == null ? 0 : 1,
        child: Align(
          alignment: flash?.forward == false ? const Alignment(-0.6, 0) : const Alignment(0.6, 0),
          child: flash == null
              ? const SizedBox.shrink()
              : Card(
                  shape: const StadiumBorder(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(flash.forward ? IconsaxPlusLinear.forward : IconsaxPlusLinear.backward),
                        const SizedBox(width: 8),
                        Text(
                          '${flash.forward ? '+' : '-'}${flash.seconds} giây',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0.8), Colors.black.withValues(alpha: 0)],
        ),
      ),
      padding: EdgeInsets.fromLTRB(padding.left + 12, padding.top + 12, padding.right + 12, 32),
      child: Row(
        children: [
          IconButton(
            onPressed: _close,
            tooltip: 'Quay lại thư viện',
            icon: const Icon(IconsaxPlusLinear.arrow_left_1, size: 26),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: c.index,
              builder: (context, i, _) => _Title(title: widget.request.queue[i].title, logo: widget.request.logo),
            ),
          ),
          if (_touch) IconButton(onPressed: _close, tooltip: 'Dừng', icon: const Icon(IconsaxPlusLinear.close_square)),
        ],
      ),
    );
  }

  Widget _bottomPanel(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final phone = width < 600;
    final wide = width >= 960;
    final padding = MediaQuery.paddingOf(context);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withValues(alpha: 0.8), Colors.black.withValues(alpha: 0)],
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        padding.left + (phone ? 8 : 16),
        48,
        padding.right + (phone ? 8 : 16),
        padding.bottom + 12,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: phone ? 8 : 12),
            child: _progressSection(context),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Thông tin phát',
                      onPressed: () => showPlaybackInfo(context, c.player, c.active.value),
                      icon: const Icon(IconsaxPlusLinear.more),
                    ),
                    if (wide) ...[
                      Flexible(child: _trackChip(audio: false)),
                      const SizedBox(width: 4),
                      Flexible(child: _trackChip(audio: true)),
                    ] else ...[
                      IconButton(
                        tooltip: 'Phụ đề',
                        onPressed: () => showSubtitleSheet(context, c),
                        icon: const Icon(IconsaxPlusLinear.subtitle),
                      ),
                      IconButton(
                        tooltip: 'Âm thanh',
                        onPressed: () => showAudioSheet(context, c.player, c.active),
                        icon: const Icon(IconsaxPlusLinear.audio_square),
                      ),
                    ],
                  ],
                ),
              ),
              ..._transportButtons(phone),
              Expanded(
                flex: 2,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (!_touch)
                      IconButton(onPressed: _close, tooltip: 'Dừng', icon: const Icon(IconsaxPlusLinear.close_square)),
                    const Spacer(),
                    if (!_touch && !phone)
                      _VolumeSlider(player: c.player, onMute: _toggleMute, onChanged: _restartHideTimer),
                    StreamBuilder<double>(
                      stream: c.player.stream.rate,
                      initialData: c.player.state.rate,
                      builder: (context, snap) {
                        final rate = snap.data ?? 1;
                        return rate == 1
                            ? IconButton(
                                tooltip: 'Tốc độ phát',
                                onPressed: _pickSpeed,
                                icon: const Icon(IconsaxPlusLinear.timer_1),
                              )
                            : TextButton(onPressed: _pickSpeed, child: Text('${_rateLabel(rate)}×'));
                      },
                    ),
                    IconButton(
                      tooltip: 'Tỉ lệ khung hình: ${_fit.label}',
                      onPressed: _pickFit,
                      icon: const Icon(IconsaxPlusLinear.maximize_3),
                    ),
                    if (!(isDesktop && FullscreenHelper.escapeClosesPlayer))
                      ValueListenableBuilder<bool>(
                        valueListenable: FullscreenHelper.isFullscreen,
                        builder: (context, full, _) => IconButton(
                          tooltip: full ? 'Thoát toàn màn hình' : 'Toàn màn hình',
                          onPressed: _toggleFullscreen,
                          icon: Icon(full ? IconsaxPlusLinear.minus_square : IconsaxPlusLinear.maximize_4),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _transportButtons(bool phone) {
    final small = phone ? 24.0 : 30.0;
    final seek = phone ? 32.0 : 40.0;
    return [
      ValueListenableBuilder<int>(
        valueListenable: c.index,
        builder: (context, i, _) => IconButton(
          tooltip: c.hasPrevious ? widget.request.queue[i - 1].title : null,
          onPressed: c.hasPrevious ? c.previous : null,
          iconSize: small,
          icon: const Icon(IconsaxPlusLinear.previous),
        ),
      ),
      IconButton(
        tooltip: '-10 giây',
        onPressed: () => _seek(-10),
        iconSize: seek,
        icon: const _SeekIcon(forward: false, seconds: 10),
      ),
      StreamBuilder<bool>(
        stream: c.player.stream.playing,
        initialData: c.player.state.playing,
        builder: (context, snap) => IconButton.filledTonal(
          focusNode: _playFocus,
          iconSize: phone ? 32 : 38,
          tooltip: snap.data == true ? 'Tạm dừng' : 'Phát',
          onPressed: () {
            c.player.playOrPause();
            _restartHideTimer();
          },
          icon: Icon(snap.data == true ? IconsaxPlusBold.pause : IconsaxPlusBold.play),
        ),
      ),
      IconButton(
        tooltip: '+30 giây',
        onPressed: () => _seek(30),
        iconSize: seek,
        icon: const _SeekIcon(forward: true, seconds: 30),
      ),
      ValueListenableBuilder<int>(
        valueListenable: c.index,
        builder: (context, i, _) => IconButton(
          tooltip: c.hasNext ? widget.request.queue[i + 1].title : null,
          onPressed: c.hasNext ? c.next : null,
          iconSize: small,
          icon: const Icon(IconsaxPlusLinear.next),
        ),
      ),
    ].expand((w) => [w, SizedBox(width: phone ? 2 : 6)]).toList()..removeLast();
  }

  Widget _trackChip({required bool audio}) {
    return StreamBuilder<Tracks>(
      stream: c.player.stream.tracks,
      initialData: c.player.state.tracks,
      builder: (context, tracks) => ValueListenableBuilder<ActiveTracks>(
        valueListenable: c.active,
        builder: (context, act, _) {
          final all = tracks.data ?? c.player.state.tracks;
          final String label;
          if (audio) {
            final t = act.audioOf(all);
            label = t == null ? 'Không có' : shortTrackLabel(t.language, t.title ?? 'Audio ${t.id}');
          } else {
            final t = act.subtitleOf(all);
            label = t == null ? 'Tắt' : shortTrackLabel(t.language, t.title ?? 'Phụ đề ${t.id}');
          }
          return ElevatedButton.icon(
            onPressed: () => audio ? showAudioSheet(context, c.player, c.active) : showSubtitleSheet(context, c),
            icon: Icon(audio ? IconsaxPlusLinear.audio_square : IconsaxPlusLinear.subtitle),
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          );
        },
      ),
    );
  }

  Widget _progressSection(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return StreamBuilder<Duration>(
      stream: c.player.stream.position,
      initialData: c.player.state.position,
      builder: (context, posSnap) {
        final position = posSnap.data ?? Duration.zero;
        final state = c.player.state;
        final duration = state.duration;
        final remaining = duration - position;
        final rate = state.rate <= 0 ? 1.0 : state.rate;
        final endsAt = DateTime.now().add(Duration(milliseconds: (remaining.inMilliseconds / rate).round()));
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    duration > Duration.zero ? 'Kết thúc lúc ${formatClock(endsAt)}' : '',
                    style: text.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                _MediaInfoChips(
                  player: c.player,
                  active: c.active,
                  onTap: () => showPlaybackInfo(context, c.player, c.active.value),
                ),
              ],
            ),
            const SizedBox(height: 4),
            PlayerProgressBar(
              position: position,
              duration: duration,
              buffer: state.buffer,
              buffering: state.buffering,
              onSeek: (d) {
                c.player.seek(d);
                _restartHideTimer();
              },
              onInteraction: _restartHideTimer,
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(formatDuration(position), style: text.bodyMedium),
                Text('-${formatDuration(remaining.isNegative ? Duration.zero : remaining)}', style: text.bodyMedium),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// "4K · HEVC · HDR10" style chips, like Fladder's media info tag.
class _MediaInfoChips extends StatelessWidget {
  const _MediaInfoChips({required this.player, required this.active, required this.onTap});
  final Player player;
  final ValueListenable<ActiveTracks> active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<VideoParams>(
      stream: player.stream.videoParams,
      initialData: player.state.videoParams,
      builder: (context, snap) {
        final v = snap.data ?? player.state.videoParams;
        return ValueListenableBuilder<ActiveTracks>(
          valueListenable: active,
          builder: (context, act, _) {
            final videoTrack = act.videoOf(player.state.tracks);
            final chips = [
              resolutionLabel(v.w, v.h),
              codecLabel(videoTrack?.codec),
              hdrLabel(v.primaries, v.gamma),
            ].where((s) => s.isNotEmpty).toList();
            if (chips.isEmpty) return const SizedBox.shrink();
            return InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onTap,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(chips.join(' · ')),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _SeekIcon extends StatelessWidget {
  const _SeekIcon({required this.forward, required this.seconds});
  final bool forward;
  final int seconds;

  @override
  Widget build(BuildContext context) {
    final size = IconTheme.of(context).size ?? 32;
    return Stack(
      alignment: Alignment.center,
      children: [
        Icon(forward ? IconsaxPlusLinear.rotate_right : IconsaxPlusLinear.rotate_left, size: size),
        Text(
          '$seconds',
          style: TextStyle(fontSize: size * 0.3, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }
}

class _VolumeSlider extends StatelessWidget {
  const _VolumeSlider({required this.player, required this.onMute, required this.onChanged});
  final Player player;
  final VoidCallback onMute;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: player.stream.volume,
      initialData: player.state.volume,
      builder: (context, snap) {
        final volume = snap.data ?? 100;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: volume == 0 ? 'Bật tiếng' : 'Tắt tiếng',
              onPressed: onMute,
              icon: Icon(
                volume == 0
                    ? IconsaxPlusLinear.volume_cross
                    : volume < 50
                    ? IconsaxPlusLinear.volume_low
                    : IconsaxPlusLinear.volume_high,
              ),
            ),
            SizedBox(
              width: 110,
              child: Slider(
                value: volume.clamp(0, 100),
                max: 100,
                onChanged: (v) {
                  player.setVolume(v);
                  onChanged();
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onClose, this.onRetry, this.onNext});
  final String message;
  final VoidCallback onClose;
  final VoidCallback? onRetry;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.7),
      child: Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(IconsaxPlusLinear.danger, size: 40, color: Theme.of(context).colorScheme.error),
                  const SizedBox(height: 12),
                  Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      if (onRetry != null)
                        FilledButton.icon(
                          onPressed: onRetry,
                          icon: const Icon(IconsaxPlusLinear.refresh),
                          label: const Text('Thử lại'),
                        ),
                      if (onNext != null)
                        FilledButton.tonalIcon(
                          onPressed: onNext,
                          icon: const Icon(IconsaxPlusLinear.next),
                          label: const Text('Tập kế'),
                        ),
                      OutlinedButton.icon(
                        onPressed: onClose,
                        icon: const Icon(IconsaxPlusLinear.arrow_left_1),
                        label: const Text('Về thư viện'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Picture modes: fit / fill (crop) / stretch and fixed display ratios.
enum VideoFit {
  contain('Vừa màn hình', 'Giữ nguyên tỉ lệ, có viền đen', BoxFit.contain, null),
  cover('Lấp đầy', 'Phóng to cho kín màn hình, cắt bớt mép', BoxFit.cover, null),
  fill('Kéo giãn', 'Kéo hình cho vừa khít màn hình', BoxFit.fill, null),
  r169('16:9', 'Ép tỉ lệ 16:9', BoxFit.contain, 16 / 9),
  r219('21:9', 'Ép tỉ lệ 21:9 (2.39:1)', BoxFit.contain, 2.39),
  r43('4:3', 'Ép tỉ lệ 4:3', BoxFit.contain, 4 / 3);

  const VideoFit(this.label, this.hint, this.boxFit, this.aspectRatio);
  final String label;
  final String hint;
  final BoxFit boxFit;
  final double? aspectRatio;
}

/// Title logo from TMDB (like Fladder's ItemLogo), with the episode/version
/// label underneath; plain text when there is no logo.
class _Title extends StatelessWidget {
  const _Title({required this.title, this.logo});
  final String title;
  final Uri? logo;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final plain = Text(
      title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
    );
    final url = logo;
    if (url == null) return plain;
    final maxHeight = (MediaQuery.sizeOf(context).height * 0.14).clamp(36.0, 90.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight, maxWidth: 420),
          child: Image.network(
            url.toString(),
            fit: BoxFit.contain,
            alignment: Alignment.centerLeft,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, _, _) => plain,
            frameBuilder: (_, child, frame, sync) => frame == null && !sync ? plain : child,
          ),
        ),
        const SizedBox(height: 4),
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
      ],
    );
  }
}
