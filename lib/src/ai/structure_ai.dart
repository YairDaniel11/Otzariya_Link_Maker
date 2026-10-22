// סריקת מבנה ספר בעזרת AI והצעת כללי יצירה (פרופיל) לפי הכותרות. תרגום של structure_ai.py.
//
// הזרימה: summarizeBook -> buildPrompt -> (AI) -> parseJsonBlob -> validateProfileJson -> runProfile (בדיקה יבשה).
// המודל מקבל רק תקציר של הכותרות (ואופציונלית כמה שורות לדוגמה), לא את הספר.

import 'dart:convert';

import '../engine/common.dart';
import '../engine/linker_core.dart';
import '../engine/profile_json.dart';
import '../engine/seforim_db.dart';
import 'ai_providers.dart';

const systemPrompt = r'''You analyse the heading structure of a Hebrew Torah book file (Otzaria format) and propose rules that link each
content line to a location in a BASE book (the book the file comments on).

The file uses HTML heading tags <h1>..<h6>. Every non-heading, non-empty line under a heading is linked to the
location that the nearest relevant heading names, inside the base book's table of contents (TOC).

Return ONLY one JSON object (no markdown, no commentary) with this schema:
{
  "name": "short description",
  "target": "exact title of the base book as it appears in the library TOC list I give you, or \"\" if the target comes from the file name / headings",
  "target_from_name": true|false,         // true when the tractate (masechet) is named in the file name
  "link_type": "פירוש",
  "validate": true,
  "rules": [ ... ]
}
Rule types:
  {"type":"daf","levels":[2,6],"formats":["std","ext"]}
      headings that are a Talmud page: "ב." / "ג:" (std), or "יד, ב" / "דף ב ע\"א" (ext). Target = a Talmud tractate.
  {"type":"heading","levels":[2,2],"regex":"^(פרק [א-ת]+)$","ref":"{1}","role":"ref"}
      a heading matching the regex sets the location. {1},{2} are regex groups. It must equal a TOC entry text of the target book.
      role "chapter" sets a chapter only (no lines are linked by it); role "sub" builds the location from the last chapter,
      e.g. {"type":"heading","levels":[3,3],"regex":"^סימן ([א-ת]+)$","ref":"{chapter} הלכה {1}","role":"sub"}
      Combined location strings must match the TOC exactly (compare with the TOC sample I give you).
  {"type":"target_switch","levels":[2,2],"regex":"^מסכת (.+?)$"}
      a heading that changes the target book (e.g. a file with several tractates).
  {"type":"anchor"}
      lines that start with "בדף X." set the page (use only if headings give no location).

Rules: use ONLY heading levels that exist in the summary. Prefer the simplest rule set. Regexes are simple, portable regexes (no lookbehind, no named groups)
applied to the heading text without tags. Hebrew numerals look like א, ב, יד, קס. If the headings carry no location that exists in the target TOC,
return {"name":"אין מבנה מתאים","rules":[],"reason":"..."} and explain in "reason" (Hebrew).''';

final _digits = RegExp(r'\d+');
final _shortHeb = RegExp(r'(?<![א-ת])[א-ת]{1,3}(?![א-ת])');

String _cut(String s, int n) => s.length > n ? s.substring(0, n) : s;

String _pattern(String text) => _cut(text.replaceAll(_digits, '0').replaceAll(_shortHeb, '#'), 50);

