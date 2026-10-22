// עבודות רקע של מסך יצירת הכותרות: כולן פונקציות ברמה העליונה עם ארגומנטים שניתן לשלוח בין isolates
// (בלי RegExp ובלי ווידג'טים), כדי שהממשק לא ייתקע בקבצים גדולים.

import 'dart:io';

import '../../engine/errors.dart';
import '../../headers/book_builder.dart';
import '../../headers/docx_reader.dart';
import '../../headers/header_utils.dart';
import '../../headers/md_import.dart';
import '../../headers/txt_headers.dart';
import '../../services/jobs.dart';

enum SourceKind { docx, txt, md, doc, unknown }

SourceKind kindOfPath(String path) {
  final l = path.toLowerCase();
  if (l.endsWith('.docx') || l.endsWith('.dotx')) return SourceKind.docx;
  if (l.endsWith('.doc') || l.endsWith('.rtf')) return SourceKind.doc;
  if (l.endsWith('.md') || l.endsWith('.markdown')) return SourceKind.md;
  if (l.endsWith('.txt')) return SourceKind.txt;
  return SourceKind.unknown;
}

String kindLabel(SourceKind k) => switch (k) {
      SourceKind.docx => 'מסמך Word',
      SourceKind.txt => 'קובץ טקסט',
      SourceKind.md => 'קובץ Markdown',
      SourceKind.doc => 'Word ישן',
      SourceKind.unknown => 'סוג לא מוכר',
    };

// ───────────────────────────── טעינה ─────────────────────────────

class LoadArgs {
  const LoadArgs(this.path, this.kind, {this.baseHalfPts, this.noteHalfPts});
  final String path;
  final SourceKind kind;
  final int? baseHalfPts, noteHalfPts;
}

class LoadResult {
  LoadResult({
    required this.lines,
    required this.notes,
    required this.kind,
    this.detBase = 0,
    this.detNote = 0,
    this.usedBase = 0,
    this.usedNote = 0,
    this.styleHeadings = 0,
    this.detectedTitle,
  });
  final List<String> lines;
  final List<String> notes;
  final SourceKind kind;

  /// חצאי נקודות (Word בלבד).
  final int detBase, detNote, usedBase, usedNote;

  /// מספר כותרות בעיצוב של וורד / Markdown.
  final int styleHeadings;
  final String? detectedTitle;
}

LoadResult loadSourceJob(LoadArgs a, JobContext ctx) {
  ctx.progress('קורא את הקובץ', '', null);
  switch (a.kind) {
    case SourceKind.docx:
      final r = importDocx(
        a.path,
        baseHalfPts: a.baseHalfPts,
        noteHalfPts: a.noteHalfPts,
        progress: (f) => ctx.progress('קורא את הקובץ', '', f),
      );
      final n = r.stats.headingsPerLevel.values.fold<int>(0, (s, v) => s + v);
      return LoadResult(
        lines: r.lines,
        notes: r.notes,
        kind: a.kind,
        detBase: r.detectedBaseHalfPts,
        detNote: r.detectedNoteHalfPts,
        usedBase: r.baseHalfPts,
        usedNote: r.noteHalfPts,
        styleHeadings: n,
      );
    case SourceKind.md:
      final r = importMarkdown(a.path);
      return LoadResult(
        lines: r.lines,
        notes: r.notes,
        kind: a.kind,
        styleHeadings: r.headingCount.values.fold<int>(0, (s, v) => s + v),
        detectedTitle: r.detectedTitle,
      );
    case SourceKind.txt:
    case SourceKind.unknown:
      return LoadResult(lines: loadBookTextLines(a.path), notes: const [], kind: SourceKind.txt);
    case SourceKind.doc:
      throw AppError('זהו קובץ Word ישן (doc). פתחו אותו ב-Word ושמרו בשם כ-docx, ואז נסו שוב.');
  }
}

// ───────────────────────────── כללים ─────────────────────────────

/// כלל מותאם אישית שהמשתמש הוסיף.
class CustomSpec {
  const CustomSpec(this.regex, this.text);

  /// true = ביטוי רגולרי; false = "מתחילה ב...".
  final bool regex;
  final String text;

  String get id => regex ? 'custom:$text' : 'starts:${collapseWs(text)}';

  HeadingRule build({int? level}) =>
      regex ? HeadingRule.regex(text, level: level) : HeadingRule.startsWith(text, level: level);
}

List<HeadingRule> _rules(List<String> presetIds, Map<String, int> levels, List<CustomSpec> customs) {
  final out = <HeadingRule>[];
  for (final r in headingPresets()) {
    if (presetIds.contains(r.id)) out.add(levels.containsKey(r.id) ? r.copyWith(level: levels[r.id]) : r);
  }
  for (final c in customs) {
    if (presetIds.contains(c.id)) out.add(c.build(level: levels[c.id]));
  }
  return out;
}

/// כותרת מוצעת, בצורה שניתן לשלוח בין isolates.
class HeadDto {
  HeadDto({
    required this.index,
    required this.text,
    required this.plain,
    required this.ruleId,
    required this.ruleLabel,
    required this.level,
    required this.existing,
    required this.isWhole,
    this.included = true,
    this.manual = false,
  });
  final int index;
  final String text, plain;
  final String? ruleId;
  final String ruleLabel;
  int level;
  final bool existing, isWhole, manual;
  bool included;
}

