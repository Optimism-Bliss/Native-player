String formatDuration(Duration d) {
  final negative = d.isNegative;
  d = d.abs();
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final text = h > 0 ? '$h:$m:$s' : '$m:$s';
  return negative ? '-$text' : text;
}

String formatClock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

const _languageNames = {
  'vi': 'Tiếng Việt',
  'vie': 'Tiếng Việt',
  'vn': 'Tiếng Việt',
  'en': 'English',
  'eng': 'English',
  'ja': '日本語',
  'jpn': '日本語',
  'ko': '한국어',
  'kor': '한국어',
  'zh': '中文',
  'chi': '中文',
  'zho': '中文',
  'fr': 'Français',
  'fre': 'Français',
  'fra': 'Français',
  'es': 'Español',
  'spa': 'Español',
  'de': 'Deutsch',
  'ger': 'Deutsch',
  'deu': 'Deutsch',
  'th': 'ไทย',
  'tha': 'ไทย',
  'und': '',
};

String languageName(String? code) {
  if (code == null || code.isEmpty) return '';
  return _languageNames[code.toLowerCase()] ?? code.toUpperCase();
}

String channelLabel(int? count) => switch (count) {
  null || 0 => '',
  1 => 'Mono',
  2 => 'Stereo',
  6 => '5.1',
  8 => '7.1',
  _ => '$count ch',
};

String codecLabel(String? codec) {
  if (codec == null) return '';
  final c = codec.toLowerCase();
  return switch (c) {
    'hevc' || 'h265' => 'HEVC',
    'h264' || 'avc' => 'H.264',
    'av1' => 'AV1',
    'vp9' => 'VP9',
    'eac3' => 'E-AC-3',
    'ac3' => 'AC-3',
    'truehd' => 'TrueHD',
    'dts' => 'DTS',
    'aac' => 'AAC',
    'flac' => 'FLAC',
    'opus' => 'Opus',
    'subrip' => 'SRT',
    'ass' || 'ssa' => 'ASS',
    'hdmv_pgs_subtitle' => 'PGS',
    'dvd_subtitle' => 'VobSub',
    'webvtt' => 'WebVTT',
    'mov_text' => 'TX3G',
    _ => codec.toUpperCase(),
  };
}

String resolutionLabel(int? w, int? h) {
  if (w == null || h == null || w == 0 || h == 0) return '';
  if (w >= 3800 || h >= 2100) return '4K';
  if (w >= 2500 || h >= 1400) return '1440p';
  if (w >= 1900 || h >= 1000) return '1080p';
  if (w >= 1200 || h >= 700) return '720p';
  return '${h}p';
}

/// Signal type from mpv's video-params. Only says what the stream carries,
/// not whether the display path actually outputs HDR.
String hdrLabel(String? primaries, String? gamma) {
  switch (gamma) {
    case 'pq':
      return 'HDR10';
    case 'hlg':
      return 'HLG';
  }
  if (primaries == 'bt.2020') return 'BT.2020';
  return '';
}
