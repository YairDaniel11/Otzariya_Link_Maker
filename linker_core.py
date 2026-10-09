# -*- coding: utf-8 -*-
"""
ליבת מחולל הקישורים לאוצריא (בלי ממשק, בלי AI).

מה היא עושה:
  * קוראת את מבנה הכותרות של ספר (קובץ txt בפורמט אוצריא) ומשייכת כל שורת תוכן למיקום בספר יעד
    (דף בגמרא, פרק בתנ"ך, סימן בשולחן ערוך וכו'), ומאמתת את המיקום מול תוכן העניינים ב-seforim.db.
  * מייצרת קובץ קישורים בפורמט הייבוא של הספרייה האישית של אוצריא (links.csv).
  * בודקת ומתקנת קבצי קישורים קיימים אחרי שהספרים השתנו (הזזת שורות).

אין כאן תלות בחבילות חיצוניות.
"""
import collections
import csv
import glob
import io
import json
import os
import re
import shutil
import sqlite3
import time
import zipfile

LINK_HEADER = ['מקור', 'ספר_מקור', 'מקור_אישי', 'ספר_יעד', 'מיקום_יעד', 'סוג', 'יעד_אישי', 'קטגוריית_מקור']

MAS = ['בבא בתרא', 'בבא קמא', 'בבא מציעא', 'ראש השנה', 'עבודה זרה', 'מועד קטן', 'פסחים', 'קידושין', 'קדושין',
       'מגילה', 'סנהדרין', 'סוכה', 'מכות', 'ביצה', 'יומא', 'ברכות', 'חגיגה', 'נדרים', 'עירובין', 'סוטה', 'זבחים',
       'תענית', 'נדה', 'נזיר', 'מנחות', 'כריתות', 'הוריות', 'בכורות', 'ערכין', 'תמורה', 'מעילה', 'תמיד', 'כתובות',
       'שבועות', 'יבמות', 'גיטין', 'שבת', 'חולין']
ALIAS = {'קדושין': 'קידושין'}

HEAD = re.compile(r'^<h([2-6])>(.*?)</h[2-6]>\s*$')                       # כותרת קפדנית (כמו בהרצה המקורית)
HEAD_LOOSE = re.compile(r'^<h([1-6])(?:\s[^>]*)?>(.*?)</h[1-6]>\s*$')     # כותרת עם תכונות, כל הרמות
DAF = re.compile(r'^\[?(?:דף\s+)?([א-ת]{1,3})([.:])\]?$')
_Q = '"״\'׳'  # גרשיים, גרשיים עבריים וגרש


# ───────────────────────────── כלי עזר ─────────────────────────────
def strip_tags(t):
    return re.sub(r'<[^>]+>', '', t).strip()


def read_lines(path):
    """קורא ספר כרשימת שורות. אותו אופן ספירה של הקישורים (שורה 1 = השורה הראשונה בקובץ)."""
    with open(path, encoding='utf-8-sig', errors='replace') as f:
        return f.read().split('\n')


def is_lfs_pointer(lines):
    return bool(lines) and lines[0].startswith('version https://git-lfs')


def find_tractate(text):
    best = None
    for m in MAS:
        if re.search(r'(?<![א-ת])' + re.escape(m) + r'(?![א-ת])', text):
            if best is None or len(m) > len(best):
                best = m
    return best


def parse_daf_ext(t):
    """כותרות דף בפורמטים נוספים: "יד, ב", "דף ב ע"א", "כא ע״ב" -> "יד:" / "ב." / "כא:"."""
    t = t.strip().strip('[]').strip()
    m = re.match(r'^(?:דף\s+)?([א-ת' + _Q + r']{1,5}?)\s*(?:,|ע[' + _Q + r']?)\s*([אב])$', t)
    if not m:
        return None
    return re.sub('[' + _Q + ']', '', m.group(1)) + ('.' if m.group(2) == 'א' else ':')


# ───────────────────────────── seforim.db ─────────────────────────────
DB_CANDIDATES = [
    os.path.join(os.environ.get('APPDATA', ''), 'io.github.kdroidfilter.seforimapp', 'databases', 'seforim.db'),
    os.path.join(os.environ.get('PROGRAMDATA', ''), 'otzaria', 'books', 'seforim.db'),
    os.path.expanduser('~/.local/share/io.github.kdroidfilter.seforimapp/databases/seforim.db'),
    os.path.expanduser('~/Library/Application Support/io.github.kdroidfilter.seforimapp/databases/seforim.db'),
]