/// תקציר מבנה הכותרות של ספר (נשלח למודל). [sampleLines] > 0 מוסיף שורות תוכן לדוגמה.
Map<String, dynamic> summarizeBook(List<String> lines, {int sampleLines = 0}) {
  final heads = <(int, int, String)>[];
  for (var i = 1; i <= lines.length; i++) {
    final m = headLoose.firstMatch(lines[i - 1].trim());
    if (m != null) heads.add((i, int.parse(m[1]!), stripTags(m[2]!)));
  }
  // רמה -> דפוס -> (כמות, דוגמאות); LinkedHashMap שומר סדר הופעה
  final perLevel = <int, Map<String, ({int n, List<String> examples})>>{};
  for (final (_, lv, tx) in heads) {
    final pats = perLevel.putIfAbsent(lv, () => {});
    final cur = pats[_pattern(tx)] ?? (n: 0, examples: <String>[]);
    if (cur.examples.length < 3) cur.examples.add(_cut(tx, 50));
    pats[_pattern(tx)] = (n: cur.n + 1, examples: cur.examples);
  }
  final levels = perLevel.keys.toList()..sort();
  final summary = <String, dynamic>{
    'total_lines': lines.length,
    'total_headings': heads.length,
    'levels': {for (final lv in levels) '$lv': perLevel[lv]!.values.fold<int>(0, (a, v) => a + v.n)},
    'patterns_by_level': {
      for (final lv in levels)
        '$lv': [
          for (final e in perLevel[lv]!.entries.take(14)) {'pattern': e.key, 'n': e.value.n, 'examples': e.value.examples},
        ],
    },
    'first_headings': [
      for (final (_, lv, tx) in heads.take(30)) [lv, _cut(tx, 50)],
    ],
  };
  if (sampleLines > 0) {
    final body = <String>[];
    for (final l in lines.skip(1)) {
      if (l.trim().isNotEmpty && !l.startsWith('<h')) body.add(_cut(l.trim(), 140));
      if (body.length >= sampleLines) break;
    }
    summary['sample_content_lines'] = body;
  }
  return summary;
}

final _titleSplit = RegExp('[\\s\\-_,()"\'״׳]+');

/// כותרות מ-seforim.db שנראות קשורות לשם הקובץ, כדי לעזור למודל לבחור ספר יעד.
List<String> candidateTitles(SeforimDb? db, String stem, {int limit = 25}) {
  if (db == null) return const [];
  final words = [
    for (final w in stem.split(_titleSplit))
      if (w.length >= 3 && w != 'מסכת' && w != 'על' && w != 'ספר') w,
  ];
  final scored = <(int, int, String)>[];
  for (final t in db.titles()) {
    final s = words.where(t.contains).length;
    if (s > 0) scored.add((-s, t.length, t));
  }
  scored.sort((a, b) {
    var c = a.$1.compareTo(b.$1);
    if (c == 0) c = a.$2.compareTo(b.$2);
    return c != 0 ? c : a.$3.compareTo(b.$3);
  });
  return [for (final e in scored.take(limit)) e.$3];
}

/// סיכום תוכן העניינים של ספר ביעד (רמות וכמה ערכים ראשונים), או null אם אינו קיים.
Map<String, dynamic>? tocSummary(SeforimDb db, String title, {int limit = 14}) {
  final e = db.toc(title);
  if (e == null || e.isEmpty) return null;
  final lv = <String, int>{};
  for (final x in e) {
    lv['${x.level}'] = (lv['${x.level}'] ?? 0) + 1;
  }
  return {
    'levels': lv,
    'sample': [
      for (final x in e.take(limit)) [x.level, x.text],
    ],
  };
}

const _pretty = JsonEncoder.withIndent(' ');

String buildPrompt(String stem, Map<String, dynamic> summary, {SeforimDb? db, String targetHint = '', String feedback = ''}) {
  final parts = <String>['File name: $stem', 'Heading summary (JSON):', _pretty.convert(summary)];
  final cands = candidateTitles(db, stem);
  if (targetHint.isNotEmpty) {
    final t = db == null ? null : tocSummary(db, targetHint);
    parts.add('The user says the target book is "$targetHint".');
    if (t != null) {
      parts.add('Its TOC (level -> text), first entries:\n${jsonEncode(t)}');
    } else {
      parts.add('(this title was not found in the library)');
    }
  }
  if (cands.isNotEmpty) {
    parts.add('Library titles that may be the target:\n${jsonEncode(cands)}');
    if (db != null && targetHint.isEmpty) {
      for (final c in cands.take(3)) {
        final t = tocSummary(db, c, limit: 8);
        if (t != null) parts.add('TOC of "$c": ${jsonEncode(t)}');
      }
    }
  }
  if (feedback.isNotEmpty) parts.add('Feedback on the previous attempt:\n$feedback');
  return parts.join('\n\n');
}

