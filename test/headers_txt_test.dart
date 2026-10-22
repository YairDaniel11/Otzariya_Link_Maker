import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_link_maker/src/engine/errors.dart';
import 'package:otzaria_link_maker/src/headers/txt_headers.dart';

HeadingRule preset(String id) => headingPresets().firstWhere((r) => r.id == id);
List<HeadingRule> some(List<String> ids) => [for (final i in ids) preset(i)];
Map<int, int> levels(List<HeadingSuggestion> s) => {for (final x in s) x.index: x.level};

void main() {
  const long = 'מאימתי קורין את שמע בערבין משעה שהכהנים נכנסים לאכול בתרומתן עד סוף האשמורה הראשונה דברי רבי אליעזר ועוד מילים';

  test('מסכת > פרק > דף: רמות לפי סדר הופעה', () {
    final lines = ['מסכת ברכות', 'פרק א - מאימתי', 'דף ב.', long, 'דף ב:', 'גוף', 'פרק ב - היה קורא', 'דף ג.'];
    final s = detectHeadings(lines, some(['daf', 'masechet', 'perek']));
    expect(levels(s), {0: 2, 1: 3, 2: 4, 4: 4, 6: 3, 7: 4});
  });

  test('דף כיחידה העליונה = h2', () {
    final s = detectHeadings(['דף ב.', 'טקסט', 'דף ב:', 'טקסט', 'דף ג.'], some(['daf']));
    expect(levels(s), {0: 2, 2: 2, 4: 2});
  });

  test('הקדמה ופרק באותה רמה; סימן וסעיף', () {
    var s = detectHeadings(['הקדמה', 'פרק א', 'פרק שני', 'פרק יא'], some(['intro', 'perek']));
    expect(levels(s).values.toSet(), {2});
    expect(s.length, 4);
    s = detectHeadings(['סימן א', 'סעיף א', 'סעיף ב', 'סימן ב', 'סעיף א'], some(['siman', 'seif']));
    expect(levels(s), {0: 2, 1: 3, 2: 3, 3: 2, 4: 3});
  });

  test('גימטריה ומילים סודרות', () {
    final lines = ['פרק י"ג', 'פרק ראשון', 'פרק אחד עשר', 'סימן קכ"ג', 'הלכה ב', 'משנה ג', 'פרשת כי תשא', 'פרשת בראשית'];
    final s = detectHeadings(lines, some(['perek', 'siman', 'halacha', 'mishna', 'parasha']));
    expect(s.map((e) => e.index).toList(), [0, 1, 2, 3, 4, 5, 6, 7]);
  });

  test('צורות דף', () {
    final lines = ['ב.', 'ב:', 'דף ב.', 'דף יג עמוד ב', 'דף ה ע"א', '[דף יד:]', 'יד, ב', 'כל הגט', 'אבא'];
    final s = detectHeadings(lines, some(['daf']));
    expect(s.map((e) => e.index).toList(), [0, 1, 2, 3, 4, 5, 6]);
  });

  test('שורה ארוכה שמתחילה בסימון אינה כותרת שלמה', () {
    final s = detectHeadings(['פרק א. $long $long'], some(['perek']));
    expect(s.single.isWhole, isFalse);
  });

  test('שורה מודגשת, שורה קצרה, מספור', () {
    final s = detectHeadings(['<b>כותרת מודגשת</b>', 'שורה קצרה בלי נקודה', 'משפט שנגמר בנקודה.', '(א) סעיף'], some(['boldLine', 'numbering', 'shortLine']));
    expect(s.map((e) => (e.index, e.rule!.id)).toList(), [(0, 'boldLine'), (1, 'shortLine'), (3, 'numbering')]);
  });

  test('דריסת רמה וכלל מותאם', () {
    final custom = HeadingRule.startsWith('שיעור', level: 4);
    final s = detectHeadings(['שיעור ראשון', 'פרק א'], [custom, preset('perek')]);
    expect(levels(s)[0], 4);
    expect(levels(s)[1], 2); // פרק (דרגה 2) גדול מכלל מותאם (דרגה 3): אין לו אב, לכן h2
  });

  test('regex פגום', () {
    expect(() => HeadingRule.regex('(['), throwsA(isA<AppError>()));
    final r = HeadingRule.regex(r'^שיעור \d+');
    expect(detectHeadings(['שיעור 5', 'x'], [r]).single.index, 0);
  });

  test('כותרות קיימות מדווחות ומונרמלות; שורת h1 של הספר מוחרגת', () {
    final lines = ['<h1>שם</h1>', 'מחבר', '<h2>א</h2>', 'x', '<h4>ב</h4>'];
    final s = detectHeadings(lines, [], title: 'שם');
    expect(s.map((e) => (e.index, e.level, e.existing)).toList(), [(2, 2, true), (4, 3, true)]);
  });

  test('טעינה: BOM, CRLF, windows-1255', () {
    final d = Directory.systemTemp.createTempSync('hdr_txt');
    addTearDown(() => d.deleteSync(recursive: true));
    final a = File('${d.path}/a.txt')..writeAsBytesSync([0xEF, 0xBB, 0xBF, 0xD7, 0xA9, 0x0D, 0x0A, 0x78, 0x0A]);
    expect(loadBookTextLines(a.path), ['ש', 'x']);
    final b = File('${d.path}/b.txt')..writeAsBytesSync([0xF9, 0xEC, 0xE5, 0xED, 0x0A, 0xF9]);
    expect(loadBookTextLines(b.path), ['שלום', 'ש']);
  });
}
