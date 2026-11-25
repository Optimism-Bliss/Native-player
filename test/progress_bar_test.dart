import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:torbox_strm_player/player/widgets/progress_bar.dart';

void main() {
  testWidgets('TV remote: arrows move a preview, OK or a pause seeks', (tester) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              child: PlayerProgressBar(
                position: const Duration(minutes: 10),
                duration: const Duration(hours: 2),
                buffer: Duration.zero,
                buffering: false,
                onSeek: seeks.add,
              ),
            ),
          ),
        ),
      ),
    );
    final focus = Focus.of(tester.element(find.byType(MouseRegion).last));
    focus.requestFocus();
    await tester.pump();

    // two presses then a pause: one seek, 20 s ahead
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(seeks, isEmpty);
    await tester.pump(const Duration(milliseconds: 800));
    expect(seeks, [const Duration(minutes: 10, seconds: 20)]);

    // back 10 s and OK at once
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(seeks.last, const Duration(minutes: 9, seconds: 50));
    await tester.pump(const Duration(seconds: 1));
    expect(seeks.length, 2);
  });
}
