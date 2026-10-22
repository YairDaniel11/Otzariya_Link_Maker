// זיהוי כותרות בטקסט רגיל (TXT, או Word בלי סגנונות כותרת): טעינת קובץ, כללים מוכנים, והצעת רמות.
// ללא Flutter (רץ ב-isolate).

import 'dart:convert';
import 'dart:io';

import '../engine/errors.dart';
import 'header_utils.dart';

// ───────────────────────────── טעינה ─────────────────────────────

const _cp1255Hi = {
  0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021, //
  0x88: 0x02C6, 0x89: 0x2030, 0x8B: 0x2039, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, //
  0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC, 0x99: 0x2122, 0x9B: 0x203A, 0xA4: 0x20AA,
};

String _decodeCp1255(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    if (b < 0x80) {
      sb.writeCharCode(b);
    } else if (b >= 0xE0 && b <= 0xFA) {
      sb.writeCharCode(0x05D0 + b - 0xE0);
    } else if (b >= 0xC0 && b <= 0xD3) {
      sb.writeCharCode(0x05B0 + b - 0xC0);
    } else if (b >= 0xD4 && b <= 0xD8) {
      sb.writeCharCode(0x05F0 + b - 0xD4);
    } else if (b == 0xFD) {
      sb.writeCharCode(0x200E);
    } else if (b == 0xFE) {
      sb.writeCharCode(0x200F);
    } else {
      sb.writeCharCode(_cp1255Hi[b] ?? b);
    }
  }
  return sb.toString();
}

/// פענוח טקסט: UTF-8 עם/בלי BOM, UTF-16 עם BOM, ואם ה-UTF-8 פגום - windows-1255.
String decodeBookText(List<int> bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    final u = <int>[for (var i = 2; i + 1 < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8)];
    return String.fromCharCodes(u);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    final u = <int>[for (var i = 2; i + 1 < bytes.length; i += 2) (bytes[i] << 8) | bytes[i + 1]];
    return String.fromCharCodes(u);
  }
  var b = bytes;
  if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) b = b.sublist(3);
  try {
    return utf8.decode(b);
  } on FormatException {
    return _decodeCp1255(b);
  }
}

/// קורא קובץ טקסט כשורות (CRLF/LF/CR; שורה ריקה אחרונה אינה שורה).
List<String> loadBookTextLines(String path) {
  final f = File(path);
  if (!f.existsSync()) throw AppError('הקובץ לא נמצא: $path');
  var t = decodeBookText(f.readAsBytesSync()).replaceAll('﻿', '');
  t = t.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = t.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  if (lines.every((l) => l.trim().isEmpty)) throw AppError('הקובץ ריק.');
  return lines;
}

// ───────────────────────────── כללים ─────────────────────────────

const _g = r'[א-ת]{1,3}["״]?[א-ת]?[\x27׳]?'; // גימטריה
const _ordWords = r'ראשון|ראשונה|שני|שנייה|שניה|שלישי|שלישית|רביעי|רביעית|חמישי|חמישית|שישי|שישית|שביעי|שביעית|'
    r'שמיני|שמינית|תשיעי|תשיעית|עשירי|עשירית|'
    r'(?:אחד|אחת|שנים|שתים|שלשה|שלושה|ארבעה|חמשה|חמישה|ששה|שישה|שבעה|שמונה|תשעה|עשרה|עשר)(?:\s+עשר(?:ה)?)?|'
    r'עשרים|שלושים|שלשים|ארבעים';

/// מספר: גימטריה, מילה סודרת/מונה, או ספרות.
const numberPat = '(?:$_g|$_ordWords|\\d{1,3})(?![א-ת])';

/// כלל זיהוי כותרת: ביטוי רגולרי על טקסט השורה (בלי תגים), בגודל יחסי ([rank]: קטן = יחידה גדולה יותר).
class HeadingRule {
  HeadingRule({
    required this.id,
    required this.label,
    required this.example,
    required this.pattern,
    this.rank = 3,
    this.level,
    this.maxChars = 80,
    this.onRaw = false,
  });

