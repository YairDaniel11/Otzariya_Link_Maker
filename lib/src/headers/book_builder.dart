// בניית ספר אוצריא מלא משורות + כותרות מאושרות: שורות 1-2, נרמול כותרות והיררכיה, הערות שוליים,
// שם קובץ, קובצי לוואי, וולידציה (פורט של validate_book.py מהסקיל otzaria-book-format).
// גוף הספר אינו משתנה: רק פעולות מבניות. ללא Flutter (רץ ב-isolate).

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../engine/errors.dart';
import 'header_utils.dart';
import 'txt_headers.dart';

enum IssueSeverity { error, warning, info }

class ValidationIssue {
  ValidationIssue(this.severity, this.line, this.message);

  final IssueSeverity severity;

  /// מספר שורה מ-1; 0 = הודעה כללית.
  final int line;
  final String message;

  @override
  String toString() => '[${severity.name}] ${line == 0 ? '' : 'שורה $line: '}$message';
}

enum FootnoteMode { inline, separate }

class SkippedHeading {
  SkippedHeading(this.index, this.text, this.reason);

  /// אינדקס השורה (מ-0) ברשימה שהועברה ל-[buildBook].
  final int index;
  final String text;
  final String reason;
}

class BuiltBook {
  BuiltBook({
    required this.lines,
    required this.notesLines,
    required this.linksJson,
    required this.fileName,
    required this.notesFileName,
    required this.linksFileName,
    required this.issues,
    required this.skipped,
    required this.headingsPerLevel,
    required this.footnoteCount,
  });

  /// שורות הספר הסופיות (שורה 1 = h1, שורה 2 = מחבר או ריקה).
  final List<String> lines;

  /// קובץ ההערות (מצב separate): שורה N = הערה N, בלי h1. ריק במצב inline.
  final List<String> notesLines;

  /// תוכן ה-_links.json (מצב separate, כשיש הערות), אחרת null.
  final String? linksJson;

  /// שם קובץ הספר (מנוקה, עם .txt), קובץ ההערות, וקובץ הקישורים.
  final String fileName, notesFileName, linksFileName;
  final List<ValidationIssue> issues;

  /// כותרות מאושרות שלא הוחלו, עם הסיבה.
  final List<SkippedHeading> skipped;

  /// מספר כותרות לכל רמה (h2-h6; בלי h1 של שם הספר).
  final Map<int, int> headingsPerLevel;

  /// מספר הערות שהומרו.
  final int footnoteCount;

  bool get hasErrors => issues.any((i) => i.severity == IssueSeverity.error);
}

// ───────────────────────────── וולידציה ─────────────────────────────

const _voidTags = {'br', 'hr', 'img', 'wbr', 'col', 'source'};
const _documentedTags = {
  'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'b', 'strong', 'i', 'em', 'var', 'cite', 'dfn', 'big', 'small', 'u', 'ins', 's', 'del', //
  'strike', 'acronym', 'abbr', 'mark', 'sup', 'sub', 'a', 'details', 'summary', 'ol', 'ul', 'li', 'table', 'tr', 'td', 'th', //
  'caption', 'thead', 'tbody', 'div', 'p', 'blockquote', 'center', 'hr', 'pre', 'code', 'br', 'img', 'ruby', 'rt', 'rp', 'span', 'font',
};
const _reservedClasses = {
  'footnote-marker-number', 'book-note-marker', 'numbered-note-marker', 'link-anchor', 'link-anchor-active', 'link-anchor-range',
};

