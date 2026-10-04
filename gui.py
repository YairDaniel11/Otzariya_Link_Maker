# -*- coding: utf-8 -*-
"""מחולל קישורים לאוצריא: ממשק גרפי."""
import collections
import copy
import io
import json
import os
import queue
import re
import sys
import threading
import time
import traceback
import webbrowser
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ai_providers as AI
import linker_core as C
import structure_ai as SA

VERSION = '1.0'
APPDATA = os.path.join(os.environ.get('APPDATA') or os.path.expanduser('~'), 'OtzariaLinker')
CFG_PATH = os.path.join(APPDATA, 'config.json')
PROFILES_PATH = os.path.join(APPDATA, 'profiles.json')
BACKUP_DIR = os.path.join(APPDATA, 'backups')
MAX_PREVIEW = 400

DEFAULT_CFG = {'provider': 'gemini', 'keys': {}, 'models': {}, 'tier': 'free', 'send_samples': False,
               'db_path': '', 'books_dir': '', 'links_dir': '', 'out_dir': ''}


def L(text):
    """תווית עברית עם נקודתיים. tkinter ב-Windows לא מיישם BiDi, ולכן הנקודתיים נכתבות בתחילת המחרוזת."""
    return ':' + text


def R(text):
    """מסמן פסקה כימין-לשמאל. בלי זה Windows מסדר טקסט עברי שמכיל מילים באנגלית בסדר שגוי."""
    return '‫' + text + '‬'


