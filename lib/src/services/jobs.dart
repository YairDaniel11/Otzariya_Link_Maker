import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../engine/auto_links.dart';
import '../engine/common.dart';
import '../engine/errors.dart';
import '../engine/linker_core.dart';
import '../engine/seforim_db.dart';


/// הקשר של עבודה שרצה ב-isolate: דיווח התקדמות ובדיקת ביטול.
class JobContext {
  JobContext(this._send, this._flagAddress);
  final SendPort _send;
  final int _flagAddress;
  final _clock = Stopwatch()..start();
  var _lastTitle = '';

  void progress(String title, String detail, double? fraction) {
    // מצמצם הודעות: כותרת חדשה תמיד, ועדכוני פרטים לכל היותר כל 80ms
    if (title == _lastTitle && _clock.elapsedMilliseconds < 80) return;
    _lastTitle = title;
    _clock.reset();
    _send.send((title, detail, fraction));
  }

  void checkCancel() {
    if (Pointer<Uint8>.fromAddress(_flagAddress).value != 0) throw Cancelled();
  }
}

typedef ProgressListener = void Function(String title, String detail, double? fraction);

/// מריץ [fn] על [arg] ב-isolate נפרד, כדי שהממשק לא ייתקע. [isCancelled] נבדק כמה פעמים בשנייה.
Future<T> runJob<A, T>(
  T Function(A arg, JobContext ctx) fn,
  A arg, {
  ProgressListener? onProgress,
  bool Function()? isCancelled,
}) async {
  final port = ReceivePort();
  final sub = port.listen((m) {
    if (m is (String, String, double?)) onProgress?.call(m.$1, m.$2, m.$3);
  });
  // בית אחד בזיכרון נייטיבי: הדבר היחיד ששני ה-isolates יכולים לחלוק.
  final flag = malloc.allocate<Uint8>(1)..value = 0;
  final poll = Timer.periodic(const Duration(milliseconds: 150), (_) {
    if (isCancelled?.call() ?? false) flag.value = 1;
  });
  try {
    return await _spawn(fn, arg, flag.address, port.sendPort);
  } finally {
    poll.cancel();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    port.close();
    malloc.free(flag);
  }
}

/// ה-closure נוצר כאן ולא ב-[runJob] בכוונה: closure שומר את ההקשר שבו נוצר, ושם יש אובייקטים שאי אפשר לשלוח.
Future<T> _spawn<A, T>(T Function(A, JobContext) fn, A arg, int flag, SendPort send) =>
    Isolate.run(() => fn(arg, JobContext(send, flag)));

// ═══════════════════════════ עבודות: יצירת קישורים ═══════════════════════════
// (סוכנים אחרים מוסיפים את העבודות שלהם בסעיפים משלהם בהמשך הקובץ.)

/// פרטי קובץ ספר שנבחר: מספר שורות וכותרות.
class BookInfo {
  BookInfo(this.path, this.stem, this.lines, this.headings, this.isLfs);
  final String path;
  final String stem;
  final int lines;
  final int headings;
  final bool isLfs;
}

BookInfo bookInfoJob(String path, JobContext ctx) {
  final lines = readBookLines(path);
  var heads = 0;
  for (final l in lines) {
    if (headLoose.hasMatch(l.trim())) heads++;
  }
  return BookInfo(path, p.basenameWithoutExtension(path), lines.length, heads, isLfsPointer(lines));
}

/// כל שמות הספרים בספרייה הרשמית (לבחירת יעד).
List<String> titlesJob(String dbPath, JobContext ctx) {
  final db = SeforimDb(dbPath);
  try {
    return List.of(db.titles());
  } finally {
    db.close();
  }
}

/// איך מקשרים ספר: מנוע מובנה, כללים שנבחרו, או זיהוי לפי מבנה ספר היעד ([profile] ו-[builtinKind] ריקים).
class LinkPlan {
  const LinkPlan({this.builtinKind, this.rel = const [], this.target = '', this.profile, this.label = ''});
  final String? builtinKind;
  final List<String> rel;
  final String target;
  final Profile? profile;
  final String label;
}

