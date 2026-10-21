// יצירת קישורים אוטומטית לספרים: תרגום של auto_links.py.
//
// שני שלבים:
//   1. כללים מובנים (בבלי, ירושלמי שקלים, תנ"ך, הגהות אשרי, ספרי הלכה מוגדרים).
//   2. זיהוי כללי: מתוך שם הקובץ מנסים להבין על איזה ספר הוא מפרש, ובוחרים את כלל הכותרות
//      שמתאים למבנה ספר היעד. הקישור נכתב רק אם רוב שורות הספר קושרו.
// בנוסף (תוספת של התוכנה): המשתמש יכול לבחור יעד ידנית לספר, או לבטל לו קישורים.

import 'common.dart';
import 'linker_core.dart';
import 'seforim_db.dart';

const minCoverage = 0.5; // לפחות חצי משורות התוכן חייבות להיקשר
const minLinked = 3;

final _q = RegExp(r'''["״“”'׳’‘,.]''');
final _ws = RegExp(r'\s+');

/// השוואת שמות: בלי גרשיים, פסיקים ונקודות, ורווחים אחידים.
String norm(String t) => t.replaceAll(_q, '').replaceAll(_ws, ' ').trim();

final _trailingParen = RegExp(r'\s*\(.*?\)\s*$');
final _trailingNum = RegExp(r'\s+(ועוד|\d+)$');
final _dash = RegExp(r'\s[-–]\s');
final _al = RegExp(r'(?:^|\s)על\s+');

/// מועמדים לשם ספר היעד מתוך שם הקובץ, מהארוך לקצר; והשם המלא המנורמל.
(List<String>, String) targetCandidates(String stem) {
  var s = stem.replaceAll(_trailingParen, '').trim();
  s = s.replaceAll(_trailingNum, '').trim();
  final c = <String>[s, ...s.split(_dash)];
  for (final m in _al.allMatches(s)) {
    final tail = s.substring(m.end);
    c.add(tail);
    c.addAll(tail.split(_dash));
  }
  final normed = [
    for (final x in c)
      if (x.trim().isNotEmpty) norm(x),
  ];
  stableSort<String>(normed, (a, b) => b.length.compareTo(a.length));
  final seen = <String>{};
  final out = <String>[];
  for (final x in normed) {
    if (seen.add(x)) out.add(x);
  }
  return (out, norm(s));
}

/// אינדקס שמות הספרייה הרשמית: שם מנורמל -> שם מדויק (הראשון לפי סדר אלפביתי).
Map<String, String> titleIndex(SeforimDb db) {
  final index = <String, String>{};
  for (final t in db.titles()) {
    index.putIfAbsent(norm(t), () => t);
  }
  return index;
}

String? findTarget(String stem, Map<String, String> index) {
  final (cands, whole) = targetCandidates(stem);
  for (final c in cands) {
    if (c == whole) continue; // שם הקובץ עצמו הוא ספר רשמי: אין מה לקשר אותו לעצמו
    final t = index[c];
    if (t != null) return t;
  }
  return null;
}

const _labels = {'תנ"ך: פרק לפי כותרת ברמה 2': 'כותרת ברמה 2 כמיקום'};

/// פרופילים אפשריים לפי מבנה ספר היעד.
List<(String, Profile)> baseProfiles(String target, SeforimDb db) {
  final d = db.dafset(target);
  if (d != null && d.isNotEmpty) {
    return [
      (
        'דפים',
        Profile(
          target: target,
          resetOnUnmatched: true,
          rules: const [
            Rule('daf', formats: ['std', 'ext']),
          ],
        ),
      ),
    ];
  }
  final out = <(String, Profile)>[];
  presets.forEach((name, prof) {
    if (name.startsWith('בבלי') || name.startsWith('פרק ברמה 2 והלכה')) return;
    out.add((_labels[name] ?? name, prof.withTarget(target)));
  });
  out.add(('פרק והלכה', presets['פרק ברמה 2 והלכה או סימן ברמה 3']!.withTarget(target)));
  return out;
}

