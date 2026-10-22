// ייבוא Markdown (.md) לשורות בפורמט אוצריא: פורט והרחבה של md_to_lines מ-to_otzaria.py (סקיל otzaria-book-format).
//
// בלוק = שורה. הפלט נבנה מאפס מרשימת היתר: h1-h6, b, i, s, code, a (http/https/mailto), img (data: בלבד),
// br, sup (הערות), וכן ul/ol/li ו-table/tr/th/td כשורה אחת. תגים תמיד מאוזנים (מבנה רקורסיבי).
// ללא Flutter (רץ ב-isolate).

import '../engine/errors.dart';
import 'header_utils.dart';
import 'txt_headers.dart';

/// תוצאת ייבוא Markdown. דומה ל-DocxImport: [lines] + [notes] (note N = notes[N-1]).
class MdImport {
  MdImport(this.lines, this.notes, this.headingCount, this.detectedTitle);

  /// שורה לכל בלוק; כותרות כ-<h2>..<h6> (h1 של שם הספר מוסר ונחשף ב-[detectedTitle] - הבונה מוסיף אותו כשורה 1).
  final List<String> lines;

  /// גופי הערות שוליים לפי הסדר (מעברי פסקה = <br>); בגוף: <sup>N</sup>.
  final List<String> notes;

  /// מספר כותרות לכל רמת פלט (מפתחות 1..6), לא כולל כותרת הספר שהוסרה.
  final Map<int, int> headingCount;

  /// שם הספר: '#' יחיד וראשון (או title ב-front matter); null אם לא זוהה.
  final String? detectedTitle;

  /// האם יש כותרות (מעבר לכותרת הספר).
  bool get hasHeadings => headingCount.values.any((v) => v > 0);
}

/// קורא קובץ .md (UTF-8/BOM/UTF-16/windows-1255) וממיר.
MdImport importMarkdown(String path) => importMarkdownText(loadBookTextLines(path).join('\n'));

/// ממיר טקסט Markdown.
MdImport importMarkdownText(String text) {
  var t = text.replaceAll('﻿', '').replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll('\t', '    ');
  String? fmTitle;
  final fm = RegExp(r'^---[ ]*\n([\s\S]*?)\n(?:---|\.\.\.)[ ]*(?:\n|$)').firstMatch(t);
  if (fm != null) {
    final tm = RegExp(r'^title:\s*(.+)$', multiLine: true).firstMatch(fm.group(1)!);
    if (tm != null) {
      fmTitle = tm.group(1)!.trim().replaceAll(RegExp(r'''^["']|["']$'''), '');
      if (fmTitle.isEmpty) fmTitle = null;
    }
    t = t.substring(fm.end);
  }
  final st = _State();
  final src = _preHtml(_extractDefs(t.split('\n'), st), st);
  final outs = _blocks(src, st, top: true);
  return _finish(outs, st, fmTitle);
}

// ───────────────────────────── מצב ─────────────────────────────

class _Out {
  _Out(this.html, {this.level});
  final String html;

  /// רמת כותרת מקורית (1..6) או null לשורת תוכן.
  final int? level;
}

class _State {
  final Map<String, List<String>> footDefs = {}; // id -> פסקאות גולמיות
  final Map<String, String> refs = {}; // id (lowercase) -> url
  final List<String> notes = [];

  /// בלוקי HTML גולמיים (ul/ol/table) שעברו ניקוי, לפי placeholder.
  final List<String> raw = [];
}

// ───────────────────────────── HTML גולמי (Obsidian וכו') ─────────────────────────────

const _inlineMap = {
  'b': 'b', 'strong': 'b', 'i': 'i', 'em': 'i', 'cite': 'i', 'dfn': 'i', 'var': 'i', 'u': 'u', 'ins': 'u', //
  's': 's', 'del': 's', 'strike': 's', 'sub': 'sub', 'sup': 'sup', 'small': 'small', 'big': 'big', //
  'code': 'code', 'kbd': 'code', 'samp': 'code', 'tt': 'code', 'abbr': 'abbr', 'acronym': 'abbr', 'mark': 'mark', 'a': 'a',
};
const _structMap = {'ul': 'ul', 'ol': 'ol', 'li': 'li', 'table': 'table', 'tr': 'tr', 'td': 'td', 'th': 'th'};
final _blockTagRe = RegExp(
    r'</?(?:div|section|article|aside|header|footer|nav|main|details|summary|p|center|blockquote|figure|figcaption|address|form|fieldset|dl|dt|dd|caption|hgroup|li|tr|td|th|tbody|thead|tfoot|body|html|hr)\b[^<>]*>',
    caseSensitive: false);