def load_json(path, default):
    try:
        with io.open(path, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return copy.deepcopy(default)


def save_json(path, data):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with io.open(path, 'w', encoding='utf-8') as f:
            f.write(json.dumps(data, ensure_ascii=False, indent=1))
    except Exception:
        pass


def center(win, parent):
    win.update_idletasks()
    x = parent.winfo_rootx() + max((parent.winfo_width() - win.winfo_width()) // 2, 0)
    y = parent.winfo_rooty() + 60
    win.geometry(f'+{x}+{y}')


# ═════════════════════════════════ דיאלוג מדריך יצירת מפתח ═════════════════════════════════
class KeyGuideDialog(tk.Toplevel):
    def __init__(self, parent, provider):
        super().__init__(parent)
        info = AI.PROVIDERS[provider]
        self.title('איך יוצרים מפתח API: ' + info['label'])
        self.transient(parent)
        self.resizable(False, False)
        ttk.Label(self, text='יצירת מפתח API ב-' + info['label'], font=('', 11, 'bold')).pack(anchor='e', padx=16, pady=(14, 6))
        for n, step in enumerate(info['steps'], 1):
            f = ttk.Frame(self)
            f.pack(fill='x', padx=16, pady=2)
            ttk.Label(f, text=f'.{n}', width=3, anchor='e').pack(side='right', anchor='n')
            ttk.Label(f, text=step, wraplength=520, justify='right').pack(side='right', anchor='e')
        if info.get('note'):
            ttk.Label(self, text=info['note'], foreground='#8a5a00', wraplength=540, justify='right').pack(
                anchor='e', padx=16, pady=(8, 2))
        bar = ttk.Frame(self)
        bar.pack(fill='x', padx=16, pady=12)
        ttk.Button(bar, text='פתח את דף יצירת המפתח', command=lambda: webbrowser.open(info['key_url'])).pack(side='right')
        if info.get('billing_url'):
            ttk.Button(bar, text='דף החיוב והמסלולים', command=lambda: webbrowser.open(info['billing_url'])).pack(side='right', padx=6)
        ttk.Button(bar, text='סגור', command=self.destroy).pack(side='left')
        ttk.Label(self, text='ייתכן שממשק האתר השתנה מאז שנכתבה ההנחיה. עיקר השלבים זהה.',
                  foreground='#777').pack(anchor='e', padx=16, pady=(0, 10))
        center(self, parent)


GUIDE_HTML = """<!doctype html><html lang="he" dir="rtl"><head><meta charset="utf-8"><title>יצירת מפתח API: {label}</title>
<style>body{{font-family:Segoe UI,Arial,sans-serif;max-width:760px;margin:30px auto;line-height:1.7;padding:0 16px;color:#222}}
h1{{font-size:24px}}li{{margin:8px 0}}a.btn{{display:inline-block;background:#2f6fed;color:#fff;padding:9px 18px;border-radius:6px;text-decoration:none;margin:4px 0 4px 8px}}
.note{{background:#fff6dd;border:1px solid #e6c860;padding:10px 14px;border-radius:6px;margin-top:18px}}small{{color:#666}}</style></head><body>
<h1>יצירת מפתח API: {label}</h1>
<p><a class="btn" href="{key_url}" target="_blank">פתח את דף יצירת המפתח</a>
<a class="btn" style="background:#555" href="{billing_url}" target="_blank">דף החיוב והמסלולים</a></p>
<ol>{steps}</ol>
<div class="note">{note}</div>
<p><small>ייתכן שממשק האתר השתנה מאז שנכתבה ההנחיה. עיקר השלבים זהה. המפתח נשמר רק במחשב שלך, בקובץ ההגדרות של התוכנה.</small></p>
</body></html>"""


def open_key_guide(parent, provider):
    """פותח מדריך יצירת מפתח כדף HTML בדפדפן (שם הכיווניות עברית-אנגלית תקינה). אם נכשל: דיאלוג רגיל."""
    info = AI.PROVIDERS[provider]
    try:
        import html
        steps = ''.join(f'<li>{html.escape(s)}</li>' for s in info['steps'])
        page = GUIDE_HTML.format(label=html.escape(info['label']), key_url=info['key_url'],
                                 billing_url=info.get('billing_url', info['key_url']), steps=steps,
                                 note=html.escape(info.get('note', '')))
        path = os.path.join(APPDATA, f'guide_{provider}.html')
        os.makedirs(APPDATA, exist_ok=True)
        with io.open(path, 'w', encoding='utf-8') as f:
            f.write(page)
        if not webbrowser.open('file:///' + path.replace(os.sep, '/')):
            raise RuntimeError('no browser')
    except Exception:
        KeyGuideDialog(parent, provider)


def describe_profile(profile):
    """תיאור קריא בעברית של פרופיל כללים (במקום JSON גולמי)."""
    out = []
    tgt = profile.get('target') or ('לפי שם הקובץ (מסכת)' if profile.get('target_from_name') else 'לפי כותרות הקובץ')
    out.append('ספר יעד: ' + tgt)
    for k, r in enumerate(profile.get('rules') or [], 1):
        typ = r.get('type')
        lv = r.get('levels') or []
        lvt = f'ברמה {lv[0]}' if lv and lv[0] == lv[-1] else (f'ברמות {lv[0]} עד {lv[-1]}' if lv else '')
        if typ == 'daf':
            out.append(f'{k}. כותרת {lvt} שהיא מספר דף (ב. / ב: ועוד)')
        elif typ == 'anchor':
            out.append(f'{k}. שורה שפותחת באזכור דף')
        elif typ == 'target_switch':
            out.append(f'{k}. כותרת {lvt} שמחליפה את ספר היעד: {r.get("regex", "")}')
        elif typ == 'heading':
            role = ROLES.get(r.get('role', 'ref'), '')
            out.append(f'{k}. כותרת {lvt} שמתאימה לביטוי {r.get("regex", "")} ← מיקום {r.get("ref", "")} ({role})')
    return out


# ═════════════════════════════════ דיאלוג הגדרות ═════════════════════════════════
class SettingsDialog(tk.Toplevel):
    def __init__(self, app):
        super().__init__(app)
        self.app = app
        self.title('הגדרות')
        self.transient(app)
        self.resizable(False, False)
        cfg = app.cfg
        self.provider = tk.StringVar(value=cfg.get('provider', 'gemini'))
        self.key = tk.StringVar()
        self.model = tk.StringVar()
        self.tier = tk.StringVar()
        self.show = tk.BooleanVar(value=False)
        self.samples = tk.BooleanVar(value=cfg.get('send_samples', False))
        self.db_path = tk.StringVar(value=cfg.get('db_path') or C.find_seforim_db() or '')
        self.status = tk.StringVar(value='')
        self.keys = dict(cfg.get('keys', {}))
        self.models = dict(cfg.get('models', {}))
        self.tiers = dict(cfg.get('tiers', {'gemini': cfg.get('tier', 'free')}))
        self._cur = None

        ai = ttk.LabelFrame(self, text=' חיבור לבינה מלאכותית (אופציונלי: לסריקת מבנה הספר) ')
        ai.pack(fill='x', padx=12, pady=(12, 6))
        r = ttk.Frame(ai); r.pack(fill='x', padx=8, pady=(8, 2))
        ttk.Label(r, text=L('ספק')).pack(side='right')
        labels = [AI.PROVIDERS[k]['label'] for k in AI.PROVIDERS]
        self.cb_provider = ttk.Combobox(r, values=labels, width=24, state='readonly')
        self.cb_provider.pack(side='right', padx=6)
        self.cb_provider.bind('<<ComboboxSelected>>', lambda e: self._switch())
        ttk.Button(r, text='איך יוצרים מפתח?', command=self.guide).pack(side='right', padx=10)

        r = ttk.Frame(ai); r.pack(fill='x', padx=8, pady=2)
        ttk.Label(r, text=L('מפתח API')).pack(side='right')
        self.e_key = ttk.Entry(r, textvariable=self.key, show='•', width=46, justify='left')
        self.e_key.pack(side='right', padx=6)
        ttk.Checkbutton(r, text='הצג', variable=self.show, command=self._toggle_show).pack(side='right')

        self.r_tier = ttk.Frame(ai); self.r_tier.pack(fill='x', padx=8, pady=2)
        ttk.Label(self.r_tier, text=L('מסלול')).pack(side='right')
        self.cb_tier = ttk.Combobox(self.r_tier, width=26, state='readonly')
        self.cb_tier.pack(side='right', padx=6)
        self.lbl_tier = ttk.Label(self.r_tier, text='', foreground='#777')
        self.lbl_tier.pack(side='right', padx=6)

        r = ttk.Frame(ai); r.pack(fill='x', padx=8, pady=2)
        ttk.Label(r, text=L('מודל')).pack(side='right')
        self.cb_model = ttk.Combobox(r, textvariable=self.model, width=34, justify='left')
        self.cb_model.pack(side='right', padx=6)
        ttk.Button(r, text='בדוק מפתח ורענן מודלים', command=self.check_key).pack(side='right', padx=6)

        ttk.Label(ai, textvariable=self.status, foreground='#555', wraplength=520, justify='right').pack(anchor='e', padx=10, pady=2)
        ttk.Checkbutton(ai, text='שלח למודל גם כמה שורות טקסט לדוגמה (ברירת מחדל: רק כותרות הספר)',
                        variable=self.samples).pack(anchor='e', padx=10, pady=(0, 2))
        ttk.Label(ai, text='הספרים עצמם לא נשלחים: רק תקציר של הכותרות, ובמידת הצורך כמה שורות.',
                  foreground='#777').pack(anchor='e', padx=10, pady=(0, 8))

        fr = ttk.LabelFrame(self, text=' נתיבים ')
        fr.pack(fill='x', padx=12, pady=6)
        r = ttk.Frame(fr); r.pack(fill='x', padx=8, pady=8)
        ttk.Label(r, text=L('קובץ seforim.db של אוצריא')).pack(side='right')
        ttk.Button(r, text='בחר', command=self.pick_db).pack(side='right', padx=(6, 0))
        ttk.Entry(r, textvariable=self.db_path, width=46, justify='left').pack(side='right', padx=6)
        ttk.Label(fr, text='משמש רק לקריאה, כדי לאמת שהמיקומים קיימים בספר היעד. אם לא הוגדר, חיפוש אוטומטי.',
                  foreground='#777').pack(anchor='e', padx=10, pady=(0, 8))

        bar = ttk.Frame(self); bar.pack(fill='x', padx=12, pady=10)
        ttk.Button(bar, text='שמור', command=self.save).pack(side='right')
        ttk.Button(bar, text='ביטול', command=self.destroy).pack(side='right', padx=6)

        self._load(self.provider.get())
        self.grab_set()
        center(self, app)

    # בחירת ספק: מחליפה את המפתח, המודל והמסלול השמורים לאותו ספק
    def _pkey(self):
        for k, v in AI.PROVIDERS.items():
            if v['label'] == self.cb_provider.get():
                return k
        return 'gemini'

    def _load(self, p):
        self._cur = p
        self.cb_provider.set(AI.PROVIDERS[p]['label'])
        self.key.set(self.keys.get(p, ''))
        self.model.set(self.models.get(p, ''))
        tiers = AI.PROVIDERS[p]['tiers']
        if tiers:
            self.cb_tier['values'] = [t[1] for t in tiers]
            cur = self.tiers.get(p, tiers[0][0])
            self.cb_tier.set(dict(tiers).get(cur, tiers[0][1]))
            self.cb_tier.state(['!disabled'])
            self.lbl_tier.config(text='חינמי: התוכנה מאטה לבד את הבקשות')
        else:
            self.cb_tier['values'] = []
            self.cb_tier.set('ללא מסלול חינמי: חיוב לפי שימוש')
            self.cb_tier.state(['disabled'])
            self.lbl_tier.config(text='')
        self.status.set('')

    def _stash(self):
        p = self._cur
        if not p:
            return
        self.keys[p] = self.key.get().strip()
        self.models[p] = self.model.get().strip()
        tiers = AI.PROVIDERS[p]['tiers']
        if tiers:
            self.tiers[p] = next((k for k, lab in tiers if lab == self.cb_tier.get()), tiers[0][0])

    def _switch(self):
        self._stash()
        self._load(self._pkey())

    def _toggle_show(self):
        self.e_key.config(show='' if self.show.get() else '•')

    def guide(self):
        open_key_guide(self, self._pkey())

    def pick_db(self):
        p = filedialog.askopenfilename(parent=self, title='בחר seforim.db', filetypes=[('seforim.db', '*.db'), ('הכל', '*.*')])
        if p:
            self.db_path.set(p)

    def check_key(self):
        p, key = self._pkey(), self.key.get().strip()
        if not key:
            messagebox.showwarning('', 'הדבק קודם מפתח API.', parent=self)
            return
        self.status.set('בודק את המפתח ושולף מודלים...')

        def work():
            return AI.list_models(p, key)

        def done(models):
            if not models:
                self.status.set('המפתח תקין, אבל לא נמצאו מודלים זמינים.')
                return
            self.cb_model['values'] = models
            if not self.model.get() or self.model.get() not in models:
                self.model.set(AI.default_model(p, models))
            self.status.set(f'המפתח תקין. נמצאו {len(models)} מודלים. נבחר: {self.model.get()}')

        def fail(e):
            msg = str(e)
            self.status.set('הבדיקה נכשלה: ' + msg[:200] + ('\n' + AI.explain_error(msg) if AI.explain_error(msg) else ''))

        self.app.run_bg(work, done, on_error=fail, busy=False)

    def save(self):
        self._stash()
        cfg = self.app.cfg
        cfg['provider'] = self._pkey()
        cfg['keys'], cfg['models'], cfg['tiers'] = self.keys, self.models, self.tiers
        cfg['send_samples'] = self.samples.get()
        newdb = self.db_path.get().strip()
        if newdb != cfg.get('db_path'):
            self.app.db = None
        cfg['db_path'] = newdb
        self.app.save_cfg()
        self.destroy()


# ═════════════════════════════════ עורך כללי כותרות ═════════════════════════════════
RULE_TYPES = {'daf': 'דף (ב. / ב:)', 'heading': 'כותרת לפי ביטוי', 'target_switch': 'החלפת ספר יעד',
              'anchor': 'אזכור "בדף X."'}
ROLES = {'ref': 'קובע מיקום', 'chapter': 'קובע פרק', 'sub': 'מתחבר לפרק'}


class RuleEditDialog(tk.Toplevel):
    def __init__(self, parent, rule):
        super().__init__(parent)
        self.title('כלל כותרת')
        self.transient(parent)
        self.resizable(False, False)
        self.result = None
        r = rule or {'type': 'heading', 'levels': [2, 2], 'regex': '', 'ref': '{1}', 'role': 'ref'}
        self.type = tk.StringVar(value=RULE_TYPES.get(r.get('type'), RULE_TYPES['heading']))
        lv = r.get('levels') or [2, 6]
        self.lo, self.hi = tk.IntVar(value=int(lv[0])), tk.IntVar(value=int(lv[-1]))
        self.regex = tk.StringVar(value=r.get('regex', ''))
        self.ref = tk.StringVar(value=r.get('ref', '{1}'))
        self.role = tk.StringVar(value=ROLES.get(r.get('role', 'ref'), ROLES['ref']))
        self.ext = tk.BooleanVar(value='ext' in (r.get('formats') or ['std', 'ext']))

        def row(label, widget_factory):
            f = ttk.Frame(self); f.pack(fill='x', padx=12, pady=4)
            ttk.Label(f, text=L(label), width=14, anchor='e').pack(side='right')
            w = widget_factory(f); w.pack(side='right', padx=6)
            return w

        cb = row('סוג הכלל', lambda f: ttk.Combobox(f, textvariable=self.type, values=list(RULE_TYPES.values()), state='readonly', width=28))
        cb.bind('<<ComboboxSelected>>', lambda e: self._sync())

        def levels(f):
            fr = ttk.Frame(f)
            ttk.Spinbox(fr, from_=1, to=6, textvariable=self.hi, width=4).pack(side='right')
            ttk.Label(fr, text=' עד ').pack(side='right')
            ttk.Spinbox(fr, from_=1, to=6, textvariable=self.lo, width=4).pack(side='right')
            return fr
        self.w_levels = row('רמות כותרת (h)', levels)
        self.e_regex = row('ביטוי רגולרי', lambda f: ttk.Entry(f, textvariable=self.regex, width=44, justify='left'))
        self.e_ref = row('מיקום ביעד', lambda f: ttk.Entry(f, textvariable=self.ref, width=44, justify='left'))
        self.cb_role = row('תפקיד', lambda f: ttk.Combobox(f, textvariable=self.role, values=list(ROLES.values()), state='readonly', width=28))
        self.c_ext = row('פורמטים נוספים', lambda f: ttk.Checkbutton(f, text='כולל "יד, ב" ו"דף ב ע"א"', variable=self.ext))
        self.hint = ttk.Label(self, text='', foreground='#666', wraplength=480, justify='right')
        self.hint.pack(anchor='e', padx=14, pady=4)
        bar = ttk.Frame(self); bar.pack(fill='x', padx=12, pady=10)
        ttk.Button(bar, text='אישור', command=self.ok).pack(side='right')
        ttk.Button(bar, text='ביטול', command=self.destroy).pack(side='right', padx=6)
        self._sync()
        self.grab_set()
        center(self, parent)

    def _type_key(self):
        return next(k for k, v in RULE_TYPES.items() if v == self.type.get())

    def _sync(self):
        t = self._type_key()
        on = lambda w, v: w.state(['!disabled'] if v else ['disabled'])
        on(self.e_regex, t in ('heading', 'target_switch'))
        on(self.e_ref, t == 'heading')
        on(self.cb_role, t == 'heading')
        on(self.c_ext, t == 'daf')
        self.hint.config(text=R({
            'daf': 'כותרת שהיא מספר דף ("ב." עמוד א, "ב:" עמוד ב). ספר היעד חייב להיות מסכת בש"ס.',
            'heading': 'הביטוי חייב להתאים לטקסט הכותרת. במיקום אפשר להשתמש ב-{1},{2} (קבוצות הביטוי) וב-{chapter} (הפרק האחרון). '
                       'המיקום חייב להיות זהה לכותרת בתוכן העניינים של ספר היעד, למשל "פרק א" או "סימן קס".',
            'target_switch': 'כותרת שמחליפה את ספר היעד באמצע הקובץ, למשל "מסכת ברכות". הקבוצה הראשונה היא שם הספר.',
            'anchor': 'שורה שפותחת באזכור דף (למשל "בדף ב.") קובעת את הדף. הכלל חל על שורות שאחריה עד העוגן הבא או עד כותרת חדשה ברמה 2.'}[t]))

    def ok(self):
        t = self._type_key()
        rule = {'type': t}
        if t == 'anchor':
            pass
        else:
            rule['levels'] = [self.lo.get(), self.hi.get()]
        if t == 'daf':
            rule['formats'] = ['std', 'ext'] if self.ext.get() else ['std']
        if t in ('heading', 'target_switch'):
            try:
                re.compile(self.regex.get())
            except re.error as e:
                messagebox.showerror('', f'הביטוי הרגולרי שגוי: {e}', parent=self)
                return
            rule['regex'] = self.regex.get()
        if t == 'heading':
            rule['ref'] = self.ref.get()
            rule['role'] = next(k for k, v in ROLES.items() if v == self.role.get())
        self.result = rule
        self.destroy()


class RulesDialog(tk.Toplevel):
    """עריכת פרופיל כללי כותרות: טבלת כללים, ועריכת JSON לצורך הדבקה מ-AI."""

    def __init__(self, app, profile, lines):
        super().__init__(app)
        self.app, self.lines = app, lines
        self.title('כללי הכותרות של הספר')
        self.transient(app)
        self.geometry('860x520')
        self.result = None
        self.profile = copy.deepcopy(profile)
        top = ttk.Frame(self); top.pack(fill='x', padx=10, pady=8)
        ttk.Label(top, text=L('שם')).pack(side='right')
        self.name = tk.StringVar(value=self.profile.get('name', ''))
        ttk.Entry(top, textvariable=self.name, width=36).pack(side='right', padx=6)
        self.validate = tk.BooleanVar(value=self.profile.get('validate', True))
        ttk.Checkbutton(top, text='קשר רק מיקומים שקיימים בתוכן העניינים של היעד', variable=self.validate).pack(side='right', padx=14)

        nb = ttk.Notebook(self); nb.pack(fill='both', expand=True, padx=10, pady=4)
        f1 = ttk.Frame(nb); nb.add(f1, text='כללים')
        f2 = ttk.Frame(nb); nb.add(f2, text='JSON')
        cols = ('role', 'ref', 'regex', 'levels', 'type')
        self.tree = ttk.Treeview(f1, columns=cols, show='headings', height=10)
        for c, t, w in (('type', 'סוג', 140), ('levels', 'רמות', 60), ('regex', 'ביטוי', 240), ('ref', 'מיקום', 160), ('role', 'תפקיד', 110)):
            self.tree.heading(c, text=t, anchor='e')
            self.tree.column(c, width=w, anchor='e')
        self.tree.pack(fill='both', expand=True, padx=4, pady=4)
        self.tree.bind('<Double-1>', lambda e: self.edit())
        bar = ttk.Frame(f1); bar.pack(fill='x', padx=4, pady=4)
        for txt, fn in (('הוסף כלל', self.add), ('ערוך', self.edit), ('מחק', self.delete), ('למעלה', lambda: self.move(-1)), ('למטה', lambda: self.move(1)),
                        ('כמה כותרות מתאימות לכל כלל', self.count)):
            ttk.Button(bar, text=txt, command=fn).pack(side='right', padx=3)
        self.count_lbl = ttk.Label(f1, text='', foreground='#555', wraplength=800, justify='right')
        self.count_lbl.pack(anchor='e', padx=6)
        self.js = tk.Text(f2, wrap='none', height=14, font=('Consolas', 10))
        self.js.pack(fill='both', expand=True, padx=4, pady=4)
        ttk.Label(f2, text='אפשר להדביק כאן פרופיל JSON (למשל מ-AI חיצוני) וללחוץ "טען מה-JSON".', foreground='#777').pack(anchor='e', padx=6)
        ttk.Button(f2, text='טען מה-JSON', command=self.load_json_text).pack(anchor='e', padx=6, pady=4)

        bot = ttk.Frame(self); bot.pack(fill='x', padx=10, pady=8)
        ttk.Button(bot, text='אישור', command=self.ok).pack(side='right')
        ttk.Button(bot, text='ביטול', command=self.destroy).pack(side='right', padx=6)
        self.refresh()
        self.grab_set()
        center(self, app)

    def rules(self):
        return self.profile.setdefault('rules', [])

    def refresh(self):
        self.tree.delete(*self.tree.get_children())
        for r in self.rules():
            lv = r.get('levels') or ''
            self.tree.insert('', 'end', values=(ROLES.get(r.get('role', ''), '') if r.get('type') == 'heading' else '',
                                               r.get('ref', ''), r.get('regex', ''),
                                               f'{lv[0]}-{lv[-1]}' if lv else '', RULE_TYPES.get(r.get('type'), r.get('type'))))
        p = dict(self.profile)
        p['name'], p['validate'] = self.name.get(), self.validate.get()
        self.js.delete('1.0', 'end')
        self.js.insert('1.0', json.dumps(p, ensure_ascii=False, indent=1))

    def sel(self):
        s = self.tree.selection()
        return self.tree.index(s[0]) if s else None

    def add(self):
        d = RuleEditDialog(self, None); self.wait_window(d)
        if d.result:
            self.rules().append(d.result); self.refresh()

    def edit(self):
        i = self.sel()
        if i is None:
            return
        d = RuleEditDialog(self, self.rules()[i]); self.wait_window(d)
        if d.result:
            self.rules()[i] = d.result; self.refresh()

    def delete(self):
        i = self.sel()
        if i is not None:
            del self.rules()[i]; self.refresh()

    def move(self, d):
        i = self.sel()
        if i is None or not (0 <= i + d < len(self.rules())):
            return
        r = self.rules(); r[i], r[i + d] = r[i + d], r[i]; self.refresh()
        self.tree.selection_set(self.tree.get_children()[i + d])

    def count(self):
        if not self.lines:
            self.count_lbl.config(text='בחר קודם קובץ ספר.'); return
        heads = [(int(m.group(1)), C.strip_tags(m.group(2))) for m in (C.HEAD_LOOSE.match(l.strip()) for l in self.lines) if m]
        out = []
        for k, r in enumerate(self.rules(), 1):
            lo, hi = (r.get('levels') or [1, 6])[0], (r.get('levels') or [1, 6])[-1]
            n = 0
            for lv, tx in heads:
                if not (lo <= lv <= hi):
                    continue
                if r['type'] == 'daf':
                    n += bool(C.DAF.match(tx) or ('ext' in (r.get('formats') or []) and C.parse_daf_ext(tx)))
                elif r['type'] in ('heading', 'target_switch'):
                    try:
                        n += bool(re.match(r['regex'], tx))
                    except re.error:
                        pass
            out.append(f'כלל {k}: {n}')
        self.count_lbl.config(text=' · '.join(out) if out else 'אין כללים.')

    def load_json_text(self):
        try:
            p = json.loads(self.js.get('1.0', 'end'))
        except Exception as e:
            messagebox.showerror('', f'JSON לא תקין: {e}', parent=self); return
        errs = C.validate_profile(p)
        if errs:
            messagebox.showerror('', 'הפרופיל לא תקין:\n' + '\n'.join(errs), parent=self); return
        self.profile = p
        self.name.set(p.get('name', '')); self.validate.set(p.get('validate', True))
        self.refresh()

    def ok(self):
        self.profile['name'] = self.name.get().strip()
        self.profile['validate'] = self.validate.get()
        errs = C.validate_profile(self.profile)
        if errs:
            messagebox.showerror('', 'הפרופיל לא תקין:\n' + '\n'.join(errs), parent=self); return
        self.result = self.profile
        self.destroy()


# ═════════════════════════════════ תוצאת סריקת AI ═════════════════════════════════
class AIResultDialog(tk.Toplevel):
    def __init__(self, app, profile, rows_n, total, info, raw):
        super().__init__(app)
        self.title('הצעת הבינה המלאכותית')
        self.transient(app)
        self.result, self.feedback = None, None
        cov = 100.0 * rows_n / max(1, total)
        reason = profile.get('reason')
        ttk.Label(self, text=profile.get('name') or 'הצעה', font=('', 11, 'bold')).pack(anchor='e', padx=14, pady=(12, 2))
        if reason:
            ttk.Label(self, text=reason, wraplength=560, justify='right', foreground='#8a5a00').pack(anchor='e', padx=14, pady=2)
        ttk.Label(self, text=f'בבדיקה יבשה קושרו {rows_n} מתוך {total} שורות ({cov:.1f}%) לספר היעד: {profile.get("target") or "לפי שם הקובץ"}',
                  wraplength=560, justify='right').pack(anchor='e', padx=14, pady=2)
        if info.get('notes'):
            ttk.Label(self, text='הערות: ' + '; '.join(info['notes']), foreground='#b00020', wraplength=560, justify='right').pack(anchor='e', padx=14)
        box = ttk.LabelFrame(self, text=' הכללים שהוצעו ')
        box.pack(fill='x', padx=14, pady=8)
        for line in describe_profile(profile):
            ttk.Label(box, text=R(line), wraplength=540, justify='right').pack(anchor='e', padx=8, pady=1)
        ttk.Label(self, text='הכללים המלאים (כולל JSON) נמצאים ב"ערוך כללים" אחרי שתשתמש בהם.', foreground='#777').pack(anchor='e', padx=14)
        ttk.Label(self, text='אפשר לתת משוב ולנסות שוב, או להשתמש בכללים ולערוך אותם ידנית.', foreground='#777').pack(anchor='e', padx=14)
        self.fb = tk.StringVar()
        f = ttk.Frame(self); f.pack(fill='x', padx=14, pady=6)
        ttk.Label(f, text=L('משוב למודל')).pack(side='right')
        ttk.Entry(f, textvariable=self.fb, width=58).pack(side='right', padx=6)
        bar = ttk.Frame(self); bar.pack(fill='x', padx=14, pady=10)
        ok = ttk.Button(bar, text='השתמש בכללים', command=self.use)
        ok.pack(side='right')
        if not profile.get('rules'):
            ok.state(['disabled'])
        ttk.Button(bar, text='נסה שוב עם המשוב', command=self.retry).pack(side='right', padx=6)
        ttk.Button(bar, text='ביטול', command=self.destroy).pack(side='right')
        self.profile = profile
        self.grab_set()
        center(self, app)

    def use(self):
        self.result = self.profile; self.destroy()

    def retry(self):
        self.feedback = self.fb.get().strip() or 'Try again with a better rule set.'; self.destroy()


# ═════════════════════════════════ האפליקציה ═════════════════════════════════
class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(f'מחולל קישורים לאוצריא: גרסה {VERSION}')
        self.geometry('1180x760')
        self.minsize(980, 620)
        self.cfg = {**DEFAULT_CFG, **load_json(CFG_PATH, {})}
        self.saved_profiles = load_json(PROFILES_PATH, {})
        self.db = None
        self.sources, self.lines0, self.stem0 = [], [], ''
        self.profile = copy.deepcopy(C.PRESETS['בבלי: כותרות דף'])
        self.rows_by_stem = {}
        self.plan = None
        self.logq = queue.Queue()
        self.is_busy = False
        self._build()
        self.after(150, self._drain)
        self.log(f'מחולל קישורים לאוצריא, גרסה {VERSION}')

    # ───── תשתית ─────
    def save_cfg(self):
        save_json(CFG_PATH, self.cfg)

    def log(self, msg):
        self.logq.put(msg)

    def _drain(self):
        try:
            while True:
                m = self.logq.get_nowait()
                self.txt_log.config(state='normal')
                self.txt_log.insert('end', time.strftime('%H:%M:%S ') + str(m) + '\n')
                self.txt_log.see('end')
                self.txt_log.config(state='disabled')
                self.status.config(text=str(m)[:140])
        except queue.Empty:
            pass
        self.after(150, self._drain)

    def busy(self, on, msg=''):
        self.is_busy = on
        self.progress.start(12) if on else self.progress.stop()
        if msg:
            self.log(msg)

    def run_bg(self, work, done, on_error=None, busy=True, msg=''):
        if busy:
            self.busy(True, msg)
        q = queue.Queue()

        def target():
            try:
                q.put(('ok', work()))
            except Exception as e:  # noqa
                q.put(('err', e, traceback.format_exc()))

        threading.Thread(target=target, daemon=True).start()

        def poll():
            try:
                r = q.get_nowait()
            except queue.Empty:
                self.after(100, poll)
                return
            if busy:
                self.busy(False)
            if r[0] == 'ok':
                try:
                    done(r[1])
                except Exception as e:  # noqa
                    self.error(e, traceback.format_exc())
            elif on_error:
                on_error(r[1])
            else:
                self.error(r[1], r[2])

        poll()

    def error(self, e, tb=''):
        msg = str(e)
        hint = AI.explain_error(msg)
        self.log('שגיאה: ' + msg[:300])
        if tb:
            self.log(tb.strip().splitlines()[-1])
        messagebox.showerror('שגיאה', msg[:600] + ('\n\n' + hint if hint else ''), parent=self)

    def get_db(self):
        if self.db:
            return self.db
        p = self.cfg.get('db_path') or C.find_seforim_db()
        if not p or not os.path.isfile(p):
            if messagebox.askyesno('seforim.db', 'לא נמצא קובץ seforim.db של אוצריא (הוא נחוץ לאימות המיקומים).\nלבחור אותו עכשיו?', parent=self):
                p = filedialog.askopenfilename(parent=self, title='בחר seforim.db', filetypes=[('seforim.db', '*.db'), ('הכל', '*.*')])
            else:
                p = None
        if not p:
            raise RuntimeError('אין seforim.db')
        self.cfg['db_path'] = p
        self.save_cfg()
        self.db = C.SeforimDB(p)
        return self.db

    # ───── פריסה ─────
    def _build(self):
        top = ttk.Frame(self); top.pack(fill='x', padx=10, pady=(8, 2))
        ttk.Button(top, text='הגדרות', command=lambda: SettingsDialog(self)).pack(side='right')
        ttk.Button(top, text='עזרה', command=self.help).pack(side='right', padx=6)
        ttk.Label(top, text='קישורים בין פירושים לספרי הבסיס: לפי מבנה הכותרות, מאומתים מול תוכן העניינים של אוצריא',
                  foreground='#555').pack(side='left')

        self.nb = ttk.Notebook(self); self.nb.pack(fill='both', expand=True, padx=10, pady=6)
        self._tab_create()
        self._tab_repair()
        f3 = ttk.Frame(self.nb); self.nb.add(f3, text='יומן')
        self.txt_log = tk.Text(f3, state='disabled', wrap='word', font=('Consolas', 10), height=10)
        self.txt_log.pack(fill='both', expand=True, padx=6, pady=6)

        bot = ttk.Frame(self); bot.pack(fill='x', padx=10, pady=(0, 8))
        self.progress = ttk.Progressbar(bot, mode='indeterminate', length=120)
        self.progress.pack(side='left')
        self.status = ttk.Label(bot, text='', foreground='#555')
        self.status.pack(side='right')

    # ───── לשונית 1: יצירת קישורים לספר ─────
    def _tab_create(self):
        f = ttk.Frame(self.nb); self.nb.add(f, text='יצירת קישורים לספר')
        pad = dict(padx=8, pady=3)
        r = ttk.Frame(f); r.pack(fill='x', **pad)
        ttk.Label(r, text=L('קובץ הספר (או כמה קבצים)'), width=22, anchor='e').pack(side='right')
        ttk.Button(r, text='בחר קבצים', command=self.pick_sources).pack(side='right', padx=(6, 0))
        self.v_src = tk.StringVar()
        ttk.Entry(r, textvariable=self.v_src, state='readonly').pack(side='right', fill='x', expand=True, padx=6)

        r = ttk.Frame(f); r.pack(fill='x', **pad)
        ttk.Label(r, text=L('ספר יעד'), width=22, anchor='e').pack(side='right')
        self.v_target = tk.StringVar()
        self.cb_target = ttk.Combobox(r, textvariable=self.v_target, width=44, justify='left')
        self.cb_target.pack(side='right', padx=6)
        self.cb_target.bind('<KeyRelease>', self.filter_titles)
        self.v_from_name = tk.BooleanVar(value=True)
        ttk.Checkbutton(r, text='המסכת נקבעת משם הקובץ', variable=self.v_from_name, command=self.sync_target).pack(side='right', padx=8)
        self.lbl_target = ttk.Label(r, text='', foreground='#555')
        self.lbl_target.pack(side='right')

        r = ttk.Frame(f); r.pack(fill='x', **pad)
        ttk.Label(r, text=L('כללי כותרות'), width=22, anchor='e').pack(side='right')
        self.v_preset = tk.StringVar()
        self.cb_preset = ttk.Combobox(r, textvariable=self.v_preset, width=40, state='readonly')
        self.cb_preset.pack(side='right', padx=6)
        self.cb_preset.bind('<<ComboboxSelected>>', self.choose_preset)
        ttk.Button(r, text='ערוך כללים', command=self.edit_rules).pack(side='right', padx=3)
        ttk.Button(r, text='סרוק מבנה בעזרת בינה מלאכותית', command=self.ai_scan).pack(side='right', padx=3)
        ttk.Button(r, text='שמור כפרופיל', command=self.save_profile).pack(side='right', padx=3)
        self.refresh_presets()

        r = ttk.Frame(f); r.pack(fill='x', **pad)
        ttk.Button(r, text='שמור קובץ קישורים', command=self.save_links).pack(side='right')
        ttk.Button(r, text='תצוגה מקדימה', command=self.preview).pack(side='right', padx=6)
        self.lbl_sum = ttk.Label(r, text='', foreground='#333')
        self.lbl_sum.pack(side='right', padx=10)

        pw = ttk.PanedWindow(f, orient='horizontal'); pw.pack(fill='both', expand=True, padx=8, pady=4)
        right = ttk.LabelFrame(pw, text=' מבנה הכותרות בספר '); left = ttk.LabelFrame(pw, text=' תצוגה מקדימה של הקישורים ')
        pw.add(left, weight=3); pw.add(right, weight=2)
        cols = ('ex', 'n', 'pat', 'lv')
        self.t_struct = ttk.Treeview(right, columns=cols, show='headings')
        for c, t, w in (('lv', 'רמה', 40), ('pat', 'תבנית (# = מספר עברי)', 150), ('n', 'כמות', 50), ('ex', 'דוגמה', 150)):
            self.t_struct.heading(c, text=t, anchor='e'); self.t_struct.column(c, width=w, anchor='e')
        self.t_struct.pack(fill='both', expand=True, padx=4, pady=4)
        cols = ('ref', 'target', 'text', 'line')
        self.t_prev = ttk.Treeview(left, columns=cols, show='headings')
        for c, t, w in (('line', 'שורה', 60), ('text', 'תחילת השורה', 280), ('target', 'ספר יעד', 140), ('ref', 'מיקום', 100)):
            self.t_prev.heading(c, text=t, anchor='e'); self.t_prev.column(c, width=w, anchor='e')
        self.t_prev.pack(fill='both', expand=True, padx=4, pady=4)

    def refresh_presets(self):
        names = list(C.PRESETS) + [f'שמור: {n}' for n in self.saved_profiles]
        self.cb_preset['values'] = names
        if not self.v_preset.get():
            self.v_preset.set(names[0])

    def filter_titles(self, _e=None):
        txt = self.v_target.get().strip()
        if len(txt) < 2:
            return
        try:
            db = self.get_db()
        except Exception:
            return
        words = txt.split()
        vals = [t for t in db.titles() if all(w in t for w in words)][:60]
        self.cb_target['values'] = vals

    def sync_target(self):
        self.profile['target_from_name'] = self.v_from_name.get()

    def choose_preset(self, _e=None):
        n = self.v_preset.get()
        p = self.saved_profiles.get(n[5:]) if n.startswith('שמור: ') else C.PRESETS.get(n)
        if p:
            self.profile = copy.deepcopy(p)
            self.v_from_name.set(bool(p.get('target_from_name')))
            if p.get('target'):
                self.v_target.set(p['target'])
            self.log('נטענו כללים: ' + n)

    def current_profile(self):
        p = copy.deepcopy(self.profile)
        t = self.v_target.get().strip()
        p['target_from_name'] = self.v_from_name.get() and not t
        p['target'] = t
        return p

    def pick_sources(self):
        init = os.path.dirname(self.cfg.get('last_src', '')) or None
        ps = filedialog.askopenfilenames(parent=self, title='בחר קבצי ספרים (txt)', filetypes=[('ספרי אוצריא', '*.txt'), ('הכל', '*.*')], initialdir=init)
        if not ps:
            return
        self.sources = list(ps)
        self.cfg['last_src'] = ps[0]
        self.save_cfg()
        self.v_src.set(ps[0] if len(ps) == 1 else f'{len(ps)} קבצים: {os.path.basename(ps[0])} ועוד')
        self.stem0 = os.path.splitext(os.path.basename(ps[0]))[0]
        self.lines0 = C.read_lines(ps[0])
        if C.is_lfs_pointer(self.lines0):
            messagebox.showwarning('', 'הקובץ הוא מצביע git-lfs ולא הספר עצמו. הרץ git lfs checkout.', parent=self)
        self.show_structure()
        self.log(f'נבחרו {len(ps)} קבצים. מבנה: {self.stem0}')

    def show_structure(self):
        self.t_struct.delete(*self.t_struct.get_children())
        s = SA.summarize_book(self.lines0)
        for lv, pats in s['patterns_by_level'].items():
            for p in pats:
                self.t_struct.insert('', 'end', values=(p['examples'][0] if p['examples'] else '', p['n'], p['pattern'], lv))
        self.lbl_sum.config(text=f'{s["total_headings"]} כותרות, {s["total_lines"]} שורות')

    def edit_rules(self):
        d = RulesDialog(self, self.profile, self.lines0)
        self.wait_window(d)
        if d.result:
            self.profile = d.result
            self.log('כללי הכותרות עודכנו')

    def save_profile(self):
        name = self.profile.get('name') or ''
        from tkinter import simpledialog
        name = simpledialog.askstring('שמירת פרופיל', 'שם לפרופיל:', initialvalue=name, parent=self)
        if not name:
            return
        p = self.current_profile()
        p['name'] = name
        self.saved_profiles[name] = p
        save_json(PROFILES_PATH, self.saved_profiles)
        self.refresh_presets()
        self.v_preset.set('שמור: ' + name)
        self.log('הפרופיל נשמר: ' + name)

    # ───── תצוגה מקדימה ויצירה ─────
    def _compute(self, db, prof, sources):
        """רץ בתהליך רקע: לא ניגש למשתני Tk, רק לנתונים שהועברו אליו."""
        res = {}
        for p in sources:
            stem = os.path.splitext(os.path.basename(p))[0]
            L_ = C.read_lines(p)
            if C.is_lfs_pointer(L_):
                res[stem] = ({}, {'notes': ['קובץ git-lfs (מצביע)'], 'unmatched': [], 'headings': 0}, L_, prof)
                continue
            rows, info = C.run_profile(L_, prof, db, stem)
            res[stem] = (rows, info, L_, prof)
        return res

    def preview(self):
        if not self.sources:
            messagebox.showinfo('', 'בחר קודם קובץ ספר.', parent=self); return
        try:
            db = self.get_db()
        except Exception:
            return
        prof, sources = self.current_profile(), list(self.sources)

        def done(res):
            self.rows_by_stem = {s: v[0] for s, v in res.items()}
            self.t_prev.delete(*self.t_prev.get_children())
            total_rows = sum(len(v[0]) for v in res.values())
            total_lines = sum(len(v[2]) for v in res.values())
            shown = 0
            for stem, (rows, info, L_, _p) in res.items():
                for ln, (t, ref) in sorted(rows.items()):
                    if shown >= MAX_PREVIEW:
                        break
                    self.t_prev.insert('', 'end', values=(ref, t, C.strip_tags(L_[ln - 1])[:70], ln)); shown += 1
                for n in info.get('notes', []):
                    self.log(f'{stem}: {n}')
            un = res[next(iter(res))][1].get('unmatched') if res else []
            self.lbl_sum.config(text=f'קושרו {total_rows} מתוך {total_lines} שורות' + (f' (מוצגות {MAX_PREVIEW} הראשונות)' if total_rows > MAX_PREVIEW else ''))
            self.log(f'תצוגה מקדימה: {total_rows} קישורים' + (f'. כותרות בלי כלל: {un[:4]}' if un else ''))
            if total_rows == 0:
                messagebox.showinfo('', 'לא נוצרו קישורים. בדוק את ספר היעד ואת כללי הכותרות (אפשר גם לנסות "סרוק מבנה בעזרת בינה מלאכותית").', parent=self)

        self.run_bg(lambda: self._compute(db, prof, sources), done, msg='מחשב קישורים...')

    def save_links(self):
        if not self.rows_by_stem or not any(self.rows_by_stem.values()):
            messagebox.showinfo('', 'אין קישורים לשמירה. הרץ קודם "תצוגה מקדימה".', parent=self); return
        init = self.cfg.get('out_dir') or None
        path = filedialog.asksaveasfilename(parent=self, title='שמור קובץ קישורים', defaultextension='.csv', initialfile='links.csv',
                                            initialdir=init, filetypes=[('קובץ קישורים', '*.csv')])
        if not path:
            return
        self.cfg['out_dir'] = os.path.dirname(path)
        self.save_cfg()
        ltype = self.profile.get('link_type', 'פירוש')
        merge = os.path.exists(path) and messagebox.askyesno('הקובץ קיים', 'הקובץ כבר קיים.\nלמזג אליו (שורות קודמות של אותו ספר יוחלפו)?\nלחיצה על "לא" תחליף את הקובץ כולו.', parent=self)
        n = 0
        if merge:
            for stem, rows in self.rows_by_stem.items():
                C.merge_into_csv(path, stem, C.links_rows(stem, rows, ltype)); n += len(rows)
        else:
            allrows = []
            for stem, rows in self.rows_by_stem.items():
                allrows.extend(C.links_rows(stem, rows, ltype))
            C.write_csv(path, allrows); n = len(allrows)
        self.log(f'נשמרו {n} קישורים ל-{path}')
        messagebox.showinfo('נשמר', f'נשמרו {n} קישורים.\n\nלייבוא באוצריא: הגדרות, ספרים אישיים, ייבוא קישורים (אפשר לבחור את הקובץ או לשים אותו בתיקייה בשם links.csv).', parent=self)

    # ───── סריקת AI ─────
    def ai_scan(self, feedback=''):
        if not self.sources:
            messagebox.showinfo('', 'בחר קודם קובץ ספר.', parent=self); return
        prov = self.cfg.get('provider', 'gemini')
        key = (self.cfg.get('keys', {}).get(prov) or '').strip()
        model = self.cfg.get('models', {}).get(prov, '')
        if not key or not model:
            if messagebox.askyesno('חיבור לבינה מלאכותית', 'כדי לסרוק מבנה צריך מפתח API ובחירת מודל.\nלפתוח את ההגדרות?', parent=self):
                d = SettingsDialog(self); self.wait_window(d)
            return
        try:
            db = self.get_db()
        except Exception:
            return
        tier = self.cfg.get('tiers', {}).get(prov, 'paid')
        stem, L_ = self.stem0, self.lines0
        hint = self.v_target.get().strip()
        samples = 6 if self.cfg.get('send_samples') else 0

        def work():
            prof, raw = SA.propose_profile(prov, key, model, tier, stem, L_, db, hint, samples, feedback, progress=self.log)
            errs = C.validate_profile(prof) if prof.get('rules') else []
            rows, info = ({}, {})
            if prof.get('rules') and not errs:
                rows, info = C.run_profile(L_, prof, db, stem)
                if len(rows) < 0.03 * len(L_):   # כיסוי נמוך: ניסיון שני אחד עם משוב אוטומטי
                    self.log('הכיסוי נמוך. מבקש מהמודל לתקן...')
                    fb = SA.refine_feedback(prof, rows, info, len(L_))
                    try:
                        p2, raw = SA.propose_profile(prov, key, model, tier, stem, L_, db, hint, samples, fb, progress=self.log)
                        if not C.validate_profile(p2) and p2.get('rules'):
                            r2, i2 = C.run_profile(L_, p2, db, stem)
                            if len(r2) > len(rows):
                                prof, rows, info = p2, r2, i2
                    except AI.AIError as e:
                        self.log('הניסיון השני נכשל: ' + str(e)[:120])
            if errs:
                info = {'notes': errs}
            return prof, rows, info, raw

        def done(res):
            prof, rows, info, raw = res
            d = AIResultDialog(self, prof, len(rows), len(L_), info, raw)
            self.wait_window(d)
            if d.result:
                self.profile = d.result
                self.v_from_name.set(bool(d.result.get('target_from_name')))
                if d.result.get('target'):
                    self.v_target.set(d.result['target'])
                self.log('הכללים שהוצעו הופעלו')
                self.preview()
            elif d.feedback:
                self.ai_scan(d.feedback)

        self.run_bg(work, done, msg='שולח את מבנה הכותרות לבינה המלאכותית...')

    # ───── לשונית 2: בדיקה ותיקון קישורים קיימים ─────
    def _tab_repair(self):
        f = ttk.Frame(self.nb); self.nb.add(f, text='בדיקה ותיקון קישורים קיימים')
        ttk.Label(f, text='אחרי שספרים השתנו (נוספה שורה, שונה סדר), מספרי השורות בקישורים כבר לא מדויקים. הכלי משווה, ומתקן.',
                  foreground='#555').pack(anchor='e', padx=10, pady=(8, 2))
        self.v_books = tk.StringVar(value=self.cfg.get('books_dir', ''))
        self.v_links = tk.StringVar(value=self.cfg.get('links_dir', ''))
        for label, var, fn in (('תיקיית הספרים', self.v_books, self.pick_books), ('תיקיית קבצי הקישורים', self.v_links, self.pick_links)):
            r = ttk.Frame(f); r.pack(fill='x', padx=10, pady=3)
            ttk.Label(r, text=L(label), width=22, anchor='e').pack(side='right')
            ttk.Button(r, text='בחר', command=fn).pack(side='right', padx=(6, 0))
            ttk.Entry(r, textvariable=var, justify='left').pack(side='right', fill='x', expand=True, padx=6)
        r = ttk.Frame(f); r.pack(fill='x', padx=10, pady=6)
        self.b_apply = ttk.Button(r, text='תקן וכתוב (עם גיבוי)', command=self.apply_fix, state='disabled')
        self.b_apply.pack(side='right')
        ttk.Button(r, text='בדוק', command=self.check_links).pack(side='right', padx=6)
        self.only_bad = tk.BooleanVar(value=True)
        ttk.Checkbutton(r, text='הצג רק מה שדורש טיפול', variable=self.only_bad, command=self.fill_report).pack(side='right', padx=10)
        self.lbl_rep = ttk.Label(r, text='', foreground='#333'); self.lbl_rep.pack(side='right', padx=10)
        cols = ('note', 'shift', 'after', 'before', 'status', 'cat', 'book')
        self.t_rep = ttk.Treeview(f, columns=cols, show='headings')
        for c, t, w in (('book', 'ספר', 300), ('cat', 'קטגוריה', 70), ('status', 'סטטוס', 80), ('before', 'שורות לפני', 80),
                        ('after', 'שורות אחרי', 80), ('shift', 'הזזה', 60), ('note', 'הערה', 260)):
            self.t_rep.heading(c, text=t, anchor='e'); self.t_rep.column(c, width=w, anchor='e')
        self.t_rep.tag_configure('upd', background='#fff6dd'); self.t_rep.tag_configure('new', background='#e5f5e5')
        self.t_rep.pack(fill='both', expand=True, padx=10, pady=6)

    def pick_books(self):
        p = filedialog.askdirectory(parent=self, title='תיקיית הספרים (שמכילה את "קבצי קישורים וסדר הדורות")')
        if p:
            self.v_books.set(p)
            guess = os.path.join(p, 'קבצי קישורים וסדר הדורות')
            if os.path.isdir(guess) and not self.v_links.get():
                self.v_links.set(guess)

    def pick_links(self):
        p = filedialog.askdirectory(parent=self, title='תיקיית קבצי הקישורים')
        if p:
            self.v_links.set(p)

    def check_links(self):
        books, links = self.v_books.get().strip(), self.v_links.get().strip()
        if not os.path.isdir(books) or not os.path.isdir(links):
            messagebox.showinfo('', 'בחר תיקיית ספרים ותיקיית קבצי קישורים קיימות.', parent=self); return
        self.cfg['books_dir'], self.cfg['links_dir'] = books, links
        self.save_cfg()
        try:
            db = self.get_db()
        except Exception:
            return
        self.b_apply.state(['disabled'])

        def work():
            return C.plan_repair(books, links, db, progress=self.log)

        def done(plan):
            self.plan = plan
            self.fill_report()
            s = C.summarize_report(plan['report'])
            self.lbl_rep.config(text=' · '.join(f'{k}: {v}' for k, v in s.items()))
            self.log('בדיקה הסתיימה: ' + str(s))
            if s.get('עודכן') or s.get('חדש'):
                self.b_apply.state(['!disabled'])

        self.run_bg(work, done, msg='בודק את הקישורים מול הספרים (עשוי לקחת דקה)...')

    def fill_report(self):
        self.t_rep.delete(*self.t_rep.get_children())
        if not self.plan:
            return
        for stem, cat, status, b, a, sh, note in self.plan['report']:
            if self.only_bad.get() and status in ('תקין', 'ידני', 'לא נבדק'):
                continue
            tag = 'upd' if status == 'עודכן' else 'new' if status == 'חדש' else ''
            self.t_rep.insert('', 'end', values=(note, sh, a, b, status, cat, stem), tags=(tag,))

    def apply_fix(self):
        if not self.plan:
            return
        s = C.summarize_report(self.plan['report'])
        if not messagebox.askyesno('אישור', f'לכתוב את התיקונים?\nעודכנו: {s.get("עודכן", 0)} קבוצות, חדשים: {s.get("חדש", 0)} ספרים.\n\nלפני הכתיבה יישמר גיבוי של כל קבצי הקישורים:\n{BACKUP_DIR}', parent=self):
            return
        links = self.v_links.get().strip()
        new_dir = os.path.join(links, 'קישורים', '13') if os.path.isdir(os.path.join(links, 'קישורים')) else os.path.join(links, 'חדשים')

        def work():
            return C.apply_repair(self.plan, new_dir, BACKUP_DIR, progress=self.log)

        def done(n):
            self.log(f'נכתבו {n} קבצים')
            messagebox.showinfo('הסתיים', f'התיקון נכתב ({n} קבצים).\nגיבוי: {BACKUP_DIR}', parent=self)
            self.b_apply.state(['disabled'])

        self.run_bg(work, done, msg='כותב תיקונים...')

    def help(self):
        messagebox.showinfo('עזרה',
            'יצירת קישורים לספר:\n1. בחר קובץ ספר (txt בפורמט אוצריא) ואת ספר היעד.\n'
            '2. בחר כללי כותרות מוכנים, או "ערוך כללים" להגדרה אישית, או "סרוק מבנה בעזרת בינה מלאכותית" (דורש מפתח API בהגדרות).\n'
            '3. "תצוגה מקדימה" ואז "שמור קובץ קישורים". את הקובץ מייבאים באוצריא: הגדרות, ספרים אישיים, ייבוא קישורים.\n\n'
            'בדיקה ותיקון: משווה קבצי קישורים קיימים לספרים הנוכחיים, מתקן הזזות של שורות, ושומר גיבוי.\n\n'
            'הכללים נשמרים רק במחשב שלך. מפתח ה-API נשמר בקובץ ההגדרות המקומי (בלי הצפנה).', parent=self)


def selftest(log=None):
    """בדיקה בלי מסך: מודולים, פרופילים מובנים, ביטויים והמנוע. התוצאה נכתבת גם לקובץ (ל-EXE בלי קונסולה)."""
    try:
        for name, p in C.PRESETS.items():
            errs = C.validate_profile(p)
            assert not errs, (name, errs)
        assert C.parse_daf_ext('יד, ב') == 'יד:' and C.parse_daf_ext('דף ב ע"א') == 'ב.'
        s = SA.summarize_book(['<h1>x</h1>', '<h2>פרק א</h2>', 'טקסט', '<h3>ב.</h3>', 'עוד'])
        assert s['total_headings'] == 3

        class FakeDB:
            def has_book(self, t): return True
            def valid_refs(self, t): return {'פרק א'}
            def dafset(self, t): return set()
            def toc(self, t): return [(1, None, 0, t)]

        rows, _ = C.run_profile(['<h1>x</h1>', '<h2>פרק א</h2>', 'שורה'], {'target': 'T', 'rules': [
            {'type': 'heading', 'levels': [2, 2], 'regex': '^(.+)$', 'ref': '{1}', 'role': 'ref'}]}, FakeDB(), 'x')
        assert rows == {3: ('T', 'פרק א')}, rows
        assert 'gemini' in AI.PROVIDERS and AI.parse_json_blob('{"a": 1}') == {'a': 1}
        msg = 'SELFTEST OK ' + VERSION
        code = 0
    except Exception:  # noqa
        msg, code = 'SELFTEST FAILED\n' + traceback.format_exc(), 1
    print(msg)
    if log:
        with io.open(log, 'w', encoding='utf-8') as f:
            f.write(msg + '\n')
    return code


def enable_dpi_awareness():
    """טקסט חד במסכים גבוהי רזולוציה ב-Windows (בלי זה Windows מותח את החלון ומטשטש)."""
    try:
        import ctypes
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        try:
            ctypes.windll.user32.SetProcessDPIAware()
        except Exception:
            pass


if __name__ == '__main__':
    if '--selftest' in sys.argv:
        i = sys.argv.index('--selftest')
        sys.exit(selftest(sys.argv[i + 1] if len(sys.argv) > i + 1 else None))
    else:
        enable_dpi_awareness()
        App().mainloop()