final _vTag = RegExp(r'<\s*(/?)\s*([a-zA-Z][a-zA-Z0-9]*)([^>]*)>');
final _vHeadFull = RegExp(r'^\s*<\s*h([1-6])\b[^>]*>(.*?)</\s*h\1\s*>\s*$', caseSensitive: false, dotAll: true);
final _vMdHead = RegExp(r'^\s*#{1,6}\s+\S');
final _vFnMarker = RegExp(r'<sup\b[^>]*\bfootnote-marker\b[^>]*>(.*?)</sup>', caseSensitive: false, dotAll: true);
final _vFnBody = RegExp(r'<i\b[^>]*\bclass\s*=\s*"[^"]*\bfootnote\b[^"]*"[^>]*>', caseSensitive: false);
final _vSupSub = RegExp(r'<(sup|sub)\b([^>]*)>(.*?)</\1>', caseSensitive: false, dotAll: true);
final _vFnMarkerClass = RegExp(r'\bclass\s*=\s*"[^"]*\bfootnote-marker\b[^"]*"', caseSensitive: false);
final _vStyle = RegExp(r'style\s*=\s*"([^"]*)"', caseSensitive: false);
final _vClass = RegExp(r'class\s*=\s*"([^"]*)"', caseSensitive: false);
final _badCss = [
  (RegExp(r'\b\d*\.?\d+rem\b', caseSensitive: false), 'יחידת rem אינה נתמכת - em או אחוזים'),
  (RegExp(r'font-style\s*:\s*oblique', caseSensitive: false), 'font-style: oblique אינו נתמך - italic'),
  (RegExp(r'font-weight\s*:\s*(bolder|lighter)', caseSensitive: false), 'font-weight: bolder/lighter אינו נתמך - bold או 100-900'),
  (RegExp(r'text-emphasis', caseSensitive: false), 'text-emphasis הופך אותיות והמילה מוצגת הפוכה'),
  (RegExp(r'text-decoration-thickness\s*:\s*[\d.]+px', caseSensitive: false), 'text-decoration-thickness בפיקסלים אינו נתמך - אחוזים'),
  (RegExp(r'\b(position|transform|float|opacity|border-radius|animation|transition)\s*:', caseSensitive: false), 'תכונה שאינה נתמכת בקורא'),
  (RegExp(r'rebeccapurple', caseSensitive: false), 'שם הצבע rebeccapurple אינו נתמך - קוד HEX'),
];

/// "תיבות" בשורה (היפוך RTL): sup עם תכונה/תג מקונן, inline-block, img. sub ו-footnote-marker אינם תיבה.
List<String> _countBoxes(String line) {
  final boxes = <String>[];
  for (final m in _vSupSub.allMatches(line)) {
    if (m[1]!.toLowerCase() == 'sub') continue;
    final attrs = m[2]!, inner = m[3]!;
    if (_vFnMarkerClass.hasMatch(attrs)) continue;
    if (attrs.trim().isEmpty && !_vTag.hasMatch(inner)) continue;
    boxes.add('<sup> ${attrs.trim().isNotEmpty ? 'עם תכונה' : 'עם תג מקונן'}');
  }
  for (final m in _vStyle.allMatches(line)) {
    if (RegExp(r'display\s*:\s*inline-block', caseSensitive: false).hasMatch(m[1]!)) boxes.add('display:inline-block');
  }
  for (final m in _vTag.allMatches(line)) {
    if (m[2]!.toLowerCase() == 'img' && m[1]!.isEmpty) boxes.add('<img>');
  }
  return boxes;
}

void _checkBalance(String line, int n, List<ValidationIssue> out) {
  final stack = <String>[];
  for (final m in _vTag.allMatches(line)) {
    final closing = m[1]!.isNotEmpty, tag = m[2]!.toLowerCase(), attrs = m[3]!;
    if (_voidTags.contains(tag) || attrs.trimRight().endsWith('/')) continue;
    if (!closing) {
      stack.add(tag);
    } else {
      if (stack.isEmpty) {
        out.add(ValidationIssue(IssueSeverity.error, n, 'תג סוגר </$tag> בלי תג פותח באותה שורה'));
        return;
      }
      if (stack.last != tag) {
        if (stack.contains(tag)) {
          out.add(ValidationIssue(IssueSeverity.warning, n, 'קינון בסדר שגוי: נסגר </$tag> בעוד <${stack.last}> פתוח'));
          while (stack.isNotEmpty && stack.last != tag) {
            stack.removeLast();
          }
          stack.removeLast();
          continue;
        }
        out.add(ValidationIssue(IssueSeverity.error, n, 'תג סוגר </$tag> בלי תג פותח תואם'));
        return;
      }
      stack.removeLast();
    }
  }
  if (stack.isNotEmpty) {
    out.add(ValidationIssue(IssueSeverity.error, n, 'תגים שנפתחו ולא נסגרו בשורה: ${stack.map((t) => '<$t>').join(', ')}'));
  }
}