final _srcRe = RegExp(r'''\bsrc\s*=\s*["']([^"']+)["']''', caseSensitive: false);
final _hrefRe = RegExp(r'''\bhref\s*=\s*["']([^"']*)["']''', caseSensitive: false);
final _rawStartRe = RegExp(r'<(ul|ol|table)\b[^<>]*>', caseSensitive: false);

String? _entValue(String g) {
  if (g.startsWith('#')) {
    final cp = g[1] == 'x' || g[1] == 'X' ? int.tryParse(g.substring(2), radix: 16) : int.tryParse(g.substring(1));
    if (cp != null && cp > 0 && cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF)) return String.fromCharCode(cp);
    return null;
  }
  return _ents[g];
}

String _decodeEnts(String s) => s.replaceAllMapped(_entRe, (m) => _entValue(m.group(1)!) ?? m.group(0)!);

/// מנקה HTML גולמי לרשימת ההיתר: תגים לא מוכרים נפרקים (הטקסט נשמר), תגים ריקים נמחקים, הכל באותה שורה.
String _sanitize(String html) {
  final sb = StringBuffer();
  final stack = <(String, String?)>[];
  var pos = 0;
  void text(String t) {
    if (t.isEmpty) return;
    final structural = stack.isNotEmpty && const {'ul', 'ol', 'table', 'tr'}.contains(stack.last.$2);
    final d = _decodeEnts(t).replaceAll(RegExp(r'\s+'), ' ');
    if (structural && d.trim().isEmpty) return;
    sb.write(_lit(d));
  }

  for (final m in _htmlTagRe.allMatches(html)) {
    text(html.substring(pos, m.start));
    pos = m.end;
    final name = m.group(2)?.toLowerCase();
    if (name == null) continue;
    final whole = m.group(0)!;
    if (m.group(1) == '/') {
      final k = stack.lastIndexWhere((e) => e.$1 == name);
      if (k < 0) continue;
      while (stack.length > k) {
        final e = stack.removeLast();
        if (e.$2 != null) sb.write('</${e.$2}>');
      }
      continue;
    }
    if (name == 'br') {
      sb.write('<br>');
      continue;
    }
    if (name == 'img') {
      final src = _srcRe.firstMatch(whole)?.group(1);
      if (src != null && _okImg.hasMatch(src)) sb.write('<img src="$src" style="max-width: 100%;">');
      continue;
    }
    if (whole.endsWith('/>')) continue;
    String? out = _structMap[name] ?? _inlineMap[name];
    if (out == 'a') {
      final href = _hrefRe.firstMatch(whole)?.group(1) ?? '';
      if (_okHref.hasMatch(href)) {
        sb.write('<a href="${_attr(href)}">');
      } else {
        out = null;
      }
    } else if (out != null) {
      sb.write('<$out>');
    }
    stack.add((name, out));
  }
  text(html.substring(pos));
  while (stack.isNotEmpty) {
    final e = stack.removeLast();
    if (e.$2 != null) sb.write('</${e.$2}>');
  }
  var r = sb.toString();
  r = r.replaceAllMapped(RegExp(r'<(li|td|th)>\s+'), (m) => '<${m.group(1)}>');
  r = r.replaceAllMapped(RegExp(r'\s+</(li|td|th)>'), (m) => '</${m.group(1)}>');
  final empty = RegExp(r'<(b|i|u|s|sub|sup|small|big|code|abbr|mark|a|li|tr|ul|ol|table)(?: [^>]*)?></\1>');
  while (empty.hasMatch(r)) {
    r = r.replaceAll(empty, '');
  }
  return r;
}

/// עיבוד מקדים של HTML גולמי בטקסט (מחוץ לגדרות קוד): בלוקי עטיפה הופכים להפרדת פסקאות
/// (ה-Markdown שבתוכם ממשיך להיות מעובד), pre לגדר קוד, ul/ol/table לשורה אחת מנוקה.
List<String> _preHtml(List<String> lines, _State st) {
  final out = <String>[];
  final buf = <String>[];
  void flushBuf() {
    if (buf.isEmpty) return;
    out.addAll(_htmlText(buf.join('\n'), st).split('\n'));
    buf.clear();
  }

  String? fence;
  for (final l in lines) {
    final fm = _fenceRe.firstMatch(l);
    if (fence != null) {
      out.add(l);
      if (fm != null && fm.group(1)![0] == fence[0] && fm.group(1)!.length >= fence.length && fm.group(2)!.trim().isEmpty) fence = null;
    } else if (fm != null) {
      flushBuf();
      fence = fm.group(1);
      out.add(l);
    } else {
      buf.add(l);
    }
  }
  flushBuf();
  return out;
}

