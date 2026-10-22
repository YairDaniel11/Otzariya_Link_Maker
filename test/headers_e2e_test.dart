import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_link_maker/src/headers/book_builder.dart';
import 'package:otzaria_link_maker/src/headers/docx_reader.dart';
import 'package:otzaria_link_maker/src/headers/md_import.dart';
import 'package:otzaria_link_maker/src/headers/txt_headers.dart';
import 'package:otzaria_link_maker/src/screens/headers/headers_jobs.dart';

const _d = 'test/fixtures/docx';
const _t = 'test/fixtures/txt';

BuiltBook _build(List<String> lines, List<String> notes, {bool detect = false}) {
  final accepted = detect ? detectHeadings(lines, headingPresets(), title: 'ספר').where((h) => h.rule != null).toList() : <HeadingSuggestion>[];
  return buildBook(lines: lines, title: 'ספר', accepted: accepted, notes: notes);
}

void main() {
  for (final f in ['book_headings_en', 'book_headings_he', 'book_footnotes', 'book_mixed_sizes', 'book_empty_and_split']) {
    test('docx $f: נבנה בלי שגיאות', () {
      final r = importDocx('$_d/$f.docx');
      final b = _build(r.lines, r.notes);
      expect(b.lines.first, '<h1>ספר</h1>');
      expect(b.issues.where((i) => i.severity == IssueSeverity.error), isEmpty, reason: '$f: ${b.issues.map((i) => i.message).join(" | ")}');
    });
  }

  test('docx עם כותרות עברית ואנגלית נותן אותו מבנה', () {
    final en = importDocx('$_d/book_headings_en.docx');
    expect(en.stats.usedHeadingStyles, isTrue);
    expect(importDocx('$_d/book_headings_he.docx').stats.usedHeadingStyles, isTrue);
  });

  test('docx שבור וקובץ doc ישן: הודעה בעברית', () {
    expect(() => importDocx('$_d/broken.docx'), throwsA(isA<Exception>()));
    expect(() => importDocx('$_d/old_format.doc'), throwsA(isA<Exception>()));
  });

  test('txt: פרקים וסימנים מזוהים והספר תקין', () {
    final lines = loadBookTextLines('$_t/parakim_simanim.txt');
    final b = _build(lines, const [], detect: true);
    expect(b.headingsPerLevel.values.fold<int>(0, (s, v) => s + v), greaterThan(3));
    expect(b.issues.where((i) => i.severity == IssueSeverity.error), isEmpty, reason: b.issues.map((i) => i.message).join(' | '));
  });

  test('txt: קידודים (cp1255, BOM, CRLF) נקראים לעברית תקינה', () {
    for (final f in ['cp1255_windows_hebrew', 'utf8_bom', 'crlf_lines']) {
      final lines = loadBookTextLines('$_t/$f.txt');
      expect(lines.any((l) => RegExp('[א-ת]').hasMatch(l)), isTrue, reason: f);
      expect(lines.any((l) => l.contains('\r') || l.contains('﻿')), isFalse, reason: f);
    }
  });

  test('ולידציה תופסת את הבעיות שנזרעו בקובץ הבעייתי', () {
    final issues = validateBookLines(loadBookTextLines('$_t/otzaria_problems.txt'));
    expect(issues.where((i) => i.severity == IssueSeverity.error).length, greaterThanOrEqualTo(4));
    expect(validateBookLines(loadBookTextLines('$_t/otzaria_valid.txt')).where((i) => i.severity == IssueSeverity.error), isEmpty);
  });

  test('markdown: כותרות הופכות לכותרות אוצריא', () {
    final r = importMarkdownText('# ספר\n\n## פרק א\n\nטקסט **מודגש**\n\n### סימן ב\n\nעוד\n');
    final b = _build(r.lines, r.notes);
    expect(b.issues.where((i) => i.severity == IssueSeverity.error), isEmpty);
  });

  test("כותרת בודדת כמו \"סימן ג'\" וקיצורים כמו \"סי' ג\" מזוהות ונבחרות אוטומטית", () {
    final lines = ['ספר', '', "סימן ג'", 'טקסט ארוך ' * 10, 'עוד טקסט ' * 10, "סי' ד", 'סוף ' * 10, 'עוד ' * 10, 'ועוד ' * 10, 'שוב ' * 10, 'ושוב ' * 10, 'סיום ' * 10];
    final hs = detectHeadings(lines, headingPresets(), title: 'ספר');
    expect(hs.where((h) => h.rule?.id == 'siman').length, 2);
    final plains = [for (final l in lines) l];
    final counts = {'siman': 2, 'shortLine': 3};
    expect(autoPickRules(counts, plains.length), contains('siman'));
    expect(autoPickRules({'siman': 1}, 40), contains('siman'));
  });
}
