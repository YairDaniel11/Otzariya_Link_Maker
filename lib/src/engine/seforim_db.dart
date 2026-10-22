import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'zstd.dart';

/// רשומת תוכן עניינים בספרייה הרשמית.
class TocRow {
  const TocRow(this.id, this.parentId, this.level, this.text, this.lineId);
  final int id;
  final int? parentId;
  final int level;
  final String text;
  final int? lineId;
}

/// מיקומים אפשריים של seforim.db במחשב (אוצריא, ואחריה תוכנת SeforimApp).
List<String> seforimDbCandidates() {
  final env = Platform.environment;
  return [
    if (env['PROGRAMDATA'] != null) p.join(env['PROGRAMDATA']!, 'otzaria', 'books', 'seforim.db'),
    if (env['APPDATA'] != null) p.join(env['APPDATA']!, 'io.github.kdroidfilter.seforimapp', 'databases', 'seforim.db'),
    if (env['HOME'] != null) ...[
      p.join(env['HOME']!, 'Library', 'Application Support', 'otzaria', 'books', 'seforim.db'),
      p.join(env['HOME']!, '.local', 'share', 'io.github.kdroidfilter.seforimapp', 'databases', 'seforim.db'),
      p.join(
        env['HOME']!,
        'Library',
        'Application Support',
        'io.github.kdroidfilter.seforimapp',
        'databases',
        'seforim.db',
      ),
    ],
  ];
}

