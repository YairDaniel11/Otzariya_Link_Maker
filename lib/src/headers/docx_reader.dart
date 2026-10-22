// קורא Word (.docx) לשורות בפורמט אוצריא: פורט של converter.py (עורך מנחם, Otzaria/OrechMenachemPy).
//
// פסקה = שורה. סגנונות כותרת -> <h1>..<h6>; הדגשה/נטייה/קו תחתון/עילי/תחתי -> b/i/u/sup/sub;
// גודל יחסית לטקסט הרגיל -> big/small; הערות שוליים -> <sup>N</sup> בגוף + גוף ההערה ב-notes.
// תגים תמיד מאוזנים בתוך השורה. ללא Flutter (רץ ב-isolate).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../engine/errors.dart';

/// התקדמות 0..1.
typedef HeadersProgress = void Function(double fraction);

/// סטטיסטיקה של ייבוא.
class DocxStats {
  DocxStats(this.headingsPerLevel, this.footnotes, this.usedHeadingStyles, this.paragraphs, this.tocSkipped);

  /// מספר פסקאות כותרת לכל רמה (h1-h6, אחרי חיתוך ל-6).
  final Map<int, int> headingsPerLevel;
  final int footnotes;

  /// האם נמצאו פסקאות בסגנון כותרת (או outline level).
  final bool usedHeadingStyles;

  /// מספר שורות שנוצרו.
  final int paragraphs;

  /// פסקאות תוכן עניינים אוטומטי של Word שדולגו.
  final int tocSkipped;
}

class DocxImport {
  DocxImport(this.lines, this.notes, this.baseHalfPts, this.noteHalfPts, this.detectedBaseHalfPts, this.detectedNoteHalfPts, this.stats);

  /// שורה לכל פסקה, כותרות כ-<hN>טקסט</hN>.
  final List<String> lines;

  /// גופי הערות שוליים לפי הסדר (note N = notes[N-1]), מעוצבים; מעברי פסקה = <br>.
  final List<String> notes;

  /// הגדלים שבהם נעשה שימוש (חצאי נקודות; 0 = בלי תגי גודל).
  final int baseHalfPts, noteHalfPts;

  /// הגדלים שזוהו אוטומטית (חצאי נקודות; 0 = לא זוהה).
  final int detectedBaseHalfPts, detectedNoteHalfPts;
  final DocxStats stats;
}

// ───────────────────────────── קבועים ─────────────────────────────

const _wNs = {
  'http://schemas.openxmlformats.org/wordprocessingml/2006/main',
  'http://purl.oclc.org/ooxml/wordprocessingml/main',
};
const _mcNs = 'http://schemas.openxmlformats.org/markup-compatibility/2006';

const _bB = 1, _bU = 2, _bI = 4, _bSup = 8, _bSub = 16, _bBig = 32, _bSmall = 64;
// מבחוץ פנימה
const _order = [_bSmall, _bBig, _bSub, _bSup, _bI, _bU, _bB];
const _tagOf = {_bB: 'b', _bU: 'u', _bI: 'i', _bSup: 'sup', _bSub: 'sub', _bBig: 'big', _bSmall: 'small'};

/// תו מציין-מקום להפניית הערה (מוחלף ב-<sup>N</sup>).
const _fnRef = '\x02';

bool _isW(XmlNode? n, String local) => n is XmlElement && n.name.local == local && _wNs.contains(n.name.namespaceUri);

String? _attr(XmlElement e, String local) {
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return null;
}

XmlElement? _child(XmlElement? e, String local) {
  if (e == null) return null;
  for (final c in e.childElements) {
    if (_isW(c, local)) return c;
  }
  return null;
}

bool _toggle(XmlElement e) {
  final v = _attr(e, 'val');
  return v == null || !(v == '0' || v == 'false' || v == 'off');
}

int? _intVal(XmlElement? e) => e == null ? null : int.tryParse((_attr(e, 'val') ?? '').split('.').first);

// ───────────────────────────── מאפייני ריצה וסגנונות ─────────────────────────────

class _Rpr {
  bool? bCs, b, iCs, i, u;
  String? vertAlign;
  int? szCs, sz;
}

