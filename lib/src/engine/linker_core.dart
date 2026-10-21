// ליבת מחולל הקישורים לאוצריא: תרגום נאמן של linker_core.py (MyLibraryforOtzaria / Otzariya_Link_Maker).
//
// קוראת את מבנה הכותרות של ספר (TXT בפורמט אוצריא) ומשייכת כל שורת תוכן למיקום בספר יעד
// (דף בגמרא, פרק בתנ"ך, סימן בשולחן ערוך וכו'), ומאמתת את המיקום מול תוכן העניינים ב-seforim.db.

import 'common.dart';
import 'seforim_db.dart';

/// {מספר שורה (מ-1): (ספר יעד, מיקום)}.
typedef LinkMap = Map<int, (String, String)>;

const masechtot = [
  'בבא בתרא', 'בבא קמא', 'בבא מציעא', 'ראש השנה', 'עבודה זרה', 'מועד קטן', 'פסחים', 'קידושין', 'קדושין', //
  'מגילה', 'סנהדרין', 'סוכה', 'מכות', 'ביצה', 'יומא', 'ברכות', 'חגיגה', 'נדרים', 'עירובין', 'סוטה', 'זבחים', //
  'תענית', 'נדה', 'נזיר', 'מנחות', 'כריתות', 'הוריות', 'בכורות', 'ערכין', 'תמורה', 'מעילה', 'תמיד', 'כתובות', //
  'שבועות', 'יבמות', 'גיטין', 'שבת', 'חולין',
];
const _alias = {'קדושין': 'קידושין'};

String aliasOf(String s) => _alias[s] ?? s;

final dafRe = RegExp(r'^\[?(?:דף\s+)?([א-ת]{1,3})([.:])\]?$');
final _quoteRe = RegExp('[$quoteChars]');
final _masPatterns = {for (final m in masechtot) m: RegExp('(?<![א-ת])${RegExp.escape(m)}(?![א-ת])')};

String? findTractate(String text) {
  String? best;
  for (final m in masechtot) {
    if (_masPatterns[m]!.hasMatch(text) && (best == null || m.length > best.length)) best = m;
  }
  return best;
}

final _dafExt = RegExp('^(?:דף\\s+)?([א-ת$quoteChars]{1,5}?)\\s*(?:,|ע[$quoteChars]?)\\s*([אב])\$');

String _stripBrackets(String t) {
  var s = t.trim();
  var a = 0, b = s.length;
  while (a < b && (s[a] == '[' || s[a] == ']')) {
    a++;
  }
  while (b > a && (s[b - 1] == '[' || s[b - 1] == ']')) {
    b--;
  }
  return s.substring(a, b).trim();
}

/// כותרות דף בפורמטים נוספים: "יד, ב", "דף ב ע"א", "כא ע״ב" -> "יד:" / "ב." / "כא:".
String? parseDafExt(String t) {
  final m = _dafExt.firstMatch(_stripBrackets(t));
  if (m == null) return null;
  return m[1]!.replaceAll(_quoteRe, '') + (m[2] == 'א' ? '.' : ':');
}

// ───────────────────────────── מנועים מובנים ─────────────────────────────

/// תוצאת מנוע מובנה: קישורים, הערה, סוג קישור.
typedef Generated = (LinkMap, String, String);

bool _skipLine(int i, String s) => i == 1 || s.isEmpty || s.startsWith('<h1');

final _taj = RegExp(r"\s*\(כתאב אלתאג'\)$");
final _targumPrefix = RegExp(r'^תרגום (שני )?(על )?');

Generated _genTanakh(List<String> rel, String stem, List<String> lines, SeforimDb db) {
  final kind = rel.length > 1 && rel[1] == 'תרגומים' ? 'תרגום' : 'פירוש';
  var book = stem.split(' - ').first.replaceAll(_taj, '').replaceFirst(_targumPrefix, '');
  if (book == 'תהלים') book = 'תהילים';
  final ch = db.chset(book);
  if (ch == null || ch.isEmpty) return (<int, (String, String)>{}, 'אין יעד ב-seforim.db: $book', kind);
  final out = <int, (String, String)>{};
  String? cur;
  for (var i = 1; i <= lines.length; i++) {
    final s = lines[i - 1].trim();
    final hm = headStrict.firstMatch(s);
    if (hm != null) {
      if (hm[1] == '2') {
        final t = stripTags(hm[2]!);
        cur = ch.contains(t) ? t : null;
      }
      continue;
    }
    if (_skipLine(i, s)) continue;
    if (cur != null) out[i] = (book, cur);
  }
  return (out, '', kind);
}