/// מספר שורות התוכן בספר (לא כותרת, לא ריקה, לא שורה 1): המכנה של אחוז הכיסוי.
int bodyLineCount(List<String> lines) {
  var n = 0;
  for (var i = 2; i <= lines.length; i++) {
    final s = lines[i - 1].trim();
    if (s.isNotEmpty && !headLoose.hasMatch(s)) n++;
  }
  return n;
}

/// תוצאת הצעה: ה-JSON הגולמי, הפרופיל (null אם לא תקין), שגיאות אימות ובדיקה יבשה.
class StructureProposal {
  StructureProposal({
    required this.json,
    required this.raw,
    required this.errors,
    this.profile,
    this.run,
    this.bodyLines = 0,
  });
  final Map<String, dynamic> json;
  final String raw;

  /// שגיאות אימות (ריקה = תקין). אם המודל ויתר, הסיבה ב-[reason].
  final List<String> errors;
  final Profile? profile;

  /// בדיקה יבשה על הספר (null אם הפרופיל לא תקין).
  final ProfileResult? run;
  final int bodyLines;

  String get name => '${json['name'] ?? ''}';

  /// הסבר המודל כשלא מצא מבנה מתאים.
  String get reason => '${json['reason'] ?? ''}';
  bool get ok => profile != null && errors.isEmpty;
  int get linked => run?.rows.length ?? 0;
  double get coverage => bodyLines == 0 ? 0 : linked / bodyLines;

  /// משוב אוטומטי למודל לניסיון נוסף (ריק אם אין פרופיל).
  String get feedback => run == null ? '' : refineFeedback(run!, bodyLines);
}

/// מבקש מהמודל פרופיל, מאמת אותו ומריץ בדיקה יבשה. זורק [AiError] על כשל תקשורת או JSON פגום.
Future<StructureProposal> proposeProfile({
  required AiClient client,
  required AiProvider provider,
  required String key,
  required String model,
  String tier = 'paid',
  required String stem,
  required List<String> lines,
  SeforimDb? db,
  String targetHint = '',
  int sampleLines = 0,
  String feedback = '',
  void Function(String)? progress,
}) async {
  final summary = summarizeBook(lines, sampleLines: sampleLines);
  final prompt = buildPrompt(stem, summary, db: db, targetHint: targetHint, feedback: feedback);
  final raw = await client.generate(
    provider,
    key,
    model,
    systemPrompt,
    prompt,
    maxTokens: 3000,
    tier: tier,
    jsonMode: true,
    progress: progress,
  );
  final j = parseJsonBlob(raw);
  final t = j['target'];
  if (targetHint.isNotEmpty && (t is! String || t.isEmpty) && j['target_from_name'] != true) j['target'] = targetHint;
  final errors = validateProfileJson(j);
  if (errors.isNotEmpty) return StructureProposal(json: j, raw: raw, errors: errors);
  final prof = profileFromJson(j);
  final run = runProfile(lines, prof, db, stem);
  return StructureProposal(json: j, raw: raw, errors: const [], profile: prof, run: run, bodyLines: bodyLineCount(lines));
}

/// משוב אוטומטי למודל כשהפרופיל לא מכסה מספיק שורות.
String refineFeedback(ProfileResult run, int nLines) {
  final linked = run.rows.length;
  final cov = 100.0 * linked / (nLines < 1 ? 1 : nLines);
  var msg = 'The proposed profile linked $linked of $nLines lines (${cov.toStringAsFixed(1)}%).';
  if (run.unmatched.isNotEmpty) {
    msg += ' Headings that no rule matched (text, count): ${jsonEncode(run.unmatched)}';
  }
  if (run.notes.isNotEmpty) msg += ' Notes: ${run.notes.join('; ')}';
  msg += ' Fix the rules so that the location strings match the target TOC exactly.';
  return msg;
}