def find_seforim_db():
    for c in DB_CANDIDATES:
        if c and os.path.isfile(c):
            return c
    return None


class SeforimDB:
    """גישה לקריאה בלבד לתוכן העניינים של ספרי אוצריא (seforim.db)."""

    def __init__(self, path):
        self.path = path
        self.con = sqlite3.connect('file:' + path.replace('\\', '/') + '?mode=ro', uri=True, check_same_thread=False)
        self._toc, self._titles, self._sets = {}, None, {}

    def titles(self):
        if self._titles is None:
            self._titles = [r[0] for r in self.con.execute('select title from book order by title')]
        return self._titles

    def has_book(self, title):
        return self.con.execute('select 1 from book where title=? limit 1', (title,)).fetchone() is not None

    def toc(self, title):
        """רשימת (id, parentId, level, text) של הספר, או None אם אינו קיים."""
        if title not in self._toc:
            r = self.con.execute('select id from book where title=?', (title,)).fetchone()
            self._toc[title] = None if not r else self.con.execute(
                'select e.id,e.parentId,e.level,t.text from tocEntry e join tocText t on t.id=e.textId '
                'where e.bookId=? order by e.id', (r[0],)).fetchall()
        return self._toc[title]

    def dafset(self, title):
        e = self.toc(title)
        if not e:
            return None
        s = set()
        for _, _, _, t in e:
            m = re.match(r'דף ([א-ת"״\']+)([.:])', t.strip())
            if m:
                s.add(m.group(1) + m.group(2))
        return s

    def hset(self, title):
        """זוגות (טקסט הורה, טקסט ילד) של רמה 2, למשל ("פרק א", "הלכה ד")."""
        e = self.toc(title)
        if not e:
            return None
        byid = {x[0]: x for x in e}
        return {(byid[p][3].strip(), t.strip()) for i, p, l, t in e if l == 2 and p in byid}

    def chset(self, title):
        e = self.toc(title)
        return {t.strip() for _, _, l, t in e if l == 1} if e else None

    def valid_refs(self, title):
        """כל המיקומים החוקיים בספר: כל כותרת, וגם "הורה ילד" (למשל "פרק א הלכה ד"), ודפים בלי המילה "דף"."""
        if title in self._sets:
            return self._sets[title]
        e = self.toc(title)
        if e is None:
            self._sets[title] = None
            return None
        byid = {x[0]: x for x in e}
        out = set()
        for i, p, l, t in e:
            t = t.strip()
            out.add(t)
            if t.startswith('דף '):
                out.add(t[3:])
            if p in byid and l >= 2:
                out.add(byid[p][3].strip() + ' ' + t)
        self._sets[title] = out
        return out

    def toc_summary(self, title, limit=14):
        e = self.toc(title)
        if not e:
            return None
        lv = collections.Counter(x[2] for x in e)
        return {'levels': dict(lv), 'sample': [(x[2], x[3]) for x in e[:limit]]}


# ───────────────────────────── מנועי יצירה מובנים (כמו בהרצה המקורית) ─────────────────────────────
def _gen_tanakh(rel, stem, L, db):
    book = re.sub(r"\s*\(כתאב אלתאג'\)$", '', stem.split(' - ')[0])
    book = re.sub(r'^תרגום (שני )?(על )?', '', book)
    book = {'תהלים': 'תהילים'}.get(book, book)
    ch = db.chset(book)
    if not ch:
        return {}, 'אין יעד ב-seforim.db: ' + book, 'תרגום' if rel[1:2] == ('תרגומים',) else 'פירוש'
    out, cur = {}, None
    for i, l in enumerate(L, 1):
        s = l.rstrip('\r').strip()
        hm = HEAD.match(s)
        if hm:
            if hm.group(1) == '2':
                t = strip_tags(hm.group(2))
                cur = t if t in ch else None
            continue
        if i == 1 or not s or s.startswith('<h1'):
            continue
        if cur:
            out[i] = (book, cur)
    return out, '', 'תרגום' if rel[1:2] == ('תרגומים',) else 'פירוש'


