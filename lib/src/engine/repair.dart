// בדיקה ותיקון של קישורים קיימים: תרגום של plan_repair / apply_repair / summarize_report מ-linker_core.py.
//
// לכל קבוצה (ספר מקור, קטגוריה) בקבצי links.csv משווים את הקישורים הקיימים לקישורים שהמנוע
// מייצר היום מקובץ הספר, מזהים הזזת שורות (-2..3) לפי Jaccard, ומתקנים. כל כתיבה מגובה ב-zip.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'common.dart';
import 'linker_core.dart';
import 'seforim_db.dart';

/// הזזות שנבדקות (כמו range(-2, 4) במקור).
const repairShifts = [-2, -1, 0, 1, 2, 3];

/// סף התאמה (Jaccard) לשיוך קבוצה לקובץ ספר.
const repairMinMatch = 0.5;

enum RepairStatus {
  ok('תקין'),
  updated('עודכן'),
  unchecked('לא נבדק'),
  manual('ידני'),
  added('חדש');

  const RepairStatus(this.label);
  final String label;
}

/// שורה בדוח: קבוצה אחת (ספר מקור, קטגוריה).
class RepairEntry {
  const RepairEntry({
    required this.stem,
    required this.category,
    required this.status,
    required this.oldCount,
    required this.newCount,
    this.shift,
    this.note = '',
  });
  final String stem;
  final String category;
  final RepairStatus status;
  final int oldCount;
  final int newCount;

  /// הזזת השורות שזוהתה (null = לא רלוונטי).
  final int? shift;
  final String note;
}

/// ספר חדש שיש לו כלל יצירה ואין לו קישורים.
class RepairAddition {
  const RepairAddition(this.stem, this.rows);
  final String stem;
  final List<List<String>> rows;
}

/// תוכנית תיקון (לא נכתב דבר עד [applyRepair]).
class RepairPlan {
  RepairPlan({
    required this.report,
    required this.newFor,
    required this.additions,
    required this.files,
    required this.paths,
    required this.linksDir,
  });
  final List<RepairEntry> report;

  /// (ספר, קטגוריה) -> השורות החדשות שיחליפו את הקבוצה.
  final Map<(String, String), List<List<String>>> newFor;
  final List<RepairAddition> additions;

  /// נתיב קובץ links.csv -> שורותיו (כולל כותרת).
  final Map<String, List<List<String>>> files;

  /// (ספר, קטגוריה) -> קובץ הספר ששויך לקבוצה.
  final Map<(String, String), String> paths;
  final String linksDir;

  /// האם יש מה לכתוב.
  bool get hasChanges =>
      additions.isNotEmpty || report.any((r) => r.status == RepairStatus.updated);
}

class RepairResult {
  const RepairResult({required this.changedFiles, this.backupPath, this.additionsPath});

  /// כמה קבצי links.csv קיימים נכתבו מחדש.
  final int changedFiles;

  /// נתיב ה-zip של הגיבוי (null אם לא התבקש).
  final String? backupPath;

  /// הקובץ שנכתבו אליו קישורים חדשים (null אם אין).
  final String? additionsPath;
}

/// כל קבצי הקישורים של המשתמש (קישורים*/NN/links.csv וגם */links.csv), כולל כותרת.
Map<String, List<List<String>>> _loadFiles(String linksDir) => {
  for (final f in userLinkCsvFiles(linksDir)) f: readCsv(f),
};

/// מנוע מובנה על קובץ ספר: מפה, או null אם מצביע git-lfs, או ריקה אם אין כלל יצירה.
LinkMap? _expected(SeforimDb db, String stem, List<String> rel, String path, Map<String, LinkMap?> cache) {
  if (cache.containsKey(path)) return cache[path];
  final lines = readBookLines(path);
  if (isLfsPointer(lines)) return cache[path] = null;
  final kind = detectKind(rel, stem);
  return cache[path] = kind == null ? <int, (String, String)>{} : builtinExpected(kind, rel, stem, lines, db).$1;
}

class _Group {
  _Group(this.category, this.rows);
  final String category;
  final List<List<String>> rows;
}

