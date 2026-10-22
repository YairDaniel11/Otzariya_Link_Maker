import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_link_maker/src/engine/errors.dart';
import 'package:otzaria_link_maker/src/headers/docx_reader.dart';

import 'headers_fixture.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('hdr_docx'));
  tearDown(() => dir.deleteSync(recursive: true));

  String sample() => writeDocx(
        dir,
        [
          para(run('שם הספר'), style: 'Heading1'),
          para(run('רגיל ') + run('מודגש', b: true) + run(' ') + run('נטוי', i: true)),
          para(''),
          para(run('א', b: true) + run(' ') + run('ב', b: true)),
          para(run('פרק א'), style: 'Heb2'),
          para(run('סעיף'), style: 'MyOutline'),
          para(run('א') + run('2', sup: true) + run(' ') + run('גדול', sz: 28) + run(' ') + run('קטן', sz: 20) + run(' ') + fnRef(1)),
          para(run('x < y & z')),
          para(run('כותרת בולטת ') + run('עם הערה') + fnRef(2), style: 'Heading1'),
        ],
        notes: [run(' הערה ') + run('חשובה', b: true), run('שנייה')],
      );

  test('המרה מלאה: כותרות, עיצוב, גדלים, הערות', () {
    final r = importDocx(sample(), baseHalfPts: 24, noteHalfPts: 20);
    expect(r.lines, [
      '<h1>שם הספר</h1>',
      'רגיל <b>מודגש</b> <i>נטוי</i>',
      '<b>א ב</b>',
      '<h2>פרק א</h2>',
      '<h3>סעיף</h3>',
      'א<sup>2</sup> <big>גדול</big> <small>קטן</small> <sup>1</sup>',
      'x &lt; y & z',
      '<h1>כותרת בולטת עם הערה<sup>2</sup></h1>',
    ]);
    expect(r.notes, ['הערה <b>חשובה</b>', 'שנייה']);
    expect(r.stats.headingsPerLevel, {1: 2, 2: 1, 3: 1});
    expect(r.stats.footnotes, 2);
    expect(r.stats.usedHeadingStyles, isTrue);
  });

  test('זיהוי אוטומטי של גדלים', () {
    final path = sample();
    expect(detectDocxSizes(path).text, 12);
    expect(detectDocxSizes(path).notes, 10);
    final r = importDocx(path);
    expect(r.baseHalfPts, 24);
    expect(r.lines[5], contains('<big>גדול</big>'));
  });

  test('כל שורה מאוזנת ותגים לא חוצים שורות (מעבר שורה ידני)', () {
    final path = writeDocx(dir, [
      para('<w:r><w:rPr><w:b/><w:bCs/></w:rPr><w:t>אחת</w:t><w:br/><w:t>שתיים</w:t></w:r>'),
    ]);
    expect(importDocx(path, baseHalfPts: 24).lines, ['<b>אחת</b>', '<b>שתיים</b>']);
  });

  test('בלי סגנונות כותרת', () {
    final path = writeDocx(dir, [para(run('טקסט'))], styles: false);
    final r = importDocx(path, baseHalfPts: 0);
    expect(r.lines, ['טקסט']);
    expect(r.stats.usedHeadingStyles, isFalse);
  });

  test('שגיאות בעברית', () {
    final bad = File('${dir.path}/a.docx')..writeAsStringSync('לא zip');
    expect(() => importDocx(bad.path), throwsA(isA<AppError>()));
    final old = File('${dir.path}/b.doc')..writeAsBytesSync([0xD0, 0xCF, 0x11, 0xE0, 1, 2, 3]);
    expect(() => importDocx(old.path), throwsA(predicate((e) => e is AppError && e.message.contains('docx'))));
    final empty = writeDocx(dir, [para(''), para('')], name: 'e.docx');
    expect(() => importDocx(empty), throwsA(isA<AppError>()));
    expect(() => importDocx('${dir.path}/nope.docx'), throwsA(isA<AppError>()));
  });
}
