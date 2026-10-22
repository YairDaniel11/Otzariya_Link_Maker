import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_link_maker/src/ai/ai_providers.dart';
import 'package:otzaria_link_maker/src/ai/structure_ai.dart';
import 'package:otzaria_link_maker/src/engine/linker_core.dart';
import 'package:otzaria_link_maker/src/engine/profile_json.dart';
import 'package:otzaria_link_maker/src/engine/seforim_db.dart';
import 'package:sqlite3/sqlite3.dart';

const stem = 'חידושים מסכת ברכות';
const book = [
  '<img src="x">', '<h1>חידושים מסכת ברכות</h1>', '<h2>פרק א</h2>', '<h3>ב.</h3>', 'שורה א', 'שורה ב', //
  '<h3>ב:</h3>', 'שורה ג', '<h3>יד, ב</h3>', 'לא קיים ביעד', '<h3>ג.</h3>', 'שורה ד',
];

SeforimDb makeDb(String path) {
  final db = sqlite3.open(path);
  db.execute('CREATE TABLE book(id INTEGER PRIMARY KEY, title TEXT)');
  db.execute('CREATE TABLE line(id INTEGER PRIMARY KEY, bookId INTEGER, lineIndex INTEGER, heRef TEXT)');
  db.execute('CREATE TABLE tocText(id INTEGER PRIMARY KEY, text TEXT)');
  db.execute('CREATE TABLE tocEntry(id INTEGER PRIMARY KEY, bookId INTEGER, parentId INTEGER, level INTEGER, textId INTEGER, lineId INTEGER)');
  db.execute("INSERT INTO book VALUES(1,'ברכות')");
  var i = 0;
  for (final t in ['ברכות', 'דף ב.', 'דף ב:', 'דף ג.']) {
    i++;
    db.execute('INSERT INTO tocText VALUES(?,?)', [i, t]);
    db.execute('INSERT INTO tocEntry VALUES(?,1,?,?,?,NULL)', [i, i == 1 ? null : 1, i == 1 ? 0 : 1, i]);
  }
  db.close();
  return SeforimDb(path);
}