String _htmlText(String t, _State st) {
  if (!t.contains('<')) return t;
  t = t.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
  t = t.replaceAllMapped(RegExp(r'<pre\b[^<>]*>([\s\S]*?)</pre\s*>', caseSensitive: false), (m) {
    final inner = _decodeEnts(m.group(1)!.replaceAll(RegExp(r'<[^<>]+>'), '')).trim();
    return '\n\n```\n$inner\n```\n\n';
  });
  // ul/ol/table גולמיים (עם התאמת עומק)
  final sb = StringBuffer();
  var pos = 0;
  while (true) {
    final m = _rawStartRe.firstMatch(t.substring(pos));
    if (m == null) break;
    final start = pos + m.start;
    final name = m.group(1)!.toLowerCase();
    final tagRe = RegExp('<(/?)$name\\b[^<>]*>', caseSensitive: false);
    var depth = 0;
    var end = -1;
    for (final x in tagRe.allMatches(t, start)) {
      depth += x.group(1) == '/' ? -1 : 1;
      if (depth == 0) {
        end = x.end;
        break;
      }
    }
    if (end < 0) {
      sb.write(t.substring(pos, start + m.group(0)!.length));
      pos = start + m.group(0)!.length;
      continue;
    }
    sb.write(t.substring(pos, start));
    final html = _sanitize(t.substring(start, end));
    if (html.isNotEmpty) {
      st.raw.add(html);
      sb.write('\n\n\u0002${st.raw.length - 1}\u0002\n\n');
    }
    pos = end;
  }
  sb.write(t.substring(pos));
  t = sb.toString();
  t = t.replaceAllMapped(RegExp(r'<h([1-6])\b[^<>]*>([\s\S]*?)</h\1\s*>', caseSensitive: false),
      (m) => '\n\n${'#' * int.parse(m.group(1)!)} ${m.group(2)!.replaceAll('\n', ' ').trim()}\n\n');
  return t.replaceAll(_blockTagRe, '\n\n');
}

final _footDefRe = RegExp(r'^ {0,3}\[\^([^\]\s]+)\]:[ ]?(.*)$');
final _refDefRe = RegExp(r'^ {0,3}\[([^\]^][^\]]*)\]:[ ]*<?([^\s>]+)>?(?:[ ]+.*)?$');
final _fenceRe = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');

/// מוציא הגדרות הערות והפניות מהטקסט (מחוץ לגדרות קוד) ומחזיר את יתר השורות.
List<String> _extractDefs(List<String> lines, _State st) {
  final out = <String>[];
  String? fence;
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final fmatch = _fenceRe.firstMatch(line);
    if (fence != null) {
      out.add(line);
      if (fmatch != null && fmatch.group(1)![0] == fence[0] && fmatch.group(1)!.length >= fence.length && fmatch.group(2)!.trim().isEmpty) {
        fence = null;
      }
      i++;
      continue;
    }
    if (fmatch != null) {
      fence = fmatch.group(1);
      out.add(line);
      i++;
      continue;
    }
    final fd = _footDefRe.firstMatch(line);
    if (fd != null) {
      final parts = <String>[fd.group(2)!.trim()];
      i++;
      while (i < lines.length) {
        final l = lines[i];
        if (l.trim().isEmpty) {
          var k = i + 1;
          while (k < lines.length && lines[k].trim().isEmpty) {
            k++;
          }
          if (k < lines.length && lines[k].startsWith('    ')) {
            parts.add('');
            i = k;
            continue;
          }
          break;
        }
        if (l.startsWith('    ')) {
          if (parts.last.isEmpty) {
            parts[parts.length - 1] = l.trim();
          } else {
            parts[parts.length - 1] = '${parts.last} ${l.trim()}';
          }
          i++;
          continue;
        }
        break;
      }
      st.footDefs.putIfAbsent(fd.group(1)!, () => parts.where((p) => p.isNotEmpty).toList());
      continue;
    }
    final rd = _refDefRe.firstMatch(line);
    if (rd != null) {
      st.refs.putIfAbsent(rd.group(1)!.trim().toLowerCase(), () => rd.group(2)!);
      i++;
      continue;
    }
    out.add(line);
    i++;
  }
  return out;
}