final _perekEnd = RegExp(r'פרק ([א-ת]+)$');

Generated _genYerushalmi(List<String> rel, String stem, List<String> lines, SeforimDb db) {
  const target = 'תלמוד ירושלמי שקלים';
  final hs = db.hset(target) ?? {};
  final pm = _perekEnd.firstMatch(stem);
  String? per = pm != null ? 'פרק ${pm[1]}' : null;
  String? hal;
  final out = <int, (String, String)>{};
  for (var i = 1; i <= lines.length; i++) {
    final s = lines[i - 1].trim();
    final hm = headStrict.firstMatch(s);
    if (hm != null) {
      final t = stripTags(hm[2]!);
      final m = _perekEnd.firstMatch(t);
      if (hm[1] == '2' && m != null) {
        per = 'פרק ${m[1]}';
        hal = null;
      } else if (t.startsWith('הלכה ')) {
        hal = t;
      }
      continue;
    }
    if (_skipLine(i, s)) continue;
    if (per != null && hal != null && hs.contains((per, hal))) out[i] = (target, '$per $hal');
  }
  return (out, '', 'פירוש');
}

final _perekOnly = RegExp(r'^פרק [א-ת]+$');

Generated _genAshri(List<String> rel, String stem, List<String> lines, SeforimDb db) {
  final mas = aliasOf(stem.substring(stem.indexOf(' - ') + 3).trim());
  final target = 'פסקי הרא"ש על $mas';
  final hs = db.hset(target);
  if (hs == null || hs.isEmpty) return (<int, (String, String)>{}, 'אין יעד ב-seforim.db: $target', 'פירוש');
  String? per;
  (String, String)? cur;
  final out = <int, (String, String)>{};
  for (var i = 1; i <= lines.length; i++) {
    final s = lines[i - 1].trim();
    final hm = headStrict.firstMatch(s);
    if (hm != null) {
      final t = stripTags(hm[2]!);
      if (hm[1] == '2' && _perekOnly.hasMatch(t)) {
        per = t;
      } else if (t.startsWith('סימן ') && per != null) {
        final c = (per, 'הלכה ${t.substring('סימן '.length)}');
        cur = hs.contains(c) ? c : null;
      }
      continue;
    }
    if (_skipLine(i, s)) continue;
    if (cur != null) out[i] = (target, '${cur.$1} ${cur.$2}');
  }
  return (out, '', 'פירוש');
}

const _h2 = r'^<h2>(.*?)</h2>\s*$';

/// ספרי הלכה מוגדרים: שם קובץ -> (יעד, תבנית מיקום, תבנית כותרת).
const halachaCfg = <String, (String, String?, String?)>{
  'פרי חדש או״ח': ('שולחן ערוך, אורח חיים', r'^(סימן [א-ת]+)$', _h2),
  'ר״י קורקוס שבת': ('משנה תורה, הלכות שבת', r'^(פרק [א-ת]+)$', _h2),
  'דגול מרבבה אהע״ז': ('שולחן ערוך, אבן העזר', null, null),
  'חוות דעת ביאורים - הלכות ריבית': ('שולחן ערוך, יורה דעה', r'^(סימן [א-ת]+)$', _h2),
  'שער דעה - הלכות ריבית': ('שולחן ערוך, יורה דעה', r'^(סימן [א-ת]+)$', _h2),
};

final _dagul = RegExp(r'^דגול מרבבה אבן העזר (סימן [א-ת]+)$');

Generated _genHalacha(List<String> rel, String stem, List<String> lines, SeforimDb db) {
  final (target, pat, hpat) = halachaCfg[stem]!;
  final ch = db.chset(target) ?? {};
  final patRe = pat == null ? null : RegExp(pat);
  final hRe = hpat == null ? null : RegExp(hpat);
  String? cur;
  final out = <int, (String, String)>{};
  for (var i = 1; i <= lines.length; i++) {
    final s = lines[i - 1].trim();
    if (hRe != null) {
      final hm = hRe.firstMatch(s);
      if (hm != null) {
        final m = patRe!.firstMatch(stripTags(hm[1]!));
        cur = m != null && ch.contains(m[1]) ? m[1] : null;
        continue;
      }
      if (i == 1 || s.isEmpty || s.startsWith('<h')) continue;
    } else {
      final m = _dagul.firstMatch(s);
      if (m != null) {
        cur = ch.contains(m[1]) ? m[1] : null;
        continue;
      }
      if (s.isEmpty || s.startsWith('====') || s.startsWith('<h1')) continue;
    }
    if (cur != null) out[i] = (target, cur);
  }
  return (out, '', 'פירוש');
}

