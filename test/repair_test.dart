import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_link_maker/src/engine/common.dart';
import 'package:otzaria_link_maker/src/engine/errors.dart';
import 'package:otzaria_link_maker/src/engine/linker_core.dart' show linkHeader;
import 'package:otzaria_link_maker/src/engine/repair.dart';
import 'package:otzaria_link_maker/src/engine/seforim_db.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const stem = 'חידושים מסכת ברכות';
const book = [
  '<img src="x">', '<h1>חידושים מסכת ברכות</h1>', '<h2>פרק א</h2>', '<h3>ב.</h3>', 'שורה א', 'שורה ב', //
  '<h3>ב:</h3>', 'שורה ג', '<h3>יד, ב</h3>', 'לא קיים ביעד', '<h3>ג.</h3>', 'שורה ד',
];

String makeDb(String path) {
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
  return path;
}

void main() {
  late Directory tmp;
  late String books, links, lp, bookPath;
  late SeforimDb db;

  void writeBook(List<String> lines) => File(bookPath).writeAsStringSync(lines.join('\n'));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('repair_test');
    books = p.join(tmp.path, 'ספרים');
    final d = Directory(p.join(books, 'תלמוד בבלי', 'אחרונים'))..createSync(recursive: true);
    bookPath = p.join(d.path, '$stem.txt');
    writeBook(book);
    links = p.join(books, linksDirName);
    lp = p.join(links, 'קישורים', '01', 'links.csv');
    // שורה 10 (כותרת לא מוכרת) משאירה את הדף הקודם, כמו במנוע המקורי
    final old = [
      for (final (n, ref) in [(5, 'ב.'), (6, 'ב.'), (8, 'ב:'), (10, 'ב:'), (12, 'ג.')])
        ['${n - 1}', stem, 'כן', 'ברכות', ref, 'פירוש', 'לא', ''],
    ];
    writeCsv(lp, [linkHeader, ...old]);
    db = SeforimDb(makeDb(p.join(tmp.path, 'seforim.db')));
  });
  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  test('קישורים שזזו בשורה אחת: מזוהים ומתוקנים, עם גיבוי, ובריצה שנייה הכל תקין', () {
    final plan = planRepair(booksDir: books, linksDir: links, db: db);
    expect(summarizeReport(plan.report), {RepairStatus.updated: 1});
    expect(plan.report.first.shift, 1);
    expect(plan.report.first.oldCount, 5);
    expect(plan.additions, isEmpty);
    final res = applyRepair(plan, newDir: p.join(links, 'קישורים', '13'), backupDir: p.join(tmp.path, 'bak'));
    expect(res.changedFiles, 1);
    final rows = readCsv(lp).skip(1).toList();
    expect([for (final r in rows) r[0]], ['5', '6', '8', '10', '12']);
    expect(Directory(p.join(tmp.path, 'bak')).listSync().length, 1);
    final zip = ZipDecoder().decodeBytes(File(res.backupPath!).readAsBytesSync());
    expect(zip.files.single.name, 'קישורים/01/links.csv');
    final plan2 = planRepair(booksDir: books, linksDir: links, db: db);
    expect(summarizeReport(plan2.report), {RepairStatus.ok: 1});
    final raw = File(lp).readAsBytesSync();
    expect(raw.take(3).toList(), [0xEF, 0xBB, 0xBF]);
    expect(String.fromCharCodes(raw).contains('\r\n'), isTrue);
  });

  test('ללא שינוי: תקין', () {
    // הקישורים כבר תואמים לספר
    final plan0 = planRepair(booksDir: books, linksDir: links, db: db);
    applyRepair(plan0, newDir: p.join(links, 'x'));
    final plan = planRepair(booksDir: books, linksDir: links, db: db);
    expect(plan.report.single.status, RepairStatus.ok);
    expect(plan.report.single.shift, 0);
    expect(plan.hasChanges, isFalse);
  });

  test('הוספת שורה בתחילת הספר: עודכן עם הזזה', () {
    final plan0 = planRepair(booksDir: books, linksDir: links, db: db);
    applyRepair(plan0, newDir: p.join(links, 'x'));
    writeBook([book.first, 'שורה חדשה', ...book.skip(1)]);
    // כעת הקישורים הקיימים נמוכים ב-1 מהצפוי: הזזה +1
    final plan = planRepair(booksDir: books, linksDir: links, db: db);
    expect(plan.report.single.status, RepairStatus.updated);
    expect(plan.report.single.shift, 1);
    expect(plan.newFor.values.single.map((r) => r[0]).toList(), ['6', '7', '9', '11', '13']);
  });

  test('ספר ידני מדולג', () {
    final plan = planRepair(booksDir: books, linksDir: links, db: db, manual: {stem});
    expect(plan.report.single.status, RepairStatus.manual);
    expect(plan.newFor, isEmpty);
    expect(plan.hasChanges, isFalse);
  });

  test('ספר חדש בלי קישורים נוסף לקובץ החדש; ביטול נתמך', () {
    final d = Directory(p.join(books, 'תלמוד בבלי', 'אחרונים'));
    File(p.join(d.path, 'שיטה מסכת ברכות.txt')).writeAsStringSync(book.join('\n'));
    final plan = planRepair(booksDir: books, linksDir: links, db: db);
    expect(plan.additions.single.stem, 'שיטה מסכת ברכות');
    expect(plan.report.where((r) => r.status == RepairStatus.added), hasLength(1));
    final nd = p.join(links, 'קישורים', '13');
    final res = applyRepair(plan, newDir: nd);
    expect(res.additionsPath, p.join(nd, 'links.csv'));
    expect(readCsv(res.additionsPath!).length, 6);
    expect(() => planRepair(booksDir: books, linksDir: links, db: db, checkCancel: () => throw Cancelled()), throwsA(isA<Cancelled>()));
  });

  test('קבוצה בלי קובץ ספר: לא נבדק', () {
    File(bookPath).deleteSync();
    final plan = planRepair(booksDir: books, linksDir: links, db: db);
    expect(plan.report.single.status, RepairStatus.unchecked);
  });
}