// ───────────────────────────── בלוקים ─────────────────────────────

final _atxRe = RegExp(r'^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t]*$');
final _setextRe = RegExp(r'^ {0,3}(=+|-+)[ \t]*$');
final _hrRe = RegExp(r'^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$');
final _quoteRe = RegExp(r'^ {0,3}> ?');
final _listRe = RegExp(r'^( *)([-*+]|\d{1,9}[.)])[ \t]+(\S.*)$');
final _tableDelimRe = RegExp(r'^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$');

bool _isHr(String l) => _hrRe.hasMatch(l);

bool _startsBlock(String l) =>
    _atxRe.hasMatch(l) || _fenceRe.hasMatch(l) || _quoteRe.hasMatch(l) || _isHr(l);

bool _isTableStart(List<String> ls, int i) =>
    i + 1 < ls.length && ls[i].contains('|') && ls[i + 1].contains('|') && _tableDelimRe.hasMatch(ls[i + 1]);

String _joinPara(List<String> para) {
  final sb = StringBuffer();
  for (var k = 0; k < para.length; k++) {
    var l = para[k].trimLeft();
    final last = k == para.length - 1;
    var hard = false;
    if (l.endsWith('  ')) hard = true;
    l = l.trimRight();
    if (l.endsWith('\\') && !l.endsWith('\\\\')) {
      hard = true;
      l = l.substring(0, l.length - 1);
    }
    sb.write(l);
    if (!last) sb.write(hard ? '\u0001' : ' ');
  }
  return sb.toString();
}

class _Li {
  _Li(this.indent, this.ol, this.text);
  final int indent;
  final bool ol;
  String text;
  final List<_Li> kids = [];
}

String _renderLis(List<_Li> sibs, _State st) {
  final tag = sibs.first.ol ? 'ol' : 'ul';
  final sb = StringBuffer('<$tag>');
  for (final li in sibs) {
    sb.write('<li>${_inline(li.text, st)}');
    if (li.kids.isNotEmpty) sb.write(_renderLis(li.kids, st));
    sb.write('</li>');
  }
  sb.write('</$tag>');
  return sb.toString();
}

List<String> _splitCells(String row) {
  var r = row.trim();
  if (r.startsWith('|')) r = r.substring(1);
  if (r.endsWith('|') && !r.endsWith('\\|')) r = r.substring(0, r.length - 1);
  final cells = <String>[];
  final cur = StringBuffer();
  var inCode = false;
  for (var i = 0; i < r.length; i++) {
    final c = r[i];
    if (c == '\\' && i + 1 < r.length && r[i + 1] == '|') {
      cur.write('|');
      i++;
    } else if (c == '`') {
      inCode = !inCode;
      cur.write(c);
    } else if (c == '|' && !inCode) {
      cells.add(cur.toString().trim());
      cur.clear();
    } else {
      cur.write(c);
    }
  }
  cells.add(cur.toString().trim());
  return cells;
}