  final String id;
  final String label;
  final String example;
  final RegExp pattern;

  /// עומק טבעי מוצע: 1 = שער/מסכת, 2 = פרק/סימן/פרשה/הקדמה, 3 = דף/הלכה/משנה, 4 = סעיף/מספור, 5 = שורה קצרה.
  final int rank;

  /// דריסה ידנית של רמת הכותרת (2-6, h2..h6); null = אוטומטי לפי סדר ההופעה.
  final int? level;

  /// שורה ארוכה מזה אינה "כותרת שלמה" (הסימון הוא רק תחילת פסקה) - מדווחת אך לא תיכלל בבנייה.
  final int maxChars;

  /// הביטוי רץ על השורה הגולמית (עם תגים) ולא על הטקסט הנקי.
  final bool onRaw;

  HeadingRule copyWith({int? level, bool clearLevel = false, int? maxChars, int? rank}) => HeadingRule(
        id: id,
        label: label,
        example: example,
        pattern: pattern,
        rank: rank ?? this.rank,
        level: clearLevel ? null : (level ?? this.level),
        maxChars: maxChars ?? this.maxChars,
        onRaw: onRaw,
      );

  /// כלל מותאם: ביטוי רגולרי (על הטקסט הנקי). ביטוי פגום -> [AppError] בעברית.
  factory HeadingRule.regex(String source, {String? label, int rank = 3, int? level, int maxChars = 80}) {
    try {
      return HeadingRule(
        id: 'custom:$source',
        label: label ?? 'ביטוי: $source',
        example: source,
        pattern: RegExp(source),
        rank: rank,
        level: level,
        maxChars: maxChars,
      );
    } on FormatException {
      throw AppError('הביטוי הרגולרי אינו תקין: $source');
    }
  }

  /// כלל מותאם: "השורה מתחילה ב-X".
  factory HeadingRule.startsWith(String prefix, {String? label, int rank = 3, int? level, int maxChars = 80}) {
    final p = collapseWs(prefix);
    if (p.isEmpty) throw AppError('לא הוזן טקסט לחיפוש.');
    return HeadingRule(
      id: 'starts:$p',
      label: label ?? 'שורה שמתחילה ב"$p"',
      example: '$p ...',
      pattern: RegExp('^\\s*${RegExp.escape(p)}'),
      rank: rank,
      level: level,
      maxChars: maxChars,
    );
  }
}

String _kw(String words) => '^[\\[(]?(?:$words)\\s+$numberPat';

