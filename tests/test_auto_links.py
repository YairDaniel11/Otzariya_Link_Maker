# -*- coding: utf-8 -*-
"""בדיקות לזיהוי הכללי של ספר יעד לפי שם הקובץ (auto_links). בלי seforim.db ובלי רשת."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import auto_links as A
from test_engine import FakeDB

DB = FakeDB()
INDEX = {A.norm(t): t for t in DB.titles()}


class FindTarget(unittest.TestCase):
    def test_after_al(self):
        self.assertEqual(A.find_target('ביאור על שולחן ערוך יורה דעה', INDEX), 'שולחן ערוך, יורה דעה')

    def test_whole_name_is_official_book(self):
        self.assertIsNone(A.find_target('ברכות', INDEX))  # אין מה לקשר ספר לעצמו

    def test_unknown(self):
        self.assertIsNone(A.find_target('ספר רעיונות', INDEX))


class InferBook(unittest.TestCase):
    def test_simanim(self):
        L = ['שם', '<h2>סימן קס</h2>', 'א', 'ב', '<h2>סימן קסא</h2>', 'ג']
        rows, name, cov = A.infer_book(L, 'שולחן ערוך, יורה דעה', DB, 'x')
        self.assertEqual(rows, {3: ('שולחן ערוך, יורה דעה', 'סימן קס'), 4: ('שולחן ערוך, יורה דעה', 'סימן קס'),
                                6: ('שולחן ערוך, יורה דעה', 'סימן קסא')})
        self.assertEqual(cov, 1.0)

    def test_dafim(self):
        L = ['שם', '<h2>ב.</h2>', 'א', 'ב', '<h2>ב:</h2>', 'ג']
        rows, _, _ = A.infer_book(L, 'ברכות', DB, 'x')
        self.assertEqual(set(rows), {3, 4, 6})

    def test_low_coverage_is_rejected(self):
        L = ['שם', '<h2>סימן קס</h2>', 'א'] + ['שורה בלי כותרת'] * 0 + ['<h2>נושא אחר</h2>'] + ['ב'] * 9
        self.assertIsNone(A.infer_book(L, 'שולחן ערוך, יורה דעה', DB, 'x'))


class HiddenDirsAndTanakhName(unittest.TestCase):
    def test_tanach_without_gershayim(self):
        self.assertEqual(A_core().detect_kind(('תנך', 'תרגומים'), 'בראשית'), 'tanakh')


def A_core():
    import linker_core
    return linker_core


if __name__ == '__main__':
    unittest.main()