def _gen_yerushalmi(rel, stem, L, db):
    target = 'תלמוד ירושלמי שקלים'
    hs = db.hset(target) or set()
    pm = re.search(r'פרק ([א-ת]+)$', stem)
    per = 'פרק ' + pm.group(1) if pm else None
    hal, out = None, {}
    for i, l in enumerate(L, 1):
        s = l.rstrip('\r').strip()
        hm = HEAD.match(s)
        if hm:
            t = strip_tags(hm.group(2))
            m = re.search(r'פרק ([א-ת]+)$', t)
            if hm.group(1) == '2' and m:
                per, hal = 'פרק ' + m.group(1), None
            elif t.startswith('הלכה '):
                hal = t
            continue
        if i == 1 or not s or s.startswith('<h1'):
            continue
        if per and hal and (per, hal) in hs:
            out[i] = (target, per + ' ' + hal)
    return out, '', 'פירוש'


def _gen_ashri(rel, stem, L, db):
    mas = stem.split(' - ', 1)[1].strip()
    mas = ALIAS.get(mas, mas)
    target = 'פסקי הרא"ש על ' + mas
    hs = db.hset(target)
    if not hs:
        return {}, 'אין יעד ב-seforim.db: ' + target, 'פירוש'
    per, cur, out = None, None, {}
    for i, l in enumerate(L, 1):
        s = l.rstrip('\r').strip()
        hm = HEAD.match(s)
        if hm:
            t = strip_tags(hm.group(2))
            if hm.group(1) == '2' and re.match(r'^פרק [א-ת]+$', t):
                per = t
            elif t.startswith('סימן ') and per:
                c = (per, 'הלכה ' + t[len('סימן '):])
                cur = c if c in hs else None
            continue
        if i == 1 or not s or s.startswith('<h1'):
            continue
        if cur:
            out[i] = (target, cur[0] + ' ' + cur[1])
    return out, '', 'פירוש'


_H2 = r'^<h2>(.*?)</h2>\s*$'
HALACHA_CFG = {
    "פרי חדש או״ח": ('שולחן ערוך, אורח חיים', r'^(סימן [א-ת]+)$', _H2),
    'ר״י קורקוס שבת': ('משנה תורה, הלכות שבת', r'^(פרק [א-ת]+)$', _H2),
    "דגול מרבבה אהע״ז": ('שולחן ערוך, אבן העזר', None, None),
    'חוות דעת ביאורים - הלכות ריבית': ('שולחן ערוך, יורה דעה', r'^(סימן [א-ת]+)$', _H2),
    'שער דעה - הלכות ריבית': ('שולחן ערוך, יורה דעה', r'^(סימן [א-ת]+)$', _H2),
}


def _gen_halacha(rel, stem, L, db):
    target, pat, hpat = HALACHA_CFG[stem]
    ch = db.chset(target) or set()
    cur, out = None, {}
    for i, l in enumerate(L, 1):
        s = l.rstrip('\r').strip()
        if hpat:
            hm = re.match(hpat, s)
            if hm:
                m = re.match(pat, strip_tags(hm.group(1)))
                cur = m.group(1) if m and m.group(1) in ch else None
                continue
            if i == 1 or not s or s.startswith('<h'):
                continue
        else:
            m = re.match(r'^דגול מרבבה אבן העזר (סימן [א-ת]+)$', s)
            if m:
                cur = m.group(1) if m.group(1) in ch else None
                continue
            if not s or s.startswith('====') or s.startswith('<h1'):
                continue
        if cur:
            out[i] = (target, cur)
    return out, '', 'פירוש'