final _masInName = RegExp(r'מסכת (.+?)\s*(?:\(\d+\)|\d+)?\s*$');
final _trailingParen = RegExp(r'\s*\(.*?\)\s*$');
final _trailingOd = RegExp(r'\s+ועוד$');
final _masHeading = RegExp(r'^מסכת (.+?)$');

/// שם המסכת מתוך שם הקובץ ("... מסכת X" או שם מסכת בשם).
String? tractateFromName(String stem, {bool requireBavliFolder = false, List<String> rel = const []}) {
  final m = _masInName.firstMatch(stem);
  if (m != null) {
    final t = m[1]!.replaceAll(_trailingParen, '').trim().replaceAll(_trailingOd, '');
    return t.isEmpty ? null : aliasOf(t);
  }
  if (requireBavliFolder && !(rel.isNotEmpty && rel.first == 'תלמוד בבלי' && !rel.contains('מחברי זמננו'))) {
    return null;
  }
  final t = findTractate(stem.replaceAll("''", '').replaceAll("'", ''));
  return t == null ? null : aliasOf(t);
}

Generated _genBavli(List<String> rel, String stem, List<String> lines, SeforimDb db) {
  final mas0 = tractateFromName(stem, requireBavliFolder: true, rel: rel);

  (Set<String>?, LinkMap) run(bool ext) {
    var mas = mas0;
    var ds = mas0 != null ? db.dafset(mas0) : null;
    String? cur;
    final out = <int, (String, String)>{};
    for (var i = 1; i <= lines.length; i++) {
      final s = lines[i - 1].trim();
      final hm = headStrict.firstMatch(s);
      if (hm != null) {
        final t = stripTags(hm[2]!);
        final mm = _masHeading.firstMatch(t);
        if (hm[1] == '2' && mm != null) {
          final nm = aliasOf(mm[1]!.trim());
          final nd = db.dafset(nm);
          if (nd != null && nd.isNotEmpty) {
            mas = nm;
            ds = nd;
            cur = null;
          }
          continue;
        }
        final dm = dafRe.firstMatch(t);
        if (dm != null) {
          cur = dm[1]! + dm[2]!;
        } else if (ext) {
          final r = parseDafExt(t);
          if (r != null) cur = r;
        }
        continue;
      }
      if (_skipLine(i, s)) continue;
      if (ds != null && ds.isNotEmpty && cur != null && ds.contains(cur)) out[i] = (mas!, cur);
    }
    return (ds, out);
  }

  var (ds, out) = run(false);
  if (out.isEmpty) (ds, out) = run(true);
  final note = ds != null && ds.isNotEmpty ? '' : (mas0 == null ? 'לא זוהתה מסכת' : 'אין יעד ב-seforim.db: $mas0');
  return (out, note, 'פירוש');
}

const kindLabels = {
  'tanakh': 'תנ"ך (פרק לפי כותרת h2)',
  'yerushalmi': 'ירושלמי שקלים (פרק והלכה)',
  'ashri': 'הגהות אשרי (פרק וסימן ← פסקי הרא"ש)',
  'halacha': 'ספר הלכה מוגדר (שו"ע / רמב"ם)',
  'bavli': 'תלמוד בבלי (כותרות דף)',
};

final _shekalim = RegExp(r'(?<![א-ת])שקלים(?![א-ת])');

/// תיקיית "תנך" (בלי גרשיים) כמו "תנ״ך".
List<String> normalizeRel(List<String> rel) => [for (final x in rel) x == 'תנך' ? 'תנ״ך' : x];

/// איזה מנוע מובנה מתאים לספר לפי נתיב ושם הקובץ, או null.
String? detectKind(List<String> rel, String stem) {
  rel = normalizeRel(rel);
  if (halachaCfg.containsKey(stem)) return 'halacha';
  if (rel.isNotEmpty && rel.first == 'תנ״ך' && rel.length > 1 && (rel[1] == 'ראשונים' || rel[1] == 'תרגומים')) {
    return 'tanakh';
  }
  if (_shekalim.hasMatch(stem)) return 'yerushalmi';
  if (stem.startsWith('הגהות אשרי - ')) return 'ashri';
  if (rel.length >= 2 && rel[0] == 'תלמוד בבלי' && rel[1] == 'שס וגשל') return null;
  if ((rel.isNotEmpty && rel.first == 'תלמוד בבלי') ||
      (rel.length >= 2 && rel[0] == 'ספרים שאינם מותאמים לאוצריא' && rel[1] == 'תלמוד בבלי')) {
    return 'bavli';
  }
  return null;
}

