# -*- coding: utf-8 -*-
"""בדיקות למנוע ולסריקת ה-AI. לא דורשות seforim.db ולא חיבור לרשת: ה-DB וה-AI מדומים."""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import ai_providers as AI
import linker_core as C
import structure_ai as SA


class FakeDB:
    """תוכן עניינים מדומה: ברכות עם דפים ב. ב: ג., שולחן ערוך עם שני סימנים, ופסקי הרא"ש."""
    TOCS = {
        'ברכות': [(1, None, 0, 'ברכות'), (2, 1, 1, 'דף ב.'), (3, 1, 1, 'דף ב:'), (4, 1, 1, 'דף ג.')],
        'שולחן ערוך, יורה דעה': [(1, None, 0, 'x'), (2, 1, 1, 'סימן קס'), (3, 1, 1, 'סימן קסא')],
        'פסקי הרא"ש על ביצה': [(1, None, 0, 'x'), (2, 1, 1, 'פרק א'), (3, 2, 2, 'הלכה ב'), (4, 2, 2, 'הלכה ג')],
    }

    def titles(self):
        return list(self.TOCS)

    def has_book(self, t):
        return t in self.TOCS

    def toc(self, t):
        return self.TOCS.get(t)

    def dafset(self, t):
        e = self.toc(t)
        return None if not e else {x[3][3:] for x in e if x[3].startswith('דף ')}

    def chset(self, t):
        e = self.toc(t)
        return None if not e else {x[3] for x in e if x[2] == 1}

    def hset(self, t):
        e = self.toc(t)
        if not e:
            return None
        by = {x[0]: x for x in e}
        return {(by[p][3], tx) for i, p, l, tx in e if l == 2 and p in by}

    def valid_refs(self, t):
        e = self.toc(t)
        if e is None:
            return None
        by = {x[0]: x for x in e}
        out = set()
        for i, p, l, tx in e:
            out.add(tx)
            if tx.startswith('דף '):
                out.add(tx[3:])
            if p in by and l >= 2:
                out.add(by[p][3] + ' ' + tx)
        return out

    def toc_summary(self, t, limit=14):
        e = self.toc(t)
        return None if not e else {'levels': {}, 'sample': [(x[2], x[3]) for x in e[:limit]]}


DB = FakeDB()
BOOK = ['<img src="x">', '<h1>חידושים מסכת ברכות</h1>', '<h2>פרק א</h2>', '<h3>ב.</h3>', 'שורה א', 'שורה ב',
        '<h3>ב:</h3>', 'שורה ג', '<h3>יד, ב</h3>', 'לא קיים ביעד', '<h3>ג.</h3>', 'שורה ד']