String? findSeforimDb() {
  for (final c in seforimDbCandidates()) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

final _dafToc = RegExp('^דף ([א-ת"״\']+)([.:])');
final _locRe = RegExp(r'^(פרק \S+|סימן \S+|\S+[.:])(?: (הלכה \S+))?$');
final _chapterOnly = RegExp(r'^פרק (\S+)$');

/// גישה לקריאה בלבד לספרייה הרשמית של אוצריא (seforim.db).
/// מאחד את SeforimDB (מחולל הקישורים) ואת Official (בניית המסד) של המאגר המקורי.
class SeforimDb {
  SeforimDb(this.path) : db = sqlite3.open(path, mode: OpenMode.readOnly);

  final String path;
  final Database db;

  List<String>? _titles;
  final _toc = <String, List<TocRow>?>{};
  final _tocById = <int, List<TocRow>>{};
  final _refs = <String, Set<String>?>{};
  final _dafs = <String, Set<String>?>{};
  final _resolve = <(String, String), (String, int)?>{};
  ZstdLineDecoder? _decoder;

  void close() {
    _decoder?.close();
    db.close();
  }

  /// בדיקה מהירה שזה אכן מסד ספרים של אוצריא.
  static String? validate(String path) {
    if (!File(path).existsSync()) return 'הקובץ לא נמצא';
    try {
      final db = sqlite3.open(path, mode: OpenMode.readOnly);
      try {
        final t = {for (final r in db.select("SELECT name FROM sqlite_master WHERE type='table'")) r['name'] as String};
        for (final need in ['book', 'line', 'tocEntry', 'tocText']) {
          if (!t.contains(need)) return 'זה אינו מסד ספרים של אוצריא (חסרה הטבלה $need)';
        }
        return null;
      } finally {
        db.close();
      }
    } on SqliteException catch (e) {
      return 'לא ניתן לפתוח את הקובץ: ${e.message}';
    }
  }

  /// מפענח טקסט השורות (המילונים נטענים בפעם הראשונה).
  ZstdLineDecoder get decoder => _decoder ??= ZstdLineDecoder([
    if (hasTable('zstd_dict'))
      for (final r in db.select('SELECT dict FROM zstd_dict')) r['dict'] as Uint8List,
  ]);

  bool hasTable(String name) =>
      db.select("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [name]).isNotEmpty;

  /// המילון של line_content (לדחיסת המסד האישי באותו מילון), או null.
  (int, Uint8List)? lineDictionary() {
    if (!hasTable('zstd_dict')) return null;
    final rows = db.select('SELECT id, dict FROM zstd_dict ORDER BY id');
    if (rows.length != 1) return null;
    return (rows.first['id'] as int, rows.first['dict'] as Uint8List);
  }

  List<String> titles() =>
      _titles ??= [for (final r in db.select('SELECT title FROM book ORDER BY title')) r['title'] as String];

  bool hasBook(String title) => db.select('SELECT 1 FROM book WHERE title=? LIMIT 1', [title]).isNotEmpty;

  List<int> bookIds(String title) => [
    for (final r in db.select('SELECT id FROM book WHERE title=?', [title])) r['id'] as int,
  ];

  List<TocRow> _tocOf(int bookId) => _tocById[bookId] ??= [
    for (final r in db.select(
      'SELECT e.id, e.parentId, e.level, t.text, e.lineId FROM tocEntry e JOIN tocText t ON t.id=e.textId '
      'WHERE e.bookId=? ORDER BY e.id',
      [bookId],
    ))
      TocRow(r['id'] as int, r['parentId'] as int?, r['level'] as int, r['text'] as String, r['lineId'] as int?),
  ];

  /// תוכן העניינים של הספר, או null אם אינו קיים.
  List<TocRow>? toc(String title) {
    if (_toc.containsKey(title)) return _toc[title];
    final r = db.select('SELECT id FROM book WHERE title=? LIMIT 1', [title]);
    return _toc[title] = r.isEmpty ? null : _tocOf(r.first['id'] as int);
  }

  /// דפים ("ב.", "ב:") של מסכת, או null.
  Set<String>? dafset(String title) {
    if (_dafs.containsKey(title)) return _dafs[title];
    final e = toc(title);
    if (e == null || e.isEmpty) return _dafs[title] = null;
    final s = <String>{};
    for (final x in e) {
      final m = _dafToc.matchAsPrefix(x.text.trim());
      if (m != null) s.add(m[1]! + m[2]!);
    }
    return _dafs[title] = s;
  }

  /// זוגות (הורה, ילד) של רמה 2, למשל ("פרק א", "הלכה ד").
  Set<(String, String)>? hset(String title) {
    final e = toc(title);
    if (e == null || e.isEmpty) return null;
    final byId = {for (final x in e) x.id: x};
    return {
      for (final x in e)
        if (x.level == 2 && byId.containsKey(x.parentId)) (byId[x.parentId]!.text.trim(), x.text.trim()),
    };
  }

  /// כותרות רמה 1 (פרקים / סימנים).
  Set<String>? chset(String title) {
    final e = toc(title);
    if (e == null || e.isEmpty) return null;
    return {
      for (final x in e)
        if (x.level == 1) x.text.trim(),
    };
  }

  /// כל המיקומים החוקיים בספר: כל כותרת, "הורה ילד", ודפים בלי המילה "דף".
  Set<String>? validRefs(String title) {
    if (_refs.containsKey(title)) return _refs[title];
    final e = toc(title);
    if (e == null) return _refs[title] = null;
    final byId = {for (final x in e) x.id: x};
    final out = <String>{};
    for (final x in e) {
      final t = x.text.trim();
      out.add(t);
      if (t.startsWith('דף ')) out.add(t.substring(3));
      if (byId.containsKey(x.parentId) && x.level >= 2) out.add('${byId[x.parentId]!.text.trim()} $t');
    }
    return _refs[title] = out;
  }

  /// "ספר + פרק [+ הלכה]" או "מסכת + דף" -> (heRef, lineIndex) בספרייה הרשמית, או null.
  (String, int)? resolve(String title, String location) {
    final key = (title, location);
    if (_resolve.containsKey(key)) return _resolve[key];
    (String, int)? res;
    final b = bookIds(title);
    final m = _locRe.firstMatch(location);
    if (b.length == 1 && m != null) {
      final bid = b.first;
      var chap = m[1]!;
      final hal = m[2];
      if (chap.endsWith('.') || chap.endsWith(':')) chap = 'דף $chap';
      final ents = _tocOf(bid);
      int? cid;
      for (final e in ents) {
        if (e.level == 1 && e.text == chap) {
          cid = e.id;
          break;
        }
      }
      TocRow? target;
      if (cid != null) {
        for (final e in ents) {
          if (hal == null ? e.id == cid : (e.parentId == cid && e.text == hal)) {
            target = e;
            break;
          }
        }
      }
      if (target != null && target.lineId != null) {
        final li = db.select('SELECT lineIndex FROM line WHERE id=?', [target.lineId]);
        if (li.isNotEmpty) {
          final row = db.select(
            'SELECT lineIndex, heRef FROM line WHERE bookId=? AND lineIndex>=? AND heRef IS NOT NULL '
            'ORDER BY lineIndex LIMIT 1',
            [bid, li.first['lineIndex']],
          );
          if (row.isNotEmpty) res = (row.first['heRef'] as String, row.first['lineIndex'] as int);
        }
      }
    }
    return _resolve[key] = res;
  }

  /// (heRef, lineIndex) של כל פסוקי הפרק ביעד, לפי הסדר. null אם אינו תנ"ך ברמת פרק.
  List<(String, int)>? verses(String title, String location) {
    if (_chapterOnly.firstMatch(location) == null) return null;
    final b = bookIds(title);
    if (b.length != 1) return null;
    final res = resolve(title, location);
    if (res == null || ', '.allMatches(res.$1).length != 2) return null;
    final chapter = res.$1.substring(0, res.$1.lastIndexOf(', '));
    return [
      for (final r in db.select(
        'SELECT lineIndex, heRef FROM line WHERE bookId=? AND heRef LIKE ? ORDER BY lineIndex',
        [b.first, '$chapter, %'],
      ))
        (r['heRef'] as String, r['lineIndex'] as int),
    ];
  }
}