Generated builtinExpected(String kind, List<String> rel, String stem, List<String> lines, SeforimDb db) =>
    switch (kind) {
      'tanakh' => _genTanakh(rel, stem, lines, db),
      'yerushalmi' => _genYerushalmi(rel, stem, lines, db),
      'ashri' => _genAshri(rel, stem, lines, db),
      'halacha' => _genHalacha(rel, stem, lines, db),
      _ => _genBavli(rel, stem, lines, db),
    };

// ───────────────────────────── מנוע כללים ─────────────────────────────
//
//  daf            כותרת שהיא דף ("ב.", "יד, ב", "דף ב ע"א")
//  heading        כותרת שמתאימה ל-regex. role=ref קובע מיקום מלא, chapter קובע פרק, sub מתחבר לפרק האחרון.
//  target_switch  כותרת שמחליפה את ספר היעד (למשל "מסכת X")
//  anchor         שורה שפותחת ב"בדף X." קובעת דף, עד העוגן הבא או כותרת h2 חדשה

class Rule {
  const Rule(this.type, {this.levels = const [2, 6], this.regex, this.ref = '{1}', this.role = 'ref', this.formats});
  final String type;
  final List<int> levels;
  final String? regex;
  final String ref;
  final String role;
  final List<String>? formats;

  int get lo => levels.first;
  int get hi => levels.last;
}

class Profile {
  const Profile({
    this.target = '',
    this.targetFromName = false,
    this.linkType = 'פירוש',
    this.validate = true,
    this.resetOnUnmatched = false,
    required this.rules,
  });
  final String target;
  final bool targetFromName;
  final String linkType;
  final bool validate;
  final bool resetOnUnmatched;
  final List<Rule> rules;

  Profile withTarget(String t, {bool reset = true}) => Profile(
    target: t,
    targetFromName: targetFromName,
    linkType: linkType,
    validate: validate,
    resetOnUnmatched: reset,
    rules: rules,
  );
}

/// פרופילים מוכנים, באותו סדר כמו במקור (הסדר קובע בשוויון).
const presets = <String, Profile>{
  'בבלי: כותרות דף': Profile(
    targetFromName: true,
    rules: [
      Rule('daf', formats: ['std', 'ext']),
      Rule('target_switch', levels: [2, 2], regex: r'^מסכת (.+?)$'),
    ],
  ),
  'בבלי: אזכורי דף בתחילת שורה': Profile(targetFromName: true, rules: [Rule('anchor')]),
  'תנ"ך: פרק לפי כותרת ברמה 2': Profile(
    rules: [
      Rule('heading', levels: [2, 2], regex: r'^(.+)$'),
    ],
  ),
  'שולחן ערוך: סימן ברמה 2': Profile(
    target: 'שולחן ערוך, אורח חיים',
    rules: [
      Rule('heading', levels: [2, 2], regex: r'^(סימן [א-ת]+)$'),
    ],
  ),
  'משנה תורה: פרק ברמה 2': Profile(
    target: 'משנה תורה, הלכות שבת',
    rules: [
      Rule('heading', levels: [2, 2], regex: r'^(פרק [א-ת]+)$'),
    ],
  ),
  'פרק ברמה 2 והלכה או סימן ברמה 3': Profile(
    rules: [
      Rule('heading', levels: [2, 2], regex: r'^(פרק [א-ת]+)$', role: 'chapter'),
      Rule('heading', levels: [3, 3], regex: r'^(?:סימן|הלכה|משנה) ([א-ת]+)$', ref: '{chapter} הלכה {1}', role: 'sub'),
    ],
  ),
};

final _fmtRe = RegExp(r'\{(\d+|chapter)\}');

String _fmt(String template, List<String?> groups, String? chapter) => template.replaceAllMapped(_fmtRe, (m) {
  final k = m[1]!;
  if (k == 'chapter') return chapter ?? '';
  final i = int.parse(k) - 1;
  return i >= 0 && i < groups.length ? (groups[i] ?? '') : '';
}).trim();

final _anchorRe = RegExp(
  '^(?:<[^>]+>)*\\s*(?:ו)?בדף\\s+([א-ת]{1,3}[$quoteChars]?[א-ת]?)\\s*(?:([.:])|ע[$quoteChars]?([אב]))',
);

class ProfileResult {
  ProfileResult(this.rows, this.notes, this.unmatched, this.headings);
  final LinkMap rows;
  final List<String> notes;
  final Map<String, int> unmatched;
  final int headings;
}