List<_Out> _blocks(List<String> lines, _State st, {required bool top}) {
  final out = <_Out>[];
  var para = <String>[];

  void add(String html, {int? level}) {
    final h = html.replaceAll('\n', ' ').trim();
    if (h.isEmpty) return;
    if (level == null && plainText(h).trim().isEmpty && !h.contains('<img')) return;
    if (level != null && !top) {
      out.add(_Out('<b>$h</b>'));
    } else {
      out.add(_Out(h, level: level));
    }
  }

  void flush() {
    if (para.isEmpty) return;
    final t = _joinPara(para).trim();
    para = [];
    final rm = RegExp(r'^\u0002(\d+)\u0002$').firstMatch(t);
    if (rm != null) {
      add(st.raw[int.parse(rm.group(1)!)]);
      return;
    }
    add(_inline(t.replaceAll('\u0002', ''), st));
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      flush();
      i++;
      continue;
    }
    // גדר קוד
    final fm = _fenceRe.firstMatch(line);
    if (fm != null) {
      flush();
      final marker = fm.group(1)!;
      final body = <String>[];
      i++;
      while (i < lines.length) {
        final l = lines[i];
        final cm = _fenceRe.firstMatch(l);
        if (cm != null && cm.group(1)![0] == marker[0] && cm.group(1)!.length >= marker.length && cm.group(2)!.trim().isEmpty) {
          i++;
          break;
        }
        body.add(l);
        i++;
      }
      final code = body.map((l) => escapeAngle(l.trimRight())).join('<br>');
      if (body.any((l) => l.trim().isNotEmpty)) add('<code>$code</code>');
      continue;
    }
    // כותרת setext
    if (para.isNotEmpty) {
      final sm = _setextRe.firstMatch(line);
      if (sm != null) {
        final level = sm.group(1)![0] == '=' ? 1 : 2;
        final t = _joinPara(para).replaceAll('\u0001', ' ');
        para = [];
        add(_inline(t, st), level: level);
        i++;
        continue;
      }
    }
    // כותרת ATX
    final am = _atxRe.firstMatch(line);
    if (am != null) {
      flush();
      final text = (am.group(2) ?? '').replaceAll(RegExp(r'(?:^|[ \t]+)#+$'), '').trim();
      if (text.isNotEmpty) add(_inline(text, st), level: am.group(1)!.length);
      i++;
      continue;
    }
    // קו אופקי - נשמט
    if (_isHr(line)) {
      flush();
      i++;
      continue;
    }
    // ציטוט
    if (_quoteRe.hasMatch(line)) {
      flush();
      final inner = <String>[];
      while (i < lines.length && _quoteRe.hasMatch(lines[i])) {
        inner.add(lines[i].replaceFirst(_quoteRe, ''));
        i++;
      }
      // callout של Obsidian: > [!note] כותרת -> שורת כותרת מודגשת (אם יש) ואז התוכן
      final cm = inner.isEmpty ? null : RegExp(r'^\s*\[!([^\]]+)\][+-]?[ \t]*(.*)$').firstMatch(inner.first);
      if (cm != null) {
        final title = cm.group(2)!.trim();
        inner.replaceRange(0, 1, [if (title.isNotEmpty) '**$title**', '']);
      }
      out.addAll(_blocks(inner, st, top: false));
      continue;
    }
    // טבלה
    if (_isTableStart(lines, i)) {
      flush();
      final head = _splitCells(lines[i]);
      final sb = StringBuffer('<table><tr>');
      for (final c in head) {
        sb.write('<th>${_inline(c, st)}</th>');
      }
      sb.write('</tr>');
      i += 2;
      while (i < lines.length && lines[i].trim().isNotEmpty && lines[i].contains('|')) {
        final cells = _splitCells(lines[i]);
        sb.write('<tr>');
        for (var k = 0; k < head.length; k++) {
          sb.write('<td>${k < cells.length ? _inline(cells[k], st) : ''}</td>');
        }
        sb.write('</tr>');
        i++;
      }
      sb.write('</table>');
      add(sb.toString());
      continue;
    }
    // רשימה
    if (_listRe.hasMatch(line)) {
      flush();
      final roots = <_Li>[];
      final stack = <_Li>[];
      while (i < lines.length) {
        final l = lines[i];
        if (l.trim().isEmpty) {
          var k = i + 1;
          while (k < lines.length && lines[k].trim().isEmpty) {
            k++;
          }
          if (k < lines.length && stack.isNotEmpty && (_listRe.hasMatch(lines[k]) || lines[k].startsWith('  ')) && !_isHr(lines[k])) {
            if (!_listRe.hasMatch(lines[k])) stack.last.text += '\u0001';
            i = k;
            continue;
          }
          break;
        }
        final lm = _listRe.firstMatch(l);
        if (lm != null && !_isHr(l)) {
          final li = _Li(lm.group(1)!.length, RegExp(r'\d').hasMatch(lm.group(2)!), lm.group(3)!.trim());
          while (stack.isNotEmpty && stack.last.indent >= li.indent) {
            stack.removeLast();
          }
          // סוג רשימה שונה ברמה העליונה (תבליטים אחרי מספור) = רשימה חדשה
          if (stack.isEmpty && roots.isNotEmpty && roots.last.ol != li.ol) break;
          if (stack.isEmpty) {
            roots.add(li);
          } else {
            stack.last.kids.add(li);
          }
          stack.add(li);
          i++;
          continue;
        }
        if (_startsBlock(l) || _isTableStart(lines, i) || stack.isEmpty) break;
        final cur = stack.last;
        cur.text = cur.text.endsWith('\u0001') ? '${cur.text}${l.trim()}' : '${cur.text} ${l.trim()}';
        i++;
      }
      if (roots.isNotEmpty) add(_renderLis(roots, st));
      continue;
    }
    para.add(line);
    i++;
  }
  flush();
  return out;
}

