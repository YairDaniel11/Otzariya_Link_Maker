import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// שם תיקיית הקישורים והדורות (כמו במאגר MyLibraryforOtzaria).
const linksDirName = 'קבצי קישורים וסדר הדורות';

/// כותרת קפדנית: h2-h6 בלי תכונות (כמו בהרצה המקורית של מחולל הקישורים).
final headStrict = RegExp(r'^<h([2-6])>(.*?)</h[2-6]>\s*$');

/// כותרת עם תכונות, כל הרמות.
final headLoose = RegExp(r'^<h([1-6])(?:\s[^>]*)?>(.*?)</h[1-6]>\s*$');

/// כותרת לתוכן העניינים של המסד.
final headingToc = RegExp(r'^<h([1-6])[^>]*>(.*?)</h\1>\s*$');

final _tags = RegExp(r'<[^>]+>');

/// גרשיים, גרשיים עבריים וגרש.
const quoteChars = '"״\'׳';

final _dblQuotes = RegExp('[“”„״]');
final _sglQuotes = RegExp('[‘’׳]');

/// שם ספר במסד: גרשיים וגרש בצורה אחידה (כמו בספרייה הרשמית: " ו-' רגילים),
/// כך ששם קובץ עם ״ או ׳ יוצא זהה לשם עם " או '.
String dbBookTitle(String t) => t.replaceAll(_dblQuotes, '"').replaceAll(_sglQuotes, "'");

/// שם קטגוריה (תיקייה) במסד: בספרייה הרשמית קטגוריות כתובות עם ״ (למשל תנ״ך), וגרש רגיל.
String dbCategoryTitle(String t) => t.replaceAll(_dblQuotes, '״').replaceAll('"', '״').replaceAll(_sglQuotes, "'");

String stripTags(String t) => t.replaceAll(_tags, '').trim();

String removeTags(String t) => t.replaceAll(_tags, '');

/// קורא קובץ טקסט כרשימת שורות: UTF-8 (תווים פגומים מוחלפים), בלי BOM, וכל סוגי סופי השורה.
/// [dropTrailingEmpty] = כמו בבניית המסד (שורה ריקה אחרונה אינה שורה).
List<String> readBookLines(String path, {bool dropTrailingEmpty = false}) {
  var text = utf8.decode(File(path).readAsBytesSync(), allowMalformed: true);
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  if (dropTrailingEmpty && lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}

bool isLfsPointer(List<String> lines) => lines.isNotEmpty && lines.first.startsWith('version https://git-lfs');

/// ספר בתיקיית הספרים: [rel] = נתיב התיקייה ביחס לשורש (ריק = קובץ בשורש).
class BookFile {
  BookFile(this.stem, this.rel, this.path);
  final String stem;
  final List<String> rel;
  final String path;
}

bool _isBookFile(String name) => p.extension(name).toLowerCase() == '.txt';

bool _skipDir(String name) => name.startsWith('.') || name == linksDirName;

/// כל ספרי ה-TXT בתוך תיקיות (לא בשורש), בלי README, בלי תיקיות נסתרות ובלי תיקיית הקישורים.
/// ממוינים לפי הנתיב המלא, כמו ב-build_personal_db.py.
List<BookFile> scanBooks(String root, {bool includeRoot = false}) {
  final out = <BookFile>[];
  void walk(Directory d, List<String> rel) {
    final List<FileSystemEntity> entries;
    try {
      entries = d.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    final dirs = <Directory>[];
    for (final e in entries) {
      final name = p.basename(e.path);
      if (e is Directory) {
        if (!_skipDir(name)) dirs.add(e);
      } else if (e is File && _isBookFile(name)) {
        final stem = p.basenameWithoutExtension(name);
        if (stem.toLowerCase() == 'readme') continue;
        if (rel.isEmpty && !includeRoot) continue;
        out.add(BookFile(stem, rel, e.path));
      }
    }
    dirs.sort((a, b) => a.path.compareTo(b.path));
    for (final s in dirs) {
      walk(s, [...rel, p.basename(s.path)]);
    }
  }

  walk(Directory(root), const []);
  out.sort((a, b) => a.path.compareTo(b.path));
  return out;
}

/// stem -> כל הקבצים בשם הזה (ספר שמופיע פעמיים לא מקושר אוטומטית).
Map<String, List<BookFile>> booksByStem(List<BookFile> books) {
  final out = <String, List<BookFile>>{};
  for (final b in books) {
    (out[b.stem] ??= []).add(b);
  }
  return out;
}

// ───────────────────────────── CSV ─────────────────────────────

/// קורא CSV (RFC 4180, עם BOM אופציונלי) כרשימת שורות.
List<List<String>> readCsv(String path) => parseCsv(utf8.decode(File(path).readAsBytesSync(), allowMalformed: true));

List<List<String>> parseCsv(String text) {
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  var any = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(c);
      }
      continue;
    }
    switch (c) {
      case '"':
        inQuotes = true;
        any = true;
      case ',':
        row.add(field.toString());
        field.clear();
        any = true;
      case '\r':
        break;
      case '\n':
        row.add(field.toString());
        field.clear();
        rows.add(row);
        row = <String>[];
        any = false;
      default:
        field.write(c);
        any = true;
    }
  }
  if (any || field.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

/// שורות CSV כמילונים לפי הכותרת (כמו csv.DictReader). שורות ריקות מדולגות.
List<Map<String, String>> readCsvDicts(String path) {
  final rows = readCsv(path);
  if (rows.isEmpty) return const [];
  final header = rows.first;
  return [
    for (final r in rows.skip(1))
      if (!(r.length == 1 && r.first.isEmpty))
        {for (var i = 0; i < header.length; i++) header[i]: i < r.length ? r[i] : ''},
  ];
}

String _csvField(String v) => v.contains(RegExp('[",\r\n]')) ? '"${v.replaceAll('"', '""')}"' : v;

/// כותב CSV ב-UTF-8 עם BOM ו-CRLF (כמו write_csv של מחולל הקישורים, שאקסל פותח כראוי).
void writeCsv(String path, List<List<String>> rows) {
  final b = StringBuffer('\uFEFF');
  for (final r in rows) {
    b.write(r.map(_csvField).join(','));
    b.write('\r\n');
  }
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(utf8.encode(b.toString()));
}

/// קבצי links.csv של המשתמש: `<תיקיית קישורים>/קישורים*/*/links.csv` וגם `<תיקיית קישורים>/*/links.csv`.
List<String> userLinkCsvFiles(String linksDir) {
  final out = <String>{};
  final d = Directory(linksDir);
  if (!d.existsSync()) return const [];
  for (final e in d.listSync().whereType<Directory>()) {
    final direct = File(p.join(e.path, 'links.csv'));
    if (direct.existsSync()) out.add(direct.path);
    if (p.basename(e.path).startsWith('קישורים')) {
      for (final s in e.listSync().whereType<Directory>()) {
        final f = File(p.join(s.path, 'links.csv'));
        if (f.existsSync()) out.add(f.path);
      }
    }
  }
  return out.toList()..sort();
}

/// מיון יציב (List.sort של Dart אינו מבטיח יציבות).
void stableSort<T>(List<T> list, int Function(T a, T b) compare) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = compare(a.$2, b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].$2;
  }
}