class Inferred {
  Inferred(this.rows, this.name, this.coverage);
  final LinkMap rows;
  final String name;
  final double coverage;
}

/// סיבת כישלון של זיהוי לפי מבנה, לדיווח.
enum InferFail { noBody, tooFew, lowCoverage }

/// הכלל הטוב ביותר לספר מול היעד: (תוצאה, null) או (null, סיבה).
(Inferred?, InferFail?, double) inferBook(List<String> lines, String target, SeforimDb db, String stem) {
  var body = 0;
  for (var i = 1; i <= lines.length; i++) {
    final s = lines[i - 1].trim();
    if (i > 1 && s.isNotEmpty && !headLoose.hasMatch(s)) body++;
  }
  if (body == 0) return (null, InferFail.noBody, 0);
  (LinkMap, String)? best;
  for (final (name, prof) in baseProfiles(target, db)) {
    final rows = runProfile(lines, prof, db, stem).rows;
    if (best == null || rows.length > best.$1.length) best = (rows, name);
  }
  if (best == null || best.$1.length < minLinked) return (null, InferFail.tooFew, 0);
  final cov = best.$1.length / body;
  if (cov < minCoverage) return (null, InferFail.lowCoverage, cov);
  return (Inferred(best.$1, best.$2, cov), null, cov);
}

// ───────────────────────────── ניתוח ספרייה שלמה ─────────────────────────────

enum LinkStatus {
  /// נוצרו קישורים אוטומטיים.
  linked,

  /// לא נוצרו קישורים.
  notLinked,

  /// לספר יש קישורים משלו (links.csv), לא נוגעים בו.
  manual,

  /// המשתמש ביטל קישורים לספר.
  disabled,
}

class BookLinkReport {
  BookLinkReport({
    required this.stem,
    required this.rel,
    required this.status,
    this.target,
    this.method = '',
    this.reason = '',
    this.coverage,
    this.rows = const {},
    this.linkType = 'פירוש',
    this.overridden = false,
  });

  final String stem;
  final List<String> rel;
  final LinkStatus status;
  final String? target;

  /// שם הכלל שנבחר (למשל "דפים", "תלמוד בבלי (כותרות דף)").
  final String method;
  final String reason;
  final double? coverage;
  final LinkMap rows;
  final String linkType;

  /// היעד נבחר ידנית.
  final bool overridden;

  int get count => rows.length;

  /// שורות בפורמט links.csv.
  List<List<String>> csvRows() => linksRows(stem, rows, linkType: linkType);
}

/// שמות ספרי המקור שכבר יש להם קישורים בקבצי links.csv של המשתמש.
Set<String> existingLinkStems(String linksDir) {
  final out = <String>{};
  for (final f in userLinkCsvFiles(linksDir)) {
    for (final r in readCsv(f).skip(1)) {
      if (r.length > 1) out.add(r[1]);
    }
  }
  return out;
}

String _failText(InferFail f, String target, double cov, {bool chosen = false}) {
  final t = chosen ? 'נבחר היעד "$target"' : 'זוהה היעד "$target"';
  return switch (f) {
    InferFail.noBody => 'אין בספר שורות תוכן',
    InferFail.tooFew => '$t, אבל כותרות הספר לא תואמות את מבנהו (נדרשים לפחות $minLinked קישורים)',
    InferFail.lowCoverage =>
      '$t, אבל רק ${(cov * 100).round()}% מהשורות קושרו (נדרש לפחות ${(minCoverage * 100).round()}%)',
  };
}