// ───────────────────────────── סיום: כותרות ─────────────────────────────

MdImport _finish(List<_Out> outs, _State st, String? fmTitle) {
  String? title;
  final heads = [for (var k = 0; k < outs.length; k++) if (outs[k].level != null) k];
  var skip = -1;
  if (heads.isNotEmpty && outs[heads.first].level == 1 && heads.where((k) => outs[k].level == 1).length == 1) {
    skip = heads.first;
    title = collapseWs(plainText(outs[skip].html).replaceAll('&lt;', '<').replaceAll('&gt;', '>'));
    if (title.isEmpty) title = null;
  }
  title ??= fmTitle;

  final count = {for (var l = 1; l <= 6; l++) l: 0};
  final lines = <String>[];
  final stack = <(int, int)>[]; // (מקורי, פלט)
  for (var k = 0; k < outs.length; k++) {
    if (k == skip) continue;
    final o = outs[k];
    final lv = o.level;
    if (lv == null) {
      lines.add(o.html);
      continue;
    }
    while (stack.isNotEmpty && stack.last.$1 >= lv) {
      stack.removeLast();
    }
    var outLv = stack.isEmpty ? 2 : stack.last.$2 + 1;
    if (outLv > 6) outLv = 6;
    stack.add((lv, outLv));
    count[outLv] = count[outLv]! + 1;
    lines.add('<h$outLv>${o.html.replaceAll('<br>', ' ')}</h$outLv>');
  }
  if (lines.isEmpty && title == null) throw AppError('לא נמצא תוכן בקובץ ה-Markdown.');
  return MdImport(lines, List.unmodifiable(st.notes), count, title);
}

// ───────────────────────────── inline ─────────────────────────────

const _ents = {
  'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ', 'ndash': '–', 'mdash': '—', //
  'hellip': '…', 'laquo': '«', 'raquo': '»', 'lrm': '‎', 'rlm': '‏', 'shy': '',
};
final _entRe = RegExp(r'&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);');
final _footRefRe = RegExp(r'\[\^([^\]\s]+)\]');
final _autoRe = RegExp(r'<((?:https?://|mailto:)[^\s<>]+)>');
final _mailRe = RegExp(r'<([^\s<>@]+@[^\s<>@]+\.[^\s<>@]+)>');
final _htmlTagRe = RegExp(r'<(/?)([A-Za-z][A-Za-z0-9]*)(?:\s[^<>]*)?/?>|<!--[\s\S]*?-->');
final _okHref = RegExp(r'^(?:https?:|mailto:)', caseSensitive: false);
final _okImg = RegExp(r'^data:image/[A-Za-z0-9.+-]+;base64,[A-Za-z0-9+/=]+$');
final _alnum = RegExp(r'[\p{L}\p{N}]', unicode: true);
final _punct = RegExp(r'''[!-/:-@\[-`{-~]''');

String _lit(String s) => s.replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _attr(String u) => u.replaceAll('"', '%22').replaceAll('<', '%3C').replaceAll('>', '%3E').replaceAll(' ', '%20');

bool _isWs(String c) => c.trim().isEmpty;

int _runLen(String s, int i) {
  var j = i;
  while (j < s.length && s[j] == s[i]) {
    j++;
  }
  return j - i;
}

/// סוף קוד-ספאן שנפתח ב-[i] (אינדקס אחרי הגדר הסוגרת) או -1.
int _codeEnd(String s, int i) {
  final k = _runLen(s, i);
  var p = i + k;
  while (p < s.length) {
    if (s[p] == '`') {
      final r = _runLen(s, p);
      if (r == k) return p;
      p += r;
    } else {
      p++;
    }
  }
  return -1;
}

int _findCloser(String s, int from, String c, int k) {
  var fallback = -1;
  var p = from;
  while (p < s.length) {
    final ch = s[p];
    if (ch == '\\') {
      p += 2;
    } else if (ch == '`') {
      final e = _codeEnd(s, p);
      p = e < 0 ? p + _runLen(s, p) : e + _runLen(s, p);
    } else if (ch == c) {
      final rl = _runLen(s, p);
      final prevOk = p > from && !_isWs(s[p - 1]);
      final after = p + rl;
      final nextOk = c != '_' || after >= s.length || !_alnum.hasMatch(s[after]);
      if (prevOk && nextOk) {
        if (rl == k) return p;
        if (rl > k && fallback < 0 && (c == '*' || c == '_')) fallback = p + rl - k;
      }
      p += rl;
    } else {
      p++;
    }
  }
  return fallback;
}