_Rpr _extractRpr(XmlElement rpr) {
  final r = _Rpr();
  for (final c in rpr.childElements) {
    if (!_wNs.contains(c.name.namespaceUri)) continue;
    switch (c.name.local) {
      case 'bCs':
        r.bCs = _toggle(c);
      case 'b':
        r.b = _toggle(c);
      case 'iCs':
        r.iCs = _toggle(c);
      case 'i':
        r.i = _toggle(c);
      case 'u':
        final v = _attr(c, 'val');
        r.u = v != 'none';
      case 'vertAlign':
        r.vertAlign = _attr(c, 'val');
      case 'szCs':
        r.szCs = _intVal(c);
      case 'sz':
        r.sz = _intVal(c);
    }
  }
  return r;
}

class _Style {
  String? type, basedOn, name;
  int? outline;
  _Rpr rpr = _Rpr();
}

int? _builtinHeadingLevel(String? id, String? name) {
  for (final v in [name, id]) {
    if (v == null) continue;
    final t = v.trim().toLowerCase();
    for (final prefix in const ['heading', 'כותרת']) {
      if (t.startsWith(prefix)) {
        final n = int.tryParse(t.substring(prefix.length).trim());
        if (n != null && n >= 1 && n <= 9) return n;
      }
    }
  }
  return null;
}

final _tocStyleRe = RegExp(r'^(?:toc\s*\d|toc heading|table of contents|תוכן עניינים|תוכן ענינים)', caseSensitive: false);

class _Chars {
  final ch = <String>[];
  final mask = <int>[];
  void add(String c, int m) {
    ch.add(c);
    mask.add(m);
  }
}

// ───────────────────────────── המסמך ─────────────────────────────

class _Docx {
  _Docx._(this.doc, this.styles, this.defaultRpr, this.defaultPStyle, this.footnotes);

  final XmlDocument doc;
  final Map<String, _Style> styles;
  final _Rpr defaultRpr;
  final String? defaultPStyle;
  final Map<String, XmlElement> footnotes;

  static _Docx open(String path) {
    final f = File(path);
    if (!f.existsSync()) throw AppError('הקובץ לא נמצא: $path');
    final Uint8List bytes = f.readAsBytesSync();
    if (bytes.isEmpty) throw AppError('הקובץ ריק.');
    final lower = path.toLowerCase();
    if (bytes.length >= 4 && bytes[0] == 0xD0 && bytes[1] == 0xCF && bytes[2] == 0x11 && bytes[3] == 0xE0) {
      throw AppError('זהו קובץ Word ישן (doc). פתחו אותו ב-Word ושמרו בשם כ-docx, ואז נסו שוב.');
    }
    if (bytes.length >= 5 && bytes[0] == 0x7B && bytes[1] == 0x5C && bytes[2] == 0x72 && bytes[3] == 0x74 && bytes[4] == 0x66) {
      throw AppError('זהו קובץ RTF. פתחו אותו ב-Word ושמרו בשם כ-docx, ואז נסו שוב.');
    }
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4B) {
      throw AppError(lower.endsWith('.doc')
          ? 'זהו קובץ Word ישן (doc). פתחו אותו ב-Word ושמרו בשם כ-docx, ואז נסו שוב.'
          : 'הקובץ אינו מסמך Word (docx) תקין.');
    }
    final Archive zip;
    try {
      zip = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw AppError('לא ניתן לפתוח את הקובץ כ-docx (הקובץ פגום או אינו מסמך Word).');
    }
    XmlDocument? parse(String name) {
      final af = zip.findFile(name);
      if (af == null) return null;
      var s = utf8.decode(af.content, allowMalformed: true);
      if (s.startsWith('﻿')) s = s.substring(1);
      try {
        return XmlDocument.parse(s);
      } catch (_) {
        return null;
      }
    }

    final doc = parse('word/document.xml');
    if (doc == null) throw AppError('הקובץ אינו מסמך Word תקין (חסר word/document.xml).');

    final styles = <String, _Style>{};
    var defRpr = _Rpr();
    String? defP;
    final sdoc = parse('word/styles.xml');
    if (sdoc != null) {
      final root = sdoc.rootElement;
      final dd = _child(_child(_child(root, 'docDefaults'), 'rPrDefault'), 'rPr');
      if (dd != null) defRpr = _extractRpr(dd);
      for (final st in root.childElements) {
        if (!_isW(st, 'style')) continue;
        final sid = _attr(st, 'styleId');
        if (sid == null) continue;
        final bo = _child(st, 'basedOn'), nm = _child(st, 'name');
        final s = _Style()
          ..type = _attr(st, 'type')
          ..basedOn = bo == null ? null : _attr(bo, 'val')
          ..name = nm == null ? '' : _attr(nm, 'val');
        s.outline = _intVal(_child(_child(st, 'pPr'), 'outlineLvl'));
        final rpr = _child(st, 'rPr');
        if (rpr != null) s.rpr = _extractRpr(rpr);
        styles[sid] = s;
        final d = _attr(st, 'default');
        if ((d == '1' || d == 'true') && s.type == 'paragraph') defP = sid;
      }
    }