def _gen_bavli(rel, stem, L, db):
    m = re.search(r'מסכת (.+?)\s*(?:\(\d+\)|\d+)?\s*$', stem)
    mas0 = None
    if m:
        mas0 = re.sub(r"\s*\(.*?\)\s*$", '', m.group(1)).strip()
        mas0 = re.sub(r'\s+ועוד$', '', mas0)
    elif rel[:1] == ('תלמוד בבלי',) and 'מחברי זמננו' not in rel:
        mas0 = find_tractate(stem.replace("''", '').replace("'", ''))
    mas0 = ALIAS.get(mas0, mas0) if mas0 else None

    def run(ext):
        mas, ds = mas0, (db.dafset(mas0) if mas0 else None)
        cur, out = None, {}
        for i, l in enumerate(L, 1):
            s = l.rstrip('\r').strip()
            hm = HEAD.match(s)
            if hm:
                t = strip_tags(hm.group(2))
                mm = re.match(r'^מסכת (.+?)$', t)
                if hm.group(1) == '2' and mm:
                    nm = ALIAS.get(mm.group(1).strip(), mm.group(1).strip())
                    nd = db.dafset(nm)
                    if nd:
                        mas, ds, cur = nm, nd, None
                    continue
                dm = DAF.match(t)
                if dm:
                    cur = dm.group(1) + dm.group(2)
                elif ext:
                    r_ = parse_daf_ext(t)
                    if r_:
                        cur = r_
                continue
            if i == 1 or not s or s.startswith('<h1'):
                continue
            if ds and cur and cur in ds:
                out[i] = (mas, cur)
        return ds, out

    ds, out = run(False)
    if not out:
        ds, out = run(True)
    note = '' if ds else ('לא זוהתה מסכת' if not mas0 else 'אין יעד ב-seforim.db: ' + mas0)
    return out, note, 'פירוש'


KINDS = {
    'tanakh': _gen_tanakh, 'yerushalmi': _gen_yerushalmi, 'ashri': _gen_ashri,
    'halacha': _gen_halacha, 'bavli': _gen_bavli,
}
KIND_LABELS = {
    'tanakh': 'תנ"ך (פרק לפי כותרת h2)', 'yerushalmi': 'ירושלמי שקלים (פרק והלכה)',
    'ashri': 'הגהות אשרי (פרק וסימן → פסקי הרא"ש)', 'halacha': 'ספר הלכה מוגדר (שו"ע / רמב"ם)',
    'bavli': 'תלמוד בבלי (כותרות דף)',
}


def detect_kind(rel, stem):
    """קובע לפי נתיב ושם הקובץ איזה מנוע מובנה מתאים לספר (כמו במאגר הספרים), או None."""
    # במאגר הפשוט התיקייה נקראת "תנך" (בלי גרשיים)
    rel = tuple('תנ״ך' if x == 'תנך' else x for x in rel)
    if stem in HALACHA_CFG:
        return 'halacha'
    if rel[:1] == ('תנ״ך',) and len(rel) > 1 and rel[1] in ('ראשונים', 'תרגומים'):
        return 'tanakh'
    if re.search(r'(?<![א-ת])שקלים(?![א-ת])', stem):
        return 'yerushalmi'
    if stem.startswith('הגהות אשרי - '):
        return 'ashri'
    if rel[:2] == ('תלמוד בבלי', 'שס וגשל'):
        return None
    if rel[:1] == ('תלמוד בבלי',) or rel[:2] == ('ספרים שאינם מותאמים לאוצריא', 'תלמוד בבלי'):
        return 'bavli'
    return None


def builtin_expected(kind, rel, stem, lines, db):
    """מחזיר ({שורה: (ספר יעד, מיקום)}, הערה, סוג קישור)."""
    return KINDS[kind](tuple(rel), stem, lines, db)