/// בונה תוכנית תיקון בלי לכתוב כלום.
/// [manual]: ספרי מקור שלא נוגעים בהם. [progress]: הודעות; [checkCancel]: זורק Cancelled.
RepairPlan planRepair({
  required String booksDir,
  required String linksDir,
  required SeforimDb db,
  Set<String> manual = const {},
  void Function(String msg)? progress,
  void Function()? checkCancel,
}) {
  void say(String m) => progress?.call(m);
  final files = _loadFiles(linksDir);
  say('נטענו ${files.length} קבצי קישורים');

  // קבוצות לפי (ספר מקור, קטגוריה), בסדר הופעה
  final groups = <(String, String), List<List<String>>>{};
  for (final rows in files.values) {
    for (final r in rows.skip(1)) {
      if (r.length >= 8) (groups[(r[1], r[7])] ??= []).add(r);
    }
  }
  final books = booksByStem(scanBooks(booksDir, includeRoot: true));
  final cache = <String, LinkMap?>{};
  final report = <RepairEntry>[];
  final newFor = <(String, String), List<List<String>>>{};
  final paths = <(String, String), String>{};

  final byStem = <String, List<_Group>>{};
  groups.forEach((k, rows) => (byStem[k.$1] ??= []).add(_Group(k.$2, rows)));

  var n = 0;
  for (final MapEntry(key: stem, value: glist) in byStem.entries) {
    checkCancel?.call();
    n++;
    if (n % 50 == 0) say('נבדקו $n מתוך ${byStem.length} ספרי מקור');

    if (manual.contains(stem)) {
      for (final g in glist) {
        report.add(
          RepairEntry(
            stem: stem,
            category: g.category,
            status: RepairStatus.manual,
            oldCount: g.rows.length,
            newCount: g.rows.length,
            note: 'לא נבדק: מוגדר כידני',
          ),
        );
      }
      continue;
    }

    // הקישורים הקיימים: שורה -> {(יעד, מיקום)}
    final olds = <Map<int, Set<(String, String)>>>[];
    for (final g in glist) {
      final old = <int, Set<(String, String)>>{};
      for (final r in g.rows) {
        final ln = int.tryParse(r[0]);
        if (ln != null) (old[ln] ??= {}).add((r[3], r[4]));
      }
      olds.add(old);
    }

    // קבצי הספר המועמדים (עם כלל יצירה)
    final cl = <(BookFile, LinkMap)>[];
    var anyLfs = false;
    final bl = books[stem] ?? const <BookFile>[];
    for (final b in bl) {
      final e = _expected(db, stem, b.rel, b.path, cache);
      if (e == null) {
        anyLfs = true;
      } else if (e.isNotEmpty) {
        cl.add((b, e));
      }
    }

    // התאמת כל קבוצה לכל קובץ, עם הזזה מיטבית
    final pairs = <(double, int, int, int)>[]; // (jaccard, קבוצה, קובץ, הזזה)
    for (var gi = 0; gi < olds.length; gi++) {
      final old = olds[gi];
      final nOld = old.values.fold<int>(0, (a, v) => a + v.length);
      for (var ci = 0; ci < cl.length; ci++) {
        final exp = cl[ci].$2;
        var bj = 0.0, bs = 0;
        for (final s in repairShifts) {
          var m = 0;
          old.forEach((ln, ts) {
            final e = exp[ln + s];
            if (e != null && ts.contains(e)) m++;
          });
          final denom = nOld + exp.length - m;
          final j = denom != 0 ? m / denom : 0.0;
          if (j > bj) {
            bj = j;
            bs = s;
          }
        }
        pairs.add((bj, gi, ci, bs));
      }
    }
    // כמו מיון tuple יורד בפייתון
    pairs.sort((a, b) {
      var c = b.$1.compareTo(a.$1);
      if (c != 0) return c;
      c = b.$2.compareTo(a.$2);
      if (c != 0) return c;
      c = b.$3.compareTo(a.$3);
      return c != 0 ? c : b.$4.compareTo(a.$4);
    });
    final gdone = <int>{}, cdone = <int>{};
    final assign = <int, (int, int, double)>{};
    for (final (j, gi, ci, s) in pairs) {
      if (j < repairMinMatch || gdone.contains(gi) || cdone.contains(ci)) continue;
      gdone.add(gi);
      cdone.add(ci);
      assign[gi] = (ci, s, j);
    }

    for (var gi = 0; gi < glist.length; gi++) {
      final g = glist[gi];
      final nOld = g.rows.length;
      final a = assign[gi];
      if (a == null) {
        final why = anyLfs
            ? 'קובץ git-lfs (מצביע): לא נבדק'
            : bl.isEmpty
            ? 'אין קובץ בתיקיית הספרים'
            : 'אין קובץ מתאים לקבוצה (חפיפה נמוכה או שאין כלל יצירה)';
        report.add(
          RepairEntry(
            stem: stem,
            category: g.category,
            status: RepairStatus.unchecked,
            oldCount: nOld,
            newCount: nOld,
            note: why,
          ),
        );
        continue;
      }
      final (ci, s, j) = a;
      final (book, exp) = cl[ci];
      final first = g.rows.first;
      final keys = exp.keys.toList()..sort();
      final rows = [
        for (final ln in keys) ['$ln', stem, first[2], exp[ln]!.$1, exp[ln]!.$2, first[5], first[6], g.category],
      ];
      newFor[(stem, g.category)] = rows;
      paths[(stem, g.category)] = book.path;
      report.add(
        RepairEntry(
          stem: stem,
          category: g.category,
          status: s == 0 && j == 1.0 ? RepairStatus.ok : RepairStatus.updated,
          oldCount: nOld,
          newCount: rows.length,
          shift: s,
          note: 'התאמה ${(j * 100).round()}%',
        ),
      );
    }
  }

  // ספרים בלי קבוצה שיש להם כלל יצירה
  final additions = <RepairAddition>[];
  for (final MapEntry(key: stem, value: lst) in books.entries) {
    if (manual.contains(stem) || byStem.containsKey(stem) || lst.length != 1) continue;
    checkCancel?.call();
    final b = lst.first;
    final exp = _expected(db, stem, b.rel, b.path, cache);
    if (exp == null || exp.isEmpty) continue;
    final nrel = normalizeRel(b.rel);
    final typ = nrel.length >= 2 && nrel[0] == 'תנ״ך' && nrel[1] == 'תרגומים' ? 'תרגום' : 'פירוש';
    additions.add(RepairAddition(stem, linksRows(stem, exp, linkType: typ)));
    report.add(
      RepairEntry(
        stem: stem,
        category: '',
        status: RepairStatus.added,
        oldCount: 0,
        newCount: exp.length,
        note: 'ספר בלי קישורים שיש לו כלל יצירה',
      ),
    );
  }
  return RepairPlan(
    report: report,
    newFor: newFor,
    additions: additions,
    files: files,
    paths: paths,
    linksDir: linksDir,
  );
}