    final fns = <String, XmlElement>{};
    final fdoc = parse('word/footnotes.xml');
    if (fdoc != null) {
      for (final fn in fdoc.rootElement.childElements) {
        if (!_isW(fn, 'footnote')) continue;
        final t = _attr(fn, 'type');
        if (t != null && t != 'normal') continue; // separator וכד'
        final id = _attr(fn, 'id');
        if (id != null) fns[id] = fn;
      }
    }
    return _Docx._(doc, styles, defRpr, defP, fns);
  }

  XmlElement? get body {
    for (final c in doc.rootElement.childElements) {
      if (_isW(c, 'body')) return c;
    }
    return null;
  }

  // ── סגנונות ──
  List<String> _chain(String? sid) {
    final seen = <String>{};
    final out = <String>[];
    while (sid != null && styles.containsKey(sid) && seen.add(sid)) {
      out.add(sid);
      sid = styles[sid]!.basedOn;
    }
    return out;
  }

  T? _res<T>(T? Function(_Rpr) get, _Rpr run, String? rstyle, String? pstyle) {
    var v = get(run);
    if (v != null) return v;
    for (final s in _chain(rstyle)) {
      v = get(styles[s]!.rpr);
      if (v != null) return v;
    }
    for (final s in _chain(pstyle)) {
      v = get(styles[s]!.rpr);
      if (v != null) return v;
    }
    return get(defaultRpr);
  }

  int _runMask(XmlElement run, String? pstyle, int baseHp) {
    final rpr = _child(run, 'rPr');
    final r = rpr == null ? _Rpr() : _extractRpr(rpr);
    final rsEl = _child(rpr, 'rStyle');
    final rstyle = rsEl == null ? null : _attr(rsEl, 'val');
    // מאפייני הכתב המורכב (עברית) קובעים; אם אינם מוגדרים בשום מקום - נופלים למאפיינים הרגילים
    final bold = _res((x) => x.bCs, r, rstyle, pstyle) ?? _res((x) => x.b, r, rstyle, pstyle) ?? false;
    final ital = _res((x) => x.iCs, r, rstyle, pstyle) ?? _res((x) => x.i, r, rstyle, pstyle) ?? false;
    final und = _res((x) => x.u, r, rstyle, pstyle) ?? false;
    final va = _res((x) => x.vertAlign, r, rstyle, pstyle);
    final size = _res((x) => x.szCs, r, rstyle, pstyle) ?? _res((x) => x.sz, r, rstyle, pstyle);
    var m = 0;
    if (bold) m |= _bB;
    if (und) m |= _bU;
    if (ital) m |= _bI;
    if (va == 'superscript') m |= _bSup;
    if (va == 'subscript') m |= _bSub;
    if (baseHp > 0 && size != null) {
      if (size > baseHp && size <= 40) m |= _bBig;
      if (size < baseHp && size >= 6) m |= _bSmall;
    }
    return m;
  }

  int? _runSize(XmlElement run, String? pstyle) {
    final rpr = _child(run, 'rPr');
    final r = rpr == null ? _Rpr() : _extractRpr(rpr);
    final rsEl = _child(rpr, 'rStyle');
    final rstyle = rsEl == null ? null : _attr(rsEl, 'val');
    return _res((x) => x.szCs, r, rstyle, pstyle) ?? _res((x) => x.sz, r, rstyle, pstyle);
  }

  int? _styleOutline(String? sid) {
    final chain = _chain(sid);
    for (final s in chain) {
      if (styles[s]!.outline != null) return styles[s]!.outline;
    }
    for (final s in chain) {
      final l = _builtinHeadingLevel(s, styles[s]!.name);
      if (l != null) return l - 1;
    }
    return null;
  }

  String? paraStyle(XmlElement p) {
    final ps = _child(_child(p, 'pPr'), 'pStyle');
    return ps != null ? _attr(ps, 'val') : defaultPStyle;
  }

  /// 1..9 לפסקת כותרת, אחרת null.
  int? headingLevel(XmlElement p) {
    final ppr = _child(p, 'pPr');
    int? lvl;
    if (ppr != null) {
      lvl = _intVal(_child(ppr, 'outlineLvl'));
      if (lvl == null) {
        final ps = _child(ppr, 'pStyle');
        if (ps != null) lvl = _styleOutline(_attr(ps, 'val'));
      }
    }
    if (lvl == null || lvl < 0 || lvl > 8) return null;
    return lvl + 1;
  }

  bool isTocPara(XmlElement p) {
    for (final s in _chain(paraStyle(p))) {
      if (_tocStyleRe.hasMatch((styles[s]!.name ?? '').trim()) || _tocStyleRe.hasMatch(s)) return true;
    }
    return false;
  }

  // ── תוכן פסקה ──
  static bool _inSkipped(XmlNode el) {
    XmlNode? n = el.parent;
    while (n is XmlElement) {
      if (_isW(n, 'pPr') || _isW(n, 'del') || _isW(n, 'moveFrom') || (n.name.local == 'Fallback' && n.name.namespaceUri == _mcNs)) return true;
      n = n.parent;
    }
    return false;
  }

  static bool _isParaContent(XmlElement el, XmlElement p) {
    XmlNode? n = el.parent;
    while (n != null && !identical(n, p)) {
      if (n is XmlElement && (_isW(n, 'pPr') || _isW(n, 'del') || _isW(n, 'moveFrom') || _isW(n, 'p') || (n.name.local == 'Fallback' && n.name.namespaceUri == _mcNs))) {
        return false;
      }
      n = n.parent;
    }
    return true;
  }

  static XmlElement? _enclosingRun(XmlElement el, [XmlElement? p]) {
    XmlNode? n = el.parent;
    while (n is XmlElement && !identical(n, p)) {
      if (_isW(n, 'r')) return n;
      if (n.name.namespaceUri != _mcNs) return null;
      n = n.parent;
    }
    return null;
  }

  static const _content = {'t', 'tab', 'br', 'cr', 'noBreakHyphen', 'footnoteRef', 'footnoteReference'};

  /// פסקה -> תווים עם מסכת עיצוב. [plain] = בלי עיצוב (כותרות).
  _Chars paraChars(XmlElement p, String? pstyle, int baseHp, Map<String, int> fnMap, List<int> refs, {bool inFootnote = false, bool plain = false}) {
    final out = _Chars();
    final cache = <XmlElement, int>{};
    var skipLeadingWs = false;
    for (final el in p.descendantElements) {
      final name = el.name.local;
      if (!_content.contains(name)) continue;
      // תוכן במרחב של Word חייב לשבת בתוך ריצה; DrawingML/נוסחאות אינם נתמכים כטקסט פסקה
      final run = _wNs.contains(el.name.namespaceUri) ? _enclosingRun(el, p) : null;
      if (run == null) continue; // למשל w:tab בתוך w:pPr/w:tabs
      if (!_isParaContent(el, p)) continue;
      int mask() => plain ? 0 : cache.putIfAbsent(run, () => _runMask(run, pstyle, baseHp));
      switch (name) {
        case 'footnoteRef':
          skipLeadingWs = true;
        case 'footnoteReference':
          if (inFootnote) continue;
          final num = fnMap[_attr(el, 'id')];
          if (num != null) {
            out.add(_fnRef, 0);
            refs.add(num);
          }
        case 't':
          var text = el.innerText;
          if (skipLeadingWs) {
            text = text.replaceFirst(RegExp(r'^[ \t]+'), '');
            if (text.isNotEmpty) skipLeadingWs = false;
          }
          if (text.isEmpty) continue;
          final m = mask();
          for (final r in text.runes) {
            out.add(String.fromCharCode(r), m);
          }
        case 'tab':
          if (!skipLeadingWs) out.add(' ', mask());
        case 'br':
        case 'cr':
          final t = _attr(el, 'type');
          if (name == 'br' && (t == 'page' || t == 'column')) continue;
          skipLeadingWs = false;
          out.add('\n', 0);
        case 'noBreakHyphen':
          skipLeadingWs = false;
          out.add('-', mask());
      }
    }
    return out;
  }

  Map<String, int> footnoteOrder(List<String> order) {
    final map = <String, int>{};
    for (final ref in doc.descendantElements) {
      if (!_isW(ref, 'footnoteReference')) continue;
      final id = _attr(ref, 'id');
      if (id == null || !footnotes.containsKey(id) || map.containsKey(id)) continue;
      if (_enclosingRun(ref) == null || _inSkipped(ref)) continue;
      map[id] = map.length + 1;
      order.add(id);
    }
    return map;
  }

  Iterable<XmlElement> paragraphs() sync* {
    final b = body;
    if (b == null) return;
    for (final p in b.descendantElements) {
      if (_isW(p, 'p') && !_inSkipped(p)) yield p;
    }
  }

  // ── זיהוי גדלים ──
  int detectBaseHp() {
    final counts = <int, int>{};
    for (final p in paragraphs()) {
      if (headingLevel(p) != null) continue;
      final ps = paraStyle(p);
      for (final t in p.descendantElements) {
        if (!_isW(t, 't')) continue;
        final run = _enclosingRun(t, p);
        if (run == null || !_isParaContent(t, p)) continue;
        final sz = _runSize(run, ps);
        if (sz != null && sz > 0) counts[sz] = (counts[sz] ?? 0) + t.innerText.length;
      }
    }
    return _top(counts);
  }

  int detectNotesHp() {
    for (final s in styles.values) {
      final nm = (s.name ?? '').toLowerCase();
      if (s.type == 'paragraph' && (nm == 'footnote text' || nm == 'annotation text' || nm.contains('הערת שוליים'))) {
        final sz = s.rpr.szCs ?? s.rpr.sz;
        if (sz != null && sz > 0) return sz;
      }
    }
    final counts = <int, int>{};
    for (final fn in footnotes.values) {
      for (final p in fn.childElements.where((e) => _isW(e, 'p'))) {
        final ps = paraStyle(p);
        for (final t in p.descendantElements) {
          if (!_isW(t, 't')) continue;
          final run = _enclosingRun(t, p);
          if (run == null) continue;
          final sz = _runSize(run, ps);
          if (sz != null && sz > 0) counts[sz] = (counts[sz] ?? 0) + t.innerText.length;
        }
      }
    }
    return _top(counts);
  }

  static int _top(Map<int, int> c) {
    var best = 0, bestN = -1;
    c.forEach((k, v) {
      if (v > bestN) {
        best = k;
        bestN = v;
      }
    });
    return best;
  }
}