# ───────────────────────────── מנוע כללים מותאם אישית ─────────────────────────────
#
# פרופיל = {
#   "name": "שם", "target": "ספר יעד" (או "" כשהמסכת נקבעת משם הקובץ), "target_from_name": false,
#   "link_type": "פירוש", "validate": true,
#   "rules": [ {"type": "daf"|"heading"|"target_switch"|"anchor", "levels": [2, 6],
#               "regex": "...", "ref": "פרק {1}", "role": "ref"|"chapter"|"sub"} ... ]
# }
#
#  daf            כותרת שהיא דף ("ב.", "יד, ב", "דף ב ע"א")  [formats: std, ext]
#  heading        כותרת שמתאימה ל-regex. role=ref קובע מיקום מלא, chapter קובע פרק, sub מתחבר לפרק האחרון.
#  target_switch  כותרת שמחליפה את ספר היעד (למשל "מסכת X")
#  anchor         שורה שפותחת ב"בדף X." קובעת דף, עד העוגן הבא או כותרת h2 חדשה
PRESETS = {
    'בבלי: כותרות דף': {
        'target': '', 'target_from_name': True, 'link_type': 'פירוש', 'validate': True,
        'rules': [{'type': 'daf', 'levels': [2, 6], 'formats': ['std', 'ext']},
                  {'type': 'target_switch', 'levels': [2, 2], 'regex': r'^מסכת (.+?)$'}]},
    'בבלי: אזכורי דף בתחילת שורה': {
        'target': '', 'target_from_name': True, 'link_type': 'פירוש', 'validate': True,
        'rules': [{'type': 'anchor'}]},
    'תנ"ך: פרק לפי כותרת ברמה 2': {
        'target': '', 'target_from_name': False, 'link_type': 'פירוש', 'validate': True,
        'rules': [{'type': 'heading', 'levels': [2, 2], 'regex': r'^(.+)$', 'ref': '{1}', 'role': 'ref'}]},
    'שולחן ערוך: סימן ברמה 2': {
        'target': 'שולחן ערוך, אורח חיים', 'target_from_name': False, 'link_type': 'פירוש', 'validate': True,
        'rules': [{'type': 'heading', 'levels': [2, 2], 'regex': r'^(סימן [א-ת]+)$', 'ref': '{1}', 'role': 'ref'}]},
    'משנה תורה: פרק ברמה 2': {
        'target': 'משנה תורה, הלכות שבת', 'target_from_name': False, 'link_type': 'פירוש', 'validate': True,
        'rules': [{'type': 'heading', 'levels': [2, 2], 'regex': r'^(פרק [א-ת]+)$', 'ref': '{1}', 'role': 'ref'}]},
    'פרק ברמה 2 והלכה או סימן ברמה 3': {
        'target': '', 'target_from_name': False, 'link_type': 'פירוש', 'validate': True,
        'rules': [{'type': 'heading', 'levels': [2, 2], 'regex': r'^(פרק [א-ת]+)$', 'ref': '{1}', 'role': 'chapter'},
                  {'type': 'heading', 'levels': [3, 3], 'regex': r'^(?:סימן|הלכה|משנה) ([א-ת]+)$',
                   'ref': '{chapter} הלכה {1}', 'role': 'sub'}]},
}


def _levels(rule):
    lv = rule.get('levels') or [2, 6]
    return int(lv[0]), int(lv[-1])


def _fmt(template, groups, chapter):
    """מחליף {1},{2} בקבוצות ה-regex ו-{chapter} בפרק האחרון (בלי str.format, כדי שלא יקרוס על אינדקס חסר)."""
    def rep(m):
        k = m.group(1)
        if k == 'chapter':
            return chapter or ''
        i = int(k) - 1
        return (groups[i] if 0 <= i < len(groups) and groups[i] is not None else '')
    return re.sub(r'\{(\d+|chapter)\}', rep, template).strip()