class DetectArgs {
  const DetectArgs(this.lines, this.title, this.presetIds, this.levels, this.customs);
  final List<String> lines;
  final String title;
  final List<String> presetIds;
  final Map<String, int> levels;
  final List<CustomSpec> customs;
}

List<HeadDto> detectJob(DetectArgs a, JobContext ctx) {
  ctx.progress('מחפש כותרות', '', null);
  final hs = detectHeadings(a.lines, _rules(a.presetIds, a.levels, a.customs), title: a.title);
  return [
    for (final h in hs)
      HeadDto(
        index: h.index,
        text: h.text,
        plain: h.plain,
        ruleId: h.rule?.id,
        ruleLabel: h.rule?.label ?? 'כותרת שכבר קיימת בקובץ',
        level: h.level,
        existing: h.existing,
        isWhole: h.isWhole,
        // סימון שהוא רק תחילת פסקה אינו כותרת: מוצג, אך כבוי כברירת מחדל
        included: h.isWhole,
      ),
  ];
}

class CountArgs {
  const CountArgs(this.lines, this.customs);
  final List<String> lines;
  final List<CustomSpec> customs;
}

/// כמה שורות מתאימות לכל כלל (בנפרד, בלי תחרות בין כללים). מפתח = מזהה כלל.
Map<String, int> countRulesJob(CountArgs a, JobContext ctx) {
  ctx.progress('בודק אילו כותרות יש בקובץ', '', null);
  final rules = [...headingPresets(), for (final c in a.customs) c.build()];
  final counts = {for (final r in rules) r.id: 0};
  final plains = <String?>[
    for (final l in a.lines) headingOpenRe.hasMatch(l) ? null : plainText(l).trim(),
  ];
  for (var i = 0; i < a.lines.length; i++) {
    final plain = plains[i];
    if (plain == null || plain.isEmpty) continue;
    for (final r in rules) {
      if (plain.length > r.maxChars) continue;
      if (r.pattern.hasMatch(r.onRaw ? a.lines[i] : plain)) counts[r.id] = counts[r.id]! + 1;
    }
  }
  return counts;
}

// ───────────────────────────── בנייה ─────────────────────────────

class BuildArgs {
  const BuildArgs({
    required this.lines,
    required this.notes,
    required this.title,
    required this.author,
    required this.heads,
    required this.separateNotes,
  });
  final List<String> lines, notes;
  final String title, author;
  final List<HeadDto> heads;
  final bool separateNotes;
}

BuiltBook buildJob(BuildArgs a, JobContext ctx) {
  ctx.progress('בונה את הספר', '', null);
  final lines = [...a.lines];
  final accepted = <HeadingSuggestion>[];
  for (final h in a.heads) {
    if (h.existing) {
      // כותרות קיימות נכתבות מחדש לפי הבחירה: הסרה = טקסט רגיל; אחרת הרמה הנוכחית
      if (!h.included) {
        lines[h.index] = plainText(lines[h.index]).trim();
      } else {
        final m = headingFullRe.firstMatch(lines[h.index]);
        if (m != null) lines[h.index] = '<h${h.level}>${m[2]}</h${h.level}>';
      }
    } else if (h.included) {
      accepted.add(HeadingSuggestion(
        index: h.index,
        text: h.text,
        plain: h.plain,
        rule: null,
        level: h.level,
        isWhole: h.isWhole,
      ));
    }
  }
  return buildBook(
    lines: lines,
    title: a.title,
    author: a.author,
    accepted: accepted,
    notes: a.notes,
    footnotes: a.separateNotes ? FootnoteMode.separate : FootnoteMode.inline,
  );
}

// ───────────────────────────── שמירה ─────────────────────────────

class SaveArgs {
  const SaveArgs(this.book, this.dir, this.overwrite);
  final BuiltBook book;
  final String dir;
  final bool overwrite;
}

List<String> saveJob(SaveArgs a, JobContext ctx) {
  ctx.progress('שומר את הספר', '', null);
  Directory(a.dir).createSync(recursive: true);
  return writeBookFiles(a.book, a.dir, overwrite: a.overwrite, linksDir: a.dir);
}

/// שם ברירת מחדל לספר מתוך שם הקובץ.
String guessTitle(String path) {
  var n = path.split(RegExp(r'[\\/]')).last;
  final dot = n.lastIndexOf('.');
  if (dot > 0) n = n.substring(0, dot);
  n = n.replaceAll(RegExp(r'[_]+'), ' ').replaceAll(RegExp(r'\s*\(\d+\)$'), '');
  return cleanBookTitle(n);
}

/// בוחר אוטומטית את הכללים שמתאימים היטב: מעט כללים "חזקים" קודם, והכלליים רק אם אין אחרים.
Set<String> autoPickRules(Map<String, int> counts, int lineCount) {
  const weak = {'numbering', 'boldLine', 'shortLine'};
  final strong = <String>{};
  for (final r in headingPresets()) {
    if (weak.contains(r.id)) continue;
    final c = counts[r.id] ?? 0;
    final need = (r.id == 'masechet' || r.id == 'intro' || r.id == 'section') ? 1 : 2;
    if (c >= need && c <= lineCount * 0.3) strong.add(r.id);
  }
  if (strong.isNotEmpty) return strong;
  final out = <String>{};
  for (final id in const ['boldLine', 'numbering']) {
    final c = counts[id] ?? 0;
    if (c >= 3 && c <= lineCount * 0.1) {
      out.add(id);
      break;
    }
  }
  return out;
}