/// מחפש קישור/תמונה שמתחיל ב-'[' באינדקס [i]. מחזיר (טקסט, כתובת, סוף) או null.
(String, String, int)? _parseLink(String s, int i, _State st) {
  var depth = 0;
  var j = i;
  while (j < s.length) {
    final c = s[j];
    if (c == '\\') {
      j += 2;
      continue;
    }
    if (c == '[') depth++;
    if (c == ']') {
      depth--;
      if (depth == 0) break;
    }
    j++;
  }
  if (j >= s.length) return null;
  final text = s.substring(i + 1, j);
  if (j + 1 < s.length && s[j + 1] == '(') {
    var d = 1;
    var k = j + 2;
    while (k < s.length) {
      if (s[k] == '\\') {
        k += 2;
        continue;
      }
      if (s[k] == '(') d++;
      if (s[k] == ')') {
        d--;
        if (d == 0) break;
      }
      k++;
    }
    if (k >= s.length) return null;
    var inside = s.substring(j + 2, k).trim();
    if (inside.startsWith('<') && inside.contains('>')) {
      inside = inside.substring(1, inside.indexOf('>'));
    } else {
      inside = inside.split(RegExp(r'\s+')).first;
    }
    return (text, inside, k + 1);
  }
  if (j + 1 < s.length && s[j + 1] == '[') {
    final e = s.indexOf(']', j + 2);
    if (e < 0) return null;
    var id = s.substring(j + 2, e).trim();
    if (id.isEmpty) id = text.trim();
    final url = st.refs[id.toLowerCase()];
    if (url == null) return null;
    return (text, url, e + 1);
  }
  return null;
}