def run_profile(lines, profile, db, stem=''):
    """מריץ פרופיל כללים על ספר. מחזיר (rows, info):
       rows = {שורה: (ספר יעד, מיקום)}, info = {'notes': [...], 'unmatched': [...], 'headings': n}"""
    rules = profile.get('rules') or []
    target0 = (profile.get('target') or '').strip()
    validate = profile.get('validate', True)
    if profile.get('target_from_name') and not target0:
        t = find_tractate(stem.replace("''", '').replace("'", ''))
        m = re.search(r'מסכת (.+?)\s*(?:\(\d+\)|\d+)?\s*$', stem)
        if m:
            t = re.sub(r'\s+ועוד$', '', re.sub(r"\s*\(.*?\)\s*$", '', m.group(1)).strip())
        target0 = ALIAS.get(t, t) if t else ''
    notes, unmatched = [], collections.Counter()
    if not target0 and not any(r.get('type') == 'target_switch' for r in rules):
        return {}, {'notes': ['לא הוגדר ספר יעד'], 'unmatched': [], 'headings': 0}

    state = {'target': target0, 'cur': None, 'chapter': None}
    refs_cache = {}

    def valid_for(target):
        if not validate:
            return None
        if target not in refs_cache:
            refs_cache[target] = db.valid_refs(target) if db else None
        return refs_cache[target]

    dafs_cache = {}

    def dafs_for(target):
        if target not in dafs_cache:
            dafs_cache[target] = db.dafset(target) if db else None
        return dafs_cache[target]

    use_anchor = any(r.get('type') == 'anchor' for r in rules)
    anchor_re = re.compile(r'^(?:<[^>]+>)*\s*(?:ו)?בדף\s+([א-ת]{1,3}[' + _Q + r']?[א-ת]?)\s*(?:([.:])|ע[' + _Q + r']?([אב]))')
    out, n_head = {}, 0
    head_re = HEAD_LOOSE
    for i, l in enumerate(lines, 1):
        s = l.rstrip('\r').strip()
        hm = head_re.match(s)
        if hm:
            lvl, text = int(hm.group(1)), strip_tags(hm.group(2))
            n_head += 1
            if use_anchor and lvl == 2:
                state['cur'] = None
            matched = False
            for r in rules:
                lo, hi = _levels(r)
                if not (lo <= lvl <= hi):
                    continue
                typ = r.get('type')
                if typ == 'target_switch':
                    m = re.match(r['regex'], text)
                    if m:
                        nt = ALIAS.get(m.group(1).strip(), m.group(1).strip()) if m.groups() else m.group(0)
                        if (not db) or db.has_book(nt):
                            state.update(target=nt, cur=None)
                        matched = True
                        break
                elif typ == 'daf':
                    ref = None
                    dm = DAF.match(text)
                    if dm:
                        ref = dm.group(1) + dm.group(2)
                    elif 'ext' in (r.get('formats') or ['std', 'ext']):
                        ref = parse_daf_ext(text)
                    if ref:
                        state['cur'] = ref
                        matched = True
                        break
                elif typ == 'heading':
                    m = re.match(r['regex'], text)
                    if not m:
                        continue
                    role = r.get('role', 'ref')
                    ref = _fmt(r.get('ref', '{1}'), m.groups(), state['chapter']) if (
                        role != 'sub' or state['chapter']) else None
                    if role == 'chapter':
                        state['chapter'] = ref
                        state['cur'] = None
                    elif role == 'sub':
                        state['cur'] = ref
                    else:
                        state['cur'] = ref
                    matched = True
                    break
            if not matched and lvl >= 2:
                unmatched[text[:40]] += 1
                # זיהוי אוטומטי: כותרת לא מזוהה ברמה של הכללים מנתקת את המיקום, כדי שלא יידבקו אליו שורות שלא שייכות
                if profile.get('reset_on_unmatched') and any(_levels(r)[0] <= lvl <= _levels(r)[1] for r in rules if r.get('type') != 'anchor'):
                    state['cur'] = None
            continue
        if i == 1 or not s:
            continue
        if use_anchor:
            m = anchor_re.match(s)
            if m:
                side = m.group(2) or ('.' if m.group(3) == 'א' else ':')
                state['cur'] = re.sub('[' + _Q + ']', '', m.group(1)) + side
        cur = state['cur']
        if not cur or not state['target']:
            continue
        v = valid_for(state['target'])
        if validate and v is not None:
            d = dafs_for(state['target'])
            if cur not in v and not (d and cur in d):
                continue
        out[i] = (state['target'], cur)
    if validate and db and state['target'] and db.toc(state['target']) is None and target0:
        notes.append('ספר היעד לא נמצא ב-seforim.db: ' + target0)
    return out, {'notes': notes, 'unmatched': unmatched.most_common(12), 'headings': n_head}


def profile_for_ai(profile):
    return json.dumps(profile, ensure_ascii=False, indent=1)


def validate_profile(profile):
    """בדיקת תקינות של פרופיל שהגיע מהמשתמש או מ-AI. מחזיר רשימת שגיאות (ריקה = תקין)."""
    errs = []
    if not isinstance(profile, dict):
        return ['הפרופיל אינו אובייקט']
    rules = profile.get('rules')
    if not isinstance(rules, list) or not rules:
        errs.append('חסרים כללים')
        return errs
    for k, r in enumerate(rules, 1):
        if not isinstance(r, dict) or r.get('type') not in ('daf', 'heading', 'target_switch', 'anchor'):
            errs.append(f'כלל {k}: סוג לא מוכר')
            continue
        if r['type'] in ('heading', 'target_switch'):
            try:
                re.compile(r.get('regex', ''))
            except re.error as e:
                errs.append(f'כלל {k}: ביטוי רגולרי שגוי ({e})')
            if r['type'] == 'heading' and r.get('role', 'ref') not in ('ref', 'chapter', 'sub'):
                errs.append(f'כלל {k}: role לא מוכר')
    return errs


# ───────────────────────────── קבצי קישורים ─────────────────────────────
def links_rows(stem, rows, link_type='פירוש', category=''):
    return [[str(ln), stem, 'כן', t, ref, link_type, 'לא', category] for ln, (t, ref) in sorted(rows.items())]


