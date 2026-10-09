# -*- coding: utf-8 -*-
"""יוצר קישורים אוטומטית לספרים במאגר, בעזרת מנוע "מחולל הקישורים" (linker_core), ומאמת מול seforim.db הרשמי.

שני שלבים:
  1. כללים מובנים (בבלי, ירושלמי שקלים, תנ"ך, הגהות אשרי, חמישה ספרי הלכה מוגדרים).
  2. זיהוי כללי: לכל ספר אחר מנסים להבין מתוך שם הקובץ על איזה ספר הוא מפרש (למשל "...על שולחן ערוך אורח חיים"),
     ובוחרים את כלל הכותרות שמתאים למבנה של ספר היעד. הקישור נכתב רק אם רוב שורות הספר קושרו.
     זה ניחוש כללי ולא תמיד מדויק.

הקישורים נכתבים ל-<תיקיית קישורים>/קישורים/auto/links.csv, בפורמט ש-build_personal_db.py קורא.
ספרים שיש להם כבר קישורים משלהם (קבצי links.csv שהמשתמש העלה) לא נוגעים בהם.

שימוש: python auto_links.py <תיקיית ספרים> <seforim.db> [<תיקיית קישורים>]
"""
import copy
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import linker_core as C

MIN_COVERAGE = 0.5   # לפחות חצי משורות התוכן חייבות להיקשר, אחרת לא נכתבים קישורים
MIN_LINKED = 3

_Q = re.compile('[\u0022\u05f4\u201c\u201d\u0027\u05f3\u2019\u2018,.]')


def norm(t):
    """השוואת שמות: בלי גרשיים, פסיקים ונקודות, ורווחים אחידים."""
    return re.sub(r'\s+', ' ', _Q.sub('', t)).strip()


def target_candidates(stem):
    """מועמדים לשם ספר היעד מתוך שם הקובץ, מהארוך לקצר."""
    s = re.sub(r'\s*\(.*?\)\s*$', '', stem).strip()
    s = re.sub(r'\s+(ועוד|\d+)$', '', s).strip()
    c = []
    for part in (s, *re.split(r'\s[-–]\s', s)):
        c.append(part)
    for m in re.finditer(r'(?:^|\s)על\s+', s):
        tail = s[m.end():]
        c.append(tail)
        c.extend(re.split(r'\s[-–]\s', tail))
    seen, out = set(), []
    for x in sorted((norm(x) for x in c if x.strip()), key=len, reverse=True):
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out, norm(s)


def find_target(stem, index):
    cands, whole = target_candidates(stem)
    for c in cands:
        if c == whole:
            continue  # שם הקובץ עצמו הוא ספר רשמי: אין מה לקשר אותו לעצמו
        if c in index:
            return index[c]
    return None


LABELS = {'תנ"ך: פרק לפי כותרת ברמה 2': 'כותרת ברמה 2 כמיקום'}


def base_profiles(target, db):
    """פרופילים אפשריים לפי מבנה ספר היעד."""
    if db.dafset(target):
        return [('דפים', {'target': target, 'link_type': 'פירוש', 'validate': True, 'reset_on_unmatched': True,
                          'rules': [{'type': 'daf', 'levels': [2, 6], 'formats': ['std', 'ext']}]})]
    out = []
    for name, p in C.PRESETS.items():
        if name.startswith('בבלי') or name.startswith('פרק ברמה 2 והלכה'):
            continue
        q = copy.deepcopy(p)
        q['target'] = target
        q['reset_on_unmatched'] = True
        out.append((LABELS.get(name, name), q))
    q = copy.deepcopy(C.PRESETS['פרק ברמה 2 והלכה או סימן ברמה 3'])
    q['target'] = target
    q['reset_on_unmatched'] = True
    out.append(('פרק והלכה', q))
    return out


def infer_book(lines, target, db, stem):
    """מחזיר (rows, שם הכלל, כיסוי) של הכלל הטוב ביותר, או None."""
    r = infer_book_full(lines, target, db, stem)
    return r[:3] if r else None


def infer_book_full(lines, target, db, stem):
    """כמו infer_book, ובנוסף מחזיר את הפרופיל עצמו: (rows, שם הכלל, כיסוי, פרופיל)."""
    body = 0
    for i, l in enumerate(lines, 1):
        s = l.strip()
        if i > 1 and s and not C.HEAD_LOOSE.match(s):
            body += 1
    if not body:
        return None
    best = None
    for name, prof in base_profiles(target, db):
        rows, _ = C.run_profile(lines, prof, db, stem)
        if best is None or len(rows) > len(best[0]):
            best = (rows, name, prof)
    if not best or len(best[0]) < MIN_LINKED:
        return None
    cov = len(best[0]) / body
    if cov < MIN_COVERAGE:
        return None
    return best[0], best[1], cov, best[2]


def existing_stems(links_dir):
    out = set()
    for p in glob.glob(os.path.join(links_dir, 'קישורים*', '*', 'links.csv')) + glob.glob(os.path.join(links_dir, '*', 'links.csv')):
        for r in C.read_csv(p)[1:]:
            if len(r) > 1:
                out.add(r[1])
    return out


def main():
    books_dir, db_path = sys.argv[1], sys.argv[2]
    links_dir = sys.argv[3] if len(sys.argv) > 3 else os.path.join(books_dir, 'קבצי קישורים וסדר הדורות')
    db = C.SeforimDB(db_path)
    plan = C.plan_repair(books_dir, links_dir, db, progress=print)
    rows, done = [], set()
    print('--- כללים מובנים ---')
    for stem, a in plan['additions']:
        rows.extend(a)
        done.add(stem)
        print(f'  קושר: {stem}: {len(a)} קישורים')

    done |= existing_stems(links_dir)
    index = {}
    for t in db.titles():
        index.setdefault(norm(t), t)
    print('--- זיהוי כללי לפי שם הקובץ ---')
    books = C.find_books(books_dir)
    for stem, lst in sorted(books.items()):
        if stem in done or len(lst) != 1:
            continue
        rel, path = lst[0]
        if not rel or stem.lower() == 'readme':
            continue  # כמו בבניית ה-DB: לא קבצי שורש ולא README
        lines = C.read_lines(path)
        if C.is_lfs_pointer(lines):
            continue
        target = find_target(stem, index)
        if not target:
            print(f'  לא קושר: {stem}: לא זוהה ספר יעד בשם הקובץ')
            continue
        res = infer_book(lines, target, db, stem)
        if not res:
            print(f'  לא קושר: {stem}: זוהה היעד "{target}" אבל כותרות הספר לא תואמות את מבנהו')
            continue
        exp, name, cov = res
        rows.extend(C.links_rows(stem, exp))
        done.add(stem)
        print(f'  קושר: {stem} ← {target} ({name}, {len(exp)} קישורים, כיסוי {cov:.0%})')

    if not rows:
        print('לא נוצרו קישורים אוטומטיים')
        return 0
    out = os.path.join(links_dir, 'קישורים', 'auto', 'links.csv')
    C.write_csv(out, rows)
    print(f'נכתבו {len(rows)} שורות קישורים ב-{out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