String _inline(String s, _State st, {bool notes = true}) {
  final sb = StringBuffer();
  final n = s.length;
  var i = 0;
  while (i < n) {
    final c = s[i];
    switch (c) {
      case '\\':
        if (i + 1 < n && _punct.hasMatch(s[i + 1])) {
          sb.write(_lit(s[i + 1]));
          i += 2;
        } else {
          sb.write('\\');
          i++;
        }
      case '\u0001':
        sb.write('<br>');
        i++;
      case '`':
        final e = _codeEnd(s, i);
        final k = _runLen(s, i);
        if (e < 0) {
          sb.write('`' * k);
          i += k;
        } else {
          var code = s.substring(i + k, e);
          if (code.length > 2 && code.startsWith(' ') && code.endsWith(' ') && code.trim().isNotEmpty) {
            code = code.substring(1, code.length - 1);
          }
          code = code.replaceAll('\u0001', ' ');
          if (code.trim().isNotEmpty) sb.write('<code>${escapeAngle(code)}</code>');
          i = e + k;
        }
      case '!':
        if (s.startsWith('![[', i)) {
          final e = s.indexOf(']]', i + 3);
          if (e > 0) {
            i = e + 2; // הטמעת Obsidian - נשמטת
            break;
          }
        }
        if (i + 1 < n && s[i + 1] == '[') {
          final l = _parseLink(s, i + 1, st);
          if (l != null) {
            if (_okImg.hasMatch(l.$2)) sb.write('<img src="${l.$2}" style="max-width: 100%;">');
            i = l.$3;
            break;
          }
        }
        sb.write('!');
        i++;
      case '[':
        if (s.startsWith('[[', i)) {
          final e = s.indexOf(']]', i + 2);
          if (e > 0 && !s.substring(i + 2, e).contains('[')) {
            final inner = s.substring(i + 2, e);
            var label = inner.contains('|') ? inner.substring(inner.lastIndexOf('|') + 1) : inner.replaceAll(RegExp(r'#\^.*$'), '').replaceAll('#', ' > ');
            label = label.trim();
            if (label.startsWith('> ')) label = label.substring(2);
            sb.write(_lit(label));
            i = e + 2;
            break;
          }
        }
        final fr = _footRefRe.matchAsPrefix(s, i);
        if (fr != null && notes && st.footDefs.containsKey(fr.group(1))) {
          final parts = st.footDefs[fr.group(1)]!;
          st.notes.add(parts.map((p) => _inline(p, st, notes: false)).join('<br>'));
          sb.write('<sup>${st.notes.length}</sup>');
          i = fr.end;
          break;
        }
        final l = _parseLink(s, i, st);
        if (l == null) {
          sb.write('[');
          i++;
          break;
        }
        final label = _inline(l.$1, st, notes: notes);
        if (_okHref.hasMatch(l.$2)) {
          sb.write('<a href="${_attr(l.$2)}">${label.isEmpty ? _lit(l.$2) : label}</a>');
        } else {
          sb.write(label);
        }
        i = l.$3;
      case '<':
        final a = _autoRe.matchAsPrefix(s, i);
        if (a != null) {
          sb.write('<a href="${_attr(a.group(1)!)}">${_lit(a.group(1)!)}</a>');
          i = a.end;
          break;
        }
        final m = _mailRe.matchAsPrefix(s, i);
        if (m != null) {
          sb.write('<a href="mailto:${_attr(m.group(1)!)}">${_lit(m.group(1)!)}</a>');
          i = m.end;
          break;
        }
        final h = _htmlTagRe.matchAsPrefix(s, i);
        if (h != null) {
          i = h.end;
          final name = (h.group(2) ?? '').toLowerCase();
          final whole = h.group(0)!;
          if (name == 'br' && h.group(1) != '/') {
            sb.write('<br>');
          } else if (name == 'img') {
            final src = _srcRe.firstMatch(whole)?.group(1);
            if (src != null && _okImg.hasMatch(src)) sb.write('<img src="$src" style="max-width: 100%;">');
          } else if (h.group(1) != '/' && !whole.endsWith('/>') && _inlineMap.containsKey(name)) {
            // מחפש את התג הסוגר התואם (עם עומק); אם אין - התג נפרק
            final tagRe = RegExp('<(/?)$name\\b[^<>]*>', caseSensitive: false);
            var depth = 1;
            RegExpMatch? close;
            for (final x in tagRe.allMatches(s, i)) {
              depth += x.group(1) == '/' ? -1 : (x.group(0)!.endsWith('/>') ? 0 : 1);
              if (depth == 0) {
                close = x;
                break;
              }
            }
            if (close != null) {
              final inner = _inline(s.substring(i, close.start), st, notes: notes);
              final outName = _inlineMap[name]!;
              final hasContent = plainText(inner).trim().isNotEmpty || inner.contains('<img') || inner.contains('<br>');
              if (outName == 'a') {
                final href = _hrefRe.firstMatch(whole)?.group(1) ?? '';
                if (_okHref.hasMatch(href) && hasContent) {
                  sb.write('<a href="${_attr(href)}">$inner</a>');
                } else {
                  sb.write(inner);
                }
              } else if (hasContent) {
                sb.write('<$outName>$inner</$outName>');
              } else {
                sb.write(inner);
              }
              i = close.end;
            }
          }
          break;
        }
        sb.write('&lt;');
        i++;
      case '>':
        sb.write('&gt;');
        i++;
      case '&':
        final e = _entRe.matchAsPrefix(s, i);
        final dec = e == null ? null : _entValue(e.group(1)!);
        if (dec != null) {
          sb.write(_lit(dec));
          i = e!.end;
        } else {
          sb.write('&');
          i++;
        }
      case '*' || '_' || '~' || '=':
        final r = _runLen(s, i);
        var done = false;
        if (c == '~' || c == '=') {
          if (r == 2 && i + 2 < n && !_isWs(s[i + 2])) {
            final j = _findCloser(s, i + 2, c, 2);
            if (j > i + 2) {
              final inner = _inline(s.substring(i + 2, j), st, notes: notes);
              final tag = c == '~' ? 's' : 'mark';
              if (inner.isNotEmpty) sb.write('<$tag>$inner</$tag>');
              i = j + 2;
              done = true;
            }
          }
        } else if (!(c == '_' && i > 0 && _alnum.hasMatch(s[i - 1]))) {
          for (var k = r < 3 ? r : 3; k >= 1 && !done; k--) {
            final a = i + k;
            if (a >= n || _isWs(s[a])) continue;
            final j = _findCloser(s, a, c, k);
            if (j <= a) continue;
            final inner = _inline(s.substring(a, j), st, notes: notes);
            if (inner.isEmpty) continue;
            sb.write(switch (k) {
              3 => '<b><i>$inner</i></b>',
              2 => '<b>$inner</b>',
              _ => '<i>$inner</i>',
            });
            i = j + k;
            done = true;
          }
        }
        if (!done) {
          sb.write(c * r);
          i += r;
        }
      default:
        sb.write(c);
        i++;
    }
  }
  return sb.toString();
}