def write_csv(path, rows, header=True):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    out = io.StringIO()
    w = csv.writer(out, lineterminator='\r\n')
    if header:
        w.writerow(LINK_HEADER)
    w.writerows(rows)
    with open(path, 'wb') as f:
        f.write(('﻿' + out.getvalue()).encode('utf-8'))


def read_csv(path):
    with open(path, encoding='utf-8-sig', newline='') as f:
        return list(csv.reader(f))


def merge_into_csv(path, stem, new_rows):
    """מוסיף שורות לקובץ קישורים קיים, ומחליף שורות קודמות של אותו ספר מקור (בלי כפילויות)."""
    base = read_csv(path) if os.path.exists(path) else [LINK_HEADER]
    kept = [r for r in base[1:] if len(r) < 2 or r[1] != stem]
    write_csv(path, kept + new_rows)
    return len(base) - 1 - len(kept)  # כמה שורות ישנות הוחלפו


# ───────────────────────────── חיפוש ספרים ─────────────────────────────
def find_books(books_dir):
    """stem -> [(rel, path)] לכל קובצי ה-txt בתיקיית הספרים (בלי תיקיית הקישורים)."""
    out = collections.defaultdict(list)
    for dp, dirs, fs in os.walk(books_dir):
        dirs[:] = [d for d in dirs if not d.startswith('.')]  # .git, .github
        if 'קבצי קישורים' in dp:
            continue
        rel = tuple(os.path.relpath(dp, books_dir).split(os.sep))
        if rel == ('.',):
            rel = ()
        for f in sorted(fs):
            if f.endswith('.txt'):
                out[f[:-4]].append((rel, os.path.join(dp, f)))
    return out


# ───────────────────────────── בדיקה ותיקון של קישורים קיימים ─────────────────────────────
SHIFTS = range(-2, 4)


def _expected(books, db, stem, rel, path, cache):
    if path not in cache:
        L = read_lines(path)
        if is_lfs_pointer(L):
            cache[path] = None
        else:
            kind = detect_kind(rel, stem)
            cache[path] = builtin_expected(kind, rel, stem, L, db)[0] if kind else {}
    return cache[path]