/// מריץ פרופיל כללים על ספר.
ProfileResult runProfile(List<String> lines, Profile profile, SeforimDb? db, [String stem = '']) {
  final rules = profile.rules;
  var target0 = profile.target.trim();
  if (profile.targetFromName && target0.isEmpty) {
    target0 = tractateFromName(stem) ?? '';
  }
  final notes = <String>[];
  final unmatched = <String, int>{};
  if (target0.isEmpty && !rules.any((r) => r.type == 'target_switch')) {
    return ProfileResult({}, ['לא הוגדר ספר יעד'], {}, 0);
  }
  var target = target0;
  String? cur;
  String? chapter;
  final compiled = {
    for (final r in rules)
      if (r.regex != null) r: RegExp(r.regex!),
  };
  final useAnchor = rules.any((r) => r.type == 'anchor');
  final out = <int, (String, String)>{};
  var nHead = 0;
  for (var i = 1; i <= lines.length; i++) {
    final s = lines[i - 1].trim();
    final hm = headLoose.firstMatch(s);
    if (hm != null) {
      final lvl = int.parse(hm[1]!);
      final text = stripTags(hm[2]!);
      nHead++;
      if (useAnchor && lvl == 2) cur = null;
      var matched = false;
      for (final r in rules) {
        if (lvl < r.lo || lvl > r.hi) continue;
        if (r.type == 'target_switch') {
          final m = compiled[r]!.matchAsPrefix(text);
          if (m != null) {
            final nt = m.groupCount > 0 ? aliasOf(m[1]!.trim()) : m[0]!;
            if (db == null || db.hasBook(nt)) {
              target = nt;
              cur = null;
            }
            matched = true;
            break;
          }
        } else if (r.type == 'daf') {
          String? ref;
          final dm = dafRe.firstMatch(text);
          if (dm != null) {
            ref = dm[1]! + dm[2]!;
          } else if ((r.formats ?? const ['std', 'ext']).contains('ext')) {
            ref = parseDafExt(text);
          }
          if (ref != null) {
            cur = ref;
            matched = true;
            break;
          }
        } else if (r.type == 'heading') {
          final m = compiled[r]!.matchAsPrefix(text);
          if (m == null) continue;
          final groups = [for (var g = 1; g <= m.groupCount; g++) m[g]];
          final ref = (r.role != 'sub' || chapter != null) ? _fmt(r.ref, groups, chapter) : null;
          if (r.role == 'chapter') {
            chapter = ref;
            cur = null;
          } else {
            cur = ref;
          }
          matched = true;
          break;
        }
      }
      if (!matched && lvl >= 2) {
        final k = text.length > 40 ? text.substring(0, 40) : text;
        unmatched[k] = (unmatched[k] ?? 0) + 1;
        // כותרת לא מזוהה ברמה של הכללים מנתקת את המיקום, כדי שלא יידבקו אליו שורות שלא שייכות
        if (profile.resetOnUnmatched && rules.any((r) => r.type != 'anchor' && r.lo <= lvl && lvl <= r.hi)) {
          cur = null;
        }
      }
      continue;
    }
    if (i == 1 || s.isEmpty) continue;
    if (useAnchor) {
      final m = _anchorRe.firstMatch(s);
      if (m != null) {
        final side = m[2] ?? (m[3] == 'א' ? '.' : ':');
        cur = m[1]!.replaceAll(_quoteRe, '') + side;
      }
    }
    final c = cur;
    if (c == null || c.isEmpty || target.isEmpty) continue;
    if (profile.validate && db != null) {
      final v = db.validRefs(target);
      if (v != null) {
        final d = db.dafset(target);
        if (!v.contains(c) && !(d != null && d.contains(c))) continue;
      }
    }
    out[i] = (target, c);
  }
  if (profile.validate && db != null && target.isNotEmpty && db.toc(target) == null && target0.isNotEmpty) {
    notes.add('ספר היעד לא נמצא ב-seforim.db: $target0');
  }
  return ProfileResult(out, notes, unmatched, nHead);
}

/// שורות links.csv לספר.
List<List<String>> linksRows(String stem, LinkMap rows, {String linkType = 'פירוש', String category = ''}) {
  final keys = rows.keys.toList()..sort();
  return [
    for (final ln in keys) ['$ln', stem, 'כן', rows[ln]!.$1, rows[ln]!.$2, linkType, 'לא', category],
  ];
}

const linkHeader = ['מקור', 'ספר_מקור', 'מקור_אישי', 'ספר_יעד', 'מיקום_יעד', 'סוג', 'יעד_אישי', 'קטגוריית_מקור'];
