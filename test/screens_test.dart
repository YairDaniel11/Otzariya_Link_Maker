import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_link_maker/main.dart';
import 'package:otzaria_link_maker/src/controllers/app_controller.dart';

void main() {
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('כל המסכים נפתחים בלי גלישה (${mode.name})', (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final c = AppController(persist: false)..settings.themeMode = mode;
      await tester.pumpWidget(LinkMakerApp(controller: c));
      await tester.pumpAndSettle();
      expect(find.text('מה רוצים לעשות?'), findsOneWidget);
      for (final label in ['יצירת כותרות', 'יצירת קישורים', 'בדיקת קישורים', 'עזרה']) {
        await tester.tap(find.text(label).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: label);
      }
      await tester.tap(find.text('הגדרות'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