/// הכללים המוכנים, לפי סדר עדיפות (כלל ראשון שמתאים לשורה גובר). ה-UI מציע אותם כתיבות סימון.
List<HeadingRule> headingPresets() => [
      HeadingRule(
        id: 'daf',
        label: 'דף (ב. / ב: / דף ב ע״א)',
        example: 'דף ב.   ב:   דף יג עמוד ב   יד, ב',
        pattern: RegExp('^\\[?(?:דף\\s+$_g(?:\\s*[.:]|(?:,\\s*|\\s+ע(?:מוד)?["״\'׳]?\\s*)[אב])?|$_g(?:,\\s*|\\s+ע(?:מוד)?["״\'׳]?\\s*)[אב]|$_g[.:])\\]?\$'),
        rank: 3,
        maxChars: 25,
      ),
      HeadingRule(
        id: 'masechet',
        label: 'מסכת X',
        example: 'מסכת ברכות',
        pattern: RegExp(r'^[\[(]?מסכת\s+[א-ת]'),
        rank: 1,
        maxChars: 40,
      ),
      HeadingRule(
        id: 'section',
        label: 'שער / חלק / ספר / קונטרס X',
        example: 'שער הבטחון   חלק ראשון   ספר שמות',
        pattern: RegExp(r'^[\[(]?(?:שער|חלק|ספר|קונטרס|כרך|מדור)\s+[^.]{1,40}$'),
        rank: 1,
        maxChars: 50,
      ),
      HeadingRule(
        id: 'intro',
        label: 'הקדמה / מבוא / פתח דבר / מפתח',
        example: 'הקדמה   מבוא   פתח דבר   הקדמת המחבר',
        pattern: RegExp(
            r'^[\[(]?(?:הקדמה|הקדמת\s+[א-ת"]+(?:\s+[א-ת"]+)?|מבוא|פתח דבר|פתיחה|דברי פתיחה|הסכמה|הסכמות|מפתח|מפתחות|נספח|נספחים|אחרית דבר|סוף דבר)[\])\s:.\-–]*$'),
        rank: 2,
        maxChars: 40,
      ),
      HeadingRule(
        id: 'parasha',
        label: 'פרשת X / פרשה',
        example: 'פרשת בראשית   פרשת כי תשא   פרשה א',
        pattern: RegExp('^[\\[(]?(?:פרשת\\s+[א-ת]+(?:\\s+[א-ת]+){0,2}|פרשה\\s+$numberPat)[\\])\\s:.]*\$'),
        rank: 2,
        maxChars: 40,
      ),
      HeadingRule(
        id: 'perek',
        label: 'פרק א / פרק ראשון',
        example: 'פרק א   פרק ראשון - בא הים',
        pattern: RegExp(_kw("פרק|פ['׳]")),
        rank: 2,
      ),
      HeadingRule(
        id: 'siman',
        label: 'סימן א',
        example: 'סימן א   סימן קכ"ג',
        pattern: RegExp(_kw("סימן|סי['׳]")),
        rank: 2,
      ),
      HeadingRule(
        id: 'halacha',
        label: 'הלכה א',
        example: 'הלכה א   הלכה ראשונה',
        pattern: RegExp(_kw("הלכה|הל['׳]")),
        rank: 3,
      ),
      HeadingRule(
        id: 'mishna',
        label: 'משנה א',
        example: 'משנה א   משנה ראשונה',
        pattern: RegExp(_kw('משנה')),
        rank: 3,
      ),
      HeadingRule(
        id: 'seif',
        label: 'סעיף א',
        example: 'סעיף א',
        pattern: RegExp(_kw("סעיף|סעי['׳]")),
        rank: 4,
      ),
      HeadingRule(
        id: 'numbering',
        label: 'מספור (א) (ב) / 1.',
        example: '(א)   ב)   (3)   4.',
        pattern: RegExp('^(?:\\($_g\\)|$_g\\)|\\(\\d{1,3}\\)|\\d{1,3}[.)])(?:\\s+.{0,60})?\$'),
        rank: 4,
        maxChars: 40,
      ),
      HeadingRule(
        id: 'boldLine',
        label: 'שורה קצרה מודגשת לבדה (<b>)',
        example: '<b>כותרת מודגשת</b>',
        pattern: RegExp(r'^\s*<(b|strong)>[^<]{2,80}</\1>\s*$'),
        rank: 4,
        maxChars: 80,
        onRaw: true,
      ),
      HeadingRule(
        id: 'shortLine',
        label: 'שורה קצרה שאינה מסתיימת בנקודה או נקודתיים',
        example: 'שורה קצרה בלי נקודה בסוף',
        pattern: RegExp(r'^(?=.*[א-ת])[^<>]{2,}(?<![.:,;?!])$'),
        rank: 5,
        maxChars: 40,
      ),
    ];

// ───────────────────────────── זיהוי ─────────────────────────────

/// הצעת כותרת לשורה.
class HeadingSuggestion {
  HeadingSuggestion({
    required this.index,
    required this.text,
    required this.plain,
    required this.rule,
    required this.level,
    this.existing = false,
    this.isWhole = true,
  });

  /// אינדקס השורה (מ-0) ברשימה שהועברה ל-[detectHeadings].
  final int index;

  /// השורה המקורית.
  final String text;

  /// הטקסט בלי תגים.
  final String plain;

