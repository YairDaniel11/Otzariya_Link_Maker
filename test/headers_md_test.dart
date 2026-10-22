import 'package:flutter_test/flutter_test.dart';
import 'package:otzaria_link_maker/src/headers/book_builder.dart';
import 'package:otzaria_link_maker/src/headers/md_import.dart';

/// בדיקת איזון תגים בשורה (בלי void tags).
bool balanced(String line) {
  final stack = <String>[];
  for (final m in RegExp(r'<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>').allMatches(line)) {
    final t = m.group(2)!.toLowerCase();
    if (const {'br', 'img', 'hr'}.contains(t)) continue;
    if (m.group(1) == '') {
      stack.add(t);
    } else {
      if (stack.isEmpty || stack.last != t) return false;
      stack.removeLast();
    }
  }
  return stack.isEmpty;
}

void main() {
  test('כותרות ורמות, כותרת ספר יחידה', () {
    final r = importMarkdownText('# שם הספר\n\n## פרק א\n\nטקסט\n\n#### עמוק\n\n## פרק ב\n');
    expect(r.detectedTitle, 'שם הספר');
    expect(r.lines, ['<h2>פרק א</h2>', 'טקסט', '<h3>עמוק</h3>', '<h2>פרק ב</h2>']);
    expect(r.headingCount[2], 2);
    expect(r.headingCount[3], 1);
    expect(r.hasHeadings, isTrue);
  });

  test('בלי כותרת יחידה: h1 מרובים הופכים ל-h2', () {
    final r = importMarkdownText('# א\n\nx\n\n# ב\n\n## ג\n');
    expect(r.detectedTitle, isNull);
    expect(r.lines, ['<h2>א</h2>', 'x', '<h2>ב</h2>', '<h3>ג</h3>']);
  });

  test('setext', () {
    final r = importMarkdownText('כותרת ראשית\n===========\n\nפרק\n---\n\nגוף\n');
    expect(r.detectedTitle, 'כותרת ראשית');
    expect(r.lines, ['<h2>פרק</h2>', 'גוף']);
  });

  test('הדגשות מקוננות ומאוזנות', () {
    final r = importMarkdownText('**מודגש *ונטוי* כאן** ו-__גם__ ו-_נטוי_ ו-***שניהם*** ~~מחוק~~ `קוד <x>`\n');
    expect(r.lines.single,
        '<b>מודגש <i>ונטוי</i> כאן</b> ו-<b>גם</b> ו-<i>נטוי</i> ו-<b><i>שניהם</i></b> <s>מחוק</s> <code>קוד &lt;x&gt;</code>');
    expect(balanced(r.lines.single), isTrue);
  });

  test('תגים לא סגורים נשארים תווים, והשורה מאוזנת', () {
    final r = importMarkdownText('כוכבית * בודדת ו-**פתוח בלי סגירה\n');
    expect(balanced(r.lines.single), isTrue);
    expect(r.lines.single.contains('<b>'), isFalse);
  });

  test('פסקה אחת = שורה, ירידת שורה רכה לרווח, קשיחה ל-br', () {
    final r = importMarkdownText('שורה א\nשורה ב  \nשורה ג\\\nשורה ד\n\nפסקה שנייה\n');
    expect(r.lines, ['שורה א שורה ב<br>שורה ג<br>שורה ד', 'פסקה שנייה']);
  });

  test('רשימות וטבלאות בשורה אחת', () {
    final r = importMarkdownText('- א\n- ב\n  - ב1\n- ג\n\n1. אחד\n2. שניים\n\n| כ1 | כ2 |\n|---|:-:|\n| a | **b** |\n| c |\n');
    expect(r.lines.length, 3);
    expect(r.lines[0], '<ul><li>א</li><li>ב<ul><li>ב1</li></ul></li><li>ג</li></ul>');
    expect(r.lines[1], '<ol><li>אחד</li><li>שניים</li></ol>');
    expect(r.lines[2], '<table><tr><th>כ1</th><th>כ2</th></tr><tr><td>a</td><td><b>b</b></td></tr><tr><td>c</td><td></td></tr></table>');
    for (final l in r.lines) {
      expect(balanced(l), isTrue);
    }
  });

  test('ציטוט, גדר קוד וקו אופקי', () {
    final r = importMarkdownText('> ציטוט א\n> המשך\n\n```\nx < y\nשורה 2\n```\n\n---\n\nסוף\n');
    expect(r.lines, ['ציטוט א המשך', '<code>x &lt; y<br>שורה 2</code>', 'סוף']);
  });

  test('הערות שוליים', () {
    final r = importMarkdownText('טקסט[^1] ועוד[^b].\n\n[^1]: גוף **ראשון**.\n[^b]: שני\n\n    פסקה נוספת.\n\nסוף\n');
    expect(r.lines, ['טקסט<sup>1</sup> ועוד<sup>2</sup>.', 'סוף']);
    expect(r.notes, ['גוף <b>ראשון</b>.', 'שני<br>פסקה נוספת.']);
  });

  test('קישורים: רשימת היתר, תמונות', () {
    final r = importMarkdownText('[א](https://x.co/a?b=1) [ב](javascript:alert(1)) [ג](mailto:a@b.co) [ד](data:text/html,x) '
        '![i](http://x/i.png) ![d](data:image/png;base64,AAAA) <https://y.co>\n');
    final l = r.lines.single;
    expect(l, contains('<a href="https://x.co/a?b=1">א</a>'));
    expect(l, contains(' ב '));
    expect(l, isNot(contains('javascript')));
    expect(l, contains('<a href="mailto:a@b.co">ג</a>'));
    expect(l, isNot(contains('data:text')));
    expect(l, isNot(contains('x/i.png')));
    expect(l, contains('<img src="data:image/png;base64,AAAA" style="max-width: 100%;">'));
    expect(l, contains('<a href="https://y.co">https://y.co</a>'));
    expect(balanced(l), isTrue);
  });

  test('ישויות HTML פעם אחת', () {
    final r = importMarkdownText('a &amp; b &lt;c&gt; &#1488; &nbsp;x\n');
    expect(r.lines.single, 'a & b &lt;c&gt; א  x');
  });

  test('HTML גולמי: פירוק תגים לא מוכרים, markdown בתוך div', () {
    final r = importMarkdownText('<div class="x">\n\n**מודגש** <span style="c">רגיל</span> <u>קו</u> <mark>סימון</mark> <b></b>\n\n</div>\n'
        '<details><summary>סיכום</summary>\n\n- פריט\n\n</details>\n');
    expect(r.lines[0], '<b>מודגש</b> רגיל <u>קו</u> <mark>סימון</mark> ');
    expect(r.lines, contains('סיכום'));
    expect(r.lines, contains('<ul><li>פריט</li></ul>'));
    for (final l in r.lines) {
      expect(balanced(l), isTrue);
    }
  });

  test('HTML גולמי: טבלה ורשימה ו-pre', () {
    final r = importMarkdownText('<table>\n<tr><td>א</td><td><i>ב</i></td></tr>\n</table>\n\n<pre>a\nb &lt;</pre>\n');
    expect(r.lines, ['<table><tr><td>א</td><td><i>ב</i></td></tr></table>', '<code>a<br>b &lt;</code>']);
  });

  test('תוספות Obsidian', () {
    final r = importMarkdownText('---\ntitle: "ספר נבחר"\ntags: [a]\n---\n\n==מודגש== ו-[[דף|כינוי]] ו-[[עמוד#פרק]] #תג ![[pic.png]]\n\n> [!note] כותרת\n> גוף הערה\n');
    expect(r.detectedTitle, 'ספר נבחר');
    expect(r.lines[0], '<mark>מודגש</mark> ו-כינוי ו-עמוד > פרק #תג ');
    expect(r.lines[1], '<b>כותרת</b>');
    expect(r.lines[2], 'גוף הערה');
  });

  test('פלט עובר validateBookLines', () {
    final r = importMarkdownText('# ספר\n\n## פרק\n\nטקסט **עברי** עם [קישור](https://a.co)[^1].\n\n- א\n- ב\n\n[^1]: הערה\n');
    final lines = ['<h1>${r.detectedTitle}</h1>', '', ...r.lines];
    final issues = validateBookLines(lines);
    expect(issues.where((i) => i.severity == IssueSeverity.error), isEmpty, reason: issues.map((i) => i.message).join('; '));
  });
}