class ProfileEngine(unittest.TestCase):
    def test_daf_headings(self):
        rows, _ = C.run_profile(BOOK, C.PRESETS['בבלי: כותרות דף'], DB, 'חידושים מסכת ברכות')
        self.assertEqual(rows, {5: ('ברכות', 'ב.'), 6: ('ברכות', 'ב.'), 8: ('ברכות', 'ב:'), 12: ('ברכות', 'ג.')})

    def test_first_line_and_headings_never_linked(self):
        rows, _ = C.run_profile(BOOK, C.PRESETS['בבלי: כותרות דף'], DB, 'מסכת ברכות')
        self.assertNotIn(1, rows)
        self.assertTrue(all(not BOOK[i - 1].startswith('<h') for i in rows))

    def test_chapter_and_sub(self):
        lines = ['x', '<h1>t</h1>', '<h2>פרק א</h2>', '<h3>סימן ב</h3>', 'טקסט', '<h3>סימן ז</h3>', 'אין כזה']
        p = dict(C.PRESETS['פרק ברמה 2 והלכה או סימן ברמה 3'], target='פסקי הרא"ש על ביצה')
        rows, _ = C.run_profile(lines, p, DB, 'x')
        self.assertEqual(rows, {5: ('פסקי הרא"ש על ביצה', 'פרק א הלכה ב')})

    def test_shulchan_aruch_simanim(self):
        lines = ['x', '<h1>t</h1>', '<h2>סימן קס</h2>', 'א', 'ב', '<h2>סימן קסב</h2>', 'לא קיים']
        p = dict(C.PRESETS['שולחן ערוך: סימן ברמה 2'], target='שולחן ערוך, יורה דעה')
        rows, _ = C.run_profile(lines, p, DB, 'x')
        self.assertEqual(sorted(rows), [4, 5])

    def test_validate_off_keeps_unknown_refs(self):
        lines = ['x', '<h2>סימן קסב</h2>', 'א']
        p = dict(C.PRESETS['שולחן ערוך: סימן ברמה 2'], target='שולחן ערוך, יורה דעה', validate=False)
        rows, _ = C.run_profile(lines, p, DB, 'x')
        self.assertEqual(rows, {3: ('שולחן ערוך, יורה דעה', 'סימן קסב')})

    def test_anchor_mode(self):
        lines = ['x', '<h1>t</h1>', 'פתיחה', 'בדף ב. שנים אוחזין', 'המשך', 'בדף ג. עוד', 'סוף']
        rows, _ = C.run_profile(lines, C.PRESETS['בבלי: אזכורי דף בתחילת שורה'], DB, 'מסכת ברכות')
        self.assertEqual(rows, {4: ('ברכות', 'ב.'), 5: ('ברכות', 'ב.'), 6: ('ברכות', 'ג.'), 7: ('ברכות', 'ג.')})

    def test_template_without_groups_does_not_crash(self):
        lines = ['x', '<h2>סימן קס</h2>', 'א']
        p = {'target': 'שולחן ערוך, יורה דעה',
             'rules': [{'type': 'heading', 'levels': [2, 2], 'regex': '^סימן קס$', 'ref': '{1}', 'role': 'ref'}]}
        rows, _ = C.run_profile(lines, p, DB, 'x')  # {1} חסר: מחרוזת ריקה, בלי חריגה
        self.assertEqual(rows, {})

    def test_validate_profile(self):
        self.assertTrue(C.validate_profile({'rules': []}))
        self.assertTrue(C.validate_profile({'rules': [{'type': 'heading', 'regex': '('}]}))
        self.assertTrue(C.validate_profile({'rules': [{'type': 'nope'}]}))
        for p in C.PRESETS.values():
            self.assertEqual(C.validate_profile(p), [])


class Repair(unittest.TestCase):
    def test_shift_is_detected_and_fixed(self):
        with tempfile.TemporaryDirectory() as tmp:
            books = os.path.join(tmp, 'ספרים')
            d = os.path.join(books, 'תלמוד בבלי', 'אחרונים')
            os.makedirs(d)
            stem = 'חידושים מסכת ברכות'
            with open(os.path.join(d, stem + '.txt'), 'w', encoding='utf-8') as f:
                f.write('\n'.join(BOOK))
            links = os.path.join(books, 'קבצי קישורים וסדר הדורות')
            os.makedirs(os.path.join(links, 'קישורים', '01'))
            old = [[str(n - 1), stem, 'כן', 'ברכות', ref, 'פירוש', 'לא', ''] for n, ref in ((5, 'ב.'), (6, 'ב.'), (8, 'ב:'), (10, 'ב:'), (12, 'ג.'))]  # שורה 10: כותרת לא מוכרת משאירה את הדף הקודם (כמו במנוע המקורי)
            lp = os.path.join(links, 'קישורים', '01', 'links.csv')
            C.write_csv(lp, old)
            plan = C.plan_repair(books, links, DB)
            self.assertEqual(C.summarize_report(plan['report']), {'עודכן': 1})
            self.assertEqual(plan['report'][0][5], 1)  # הזזה של +1
            C.apply_repair(plan, os.path.join(links, 'קישורים', '13'), os.path.join(tmp, 'bak'))
            rows = C.read_csv(lp)[1:]
            self.assertEqual([r[0] for r in rows], ['5', '6', '8', '10', '12'])
            self.assertEqual(len(os.listdir(os.path.join(tmp, 'bak'))), 1)       # נוצר גיבוי
            plan2 = C.plan_repair(books, links, DB)
            self.assertEqual(C.summarize_report(plan2['report']), {'תקין': 1})    # ריצה שנייה: הכל תקין
            raw = open(lp, 'rb').read()
            self.assertTrue(raw.startswith(b'\xef\xbb\xbf') and b'\r\n' in raw)   # BOM ו-CRLF

    def test_merge_replaces_same_book_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = os.path.join(tmp, 'links.csv')
            C.write_csv(p, [['1', 'א', 'כן', 'ברכות', 'ב.', 'פירוש', 'לא', ''], ['2', 'ב', 'כן', 'ברכות', 'ב.', 'פירוש', 'לא', '']])
            C.merge_into_csv(p, 'א', [['9', 'א', 'כן', 'ברכות', 'ג.', 'פירוש', 'לא', '']])
            rows = C.read_csv(p)[1:]
            self.assertEqual(sorted((r[1], r[0]) for r in rows), [('א', '9'), ('ב', '2')])


