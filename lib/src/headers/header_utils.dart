// כלים משותפים ליצירת כותרות: ניקוי טקסט כותרת, סגנון דף מקוצר, שם קובץ ורמות כותרות קיימות.
// ללא תלות ב-Flutter (רץ גם ב-isolate).

/// כל תג HTML.
final tagRe = RegExp(r'<[^>]+>');

/// טקסט השורה בלי תגים (בלי trim).
String plainText(String t) => t.replaceAll(tagRe, '');

/// כותרת שלמה: <hN ...>טקסט</hN> בלבד בשורה (1-6).
final headingFullRe = RegExp(r'^\s*<h([1-6])(?:\s[^>]*)?>(.*?)</h\1>\s*$', dotAll: true);

/// כותרת עם טקסט אחריה באותה שורה.
final headingTailRe = RegExp(r'^\s*<h([1-6])(?:\s[^>]*)?>(.*?)</h\1>(.+)$', dotAll: true);

/// שורה שמתחילה בתג כותרת כלשהו (גם h7+, כמו בוולידציה).
final headingOpenRe = RegExp(r'^\s*<\s*h([1-9][0-9]?)\b', caseSensitive: false);

/// הערה inline: סמן + גוף צמודים.
final footnotePairRe = RegExp(
  r'<sup\b[^>]*footnote-marker[^>]*>.*?</sup>\s*<i\b[^>]*class="[^"]*footnote[^"]*"[^>]*>.*?</i>',
  dotAll: true,
);

/// תגי עיצוב שאין להם מקום בתוך כותרת (הכותרת כבר מודגשת ומוגדלת).
final _fmtTagRe = RegExp(r'</?(?:b|i|u|big|small|strong|em|s|strike|del|ins|mark)>', caseSensitive: false);

/// מסיר תגי עיצוב מטקסט כותרת; הערות inline וכל תג אחר נשארים.
String stripFormattingTags(String s) {
  final saved = <String>[];
  final guarded = s.replaceAllMapped(footnotePairRe, (m) {
    saved.add(m[0]!);
    return '\u0001${saved.length - 1}\u0001';
  });
  final out = guarded.replaceAll(_fmtTagRe, '');
  return out.replaceAllMapped(RegExp('\u0001(\\d+)\u0001'), (m) => saved[int.parse(m[1]!)]);
}

String escapeAngle(String s) => s.replaceAll('<', '&lt;').replaceAll('>', '&gt;');

final _ws = RegExp(r'\s+');
String collapseWs(String s) => s.replaceAll(' ', ' ').replaceAll(_ws, ' ').trim();

/// גרשיים: '' ו“ ” „ ״ -> "  ;  ‘ ’ ׳ -> '
String normalizeQuotes(String s) =>
    s.replaceAll("''", '"').replaceAll(RegExp('[“”„״]'), '"').replaceAll(RegExp('[‘’׳]'), "'");

// ───────────────────────────── דף מקוצר ─────────────────────────────

/// מספר בגימטריה (1-4 אותיות, גרשיים אופציונליים).
const gematriaPat = r'[א-ת]{1,3}"?[א-ת]?\x27?';

final _dafAmud = RegExp('^(?:דף\\s+)?($gematriaPat)(?:,\\s*|\\s+ע(?:מוד)?"?\\s*)([אב])\$');
final _dafSuffix = RegExp('^דף\\s+($gematriaPat)\\s*([.:])\$');
final _dafShort = RegExp('^($gematriaPat)([.:])\$');
final _amudOnly = RegExp(r'^(?:עמוד|ע"?)\s*([אב])$');

/// זוכר את הדף האחרון, כדי ש"עמוד ב" לבדו יהפוך ל"יג:".
class DafTracker {
  String? last;
}

String _num(String g) => g.replaceAll('"', '').replaceAll("'", '');

/// "דף יג עמוד א" / "יג ע"ב" / "יד, ב" / "דף יג:" -> "יג." / "יג:" ; אחרת null.
String? shortDaf(String s, [DafTracker? t]) {
  var m = _dafAmud.firstMatch(s);
  if (m != null) {
    final n = _num(m[1]!);
    t?.last = n;
    return n + (m[2] == 'א' ? '.' : ':');
  }
  m = _dafSuffix.firstMatch(s);
  if (m != null) {
    final n = _num(m[1]!);
    t?.last = n;
    return n + m[2]!;
  }
  m = _dafShort.firstMatch(s);
  if (m != null) {
    t?.last = _num(m[1]!);
    return s; // כבר בצורה המקוצרת
  }
  m = _amudOnly.firstMatch(s);
  if (m != null && t?.last != null) return t!.last! + (m[1] == 'א' ? '.' : ':');
  return null;
}