String _stamp() {
  final t = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

/// כותב את התוכנית. אם [backupDir] מוגדר, קודם מגבה את כל קבצי הקישורים ל-zip.
/// קישורים חדשים לספרים בלי קבוצה נכתבים ל-`<newDir>/links.csv`.
RepairResult applyRepair(
  RepairPlan plan, {
  required String newDir,
  String? backupDir,
  void Function(String msg)? progress,
  void Function()? checkCancel,
}) {
  void say(String m) => progress?.call(m);
  String? zipPath;
  if (backupDir != null) {
    Directory(backupDir).createSync(recursive: true);
    final arc = Archive();
    for (final f in plan.files.keys) {
      // נתיב יחסי לתיקיית הקישורים, כדי ששני קבצים באותו שם תיקייה לא יתנגשו
      final name = p.posix.joinAll(p.split(p.relative(f, from: plan.linksDir)));
      arc.add(ArchiveFile.bytes(name, File(f).readAsBytesSync()));
    }
    // קובץ הקישורים החדשים שקיים כבר ולא נקרא בתוכנית: גם הוא ייכתב מחדש, אז נכנס לגיבוי
    final addFile = File(p.join(newDir, 'links.csv'));
    if (plan.additions.isNotEmpty && addFile.existsSync() && !plan.files.containsKey(addFile.path)) {
      final name = p.posix.joinAll(p.split(p.relative(addFile.path, from: plan.linksDir)));
      arc.add(ArchiveFile.bytes(name, addFile.readAsBytesSync()));
    }
    zipPath = p.join(backupDir, 'links_backup_${_stamp()}.zip');
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(arc));
    say('גיבוי נשמר: $zipPath');
  }
  var changed = 0;
  for (final MapEntry(key: path, value: rows) in plan.files.entries) {
    checkCancel?.call();
    final out = <List<String>>[];
    final emitted = <(String, String)>{};
    var ch = false;
    for (final r in rows.skip(1)) {
      final key = r.length >= 8 ? (r[1], r[7]) : null;
      if (key != null && plan.newFor.containsKey(key)) {
        ch = true;
        if (emitted.add(key)) out.addAll(plan.newFor[key]!);
        continue;
      }
      out.add(r);
    }
    if (ch) {
      writeCsv(path, [linkHeader, ...out]);
      changed++;
    }
  }
  String? addPath;
  if (plan.additions.isNotEmpty) {
    addPath = p.join(newDir, 'links.csv');
    final existing = File(addPath).existsSync() ? readCsv(addPath).skip(1).toList() : <List<String>>[];
    final names = {for (final a in plan.additions) a.stem};
    final rows = [
      for (final r in existing)
        if (r.length < 2 || !names.contains(r[1])) r,
      for (final a in plan.additions) ...a.rows,
    ];
    writeCsv(addPath, [linkHeader, ...rows]);
    say('קישורים חדשים ל-${plan.additions.length} ספרים ב-$addPath');
  }
  say('נכתבו $changed קבצים קיימים');
  return RepairResult(changedFiles: changed, backupPath: zipPath, additionsPath: addPath);
}

/// ספירת הדוח לפי סטטוס.
Map<RepairStatus, int> summarizeReport(List<RepairEntry> report) {
  final c = <RepairStatus, int>{};
  for (final r in report) {
    c[r.status] = (c[r.status] ?? 0) + 1;
  }
  return c;
}