/// מנתח את כל ספרי הספרייה ומחזיר דוח לכל ספר (כולל הקישורים עצמם).
/// [overrides]: שם ספר -> יעד שנבחר ידנית ('' = בלי קישורים).
/// [only]: לנתח רק את הספרים האלה (לניתוח מחדש אחרי שינוי יעד).
List<BookLinkReport> analyzeLinks({
  required List<BookFile> books,
  required SeforimDb db,
  required Set<String> existing,
  Map<String, String> overrides = const {},
  Set<String>? only,
  void Function(int done, int total, String stem)? onProgress,
  void Function()? checkCancel,
}) {
  final byStem = booksByStem(books);
  Map<String, String>? index;
  final stems = byStem.keys.toList()..sort();
  final out = <BookLinkReport>[];
  var n = 0;
  for (final stem in stems) {
    if (only != null && !only.contains(stem)) continue;
    checkCancel?.call();
    onProgress?.call(n++, only?.length ?? stems.length, stem);
    final lst = byStem[stem]!;
    final rel = lst.first.rel;
    BookLinkReport report(LinkStatus s, {String reason = '', String? target}) =>
        BookLinkReport(stem: stem, rel: rel, status: s, reason: reason, target: target);

    if (existing.contains(stem)) {
      out.add(report(LinkStatus.manual, reason: 'יש לספר קישורים משלך (links.csv), והם נכללים כמות שהם'));
      continue;
    }
    if (lst.length != 1) {
      out.add(report(LinkStatus.notLinked, reason: 'יש ${lst.length} ספרים בשם הזה בתיקיות שונות'));
      continue;
    }
    final lines = readBookLines(lst.first.path);
    if (isLfsPointer(lines)) {
      out.add(report(LinkStatus.notLinked, reason: 'הקובץ הוא מצביע git-lfs ולא הספר עצמו'));
      continue;
    }

    final override = overrides[stem];
    if (override != null) {
      if (override.isEmpty) {
        out.add(report(LinkStatus.disabled, reason: 'הקישורים בוטלו ידנית'));
        continue;
      }
      if (!db.hasBook(override)) {
        out.add(report(LinkStatus.notLinked, target: override, reason: 'הספר "$override" לא נמצא בספרייה הרשמית'));
        continue;
      }
      final (inf, fail, cov) = inferBook(lines, override, db, stem);
      if (inf == null) {
        out.add(
          BookLinkReport(
            stem: stem,
            rel: rel,
            status: LinkStatus.notLinked,
            target: override,
            overridden: true,
            coverage: cov,
            reason: _failText(fail!, override, cov, chosen: true),
          ),
        );
      } else {
        out.add(
          BookLinkReport(
            stem: stem,
            rel: rel,
            status: LinkStatus.linked,
            target: override,
            overridden: true,
            method: inf.name,
            coverage: inf.coverage,
            rows: inf.rows,
          ),
        );
      }
      continue;
    }

    // 1. כללים מובנים
    final kind = detectKind(rel, stem);
    String builtinNote = '';
    if (kind != null) {
      final (exp, note, _) = builtinExpected(kind, rel, stem, lines, db);
      if (exp.isNotEmpty) {
        final nrel = normalizeRel(rel);
        final type = nrel.length >= 2 && nrel[0] == 'תנ״ך' && nrel[1] == 'תרגומים' ? 'תרגום' : 'פירוש';
        final targets = {for (final v in exp.values) v.$1};
        out.add(
          BookLinkReport(
            stem: stem,
            rel: rel,
            status: LinkStatus.linked,
            target: targets.join(', '),
            method: kindLabels[kind]!,
            rows: exp,
            linkType: type,
          ),
        );
        continue;
      }
      builtinNote = note;
    }

    // 2. זיהוי כללי לפי שם הקובץ
    index ??= titleIndex(db);
    final target = findTarget(stem, index);
    if (target == null) {
      out.add(report(LinkStatus.notLinked, reason: builtinNote.isNotEmpty ? builtinNote : 'לא זוהה ספר יעד בשם הקובץ'));
      continue;
    }
    final (inf, fail, cov) = inferBook(lines, target, db, stem);
    if (inf == null) {
      out.add(
        BookLinkReport(
          stem: stem,
          rel: rel,
          status: LinkStatus.notLinked,
          target: target,
          coverage: cov,
          reason: _failText(fail!, target, cov),
        ),
      );
      continue;
    }
    out.add(
      BookLinkReport(
        stem: stem,
        rel: rel,
        status: LinkStatus.linked,
        target: target,
        method: inf.name,
        coverage: inf.coverage,
        rows: inf.rows,
      ),
    );
  }
  return out;
}
