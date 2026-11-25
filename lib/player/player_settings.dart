import 'package:shared_preferences/shared_preferences.dart';

import '../util/tv_mode.dart';

/// Player settings (Settings → Trình phát), after Fladder's player settings page.
/// TV-only switches (Media3 / mpv, tunneling, frame rate) stay in [TvPlaybackPrefs].
class PlayerSettings {
  PlayerSettings._();

  /// Next episode starts when one ends.
  static bool autoNext = true;

  /// Seek steps (seconds): back / forward buttons, J / L, media keys, remote.
  static int seekBack = 10;
  static int seekForward = 30;

  /// Read-ahead cache in MB (0 = automatic: 64 on TVs, 150 elsewhere).
  static int bufferMb = 0;

  /// Preferred languages for embedded tracks, in order ("" = file's default).
  static String audioLang = 'vi';
  static String subLang = 'vi';

  /// Phones: double tap left / right to seek, vertical swipes for brightness / volume.
  static bool doubleTapSeek = true;
  static bool swipeGestures = true;

  /// Android phones: Home while playing shrinks the film into a small window.
  static bool autoPip = true;

  static const seekChoices = [5, 10, 15, 30, 60];
  static const bufferChoices = [0, 32, 64, 150, 300, 500];
  static const langChoices = <(String, String)>[
    ('', 'Theo file'),
    ('vi', 'Tiếng Việt'),
    ('en', 'Tiếng Anh'),
    ('ja', 'Tiếng Nhật'),
    ('ko', 'Tiếng Hàn'),
    ('zh', 'Tiếng Trung'),
  ];

  static int get effectiveBufferMb => bufferMb > 0 ? bufferMb : (isTvDevice ? 64 : 150);

  static const _codes = {'vi': 'vi,vie,vn', 'en': 'en,eng', 'ja': 'ja,jpn', 'ko': 'ko,kor', 'zh': 'zh,chi,zho,chs,cht'};

  /// mpv `alang` / `slang` list: the chosen language first, then Vietnamese / English.
  static String mpvLangs(String first, {bool audio = false}) {
    final order = [first, 'vi', 'en', if (audio) 'ja'].where((l) => l.isNotEmpty).toSet();
    return order.map((l) => _codes[l]!).join(',');
  }

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    autoNext = p.getBool('ps_auto_next') ?? true;
    seekBack = p.getInt('ps_seek_back') ?? 10;
    seekForward = p.getInt('ps_seek_forward') ?? 30;
    bufferMb = p.getInt('ps_buffer_mb') ?? 0;
    audioLang = p.getString('ps_audio_lang') ?? 'vi';
    subLang = p.getString('ps_sub_lang') ?? 'vi';
    doubleTapSeek = p.getBool('ps_double_tap') ?? true;
    swipeGestures = p.getBool('ps_swipe') ?? true;
    autoPip = p.getBool('ps_auto_pip') ?? true;
  }

  static Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('ps_auto_next', autoNext);
    await p.setInt('ps_seek_back', seekBack);
    await p.setInt('ps_seek_forward', seekForward);
    await p.setInt('ps_buffer_mb', bufferMb);
    await p.setString('ps_audio_lang', audioLang);
    await p.setString('ps_sub_lang', subLang);
    await p.setBool('ps_double_tap', doubleTapSeek);
    await p.setBool('ps_swipe', swipeGestures);
    await p.setBool('ps_auto_pip', autoPip);
  }
}
