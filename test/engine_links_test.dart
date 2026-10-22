import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_link_maker/src/engine/auto_links.dart';
import 'package:otzaria_link_maker/src/engine/common.dart';
import 'package:otzaria_link_maker/src/engine/linker_core.dart';
import 'package:path/path.dart' as p;

import 'support/fake_seforim_db.dart';

const sa = 'שולחן ערוך, יורה דעה';
const ashri = 'פסקי הרא"ש על ביצה';

final book = <String>[
  '<img src="x">',
  '<h1>חידושים מסכת ברכות</h1>',
  '<h2>פרק א</h2>',
  '<h3>ב.</h3>',
  'שורה א',
  'שורה ב',
  '<h3>ב:</h3>',
  'שורה ג',
  '<h3>כא, ב</h3>',
  'לא קיים ביעד',
  '<h3>ג.</h3>',
  'שורה ד',
];

void main() {
  late FakeSeforim fake;
  setUpAll(() => fake = FakeSeforim.create());
  tearDownAll(() => fake.dispose());

  group('runProfile (ported from test_engine.py)', () {
    test('daf headings', () {
      final r = runProfile(book, presets['בבלי: כותרות דף']!, fake.db, 'חידושים מסכת ברכות');
      expect(r.rows, {
        5: ('ברכות', 'ב.'),
        6: ('ברכות', 'ב.'),
        8: ('ברכות', 'ב:'),
        12: ('ברכות', 'ג.'),
      });
      expect(r.headings, 6);
      expect(r.unmatched, {'פרק א': 1});
    });

    test('first line and headings never linked', () {
      final r = runProfile(book, presets['בבלי: כותרות דף']!, fake.db, 'מסכת ברכות');
      expect(r.rows.containsKey(1), isFalse);
      expect(r.rows.keys.every((i) => !book[i - 1].startsWith('<h')), isTrue);
    });

    test('chapter and sub', () {
      final lines = ['x', '<h1>t</h1>', '<h2>פרק א</h2>', '<h3>סימן ב</h3>', 'טקסט', '<h3>סימן ז</h3>', 'אין כזה'];
      final prof = presets['פרק ברמה 2 והלכה או סימן ברמה 3']!.withTarget(ashri, reset: false);
      expect(runProfile(lines, prof, fake.db, 'x').rows, {5: (ashri, 'פרק א הלכה ב')});
    });

    test('shulchan aruch simanim', () {
      final lines = ['x', '<h1>t</h1>', '<h2>סימן קס</h2>', 'א', 'ב', '<h2>סימן קסב</h2>', 'לא קיים'];
      final prof = presets['שולחן ערוך: סימן ברמה 2']!.withTarget(sa, reset: false);
      expect(runProfile(lines, prof, fake.db, 'x').rows.keys.toList()..sort(), [4, 5]);
    });

    test('validate off keeps unknown refs', () {
      final lines = ['x', 'y', '<h2>סימן קסב</h2>', 'א'];
      const base = Profile(
        target: sa,
        validate: false,
        rules: [Rule('heading', levels: [2, 2], regex: r'^(סימן [א-ת]+)$')],
      );
      expect(runProfile(lines, base, fake.db, 'x').rows, {4: (sa, 'סימן קסב')});
    });

    test('anchor mode', () {
      final lines = ['x', '<h1>t</h1>', 'פתיחה', 'בדף ב. שנים אוחזין', 'המשך', 'בדף ג. עוד', 'סוף'];
      final r = runProfile(lines, presets['בבלי: אזכורי דף בתחילת שורה']!, fake.db, 'מסכת ברכות');
      expect(r.rows, {
        4: ('ברכות', 'ב.'),
        5: ('ברכות', 'ב.'),
        6: ('ברכות', 'ג.'),
        7: ('ברכות', 'ג.'),
      });
    });

    test('anchor with ע"א / ע"ב forms', () {
      final lines = ['x', 'y', 'בדף ב ע"א התחלה', 'המשך', 'ובדף ב ע"ב עוד', 'סוף'];
      final r = runProfile(lines, presets['בבלי: אזכורי דף בתחילת שורה']!, fake.db, 'מסכת ברכות');
      expect(r.rows, {
        3: ('ברכות', 'ב.'),
        4: ('ברכות', 'ב.'),
        5: ('ברכות', 'ב:'),
        6: ('ברכות', 'ב:'),
      });
    });

    test('template without groups does not crash', () {
      final lines = ['x', 'y', '<h2>סימן קס</h2>', 'א'];
      const prof = Profile(
        target: sa,
        rules: [Rule('heading', levels: [2, 2], regex: r'^סימן קס$', ref: '{1}')],
      );
      expect(runProfile(lines, prof, fake.db, 'x').rows, isEmpty);
    });
  });

  group('runProfile presets', () {
    test('no target: note and no rows', () {
      final r = runProfile(['x', 'y', '<h2>פרק א</h2>', 'a'], presets['תנ"ך: פרק לפי כותרת ברמה 2']!, fake.db);
      expect(r.rows, isEmpty);
      expect(r.notes, ['לא הוגדר ספר יעד']);
    });

    test('tanakh preset with target', () {
      final lines = ['x', 'y', '<h2>פרק א</h2>', 'a', '<h2>פרק ט</h2>', 'b', '<h2>פרק ב</h2>', 'c'];
      final prof = presets['תנ"ך: פרק לפי כותרת ברמה 2']!.withTarget('בראשית');
      expect(runProfile(lines, prof, fake.db).rows, {
        4: ('בראשית', 'פרק א'),
        8: ('בראשית', 'פרק ב'),
      });
    });

    test('resetOnUnmatched drops stale location', () {
      final lines = ['x', 'y', '<h2>סימן קס</h2>', 'a', '<h2>נושא</h2>', 'b'];
      final base = presets['שולחן ערוך: סימן ברמה 2']!.withTarget(sa, reset: false);
      expect(runProfile(lines, base, fake.db).rows.keys, [4, 6]);
      expect(runProfile(lines, base.withTarget(sa), fake.db).rows.keys, [4]);
    });

    test('target_switch changes the book; unknown masechet does not', () {
      final lines = [
        'x',
        '<h1>t</h1>',
        '<h2>מסכת ברכות</h2>',
        '<h3>ב.</h3>',
        'a',
        '<h2>מסכת פסחים</h2>',
        'b',
      ];
      final r = runProfile(lines, presets['בבלי: כותרות דף']!, fake.db, '');
      expect(r.rows[5], ('ברכות', 'ב.'));
      expect(r.rows[7], ('ברכות', 'ב.'));
    });

    test('mishneh torah preset: missing target gets a note and no validation', () {
      final lines = ['x', 'y', '<h2>פרק א</h2>', 'a'];
      final r = runProfile(lines, presets['משנה תורה: פרק ברמה 2']!, fake.db);
      expect(r.rows, {4: ('משנה תורה, הלכות שבת', 'פרק א')});
      expect(r.notes.single, contains('לא נמצא'));
    });

    test('validate:false-less run without db skips validation', () {
      final lines = ['x', 'y', '<h2>סימן ט</h2>', 'a'];
      final r = runProfile(lines, presets['שולחן ערוך: סימן ברמה 2']!, null);
      expect(r.rows, {4: ('שולחן ערוך, אורח חיים', 'סימן ט')});
    });

    test('linksRows format', () {
      final rows = linksRows('ספר', {7: ('ברכות', 'ב.'), 3: ('ברכות', 'ב:')});
      expect(rows, [
        ['3', 'ספר', 'כן', 'ברכות', 'ב:', 'פירוש', 'לא', ''],
        ['7', 'ספר', 'כן', 'ברכות', 'ב.', 'פירוש', 'לא', ''],
      ]);
      expect(rows.first.length, linkHeader.length);
    });
  });

  group('(a) line 1 and 2 never linked', () {
    test('runProfile: author line 2 is skipped even after heading on line 1', () {
      final lines = ['<h2>סימן קס</h2>', 'מחבר', 'גוף'];
      final prof = presets['שולחן ערוך: סימן ברמה 2']!.withTarget(sa);
      expect(runProfile(lines, prof, fake.db).rows, {3: (sa, 'סימן קס')});
    });

    test('tanakh builtin', () {
      final lines = ['<h2>פרק א</h2>', 'מחבר', 'גוף'];
      final (rows, note, _) = builtinExpected('tanakh', ['תנ״ך', 'ראשונים'], 'בראשית - רש"י', lines, fake.db);
      expect(note, '');
      expect(rows, {3: ('בראשית', 'פרק א')});
    });

    test('bavli builtin', () {
      final lines = ['<h3>ב.</h3>', 'מחבר', 'גוף'];
      final (rows, _, _) = builtinExpected('bavli', ['תלמוד בבלי', 'x'], 'חידושים מסכת ברכות', lines, fake.db);
      expect(rows, {3: ('ברכות', 'ב.')});
    });

    test('line 3 is linked (boundary)', () {
      final lines = ['x', 'y', 'z'];
      const prof = Profile(target: sa, rules: [Rule('heading', levels: [2, 2], regex: r'^(.+)$')]);
      expect(runProfile(lines, prof, fake.db).rows, isEmpty);
    });
  });

  group('(b) heading lines never linked', () {
    test('headings with attributes or trailing text', () {
      final lines = [
        'x',
        '<h1>t</h1>',
        '<h2>סימן קס</h2>',
        '<h3 id="a">כותרת</h3>',
        '<h4>כותרת עם טקסט</h4> סוף',
        '<h5 class="q">',
        'טקסט',
      ];
      final prof = presets['שולחן ערוך: סימן ברמה 2']!.withTarget(sa, reset: false);
      expect(runProfile(lines, prof, fake.db).rows, {7: (sa, 'סימן קס')});
    });

    test('bavli builtin: attribute heading is skipped, not a daf switch', () {
      final lines = ['x', 'y', '<h3>ב.</h3>', 'א', '<h3 class="q">ב:</h3>', 'ב'];
      final (rows, _, _) = builtinExpected('bavli', ['תלמוד בבלי', 'x'], 'חידושים מסכת ברכות', lines, fake.db);
      expect(rows, {4: ('ברכות', 'ב.'), 6: ('ברכות', 'ב.')});
    });

    test('tanakh builtin: heading line with trailing text is skipped', () {
      final lines = ['x', 'y', '<h2>פרק א</h2>', 'a', '<h3>sub</h3> עוד', '<h3 x="1">sub</h3>', 'c'];
      final (rows, _, _) = builtinExpected('tanakh', ['תנ״ך', 'ראשונים'], 'בראשית - רש"י', lines, fake.db);
      expect(rows.keys.toList()..sort(), [4, 7]);
    });
  });

  group('(c) daf heading formats', () {
    test('parseDafExt', () {
      expect(parseDafExt('דף יג עמוד א'), 'יג.');
      expect(parseDafExt('[דף יג עמוד ב]'), 'יג:');
      expect(parseDafExt('(יד, ב)'), 'יד:');
      expect(parseDafExt('יד, ב'), 'יד:');
      expect(parseDafExt('דף ב ע"א'), 'ב.');
      expect(parseDafExt('כא ע״ב'), 'כא:');
      expect(parseDafExt('ב'), isNull);
      expect(parseDafExt('פרק א'), isNull);
    });

    test('preset links ext headings', () {
      final lines = [
        'x',
        '<h1>t</h1>',
        '<h3>דף יג עמוד א</h3>',
        'a',
        '<h3>[דף יג עמוד ב]</h3>',
        'b',
        '<h3>(יד, ב)</h3>',
        'c',
      ];
      final r = runProfile(lines, presets['בבלי: כותרות דף']!, fake.db, 'מסכת ברכות');
      expect(r.rows, {4: ('ברכות', 'יג.'), 6: ('ברכות', 'יג:'), 8: ('ברכות', 'יד:')});
    });

    test('daf rule with only std format ignores ext', () {
      final lines = ['x', 'y', '<h3>דף יג עמוד א</h3>', 'a'];
      const prof = Profile(target: 'ברכות', rules: [Rule('daf', formats: ['std'])]);
      expect(runProfile(lines, prof, fake.db).rows, isEmpty);
    });

    test('bavli builtin falls back to ext formats', () {
      final lines = ['x', 'y', '<h3>דף יג עמוד א</h3>', 'a', '<h3>(יד, ב)</h3>', 'b'];
      final (rows, note, _) = builtinExpected('bavli', ['תלמוד בבלי', 'x'], 'חידושים מסכת ברכות', lines, fake.db);
      expect(note, '');
      expect(rows, {4: ('ברכות', 'יג.'), 6: ('ברכות', 'יד:')});
    });
  });

  group('detectKind', () {
    test('cases', () {
      expect(detectKind(['תנך', 'תרגומים'], 'בראשית'), 'tanakh');
      expect(detectKind(['תנ״ך', 'ראשונים'], 'בראשית - רש"י'), 'tanakh');
      expect(detectKind(['תנ״ך', 'אחרונים'], 'x'), isNull);
      expect(detectKind(['x'], 'פרי חדש או״ח'), 'halacha');
      expect(detectKind(['x'], 'ירושלמי שקלים פרק א'), 'yerushalmi');
      expect(detectKind(['x'], 'הגהות אשרי - ביצה'), 'ashri');
      expect(detectKind(['תלמוד בבלי', 'אחרונים'], 'חידושים מסכת ברכות'), 'bavli');
      expect(detectKind(['תלמוד בבלי', 'שס וגשל'], 'ברכות'), isNull);
      expect(detectKind(['ספרים שאינם מותאמים לאוצריא', 'תלמוד בבלי'], 'x'), 'bavli');
      expect(detectKind(['הלכה'], 'ספר כלשהו'), isNull);
      expect(detectKind([], 'ספר כלשהו'), isNull);
    });
  });

  group('findTarget / targetCandidates', () {
    late Map<String, String> index;
    setUpAll(() => index = titleIndex(fake.db));

    test('after "על"', () => expect(findTarget('ביאור על שולחן ערוך יורה דעה', index), sa));
    test('whole name is official book', () => expect(findTarget('ברכות', index), isNull));
    test('unknown', () => expect(findTarget('ספר רעיונות', index), isNull));
    test('dash part', () => expect(findTarget('חידושים - ברכות', index), 'ברכות'));
    test('trailing paren and number stripped', () => expect(findTarget('חידושים על ברכות (2)', index), 'ברכות'));
    test('trailing "ועוד"', () => expect(findTarget('חידושים על ברכות ועוד', index), 'ברכות'));

    test('targetCandidates order', () {
      final (c, whole) = targetCandidates('אאא - בבב על גגג');
      expect(whole, 'אאא - בבב על גגג');
      expect(c, ['אאא - בבב על גגג', 'בבב על גגג', 'אאא', 'גגג']);
    });

    test('norm strips quotes and punctuation', () {
      expect(norm('שולחן ערוך, יורה דעה'), 'שולחן ערוך יורה דעה');
      expect(norm('פסקי הרא״ש'), 'פסקי הראש');
    });
  });

  group('inferBook', () {
    test('simanim', () {
      final l = ['שם', '<h2>סימן קס</h2>', 'א', 'ב', '<h2>סימן קסא</h2>', 'ג'];
      final (inf, fail, cov) = inferBook(l, sa, fake.db, 'x');
      expect(fail, isNull);
      expect(inf!.rows, {3: (sa, 'סימן קס'), 4: (sa, 'סימן קס'), 6: (sa, 'סימן קסא')});
      expect(cov, 1.0);
    });

    test('dafim', () {
      final l = ['שם', '<h2>ב.</h2>', 'א', 'ב', '<h2>ב:</h2>', 'ג'];
      final (inf, _, _) = inferBook(l, 'ברכות', fake.db, 'x');
      expect(inf!.rows.keys.toSet(), {3, 4, 6});
      expect(inf.name, 'דפים');
    });

    test('noBody', () {
      final (inf, fail, cov) = inferBook(['שם', '<h2>סימן קס</h2>', ''], sa, fake.db, 'x');
      expect((inf, fail, cov), (null, InferFail.noBody, 0.0));
    });

    test('tooFew (2 linked)', () {
      final (inf, fail, _) = inferBook(['שם', '<h2>סימן קס</h2>', 'א', 'ב'], sa, fake.db, 'x');
      expect(inf, isNull);
      expect(fail, InferFail.tooFew);
    });

    test('exactly minLinked accepted', () {
      final (inf, fail, _) = inferBook(['שם', '<h2>סימן קס</h2>', 'א', 'ב', 'ג'], sa, fake.db, 'x');
      expect(fail, isNull);
      expect(inf!.rows.length, minLinked);
    });

    test('low coverage rejected', () {
      final l = ['שם', '<h2>סימן קס</h2>', 'א', 'ב', 'ג', '<h2>נושא אחר</h2>', ...List.filled(5, 'ד')];
      final (inf, fail, cov) = inferBook(l, sa, fake.db, 'x');
      expect(inf, isNull);
      expect(fail, InferFail.lowCoverage);
      expect(cov, closeTo(3 / 8, 1e-9));
    });

    test('exactly 50% coverage accepted', () {
      final l = ['שם', '<h2>סימן קס</h2>', 'א', 'ב', 'ג', '<h2>נושא אחר</h2>', 'ד', 'ה', 'ו'];
      final (inf, fail, cov) = inferBook(l, sa, fake.db, 'x');
      expect(fail, isNull);
      expect(cov, 0.5);
      expect(inf!.rows.length, 3);
    });

    test('heading-like lines with attributes/trailing text are not body', () {
      final l = ['שם', '<h2>סימן קס</h2>', 'א', 'ב', 'ג', '<h2 x="1">כותרת</h2> זנב'];
      final (inf, fail, cov) = inferBook(l, sa, fake.db, 'x');
      expect(fail, isNull);
      expect(cov, 1.0);
      expect(inf!.rows.length, 3);
    });

    test('lines 1-2 are not body', () {
      final (_, fail, _) = inferBook(['שם', 'מחבר', '<h2>סימן קס</h2>'], sa, fake.db, 'x');
      expect(fail, InferFail.noBody);
    });
  });

  group('analyzeLinks', () {
    late Directory tmp;
    late String root;

    String write(List<String> rel, String stem, List<String> lines) {
      final f = File(p.joinAll([root, ...rel, '$stem.txt']));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(lines.join('\n'));
      return f.path;
    }

    final siman = ['שם', '<h2>סימן קס</h2>', 'א', 'ב', '<h2>סימן קסא</h2>', 'ג'];

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('analyze_');
      root = p.join(tmp.path, 'ספרים');
      write(['שונות'], 'ביאור על שולחן ערוך יורה דעה', siman);
      write(['שונות'], 'ספר רעיונות', siman);
      write(['שונות'], 'ספר עם קישורים', siman);
      write(['שונות'], 'ביאור על ברכות', ['שם', '<h2>נושא</h2>', 'א', 'ב']);
      write(['תלמוד בבלי', 'אחרונים'], 'חידושים מסכת ברכות', book);
      write(['א'], 'כפול', siman);
      write(['ב'], 'כפול', siman);
      write(['שונות'], 'מצביע', ['version https://git-lfs.github.com/spec/v1', 'oid sha256:abc']);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Map<String, BookLinkReport> run({
      Map<String, String> overrides = const {},
      Set<String>? only,
      Set<String> existing = const {'ספר עם קישורים'},
    }) {
      final reports = analyzeLinks(
        books: scanBooks(root),
        db: fake.db,
        existing: existing,
        overrides: overrides,
        only: only,
      );
      return {for (final r in reports) r.stem: r};
    }

    test('statuses without overrides', () {
      final r = run();
      final linked = r['ביאור על שולחן ערוך יורה דעה']!;
      expect(linked.status, LinkStatus.linked);
      expect(linked.target, sa);
      expect(linked.overridden, isFalse);
      expect(linked.count, 3);
      expect(linked.coverage, 1.0);

      expect(r['ספר עם קישורים']!.status, LinkStatus.manual);
      expect(r['ספר עם קישורים']!.count, 0);

      final unknown = r['ספר רעיונות']!;
      expect(unknown.status, LinkStatus.notLinked);
      expect(unknown.target, isNull);

      final low = r['ביאור על ברכות']!;
      expect(low.status, LinkStatus.notLinked);
      expect(low.target, 'ברכות');

      expect(r['כפול']!.status, LinkStatus.notLinked);
      expect(r['כפול']!.reason, contains('2'));
      expect(r['מצביע']!.status, LinkStatus.notLinked);
      expect(r['מצביע']!.reason, contains('git-lfs'));
    });

    test('builtin bavli', () {
      final b = run()['חידושים מסכת ברכות']!;
      expect(b.status, LinkStatus.linked);
      expect(b.method, kindLabels['bavli']);
      expect(b.target, 'ברכות');
      expect(b.rows.keys.toList()..sort(), [5, 6, 8, 10, 12]);
      expect(b.linkType, 'פירוש');
      expect(b.csvRows().length, 5);
      expect(b.csvRows().first.first, '5');
    });

    test('disabled override', () {
      final r = run(overrides: {'ביאור על שולחן ערוך יורה דעה': ''})['ביאור על שולחן ערוך יורה דעה']!;
      expect(r.status, LinkStatus.disabled);
      expect(r.count, 0);
    });

    test('override picks a target for an undetected book', () {
      final r = run(overrides: {'ספר רעיונות': sa})['ספר רעיונות']!;
      expect(r.status, LinkStatus.linked);
      expect(r.overridden, isTrue);
      expect(r.target, sa);
      expect(r.count, 3);
    });

    test('override to unknown book', () {
      final r = run(overrides: {'ספר רעיונות': 'לא קיים'})['ספר רעיונות']!;
      expect(r.status, LinkStatus.notLinked);
      expect(r.target, 'לא קיים');
      expect(r.reason, contains('לא נמצא'));
    });

    test('override with mismatched structure', () {
      final r = run(overrides: {'ספר רעיונות': 'ברכות'})['ספר רעיונות']!;
      expect(r.status, LinkStatus.notLinked);
      expect(r.overridden, isTrue);
      expect(r.reason, contains('נבחר היעד'));
    });

    test('manual wins over override', () {
      final r = run(overrides: {'ספר עם קישורים': sa})['ספר עם קישורים']!;
      expect(r.status, LinkStatus.manual);
    });

    test('only filters books', () {
      final r = run(only: {'ספר רעיונות'});
      expect(r.keys, ['ספר רעיונות']);
    });
  });
}
