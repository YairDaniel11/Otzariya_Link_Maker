import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_link_maker/src/ai/ai_providers.dart';
import 'package:otzaria_link_maker/src/controllers/app_controller.dart';
import 'package:otzaria_link_maker/src/screens/ai_scan_dialog.dart';
import 'package:otzaria_link_maker/src/screens/check_links_screen.dart';
import 'package:otzaria_link_maker/src/theme/app_theme.dart';

Widget _host(Widget child, ThemeData theme) => MaterialApp(
  theme: theme,
  locale: const Locale('he'),
  builder: (context, c) => Directionality(textDirection: TextDirection.rtl, child: c!),
  home: Scaffold(body: child),
);

void main() {
  for (final dark in [false, true]) {
    testWidgets('מסך בדיקת קישורים: מצב ריק, ${dark ? 'כהה' : 'בהיר'}, בלי overflow', (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = AppController();
      await tester.pumpWidget(_host(CheckLinksScreen(controller: controller), dark ? AppTheme.dark() : AppTheme.light()));
      await tester.pump();
      expect(find.text('בדיקת קישורים'), findsWidgets);
      expect(find.text('בדוק'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('חלון סריקת AI: הצעה עם ספק מדומה, ואישור מחזיר פרופיל', (tester) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = AppController();
    controller.settings.aiProvider = 'claude';
    controller.settings.aiKeys = {'claude': 'k'};
    controller.settings.aiModels = {'claude': 'm'};
    final reply = jsonEncode({
      'name': 'דפים',
      'target': 'ברכות',
      'link_type': 'פירוש',
      'validate': false,
      'rules': [
        {'type': 'daf', 'levels': [2, 6], 'formats': ['std', 'ext']},
      ],
    });
    final client = AiClient(
      post: (u, h, b) async => (200, jsonEncode({'content': [{'type': 'text', 'text': reply}]})),
    );
    Object? result = 'pending';
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showAiScanDialog(
              context,
              controller: controller,
              stem: 'חידושים מסכת ברכות',
              lines: const ['<h1>חידושים</h1>', '<h3>ב.</h3>', 'שורה', '<h3>ב:</h3>', 'שורה'],
              client: client,
            ),
            child: const Text('פתח'),
          ),
        ),
        AppTheme.light(),
      ),
    );
    await tester.tap(find.text('פתח'));
    await tester.pumpAndSettle();
    expect(find.text('סרוק'), findsOneWidget);
    await tester.tap(find.text('סרוק'));
    await tester.pumpAndSettle();
    expect(find.textContaining('כיסוי'), findsOneWidget);
    await tester.tap(find.text('השתמש בכללים האלה'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result, isNot('pending'));
  });
}
