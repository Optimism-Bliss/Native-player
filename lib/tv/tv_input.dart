import 'package:flutter/foundation.dart';

/// The text field that has focus on the TV (web page or app screen), so a
/// paired phone can type into it: the remote's on-screen keyboard is slow.
class TvField {
  const TvField({required this.label, required this.kind, this.value = ''});
  final String label;

  /// text | password | search | email | url | number
  final String kind;

  /// Current text (never sent for passwords).
  final String value;

  bool get password => kind == 'password';

  Map<String, Object?> toJson() => {'label': label, 'kind': kind, 'value': password ? '' : value};

  static TvField? fromJson(Object? j) {
    if (j is! Map || j['kind'] is! String) return null;
    return TvField(
      label: j['label'] is String ? j['label'] as String : '',
      kind: j['kind'] as String,
      value: j['value'] is String ? j['value'] as String : '',
    );
  }
}

/// Where typing from the phone goes on the TV. The screen showing the focused
/// field sets [sink]; `set` replaces the text, `enter` submits.
class TvInput {
  static final ValueNotifier<TvField?> field = ValueNotifier(null);
  static Future<bool> Function(String action, String text)? sink;

  static void focus(TvField f, Future<bool> Function(String action, String text) to) {
    field.value = f;
    sink = to;
  }

  static void blur([Object? owner]) {
    field.value = null;
    sink = null;
  }
}