void main() {
  late Directory tmp;
  late SeforimDb db;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ai_test');
    db = makeDb('${tmp.path}/seforim.db');
  });
  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  final reply = jsonEncode({
    'name': 'דפים',
    'target': '',
    'target_from_name': true,
    'link_type': 'פירוש',
    'validate': true,
    'rules': [
      {'type': 'daf', 'levels': [2, 6], 'formats': ['std', 'ext']},
    ],
  });

  test('parseJsonBlob: בלוק מגודר, טקסט מסביב, ושגיאות', () {
    expect(parseJsonBlob('הנה:\n```json\n{"a": 1}\n```'), {'a': 1});
    expect(parseJsonBlob('{"a": {"b": 2}} תודה'), {
      'a': {'b': 2},
    });
    expect(() => parseJsonBlob('אין כאן json'), throwsA(isA<AiError>()));
    expect(() => parseJsonBlob('{"a": }'), throwsA(isA<AiError>()));
  });

  test('explainError', () {
    expect(explainError('HTTP 429: quota'), contains('מכסת'));
    expect(explainError('HTTP 401: API key not valid'), contains('המפתח נדחה'));
    expect(explainError('HTTP 503: overloaded'), contains('עמוס'));
    expect(explainError('תקלת רשת: x'), contains('חיבור'));
    expect(explainError('משהו אחר'), '');
  });

  test('רשימת מודלים של Gemini מסוננת וממוינת, וברירת מחדל flash', () async {
    final c = AiClient(
      get: (u, h) async => (
        200,
        jsonEncode({
          'models': [
            {'name': 'models/gemini-2.5-flash', 'supportedGenerationMethods': ['generateContent']},
            {'name': 'models/gemini-2.5-pro', 'supportedGenerationMethods': ['generateContent']},
            {'name': 'models/gemini-2.5-flash-image', 'supportedGenerationMethods': ['generateContent']},
            {'name': 'models/embedding-001', 'supportedGenerationMethods': ['embedContent']},
          ],
        }),
      ),
    );
    final ms = await c.listModels(AiProvider.gemini, 'k');
    expect(ms, ['gemini-2.5-flash', 'gemini-2.5-pro']);
    expect(defaultModel(AiProvider.gemini, ms), 'gemini-2.5-flash');
    expect(defaultModel(AiProvider.claude, ['claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-5-5']), 'claude-haiku-5-5');
    expect(() => c.listModels(AiProvider.gemini, ' '), throwsA(isA<AiError>()));
  });

  test('generate: ניסיון חוזר על 429 עם retryDelay', () async {
    var calls = 0;
    final waits = <Duration>[];
    final c = AiClient(
      post: (u, h, b) async {
        calls++;
        if (calls == 1) {
          return (429, '{"error":{"message":"rate limited","details":[{"retryDelay":"7s"}]}}');
        }
        return (200, jsonEncode({'content': [{'type': 'text', 'text': 'שלום'}]}));
      },
      sleep: (d) async => waits.add(d),
    );
    final msgs = <String>[];
    final out = await c.generate(AiProvider.claude, 'k', 'm', 's', 'u', progress: msgs.add);
    expect(out, 'שלום');
    expect(calls, 2);
    expect(waits.single, const Duration(seconds: 9)); // retryDelay 7 + 2
    expect(msgs, hasLength(1));
  });

  test('generate: Retry-After בגוף ממתין כמבוקש; מכסה אמיתית ו-401 לא נוסים שוב', () async {
    var calls = 0;
    final waits = <Duration>[];
    final c = AiClient(
      post: (u, h, b) async {
        calls++;
        return calls == 1 ? (503, 'busy\nretry in 10') : (200, jsonEncode({'choices': [{'message': {'content': 'ok'}}]}));
      },
      sleep: (d) async => waits.add(d),
    );
    expect(await c.generate(AiProvider.openai, 'k', 'm', 's', 'u'), 'ok');
    expect(waits.single, const Duration(seconds: 12));

    var n2 = 0;
    final c2 = AiClient(post: (u, h, b) async {
      n2++;
      return (429, jsonEncode({'error': {'message': 'You exceeded your current quota'}}));
    });
    await expectLater(c2.generate(AiProvider.openai, 'k', 'm', 's', 'u'), throwsA(isA<AiError>()));
    expect(n2, 1);

    var n3 = 0;
    final c3 = AiClient(post: (u, h, b) async {
      n3++;
      return (401, jsonEncode({'error': {'message': 'API key not valid'}}));
    });
    try {
      await c3.generate(AiProvider.claude, 'k', 'm', 's', 'u');
      fail('expected AiError');
    } on AiError catch (e) {
      expect(e.message, startsWith('HTTP 401'));
      expect(explainError(e.message), contains('המפתח נדחה'));
    }
    expect(n3, 1);
  });

  test('generate: נותנים עד הסוף ומדווחים על תקלת רשת', () async {
    var calls = 0;
    final c = AiClient(post: (u, h, b) async {
      calls++;
      return (0, 'down');
    }, sleep: (d) async {});
    try {
      await c.generate(AiProvider.claude, 'k', 'm', 's', 'u');
      fail('expected AiError');
    } on AiError catch (e) {
      expect(e.message, contains('תקלת רשת'));
    }
    expect(calls, 5);
  });

  test('generate: Gemini - גוף הבקשה ופענוח התשובה', () async {
    Map? sent;
    final c = AiClient(post: (u, h, b) async {
      sent = jsonDecode(b) as Map;
      expect(u.path, contains('gemini-x:generateContent'));
      return (200, jsonEncode({'candidates': [{'content': {'parts': [{'text': 'א'}, {'text': 'ב'}]}}]}));
    });
    expect(await c.generate(AiProvider.gemini, 'k', 'gemini-x', 'sys', 'usr', jsonMode: true), 'אב');
    expect(sent!['generationConfig']['responseMimeType'], 'application/json');
    await expectLater(
      AiClient(post: (u, h, b) async => (200, '{"candidates": []}')).generate(AiProvider.gemini, 'k', 'm', 's', 'u'),
      throwsA(isA<AiError>()),
    );
  });

  test('summarizeBook: דגימת שורות רק כשמבקשים', () {
    final s = summarizeBook(book, sampleLines: 2);
    expect((s['sample_content_lines'] as List).length, 2);
    expect(summarizeBook(book).containsKey('sample_content_lines'), isFalse);
    expect(s['total_headings'], 6);
    expect(s['levels'], {'1': 1, '2': 1, '3': 4});
  });

  test('buildPrompt: מכיל מועמדים, תוכן עניינים, משוב, ובלי שורות טקסט', () {
    final p = buildPrompt(stem, summarizeBook(book), db: db, feedback: 'fix it');
    expect(p, contains('File name: $stem'));
    expect(p, contains('first_headings'));
    expect(p, contains('"ברכות"'));
    expect(p, contains('TOC of "ברכות"'));
    expect(p, contains('Feedback on the previous attempt:\nfix it'));
    expect(p, isNot(contains('שורה א')));
    expect(buildPrompt('xyz', summarizeBook(book), db: db, targetHint: 'לא קיים'), contains('not found in the library'));
  });

  test('proposeProfile: פרופיל תקין וכיסוי מהבדיקה היבשה', () async {
    String? userPrompt;
    final c = AiClient(post: (u, h, b) async {
      userPrompt = (jsonDecode(b)['messages'][0]['content']) as String;
      return (200, jsonEncode({'content': [{'type': 'text', 'text': '```json\n$reply\n```'}]}));
    });
    final r = await proposeProfile(
      client: c, provider: AiProvider.claude, key: 'k', model: 'm', stem: stem, lines: book, db: db,
    );
    expect(r.ok, isTrue);
    expect(r.name, 'דפים');
    expect(r.linked, 4);
    expect(r.bodyLines, 5);
    expect(r.coverage, closeTo(0.8, 1e-9));
    expect(r.feedback, contains('linked 4 of 5 lines'));
    expect(userPrompt, isNot(contains('שורה א')));
  });

  test('proposeProfile: המודל ויתר או החזיר פרופיל שגוי', () async {
    AiClient fake(String text) => AiClient(post: (u, h, b) async => (200, jsonEncode({'content': [{'type': 'text', 'text': text}]})));
    final r = await proposeProfile(
      client: fake('{"name":"אין מבנה מתאים","rules":[],"reason":"אין כותרות"}'),
      provider: AiProvider.claude, key: 'k', model: 'm', stem: stem, lines: book,
    );
    expect(r.ok, isFalse);
    expect(r.reason, 'אין כותרות');
    expect(r.errors, ['חסרים כללים']);
    final bad = await proposeProfile(
      client: fake('{"rules":[{"type":"heading","regex":"("}]}'),
      provider: AiProvider.claude, key: 'k', model: 'm', stem: stem, lines: book,
    );
    expect(bad.errors.single, startsWith('כלל 1: ביטוי רגולרי שגוי'));
    // target_hint ממולא כשהמודל לא קבע יעד
    final h = await proposeProfile(
      client: fake('{"rules":[{"type":"heading","levels":[2,2],"regex":"^(.+)\$"}]}'),
      provider: AiProvider.claude, key: 'k', model: 'm', stem: stem, lines: book, db: db, targetHint: 'ברכות',
    );
    expect(h.profile!.target, 'ברכות');
  });

  group('profile_json', () {
    test('כל הפריסטים תקינים וחוזרים אחרי הלוך-חזור', () {
      for (final p in presets.values) {
        final j = profileToJson(p);
        expect(validateProfileJson(j), isEmpty);
        final back = profileFromJson(jsonDecode(jsonEncode(j)) as Map);
        expect(profileToJson(back), j);
        expect(back.rules.length, p.rules.length);
      }
    });

    test('שדות ברירת מחדל ורמות', () {
      final p = profileFromJson({
        'rules': [
          {'type': 'heading', 'regex': '^(x)\$', 'levels': [3.0, 4]},
          {'type': 'anchor'},
        ],
        'reset_on_unmatched': true,
        'link_type': 'תרגום',
      });
      expect(p.rules.first.lo, 3);
      expect(p.rules.first.hi, 4);
      expect(p.rules.first.ref, '{1}');
      expect(p.rules.first.role, 'ref');
      expect(p.validate, isTrue);
      expect(p.resetOnUnmatched, isTrue);
      expect(p.linkType, 'תרגום');
    });

    test('validateProfileJson', () {
      expect(validateProfileJson('x'), ['הפרופיל אינו אובייקט']);
      expect(validateProfileJson({'rules': []}), ['חסרים כללים']);
      expect(validateProfileJson({'rules': [{'type': 'nope'}]}), ['כלל 1: סוג לא מוכר']);
      expect(validateProfileJson({'rules': [{'type': 'heading', 'regex': '(' }]}).single, startsWith('כלל 1: ביטוי רגולרי שגוי'));
      expect(validateProfileJson({'rules': [{'type': 'heading', 'regex': 'a', 'role': 'zzz'}]}), ['כלל 1: role לא מוכר']);
      expect(() => profileFromJson({'rules': [{'type': 'nope'}]}), throwsFormatException);
    });
  });
}
