import 'dart:io';

import 'package:otzaria_link_maker/src/engine/seforim_db.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// רשומת תוכן עניינים מדומה: (מזהה מקומי בספר, הורה מקומי, רמה, טקסט).
typedef FakeToc = (int, int?, int, String);

/// תוכן עניינים מדומה, בדומה ל-FakeDB של בדיקות הפייתון.
const fakeTocs = <String, List<FakeToc>>{
  'ברכות': [(1, null, 0, 'ברכות'), (2, 1, 1, 'דף ב.'), (3, 1, 1, 'דף ב:'), (4, 1, 1, 'דף ג.'), (5, 1, 1, 'דף יג.'), (6, 1, 1, 'דף יג:'), (7, 1, 1, 'דף יד:')],
  'בראשית': [(1, null, 0, 'בראשית'), (2, 1, 1, 'פרק א'), (3, 1, 1, 'פרק ב')],
  'שולחן ערוך, יורה דעה': [(1, null, 0, 'x'), (2, 1, 1, 'סימן קס'), (3, 1, 1, 'סימן קסא')],
  'פסקי הרא"ש על ביצה': [(1, null, 0, 'x'), (2, 1, 1, 'פרק א'), (3, 2, 2, 'הלכה ב'), (4, 2, 2, 'הלכה ג')],
};

/// יוצר seforim.db קטן ואמיתי (sqlite) בתיקייה זמנית, עם הטבלאות והעמודות ש-SeforimDb קורא.
class FakeSeforim {
  FakeSeforim._(this.dir, this.path, this.db);

  final Directory dir;
  final String path;
  final SeforimDb db;

  static FakeSeforim create([Map<String, List<FakeToc>> tocs = fakeTocs]) {
    final dir = Directory.systemTemp.createTempSync('fake_seforim_');
    final path = p.join(dir.path, 'seforim.db');
    final w = sqlite3.open(path);
    w.execute('CREATE TABLE book(id INTEGER PRIMARY KEY, title TEXT)');
    w.execute('CREATE TABLE line(id INTEGER PRIMARY KEY, bookId INTEGER, lineIndex INTEGER, heRef TEXT)');
    w.execute('CREATE TABLE tocText(id INTEGER PRIMARY KEY, text TEXT)');
    w.execute(
      'CREATE TABLE tocEntry(id INTEGER PRIMARY KEY, bookId INTEGER, parentId INTEGER, level INTEGER, '
      'textId INTEGER, lineId INTEGER)',
    );
    var bookId = 0, entryId = 0, textId = 0, lineId = 0;
    tocs.forEach((title, entries) {
      bookId++;
      w.execute('INSERT INTO book(id,title) VALUES(?,?)', [bookId, title]);
      final base = entryId;
      var idx = 0;
      for (final (id, parent, level, text) in entries) {
        entryId++;
        textId++;
        lineId++;
        w.execute('INSERT INTO tocText(id,text) VALUES(?,?)', [textId, text]);
        w.execute('INSERT INTO line(id,bookId,lineIndex,heRef) VALUES(?,?,?,?)', [lineId, bookId, idx++, '$title $text']);
        w.execute('INSERT INTO tocEntry(id,bookId,parentId,level,textId,lineId) VALUES(?,?,?,?,?,?)', [
          base + id,
          bookId,
          parent == null ? null : base + parent,
          level,
          textId,
          lineId,
        ]);
      }
    });
    w.close();
    return FakeSeforim._(dir, path, SeforimDb(path));
  }

  void dispose() {
    db.close();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // ignore
    }
  }
}
