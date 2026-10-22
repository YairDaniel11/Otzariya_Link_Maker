import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_link_maker/src/headers/book_builder.dart';
import 'package:otzaria_link_maker/src/headers/txt_headers.dart';

HeadingRule preset(String id) => headingPresets().firstWhere((r) => r.id == id);

BuiltBook build(List<String> lines, List<String> ruleIds,
    {String title = 'חידושים על ברכות',
    String author = 'מחבר',
    List<HeadingRule>? rules,
    bool insert = false,
    FootnoteMode fm = FootnoteMode.inline,
    List<String> notes = const [],
    bool remove = false}) {
  final r = rules ?? [for (final i in ruleIds) preset(i)];
  return buildBook(
    lines: lines,
    title: title,
    author: author,
    accepted: detectHeadings(lines, r, title: title),
    insertMissingParents: insert,
    footnotes: fm,
    notes: notes,
    removeEmptyLines: remove,
  );
}

List<int> headingLevels(List<String> lines) {
  final out = <int>[];
  for (final l in lines) {
    final m = RegExp(r'^<h([1-6])>').firstMatch(l);
    if (m != null) out.add(int.parse(m[1]!));
  }
  return out;
}

void main() {
  test('מבנה: שורה 1-2, כותרות, בלי שגיאות', () {
    final b = build(['מסכת ברכות', 'פרק א - מאימתי', 'דף ב.', 'גוף א', 'דף ב:', 'גוף ב'], ['daf', 'masechet', 'perek']);
    expect(b.lines, [
      '<h1>חידושים על ברכות</h1>',
      'מחבר',
      '<h2>מסכת ברכות</h2>',
      '<h3>פרק א - מאימתי</h3>',
      '<h4>ב.</h4>',
      'גוף א',
      '<h4>ב:</h4>',
      'גוף ב',
    ]);
    expect(b.hasErrors, isFalse);
    expect(b.fileName, 'חידושים על ברכות.txt');
    expect(b.headingsPerLevel, {2: 1, 3: 1, 4: 2});
  });

  test('מחבר ריק = שורה 2 ריקה', () {
    final b = build(['דף ב.', 'x'], ['daf'], author: '');
    expect(b.lines[1], '');
    expect(b.hasErrors, isFalse);
  });

  test('נרמול כותרות: דף מקוצר, סוגריים, גרשיים, נקודה בסוף', () {
    final lines = ['[דף יג עמוד ב]', 'x', 'עמוד א', 'דף יד ע"ב', 'פרק ג.', "פרק ד ''בא''", '(הקדמה)'];
    final rules = [HeadingRule.regex(r'^\[?דף|^עמוד|^פרק|^\(הקדמה', level: 2)];
    final b = build(lines, [], rules: rules);
    expect(b.lines.sublist(2), ['<h2>יג:</h2>', 'x', '<h2>יג.</h2>', '<h2>יד:</h2>', '<h2>פרק ג</h2>', '<h2>פרק ד "בא"</h2>', '<h2>הקדמה</h2>']);
  });

  test('היררכיה: מיזוג רמות עם פער והעלאת כותרת בלי אב', () {
    final lines = ['א1', 'ב1', 'א2', 'ב1'];
    final rules = [HeadingRule.regex(r'^א', level: 2), HeadingRule.regex(r'^ב', level: 5)];
    var b = build(lines, [], rules: rules);
    expect(headingLevels(b.lines), [1, 2, 3, 2, 3]);
    final r2 = [HeadingRule.regex(r'^ב', level: 3), HeadingRule.regex(r'^א', level: 2)];
    b = build(['ב1', 'א1', 'ב1'], [], rules: r2);
    expect(headingLevels(b.lines), [1, 2, 2, 3]);
    expect(b.issues.any((i) => i.severity == IssueSeverity.info), isTrue);
    b = build(['ב1', 'א1', 'ב1'], [], rules: r2, insert: true);
    expect(b.lines[2], '<h2>חידושים על ברכות</h2>');
    expect(headingLevels(b.lines), [1, 2, 3, 2, 3]);
    expect(b.hasErrors, isFalse);
  });

  test('כותרות קיימות מהמרת Word מונרמלות', () {
    final lines = ['<h1>חידושים על ברכות</h1>', 'מחבר', '<h1>פרק א</h1>', 'טקסט', '<h3>סעיף</h3>', 'עוד'];
    final b = build(lines, []);
    expect(b.lines, ['<h1>חידושים על ברכות</h1>', 'מחבר', '<h2>פרק א</h2>', 'טקסט', '<h3>סעיף</h3>', 'עוד']);
  });

  test('כותרת עם טקסט אחריה מפוצלת', () {
    final b = build(['<h2>פרק</h2>המשך'], []);
    expect(b.lines.sublist(2), ['<h2>פרק</h2>', 'המשך']);
  });

  test('דילוג על שורות שאינן כותרת שלמה', () {
    final long = 'פרק א. ${'מילה ' * 40}';
    final b = build([long, 'פרק ב'], ['perek']);
    expect(b.skipped.single.index, 0);
    expect(b.lines.sublist(2), [long, '<h2>פרק ב</h2>']);
  });

  test('הסרת שורות ריקות (אופציונלי)', () {
    final b = build(['דף ב.', '', 'x', ''], ['daf'], remove: true);
    expect(b.lines.sublist(2), ['<h2>ב.</h2>', 'x']);
  });

  test('הערות inline', () {
    final b = build(['מילה<sup>1</sup> ועוד<sup>2</sup>', 'שורה <sup>9</sup>'], [], notes: ['א', 'ב <i>x</i>']);
    expect(b.lines[2],
        'מילה<sup class="footnote-marker">1</sup><i class="footnote">א</i> ועוד<sup class="footnote-marker">2</sup><i class="footnote">ב <em>x</em></i>');
    expect(b.lines[3], 'שורה <sup>9</sup>');
    expect(b.footnoteCount, 2);
    expect(b.hasErrors, isFalse);
  });

  test('הערות בקובץ נפרד + links', () {
    final b = build(['a<sup>1</sup>', 'b<sup>2</sup>'], [], notes: ['הערה ראשונה', 'שנייה'], fm: FootnoteMode.separate);
    expect(b.lines.sublist(2), ['a<sup style="color: gray;">1</sup>', 'b<sup style="color: gray;">2</sup>']);
    expect(b.notesLines, ['הערה ראשונה', 'שנייה']);
    final j = jsonDecode(b.linksJson!) as List;
    expect(j[1], {'line_index_1': 4, 'line_index_2': 2, 'heRef_2': 'הערות', 'path_2': 'הערות על חידושים על ברכות.txt', 'Conection Type': 'footnotes'});
    expect(b.linksJson, contains('"Conection Type": "footnotes"'));
    expect(b.notesFileName, 'הערות על חידושים על ברכות.txt');
    expect(b.linksFileName, 'חידושים על ברכות_links.json');
    final two = build(['a<sup>1</sup> b<sup>2</sup>'], [], notes: ['x', 'y'], fm: FootnoteMode.separate);
    expect(two.hasErrors, isTrue);
  });

  test('שם קובץ מנוקה, h1 שומר גרשיים', () {
    final b = build(['x'], [], title: 'שו״ת מהרש״ם: חלק ג?');
    expect(b.fileName, 'שות מהרשם חלק ג.txt');
    expect(b.lines[0], '<h1>שו"ת מהרש"ם: חלק ג?</h1>');
  });

  test('עריכה מחדש של קובץ אוצריא: h1 ומחבר לא כפולים', () {
    final b = build(['<h1>חידושים על ברכות</h1>', 'מחבר', '<h2>א</h2>', 'x'], []);
    expect(b.lines, ['<h1>חידושים על ברכות</h1>', 'מחבר', '<h2>א</h2>', 'x']);
  });

  group('validateBookLines', () {
    bool has(List<ValidationIssue> l, IssueSeverity s, String part) => l.any((i) => i.severity == s && i.message.contains(part));
    test('שגיאות מרכזיות', () {
      expect(has(validateBookLines(['שלום', 'x']), IssueSeverity.error, 'שורה 1'), isTrue);
      final v = validateBookLines([
        '<h1>ס</h1>', '', '<h2>א</h2>', '<h4>ב</h4>', '<h3>ג</h3>tail', '<b>לא סגור', 'x</i>', '<h7>x</h7>', '# md', //
        'a<sup style="x">1</sup> b<sup style="y">2</sup>', 'm<sup class="footnote-marker">1</sup>ללא גוף', 'x<style>',
      ]);
      expect(has(v, IssueSeverity.error, 'דילוג'), isTrue);
      expect(has(v, IssueSeverity.error, 'כולה'), isTrue);
      expect(has(v, IssueSeverity.error, 'ולא נסגרו'), isTrue);
      expect(has(v, IssueSeverity.error, 'תג סוגר'), isTrue);
      expect(has(v, IssueSeverity.error, 'h7'), isTrue);
      expect(has(v, IssueSeverity.error, 'Markdown'), isTrue);
      expect(has(v, IssueSeverity.error, 'תיבה'), isTrue);
      expect(has(v, IssueSeverity.error, 'footnote-marker'), isTrue);
      expect(has(v, IssueSeverity.error, '<style>'), isTrue);
    });
    test('ספר תקין', () {
      final v = validateBookLines(
          ['<h1>ס</h1>', 'מחבר', '<h2>א</h2>', 'a<b>x</b><sup>1</sup> b<sup class="footnote-marker">2</sup><i class="footnote">n</i>'],
          stem: 'ס');
      expect(v.where((i) => i.severity == IssueSeverity.error), isEmpty);
    });
  });

  test('כתיבה לדיסק: UTF-8 בלי BOM, בלי דריסה', () {
    final d = Directory.systemTemp.createTempSync('hdr_w');
    addTearDown(() => d.deleteSync(recursive: true));
    final b = build(['a<sup>1</sup>'], [], notes: ['n'], fm: FootnoteMode.separate);
    final paths = writeBookFiles(b, d.path, linksDir: '${d.path}/links');
    expect(paths.length, 3);
    final bytes = File(paths[0]).readAsBytesSync();
    expect(bytes.take(3), isNot([0xEF, 0xBB, 0xBF]));
    expect(utf8.decode(bytes), serializeBook(b.lines));
    expect(() => writeBookFiles(b, d.path), throwsA(anything));
    expect(writeBookFiles(b, d.path, overwrite: true).length, 2);
  });
}