// ───────────────────────────── עיבוד תווים לשורות מאוזנות ─────────────────────────────

final _entityAhead = RegExp(r'^&#?[A-Za-z0-9]{1,8};');

/// מעבד רשימת תווים לשורות: מפצל ב-'\n', מכווץ רווחים, מסיר רווחי קצה, ומוציא תגים מאוזנים בכל שורה.
/// רווח בין שני תווים בעלי אותו עיצוב נשאר בתוך התגים; בין עיצובים שונים - רק העיצוב המשותף.
/// מחזיר שורות לא ריקות בלבד. [refCounter] = מונה הפניות הערה בפסקה (נדרך בין שורות).
List<String> _renderLines(_Chars c, List<int> refs) {
  final out = <String>[];
  var start = 0;
  final refIdx = [0];
  for (var k = 0; k <= c.ch.length; k++) {
    if (k == c.ch.length || c.ch[k] == '\n') {
      final s = _renderSeg(c, start, k, refs, refIdx);
      if (s != null) out.add(s);
      start = k + 1;
    }
  }
  return out;
}

String? _renderSeg(_Chars c, int a, int b, List<int> refs, List<int> refIdx) {
  final ch = <String>[];
  final mk = <int>[];
  for (var i = a; i < b; i++) {
    var x = c.ch[i];
    if (x == '\t') x = ' ';
    if (x == ' ') {
      if (ch.isEmpty || ch.last == ' ') continue;
    }
    ch.add(x);
    mk.add(c.mask[i]);
  }
  while (ch.isNotEmpty && ch.last == ' ') {
    ch.removeLast();
    mk.removeLast();
  }
  if (ch.isEmpty) return null;
  // רווח לוקח את העיצוב המשותף לשכניו
  for (var i = 0; i < ch.length; i++) {
    if (ch[i] != ' ') continue;
    var l = i - 1, r = i + 1;
    while (l >= 0 && ch[l] == ' ') {
      l--;
    }
    while (r < ch.length && ch[r] == ' ') {
      r++;
    }
    mk[i] = (l >= 0 ? mk[l] : 0) & (r < ch.length ? mk[r] : 0);
  }
  final sb = StringBuffer();
  final stack = <int>[];
  for (var i = 0; i < ch.length; i++) {
    final m = mk[i];
    var k = 0;
    while (k < stack.length && (m & stack[k]) != 0) {
      k++;
    }
    while (stack.length > k) {
      sb.write('</${_tagOf[stack.removeLast()]}>');
    }
    for (final bit in _order) {
      if ((m & bit) != 0 && !stack.contains(bit)) {
        sb.write('<${_tagOf[bit]}>');
        stack.add(bit);
      }
    }
    final x = ch[i];
    if (x == _fnRef) {
      final n = refIdx[0] < refs.length ? refs[refIdx[0]] : 0;
      refIdx[0]++;
      sb.write('<sup>$n</sup>');
    } else if (x == '<') {
      sb.write('&lt;');
    } else if (x == '>') {
      sb.write('&gt;');
    } else if (x == '&') {
      final ahead = StringBuffer();
      for (var j = i; j < ch.length && j < i + 12; j++) {
        ahead.write(ch[j]);
      }
      sb.write(_entityAhead.hasMatch(ahead.toString()) ? '&amp;' : '&');
    } else {
      sb.write(x);
    }
  }
  while (stack.isNotEmpty) {
    sb.write('</${_tagOf[stack.removeLast()]}>');
  }
  return sb.toString();
}