class AIFlow(unittest.TestCase):
    def test_propose_profile_with_mock(self):
        reply = json.dumps({'name': 'דפים', 'target': '', 'target_from_name': True, 'link_type': 'פירוש', 'validate': True,
                            'rules': [{'type': 'daf', 'levels': [2, 6], 'formats': ['std', 'ext']}]}, ensure_ascii=False)
        seen = {}
        orig = AI.generate

        def fake(prov, key, model, system, user, **kw):
            seen.update(user=user, system=system)
            return '```json\n' + reply + '\n```'

        AI.generate = fake
        try:
            prof, raw = SA.propose_profile('gemini', 'k', 'm', 'free', 'חידושים מסכת ברכות', BOOK, DB, '', 0)
        finally:
            AI.generate = orig
        self.assertEqual(C.validate_profile(prof), [])
        rows, _ = C.run_profile(BOOK, prof, DB, 'חידושים מסכת ברכות')
        self.assertEqual(len(rows), 4)
        self.assertIn('first_headings', seen['user'])
        self.assertNotIn('שורה א', seen['user'])  # בלי שורות טקסט כברירת מחדל

    def test_samples_sent_only_when_requested(self):
        s = SA.summarize_book(BOOK, sample_lines=2)
        self.assertEqual(len(s['sample_content_lines']), 2)
        self.assertNotIn('sample_content_lines', SA.summarize_book(BOOK))

    def test_parse_json_blob(self):
        self.assertEqual(AI.parse_json_blob('הנה:\n```json\n{"a": 1}\n```'), {'a': 1})
        with self.assertRaises(AI.AIError):
            AI.parse_json_blob('אין כאן json')

    def test_explain_error(self):
        self.assertIn('מכסת', AI.explain_error('HTTP 429: quota'))
        self.assertIn('המפתח נדחה', AI.explain_error('HTTP 401: API key not valid'))
        self.assertEqual(AI.explain_error('משהו אחר'), '')

    def test_model_filters(self):
        orig = AI._http
        AI._http = lambda url, *a, **k: {'models': [
            {'name': 'models/gemini-2.5-flash', 'supportedGenerationMethods': ['generateContent']},
            {'name': 'models/gemini-2.5-pro', 'supportedGenerationMethods': ['generateContent']},
            {'name': 'models/gemini-2.5-flash-image', 'supportedGenerationMethods': ['generateContent']},
            {'name': 'models/embedding-001', 'supportedGenerationMethods': ['embedContent']}]}
        try:
            ms = AI.list_models('gemini', 'k')
        finally:
            AI._http = orig
        self.assertEqual(ms, ['gemini-2.5-flash', 'gemini-2.5-pro'])
        self.assertEqual(AI.default_model('gemini', ms), 'gemini-2.5-flash')


if __name__ == '__main__':
    unittest.main(verbosity=2)