// ───────────────────────────── ניקוי כותרת ─────────────────────────────

String _unwrapBrackets(String s) {
  var t = s.trim();
  var changed = true;
  while (changed && t.length >= 2) {
    changed = false;
    for (final (o, c) in const [('[', ']'), ('(', ')')]) {
      if (t.startsWith(o) && t.endsWith(c) && !t.substring(1, t.length - 1).contains(o) && !t.substring(1, t.length - 1).contains(c)) {
        t = t.substring(1, t.length - 1).trim();
        changed = true;
      }
    }
  }
  // סוגר בודד בקצה בלי בן זוג
  for (final (o, c) in const [('[', ']'), ('(', ')')]) {
    if (t.startsWith(o) && !t.contains(c)) t = t.substring(1).trim();
    if (t.endsWith(c) && !t.contains(o)) t = t.substring(0, t.length - 1).trim();
  }
  return t;
}

final _trailPunct = RegExp(r'[.:]+$');

/// נוסח כותרת לפי הסקיל (שמרני; גוף הספר לא נוגע):
///  1. הסרת תגי עיצוב (הכותרת כבר מודגשת); הערות inline נשארות.
///  2. כיווץ רווחים; גרשיים אחידים (ראה [normalizeQuotes]).
///  3. הסרת סוגריים (מרובעים/עגולים) העוטפים את הכותרת.
///  4. סגנון דף מקוצר: "דף יג עמוד ב" -> "יג:" (כותרות דף שומרות את ה-. / :).
///  5. נקודה/נקודתיים בסוף כותרת רב-מילית נמחקות, אלא אם המילה האחרונה היא ראשי תיבות (כוללת גרשיים).
/// מחזיר טקסט ריק אם לא נשאר דבר.
String cleanHeadingText(String raw, {DafTracker? daf}) {
  var s = collapseWs(stripFormattingTags(raw));
  s = normalizeQuotes(s);
  s = _unwrapBrackets(s);
  s = collapseWs(s);
  final d = shortDaf(s, daf);
  if (d != null) return d;
  if (_trailPunct.hasMatch(s) && !s.endsWith('...') && !s.endsWith('…')) {
    final body = s.replaceFirst(_trailPunct, '');
    final words = body.split(' ');
    if (words.length > 1 && !words.last.contains('"') && !words.last.contains("'")) s = body.trimRight();
  }
  return s;
}

/// שם הספר לשורה 1: בלי תגים וסוגריים עוטפים, גרשיים אחידים; גרשיים נשארים.
String cleanBookTitle(String raw) => collapseWs(_unwrapBrackets(normalizeQuotes(collapseWs(stripFormattingTags(raw)))));

// ───────────────────────────── שם קובץ ─────────────────────────────

final _niqqud = RegExp('[֑-ׇ]');
final _illegal = RegExp(r'[\\/:*"״?<>|]');

/// כמו sanitize_filename של הסקיל: בלי ניקוד ובלי \ / : * " ״ ? < > | ; גרש נמחק; _ -> רווח.
String sanitizeFileName(String name) {
  var s = name.replaceAll(_niqqud, '').replaceAll(_illegal, '');
  s = s.replaceAll('_', ' ').replaceAll("''", '').replaceAll("'", '');
  s = collapseWs(s).replaceFirst(RegExp(r'[. ]+$'), '');
  return s.isEmpty ? 'ספר' : s;
}

// ───────────────────────────── כותרות קיימות ─────────────────────────────

/// אינדקס שורת ה-<h1> של שם הספר (השורה הלא-ריקה הראשונה, אם היא h1 ששמה כשם הספר), אחרת -1.
int titleLineIndex(List<String> lines, String? title) {
  if (title == null) return -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim().isEmpty) continue;
    final m = headingFullRe.firstMatch(lines[i]);
    if (m != null && m[1] == '1' && sanitizeFileName(plainText(m[2]!)) == sanitizeFileName(title)) return i;
    return -1;
  }
  return -1;
}

/// מיפוי רמות כותרת קיימות (גולמיות) לרצף רציף החל מ-h2: הרמות שבשימוש לפי סדר -> 2,3,4... (עד 6).
/// כמו normalize_heading_levels של to_otzaria.py. [skip] = שורת שם הספר שאינה נספרת.
Map<int, int> existingLevelMap(List<String> lines, {int skip = -1}) {
  final used = <int>{};
  for (var i = 0; i < lines.length; i++) {
    if (i == skip) continue;
    final m = headingOpenRe.firstMatch(lines[i]);
    if (m != null) used.add(int.parse(m[1]!).clamp(1, 6));
  }
  final sorted = used.toList()..sort();
  return {for (var i = 0; i < sorted.length; i++) sorted[i]: (2 + i).clamp(2, 6)};
}