void _checkFootnotes(String line, int n, List<ValidationIssue> out) {
  final markers = _vFnMarker.allMatches(line).toList();
  final bodies = _vFnBody.allMatches(line).toList();
  if (markers.isEmpty && bodies.isEmpty) return;
  if (markers.length != bodies.length) {
    out.add(ValidationIssue(IssueSeverity.error, n, 'הערות שוליים לא מאוזנות: ${markers.length} סמנים מול ${bodies.length} גופי הערה'));
  }
  for (final m in markers) {
    final rest = line.substring(m.end);
    if (_vFnBody.matchAsPrefix(rest.trimLeft()) == null) {
      out.add(ValidationIssue(IssueSeverity.error, n, 'סמן הערה footnote-marker שאין אחריו <i class="footnote"> צמוד'));
    } else if (rest.startsWith(' ') || rest.startsWith('\t')) {
      out.add(ValidationIssue(IssueSeverity.warning, n, 'רווח בין סמן ההערה לגוף ההערה - נדרשת צמידות מלאה'));
    }
    if (plainText(m[1]!).trim().isEmpty) out.add(ValidationIssue(IssueSeverity.error, n, 'סמן הערה ריק'));
  }
}

/// בדיקות מבנה של ספר (שורות הקובץ, בלי שורה ריקה אחרונה). [stem] = שם הקובץ בלי סיומת (להשוואה ל-h1).
/// [isNotesFile] = קובץ "הערות על ..." (בלי h1).
List<ValidationIssue> validateBookLines(List<String> lines, {String? stem, bool isNotesFile = false}) {
  final out = <ValidationIssue>[];
  void err(int l, String m) => out.add(ValidationIssue(IssueSeverity.error, l, m));
  void warn(int l, String m) => out.add(ValidationIssue(IssueSeverity.warning, l, m));
  if (lines.isEmpty) {
    err(0, 'קובץ ריק');
    return out;
  }
  final first = lines[0].replaceAll('﻿', '').trim();
  if (isNotesFile) {
    if (headingOpenRe.hasMatch(first)) warn(1, 'קובץ הערות שמתחיל בכותרת - הערה N יושבת בשורה N+1');
  } else {
    final m1 = _vHeadFull.firstMatch(first);
    if (m1 == null || m1[1] != '1') {
      err(1, 'שורה 1 חייבת להיות <h1>שם הספר</h1> לבדה');
    } else if (stem != null) {
      final t = plainText(m1[2]!).trim();
      if (sanitizeFileName(t) != sanitizeFileName(stem)) warn(1, 'שם ב-<h1> ("$t") שונה משם הקובץ ("$stem") גם אחרי ניקוי');
    }
    if (lines.length > 1) {
      final second = lines[1].trim();
      if (second.isNotEmpty && headingOpenRe.hasMatch(second)) warn(2, 'שורה 2 היא כותרת - המוסכמה היא שם המחבר או שורה ריקה');
    }
  }

  var h1Count = 0, lastLevel = 0;
  for (var k = 0; k < lines.length; k++) {
    final i = k + 1, line = lines[k];
    if (line.trim().isEmpty) continue;
    if (line != line.trimRight()) warn(i, 'רווחים בסוף השורה');
    final low = line.toLowerCase();
    if (low.contains('<script')) err(i, '<script> חסום לחלוטין');
    if (low.contains('<style')) err(i, '<style> אינו נתמך - אין CSS גלובלי');
    if (_vMdHead.hasMatch(line)) err(i, 'כותרת בסגנון Markdown - הסולמיות יוצגו כטקסט; השתמשו ב-<h2>..<h6>');

    final hm = headingOpenRe.firstMatch(line);
    if (hm != null) {
      final level = int.parse(hm[1]!);
      if (level > 6) {
        err(i, '<h$level> אינו קיים בתקן; מותר h1-h6');
      } else {
        final full = _vHeadFull.firstMatch(line.trim());
        if (full == null) {
          err(i, 'כותרת שאינה תופסת את השורה כולה - הטקסט שאחריה נבלע לתוך שם הכותרת בתוכן העניינים');
        } else {
          if (plainText(full[2]!).trim().isEmpty) err(i, 'כותרת ריקה');
          if (RegExp(r'<big\b', caseSensitive: false).hasMatch(full[2]!)) warn(i, '<big> בתוך כותרת - כותרות כבר מוגדלות ומודגשות');
        }
        if (level == 1) {
          h1Count++;
          if (i != 1) warn(i, '<h1> נוסף באמצע הקובץ - המוסכמה היא h1 אחד, בשורה 1');
        }
        final excluded = low.contains('data-toc="none"');
        if (!excluded && lastLevel != 0 && level > lastLevel + 1) {
          err(i, 'דילוג רמת כותרת: h$lastLevel <- h$level; הקינון חייב להיות רציף');
        }
        if (!excluded) lastLevel = level;
      }
    }

    _checkBalance(line, i, out);
    _checkFootnotes(line, i, out);
    final boxes = _countBoxes(line);
    if (boxes.length > 1) err(i, 'יותר מ"תיבה" אחת בשורה (${boxes.join(' · ')}) - הטקסט יוצג הפוך ב-RTL');

    for (final m in _vStyle.allMatches(line)) {
      final style = m[1]!;
      for (final (rx, msg) in _badCss) {
        if (rx.hasMatch(style)) err(i, msg);
      }
      if (RegExp(r'text-align\s*:', caseSensitive: false).hasMatch(style)) {
        final open = RegExp(r'<\s*([a-zA-Z][a-zA-Z0-9]*)[^>]*$').allMatches(line.substring(0, m.start)).toList();
        if (open.isNotEmpty && open.last[1]!.toLowerCase() == 'span') err(i, 'text-align על <span> אינו עובד - תג בלוק בלבד');
      }
    }
    for (final m in _vClass.allMatches(line)) {
      for (final c in m[1]!.split(RegExp(r'\s+'))) {
        if (_reservedClasses.contains(c)) err(i, 'class="$c" שמור לשימוש פנימי של התוכנה');
      }
    }
    if (RegExp(r'\sid\s*="').hasMatch(line)) warn(i, 'התכונה id אינה משמשת לקישורים באוצריא');
    for (final m in _vTag.allMatches(line)) {
      final tag = m[2]!.toLowerCase();
      if (!_documentedTags.contains(tag) && !RegExp(r'^h[1-9][0-9]?$').hasMatch(tag)) warn(i, '<$tag> אינו ברשימת התגים המתועדים - בדקו בפועל באפליקציה');
    }
  }
  if (!isNotesFile && h1Count == 0) err(1, 'אין <h1> בקובץ');
  return out;
}