  /// הכלל שהתאים (null = כותרת קיימת בקובץ).
  final HeadingRule? rule;

  /// רמת כותרת מוצעת (2-6).
  final int level;

  /// כותרת <hN> שכבר קיימת בקובץ.
  final bool existing;

  /// השורה קצרה מספיק להיות כותרת שלמה; אחרת הסימון הוא רק תחילת פסקה והבנייה תדלג עליה.
  final bool isWhole;

  HeadingSuggestion withLevel(int l) => HeadingSuggestion(
      index: index, text: text, plain: plain, rule: rule, level: l.clamp(2, 6), existing: existing, isWhole: isWhole);
}

class _Open {
  _Open(this.kind, this.level, this.rank);
  final String kind;
  final int level, rank;
}

/// מזהה כותרות: קיימות (<hN>) והתאמות לכללים. כל שורה מותאמת לכלל הראשון שמתאים לה.
/// רמות: לפי סדר הופעת כל סוג כלל, היררכית ובלי דילוגים - סוג חדש הוא בן של הכותרת הפתוחה העמוקה ביותר
/// שדרגתה ([HeadingRule.rank]) קטנה משלו, או ברמה העליונה (h2) אם אין כזו. [HeadingRule.level] גובר.
/// כותרות קיימות מונרמלות לרצף מ-h2 ([existingLevelMap]); [title] = שם הספר, שורת ה-h1 שלו אינה נספרת.
List<HeadingSuggestion> detectHeadings(List<String> lines, List<HeadingRule> rules, {String? title}) {
  final skip = titleLineIndex(lines, title);
  final emap = existingLevelMap(lines, skip: skip);

  // התאמות לפי סדר השורות
  final hits = <(int, String, String, HeadingRule?, int?, bool)>[]; // index, text, plain, rule, rawLevel, whole
  for (var i = 0; i < lines.length; i++) {
    if (i == skip) continue;
    final line = lines[i];
    if (headingOpenRe.hasMatch(line)) {
      final m = headingFullRe.firstMatch(line);
      final raw = int.parse(headingOpenRe.firstMatch(line)![1]!).clamp(1, 6);
      hits.add((i, line, plainText(m != null ? m[2]! : line).trim(), null, raw, true));
      continue;
    }
    final plain = plainText(line).trim();
    if (plain.isEmpty) continue;
    for (final r in rules) {
      final src = r.onRaw ? line : plain;
      if (r.pattern.hasMatch(src)) {
        hits.add((i, line, plain, r, null, plain.length <= r.maxChars));
        break;
      }
    }
  }

  final kindLevel = <String, int>{};
  final stack = <_Open>[];
  final levels = <int, int>{};
  for (final h in hits) {
    final (idx, _, _, rule, raw, whole) = h;
    if (!whole) continue;
    final kind = rule == null ? 'e$raw' : rule.id;
    final rank = rule == null ? 0 : rule.rank;
    var lvl = rule == null ? emap[raw]! : kindLevel[kind];
    if (lvl == null) {
      if (rule!.level != null) {
        lvl = rule.level!.clamp(2, 6);
      } else {
        _Open? parent;
        for (final o in stack.reversed) {
          if (o.rank < rank) {
            parent = o;
            break;
          }
        }
        lvl = parent == null ? 2 : (parent.level + 1).clamp(2, 6);
      }
    }
    kindLevel[kind] = lvl;
    levels[idx] = lvl;
    stack.removeWhere((o) => o.level >= lvl!);
    stack.add(_Open(kind, lvl, rank));
  }

  final out = <HeadingSuggestion>[];
  for (final h in hits) {
    final (idx, text, plain, rule, raw, whole) = h;
    final kind = rule == null ? 'e$raw' : rule.id;
    final lvl = levels[idx] ?? kindLevel[kind] ?? rule?.level ?? emap[raw] ?? 2;
    out.add(HeadingSuggestion(index: idx, text: text, plain: plain, rule: rule, level: lvl, existing: rule == null, isWhole: whole));
  }
  return out;
}