// ───────────────────────────── ממשק ציבורי ─────────────────────────────

/// גדלי הטקסט הרגיל וההערות שזוהו, בחצאי נקודות (0 = לא זוהה). מדויק (11.5pt = 23).
({int text, int notes}) detectDocxSizesHalfPts(String path) {
  final d = _Docx.open(path);
  return (text: d.detectBaseHp(), notes: d.detectNotesHp());
}

/// גדלי הטקסט הרגיל וההערות שזוהו, בנקודות שלמות (0 = לא זוהה). מעוגל - להצגה בלבד;
/// להעברה חזרה ל-[importDocx] העדיפו [detectDocxSizesHalfPts] או null (זיהוי אוטומטי).
({int text, int notes}) detectDocxSizes(String path) {
  final h = detectDocxSizesHalfPts(path);
  return (text: (h.text / 2).round(), notes: (h.notes / 2).round());
}

/// ממיר docx לשורות. [baseHalfPts]/[noteHalfPts] = גודל הטקסט הרגיל/ההערות בחצאי נקודות
/// (null = זיהוי אוטומטי; 0 = בלי תגי גודל). זורק [AppError] בעברית על קובץ לא תקין/ריק/doc ישן.
DocxImport importDocx(String path, {int? baseHalfPts, int? noteHalfPts, HeadersProgress? progress}) {
  final d = _Docx.open(path);
  final detBase = d.detectBaseHp();
  final detNote = d.detectNotesHp();
  final baseHp = baseHalfPts ?? detBase;
  final noteHp = noteHalfPts ?? (detNote > 0 ? detNote : baseHp);
  progress?.call(0.05);

  final order = <String>[];
  final fnMap = d.footnoteOrder(order);
  final paras = d.paragraphs().toList();
  final lines = <String>[];
  final perLevel = <int, int>{};
  var toc = 0;
  for (var i = 0; i < paras.length; i++) {
    final p = paras[i];
    if (progress != null && i % 400 == 0) progress(0.05 + 0.85 * i / paras.length);
    if (d.isTocPara(p)) {
      toc++;
      continue;
    }
    final lvl = d.headingLevel(p);
    final ps = d.paraStyle(p);
    final refs = <int>[];
    if (lvl != null) {
      final chars = d.paraChars(p, ps, baseHp, fnMap, refs, plain: true);
      final text = _renderLines(chars, refs).join(' ').trim();
      if (text.isEmpty) continue;
      final h = lvl.clamp(1, 6);
      perLevel[h] = (perLevel[h] ?? 0) + 1;
      lines.add('<h$h>$text</h$h>');
    } else {
      final chars = d.paraChars(p, ps, baseHp, fnMap, refs);
      lines.addAll(_renderLines(chars, refs));
    }
  }

  final notes = <String>[];
  for (final id in order) {
    final paraTexts = <String>[];
    for (final p in d.footnotes[id]!.childElements.where((e) => _isW(e, 'p'))) {
      final chars = d.paraChars(p, d.paraStyle(p), noteHp, const {}, <int>[], inFootnote: true);
      final segs = _renderLines(chars, const []);
      if (segs.isNotEmpty) paraTexts.add(segs.join('<br>'));
    }
    notes.add(paraTexts.join('<br>'));
  }

  if (lines.isEmpty) throw AppError('המסמך ריק: לא נמצא בו טקסט.');
  progress?.call(1);
  return DocxImport(lines, notes, baseHp, noteHp, detBase, detNote,
      DocxStats(perLevel, notes.length, perLevel.isNotEmpty, lines.length, toc));
}