// ───────────────────────────── בנייה ─────────────────────────────

class _Item {
  _Item.body(this.text)
      : level = 0,
        fromAccepted = false;
  _Item.heading(this.level, this.text, {this.fromAccepted = false});
  String text;
  int level; // 0 = שורת גוף
  final bool fromAccepted;
  bool get isHeading => level > 0;
}

final _bareSup = RegExp(r'<sup>(\d+)</sup>');

String _noteBody(String note) =>
    note.replaceAll('\n', ' ').replaceAll('<i>', '<em>').replaceAll('</i>', '</em>'); // i בתוך גוף ההערה ישבור את זיהוי הגוף

/// בונה ספר סופי.
/// [lines] = שורות הגוף (מ-[importDocx] או [loadBookTextLines]); [accepted] = כותרות שאושרו מ-[detectHeadings]
/// (קיימות מוחלות תמיד). כותרות שאינן שורה שלמה, או שהשורה נעלמה, מדווחות ב-skipped.
/// [normalizeHeadings]: ניקוי טקסט כותרות, רצף רמות מ-h2 בלי דילוגים. [insertMissingParents]: כשהכותרת
/// הראשונה עמוקה מ-h2 - להוסיף כותרות הורה בשם הספר (אחרת הרמות מועלות).
/// שורת h1 בתחילת [lines] ששמה כשם הספר מוסרת (ואחריה שורת המחבר אם זהה ל-[author]).
/// [notes] = גופי הערות; מצב inline: סימן <sup>N</sup> (בסדר עולה) הופך לסמן+גוף צמודים; מצב separate: קובץ הערות + links.
BuiltBook buildBook({
  required List<String> lines,
  required String title,
  String author = '',
  required List<HeadingSuggestion> accepted,
  bool normalizeHeadings = true,
  FootnoteMode footnotes = FootnoteMode.inline,
  List<String> notes = const [],
  bool insertMissingParents = false,
  bool removeEmptyLines = false,
}) {
  final cleanTitle = cleanBookTitle(title);
  if (cleanTitle.isEmpty) throw AppError('חסר שם לספר.');
  final stem = sanitizeFileName(cleanTitle);
  final infos = <(_Item, IssueSeverity, String)>[]; // (פריט, חומרה, הודעה) - מספר שורה מחושב בסוף
  final skipped = <SkippedHeading>[];
  final src = [for (final l in lines) l.replaceAll('﻿', '')];

  final ti = titleLineIndex(src, cleanTitle);
  final dropped = <int>{};
  if (ti >= 0) {
    dropped.add(ti);
    final a = author.trim();
    if (a.isNotEmpty && ti + 1 < src.length && src[ti + 1].trim() == a) dropped.add(ti + 1);
  }
  final emap = existingLevelMap(src, skip: ti);
  final acc = <int, HeadingSuggestion>{
    for (final s in accepted)
      if (!s.existing) s.index: s,
  };

  // שלב 1: פירוק לפריטים (גוף/כותרת)
  final items = <_Item>[];
  final srcIdx = <_Item, int>{};
  for (var i = 0; i < src.length; i++) {
    if (dropped.contains(i)) continue;
    final line = src[i];
    _Item add(_Item it) {
      items.add(it);
      srcIdx[it] = i;
      return it;
    }

    final s = acc[i];
    if (headingOpenRe.hasMatch(line)) {
      final full = headingFullRe.firstMatch(line);
      final tail = headingTailRe.firstMatch(line);
      if (s != null) skipped.add(SkippedHeading(i, line, 'השורה כבר כותרת'));
      if (full != null) {
        final raw = int.parse(full[1]!);
        add(_Item.heading(normalizeHeadings ? emap[raw]! : raw, full[2]!));
      } else if (tail != null && tail[3]!.trim().isNotEmpty) {
        final raw = int.parse(tail[1]!);
        final h = add(_Item.heading(normalizeHeadings ? emap[raw]! : raw, tail[2]!));
        add(_Item.body(tail[3]!.trim()));
        infos.add((h, IssueSeverity.info, 'טקסט שבא אחרי הכותרת באותה שורה הועבר לשורה משלו'));
      } else {
        add(_Item.body(line));
      }
      continue;
    }
    if (s == null) {
      add(_Item.body(line));
      continue;
    }
    final plain = plainText(line).trim();
    if (plain.isEmpty) {
      skipped.add(SkippedHeading(i, line, 'שורה ריקה'));
      add(_Item.body(line));
    } else if (!s.isWhole) {
      skipped.add(SkippedHeading(i, line, 'הסימון הוא רק תחילת השורה, לא כותרת שלמה'));
      add(_Item.body(line));
    } else {
      add(_Item.heading(s.level.clamp(2, 6), line, fromAccepted: true));
    }
  }

  // שלב 2: ניקוי טקסט כותרות (בסדר, בגלל "עמוד ב" שמסתמך על הדף הקודם)
  if (normalizeHeadings) {
    final daf = DafTracker();
    for (var k = 0; k < items.length; k++) {
      final it = items[k];
      if (!it.isHeading) continue;
      final t = cleanHeadingText(it.text, daf: daf);
      if (t.isEmpty) {
        skipped.add(SkippedHeading(srcIdx[it]!, it.text, 'הכותרת ריקה אחרי ניקוי'));
        items[k] = _Item.body(it.text);
        srcIdx[items[k]] = srcIdx[it]!;
      } else {
        it.text = t;
      }
    }
  }

  // שלב 3: רצף רמות
  if (normalizeHeadings) {
    final used = (items.where((e) => e.isHeading).map((e) => e.level).toSet().toList())..sort();
    final map = {for (var i = 0; i < used.length; i++) used[i]: (2 + i).clamp(2, 6)};
    for (final it in items) {
      if (it.isHeading) it.level = map[it.level]!;
    }
    var last = 1;
    final fixed = <_Item>[];
    for (final it in items) {
      if (it.isHeading) {
        if (it.level > last + 1) {
          if (insertMissingParents && last == 1) {
            for (var l = 2; l < it.level; l++) {
              fixed.add(_Item.heading(l, escapeAngle(cleanTitle)));
            }
            infos.add((it, IssueSeverity.info, 'נוספו כותרות הורה בשם הספר כי הכותרת הראשונה עמוקה מ-h2'));
          } else {
            infos.add((it, IssueSeverity.info, 'רמת הכותרת הועלתה מ-h${it.level} ל-h${last + 1} כדי שלא יהיה דילוג'));
            it.level = last + 1;
          }
        }
        last = it.level;
      }
      fixed.add(it);
    }
    items
      ..clear()
      ..addAll(fixed);
  }

  // שלב 4: הרכבת השורות (שורה 1-2 + גוף)
  final out = <String>[
    '<h1>${escapeAngle(cleanTitle)}</h1>',
    escapeAngle(collapseWs(author)),
  ];
  final lineOfItem = <_Item, int>{};
  for (final it in items) {
    if (!it.isHeading && removeEmptyLines && it.text.trim().isEmpty) {
      lineOfItem[it] = out.length + 1;
      continue;
    }
    out.add(it.isHeading ? '<h${it.level}>${it.text.trim()}</h${it.level}>' : it.text);
    lineOfItem[it] = out.length;
  }
  final issues = <ValidationIssue>[];
  for (final (it, sev, msg) in infos) {
    issues.add(ValidationIssue(sev, lineOfItem[it] ?? 0, msg));
  }
  for (final s in skipped) {
    issues.add(ValidationIssue(IssueSeverity.warning, 0, 'שורה ${s.index + 1} לא סומנה ככותרת: ${s.reason} ("${_clip(plainText(s.text))}")'));
  }

  // שלב 5: הערות שוליים
  var converted = 0;
  final notesLines = <String>[];
  final links = <Map<String, Object>>[];
  if (notes.isNotEmpty) {
    var next = 1;
    for (var k = 2; k < out.length; k++) {
      out[k] = out[k].replaceAllMapped(_bareSup, (m) {
        final n = int.parse(m[1]!);
        if (n != next || n > notes.length) return m[0]!;
        next++;
        converted++;
        if (footnotes == FootnoteMode.inline) {
          return '<sup class="footnote-marker">$n</sup><i class="footnote">${_noteBody(notes[n - 1])}</i>';
        }
        links.add({
          'line_index_1': k + 1,
          'line_index_2': n,
          'heRef_2': 'הערות',
          'path_2': 'הערות על $stem.txt',
          'Conection Type': 'footnotes',
        });
        return '<sup style="color: gray;">$n</sup>';
      });
    }
    if (converted < notes.length) {
      issues.add(ValidationIssue(IssueSeverity.warning, 0, 'ל-${notes.length - converted} הערות לא נמצא סימן מתאים בגוף הטקסט'));
    }
    if (footnotes == FootnoteMode.separate) {
      notesLines.addAll(notes.map(_noteBody));
      for (final l in links) {
        final ln = l['line_index_1'] as int;
        if (headingOpenRe.hasMatch(out[ln - 1])) {
          issues.add(ValidationIssue(IssueSeverity.warning, ln, 'סימן הערה בתוך כותרת - קישור אינו יכול להצביע על שורת כותרת'));
        }
      }
    }
  }

  issues.addAll(validateBookLines(out, stem: stem));
  final per = <int, int>{};
  for (var k = 1; k < out.length; k++) {
    final m = headingFullRe.firstMatch(out[k]);
    if (m != null) per[int.parse(m[1]!)] = (per[int.parse(m[1]!)] ?? 0) + 1;
  }
  return BuiltBook(
    lines: out,
    notesLines: notesLines,
    linksJson: links.isEmpty ? null : '${const JsonEncoder.withIndent('  ').convert(links)}\n',
    fileName: '$stem.txt',
    notesFileName: 'הערות על $stem.txt',
    linksFileName: '${stem}_links.json',
    issues: issues,
    skipped: skipped,
    headingsPerLevel: per,
    footnoteCount: converted,
  );
}