def plan_repair(books_dir, links_dir, db, manual=(), progress=None):
    """בונה תוכנית תיקון בלי לכתוב כלום. מחזיר dict עם:
         report     שורה לכל קבוצה (ספר, קטגוריה): סטטוס, שורות לפני/אחרי, הזזה, הערה
         new_for    {(ספר, קטגוריה): שורות חדשות} להחלפה
         additions  ספרים חדשים שיש להם קישורים צפויים ואין להם קבוצה
         files      {נתיב: שורות}
    """
    say = progress or (lambda m: None)
    files = {}
    for p in sorted(glob.glob(os.path.join(links_dir, 'קישורים*', '*', 'links.csv'))
                    + glob.glob(os.path.join(links_dir, '*', 'links.csv'))):
        if p not in files:
            files[p] = read_csv(p)
    say(f'נטענו {len(files)} קבצי קישורים')
    groups = collections.OrderedDict()
    for p, rows in files.items():
        for r in rows[1:]:
            if len(r) >= 8:
                groups.setdefault((r[1], r[7]), []).append(r)
    books = find_books(books_dir)
    cache, report, new_for, paths = {}, [], {}, {}
    by_stem = collections.OrderedDict()
    for (stem, cat), rows in groups.items():
        by_stem.setdefault(stem, []).append((cat, rows))
    for n, (stem, glist) in enumerate(by_stem.items(), 1):
        if n % 50 == 0:
            say(f'נבדקו {n} מתוך {len(by_stem)} ספרי מקור')
        olds = []
        for cat, rows in glist:
            old = collections.defaultdict(set)
            for r in rows:
                old[int(r[0])].add((r[3], r[4]))
            olds.append(old)
        if stem in manual:
            for cat, rows in glist:
                report.append((stem, cat, 'ידני', len(rows), len(rows), '', 'לא נבדק: מוגדר כידני'))
            continue
        cl, any_lfs = [], False
        for rel, path in books.get(stem, []):
            e = _expected(books, db, stem, rel, path, cache)
            if e is None:
                any_lfs = True
            elif e:
                cl.append((rel, path, e))
        pairs = []
        for gi, old in enumerate(olds):
            n_old = sum(len(v) for v in old.values())
            for ci, (rel, path, exp) in enumerate(cl):
                bj, bs = 0.0, 0
                for s in SHIFTS:
                    m = sum(1 for ln, ts in old.items() if exp.get(ln + s) in ts)
                    j = m / (n_old + len(exp) - m) if (n_old + len(exp) - m) else 0
                    if j > bj:
                        bj, bs = j, s
                pairs.append((bj, gi, ci, bs))
        pairs.sort(reverse=True)
        gdone, cdone, assign = set(), set(), {}
        for j, gi, ci, s in pairs:
            if j < 0.5 or gi in gdone or ci in cdone:
                continue
            gdone.add(gi)
            cdone.add(ci)
            assign[gi] = (ci, s, j)
        for gi, (cat, rows) in enumerate(glist):
            n_old = len(rows)
            if gi not in assign:
                why = ('קובץ git-lfs (מצביע): לא נבדק' if any_lfs else
                       'אין קובץ בתיקיית הספרים' if not books.get(stem) else
                       'אין קובץ מתאים לקבוצה (חפיפה נמוכה או שאין כלל יצירה)')
                report.append((stem, cat, 'לא נבדק', n_old, n_old, '', why))
                continue
            ci, s, j = assign[gi]
            rel, path, exp = cl[ci]
            typ = rows[0][5]
            new = [[str(ln), stem, rows[0][2], t, ref, typ, rows[0][6], cat] for ln, (t, ref) in sorted(exp.items())]
            new_for[(stem, cat)] = new
            paths[(stem, cat)] = path
            status = 'תקין' if s == 0 and j == 1.0 else 'עודכן'
            report.append((stem, cat, status, n_old, len(new), s, f'התאמה {j:.0%}'))
    additions = []
    for stem, lst in books.items():
        if stem in manual or stem in by_stem or len(lst) != 1:
            continue
        rel, path = lst[0]
        exp = _expected(books, db, stem, rel, path, cache)
        if exp:
            typ = 'תרגום' if rel[:2] == ('תנ״ך', 'תרגומים') else 'פירוש'
            additions.append((stem, [[str(ln), stem, 'כן', t, ref, typ, 'לא', ''] for ln, (t, ref) in sorted(exp.items())]))
            report.append((stem, '', 'חדש', 0, len(exp), '', 'ספר בלי קישורים שיש לו כלל יצירה'))
    return {'report': report, 'new_for': new_for, 'additions': additions, 'files': files, 'paths': paths}


def apply_repair(plan, new_dir, backup_dir=None, progress=None):
    """כותב את התוכנית. מגבה קודם את כל קבצי הקישורים ל-zip (אם הוגדר backup_dir)."""
    say = progress or (lambda m: None)
    files, new_for, additions = plan['files'], plan['new_for'], plan['additions']
    if backup_dir:
        os.makedirs(backup_dir, exist_ok=True)
        zp = os.path.join(backup_dir, 'links_backup_' + time.strftime('%Y%m%d_%H%M%S') + '.zip')
        with zipfile.ZipFile(zp, 'w', zipfile.ZIP_DEFLATED) as z:
            for p in files:
                z.write(p, os.path.basename(os.path.dirname(p)) + '/links.csv')
        say('גיבוי נשמר: ' + zp)
    changed = 0
    for p, rows in files.items():
        out_rows, emitted, ch = [rows[0]], set(), False
        for r in rows[1:]:
            key = (r[1], r[7]) if len(r) >= 8 else None
            if key in new_for:
                ch = True
                if key not in emitted:
                    out_rows.extend(new_for[key])
                    emitted.add(key)
                continue
            out_rows.append(r)
        if ch:
            write_csv(p, out_rows[1:])
            changed += 1
    if additions:
        os.makedirs(new_dir, exist_ok=True)
        out_path = os.path.join(new_dir, 'links.csv')
        existing = read_csv(out_path) if os.path.exists(out_path) else [LINK_HEADER]
        names = {a[0] for a in additions}
        rows = [r for r in existing[1:] if r[1] not in names]
        for _, adds in additions:
            rows.extend(adds)
        write_csv(out_path, rows)
        say(f'קישורים חדשים ל-{len(additions)} ספרים ב-{out_path}')
    say(f'נכתבו {changed} קבצים קיימים')
    return changed


def summarize_report(report):
    c = collections.Counter(r[2] for r in report)
    return dict(c)