/// נתיב התיקיות של הקובץ מתחילת הסיווג המוכר (תלמוד בבלי, תנ"ך), כדי שהמנועים המובנים יזהו אותו.
List<String> relFromPath(String path) {
  final dirs = p.split(p.dirname(path));
  const roots = {'תלמוד בבלי', 'תנ״ך', 'תנך', 'ספרים שאינם מותאמים לאוצריא'};
  final i = dirs.indexWhere(roots.contains);
  return i < 0 ? const [] : dirs.sublist(i);
}

int _bodyLines(List<String> lines) {
  var n = 0;
  for (var i = 3; i <= lines.length; i++) {
    final s = lines[i - 1].trim();
    if (s.isNotEmpty && !s.startsWith('<h') && !headLoose.hasMatch(s)) n++;
  }
  return n;
}

enum DetectStatus { found, lowCoverage, notFound }

class DetectResult {
  DetectResult(this.path, this.stem, this.status, {this.target = '', this.plan, this.coverage, this.reason = ''});
  final String path;
  final String stem;
  final DetectStatus status;
  final String target;
  final LinkPlan? plan;
  final double? coverage;
  final String reason;
}

class DetectArgs {
  DetectArgs(this.dbPath, this.paths);
  final String dbPath;
  final List<String> paths;
}

/// זיהוי אוטומטי של ספר היעד לכל קובץ (מנוע מובנה, ואחרת לפי שם הקובץ ומבנה הכותרות).
List<DetectResult> detectJob(DetectArgs a, JobContext ctx) {
  final db = SeforimDb(a.dbPath);
  try {
    Map<String, String>? index;
    final out = <DetectResult>[];
    for (final path in a.paths) {
      ctx.checkCancel();
      final stem = p.basenameWithoutExtension(path);
      ctx.progress('מזהה את הספר שהקובץ מפרש', stem, null);
      final lines = readBookLines(path);
      final body = _bodyLines(lines);
      final rel = relFromPath(path);
      var note = '';
      final kind = detectKind(rel, stem);
      if (kind != null) {
        final (exp, n, _) = builtinExpected(kind, rel, stem, lines, db);
        if (exp.isNotEmpty) {
          final targets = {for (final v in exp.values) v.$1};
          out.add(
            DetectResult(
              path,
              stem,
              DetectStatus.found,
              target: targets.join(', '),
              coverage: body == 0 ? null : exp.length / body,
              plan: LinkPlan(builtinKind: kind, rel: rel, label: kindLabels[kind]!),
            ),
          );
          continue;
        }
        note = n;
      }
      index ??= titleIndex(db);
      final target = findTarget(stem, index);
      if (target == null) {
        out.add(
          DetectResult(path, stem, DetectStatus.notFound, reason: note.isNotEmpty ? note : 'לא זוהה ספר יעד בשם הקובץ'),
        );
        continue;
      }
      final (inf, _, cov) = inferBook(lines, target, db, stem);
      out.add(
        DetectResult(
          path,
          stem,
          inf == null ? DetectStatus.lowCoverage : DetectStatus.found,
          target: target,
          coverage: inf?.coverage ?? cov,
          plan: LinkPlan(target: target, label: inf?.name ?? ''),
        ),
      );
    }
    return out;
  } finally {
    db.close();
  }
}

class PreviewArgs {
  PreviewArgs(this.dbPath, this.items, {this.sampleSize = 30});
  final String dbPath;
  final List<(String, LinkPlan)> items;
  final int sampleSize;
}

class FilePreview {
  FilePreview({
    required this.path,
    required this.stem,
    required this.totalLines,
    required this.body,
    required this.rows,
    required this.linkType,
    required this.notes,
    required this.unmatched,
    required this.method,
  });
  final String path;
  final String stem;
  final int totalLines;
  final int body;
  final LinkMap rows;
  final String linkType;
  final List<String> notes;
  final Map<String, int> unmatched;
  final String method;