String _clip(String s) {
  final t = collapseWs(s);
  return t.length > 40 ? '${t.substring(0, 40)}...' : t;
}

// ───────────────────────────── כתיבה ─────────────────────────────

/// שורות -> טקסט (מחובר ב-\n, בלי BOM ובלי שורה ריקה בסוף).
String serializeBook(List<String> lines) => lines.join('\n');

/// כותב את הספר (UTF-8 בלי BOM, LF) לתיקייה [dir]; קובץ הערות (מצב separate) לצידו;
/// [linksDir] (אם ניתן) מקבל את ה-_links.json. קובץ קיים: [AppError] אלא אם [overwrite]. מחזיר נתיבים שנכתבו.
List<String> writeBookFiles(BuiltBook book, String dir, {bool overwrite = false, String? linksDir}) {
  final targets = <(String, String)>[(p.join(dir, book.fileName), serializeBook(book.lines))];
  if (book.notesLines.isNotEmpty) targets.add((p.join(dir, book.notesFileName), serializeBook(book.notesLines)));
  if (linksDir != null && book.linksJson != null) targets.add((p.join(linksDir, book.linksFileName), book.linksJson!));
  if (!overwrite) {
    for (final (path, _) in targets) {
      if (File(path).existsSync()) throw AppError('הקובץ כבר קיים: $path');
    }
  }
  final written = <String>[];
  for (final (path, text) in targets) {
    Directory(p.dirname(path)).createSync(recursive: true);
    File(path).writeAsBytesSync(utf8.encode(text));
    written.add(path);
  }
  return written;
}