  double get coverage => body == 0 ? 0 : rows.length / body;
}

class PreviewRow {
  PreviewRow(this.stem, this.line, this.text, this.target, this.location);
  final String stem;
  final int line;
  final String text;
  final String target;
  final String location;
}

class PreviewResult {
  PreviewResult(this.files, this.samples);
  final List<FilePreview> files;
  final List<PreviewRow> samples;

  int get links => files.fold(0, (a, f) => a + f.rows.length);
  int get body => files.fold(0, (a, f) => a + f.body);
  double get coverage => body == 0 ? 0 : links / body;
}

/// תצוגה מקדימה: מחשבת את הקישורים של כל קובץ לפי התוכנית שלו, ובוחרת דוגמאות מפוזרות.
PreviewResult previewJob(PreviewArgs a, JobContext ctx) {
  final db = SeforimDb(a.dbPath);
  try {
    final files = <FilePreview>[];
    final texts = <String, List<String>>{};
    for (final (path, plan) in a.items) {
      ctx.checkCancel();
      final stem = p.basenameWithoutExtension(path);
      ctx.progress('מחשב קישורים', stem, null);
      final lines = readBookLines(path);
      texts[path] = lines;
      final body = _bodyLines(lines);
      FilePreview make(LinkMap rows, String type, String method, List<String> notes, Map<String, int> un) =>
          FilePreview(
            path: path,
            stem: stem,
            totalLines: lines.length,
            body: body,
            rows: rows,
            linkType: type,
            notes: notes,
            unmatched: un,
            method: method,
          );
      if (isLfsPointer(lines)) {
        files.add(make({}, 'פירוש', '', ['הקובץ הוא מצביע ריק (git-lfs) ולא הספר עצמו'], {}));
      } else if (plan.builtinKind != null) {
        final (rows, note, type) = builtinExpected(plan.builtinKind!, plan.rel, stem, lines, db);
        files.add(make(rows, type, plan.label, [if (note.isNotEmpty) note], {}));
      } else if (plan.profile != null) {
        final r = runProfile(lines, plan.profile!, db, stem);
        files.add(make(r.rows, plan.profile!.linkType, plan.label, r.notes, r.unmatched));
      } else {
        // לפי מבנה ספר היעד: הכלל שקושר הכי הרבה שורות
        ProfileResult? best;
        var name = '';
        for (final (n, prof) in baseProfiles(plan.target, db)) {
          final r = runProfile(lines, prof, db, stem);
          if (best == null || r.rows.length > best.rows.length) {
            best = r;
            name = n;
          }
        }
        files.add(make(best?.rows ?? {}, 'פירוש', name, best?.notes ?? const [], best?.unmatched ?? {}));
      }
    }
    final all = <(FilePreview, int)>[
      for (final f in files)
        for (final ln in (f.rows.keys.toList()..sort())) (f, ln),
    ];
    final samples = <PreviewRow>[];
    if (all.isNotEmpty) {
      final n = all.length < a.sampleSize ? all.length : a.sampleSize;
      for (var k = 0; k < n; k++) {
        final (f, ln) = all[(k * all.length / n).floor()];
        final (t, loc) = f.rows[ln]!;
        final text = removeTags(texts[f.path]![ln - 1]).trim();
        samples.add(PreviewRow(f.stem, ln, text.length > 80 ? text.substring(0, 80) : text, t, loc));
      }
    }
    return PreviewResult(files, samples);
  } finally {
    db.close();
  }
}

// ═══════════════════════════ עבודות: כותרות ═══════════════════════════
// (נקודת הרחבה: סוכן הכותרות מוסיף כאן.)

// ═══════════════════════════ עבודות: בדיקת קישורים ═══════════════════════════
// (נקודת הרחבה: סוכן בדיקת הקישורים מוסיף כאן.)

