# -*- coding: utf-8 -*-
"""
סריקת מבנה ספר בעזרת AI והצעת כללי יצירה (פרופיל) לפי הכותרות.

הזרימה:  summarize_book -> build_prompt -> (AI) -> parse -> validate_profile -> run_profile (בדיקה יבשה)
המודל מקבל רק תקציר של הכותרות (ואופציונלית כמה שורות לדוגמה), לא את הספר.
"""
import collections
import json
import re

import ai_providers as AI
import linker_core as C

SYSTEM_PROMPT = """You analyse the heading structure of a Hebrew Torah book file (Otzaria format) and propose rules that link each
content line to a location in a BASE book (the book the file comments on).

The file uses HTML heading tags <h1>..<h6>. Every non-heading, non-empty line under a heading is linked to the
location that the nearest relevant heading names, inside the base book's table of contents (TOC).

Return ONLY one JSON object (no markdown, no commentary) with this schema:
{
  "name": "short description",
  "target": "exact title of the base book as it appears in the library TOC list I give you, or \\"\\" if the target comes from the file name / headings",
  "target_from_name": true|false,         // true when the tractate (masechet) is named in the file name
  "link_type": "פירוש",
  "validate": true,
  "rules": [ ... ]
}
Rule types:
  {"type":"daf","levels":[2,6],"formats":["std","ext"]}
      headings that are a Talmud page: "ב." / "ג:" (std), or "יד, ב" / "דף ב ע\\"א" (ext). Target = a Talmud tractate.
  {"type":"heading","levels":[2,2],"regex":"^(פרק [א-ת]+)$","ref":"{1}","role":"ref"}
      a heading matching the regex sets the location. {1},{2} are regex groups. It must equal a TOC entry text of the target book.
      role "chapter" sets a chapter only (no lines are linked by it); role "sub" builds the location from the last chapter,
      e.g. {"type":"heading","levels":[3,3],"regex":"^סימן ([א-ת]+)$","ref":"{chapter} הלכה {1}","role":"sub"}
      Combined location strings must match the TOC exactly (compare with the TOC sample I give you).
  {"type":"target_switch","levels":[2,2],"regex":"^מסכת (.+?)$"}
      a heading that changes the target book (e.g. a file with several tractates).
  {"type":"anchor"}
      lines that start with "בדף X." set the page (use only if headings give no location).

Rules: use ONLY heading levels that exist in the summary. Prefer the simplest rule set. Regexes are Python regexes applied to the
heading text without tags. Hebrew numerals look like א, ב, יד, קס. If the headings carry no location that exists in the target TOC,
return {"name":"אין מבנה מתאים","rules":[],"reason":"..."} and explain in "reason" (Hebrew)."""


def _pattern(text):
    t = re.sub(r'\d+', '0', text)
    t = re.sub(r'(?<![א-ת])[א-ת]{1,3}(?![א-ת])', '#', t)  # מספר עברי (גימטריה) קצר
    return t[:50]


def summarize_book(lines, sample_lines=0):
    heads = []
    for i, l in enumerate(lines, 1):
        m = C.HEAD_LOOSE.match(l.strip())
        if m:
            heads.append((i, int(m.group(1)), C.strip_tags(m.group(2))))
    per_level = collections.defaultdict(lambda: collections.OrderedDict())
    for _, lv, tx in heads:
        d = per_level[lv].setdefault(_pattern(tx), {'n': 0, 'examples': []})
        d['n'] += 1
        if len(d['examples']) < 3:
            d['examples'].append(tx[:50])
    summary = {
        'total_lines': len(lines), 'total_headings': len(heads),
        'levels': {str(lv): sum(v['n'] for v in pats.values()) for lv, pats in sorted(per_level.items())},
        'patterns_by_level': {str(lv): [dict(pattern=p, **v) for p, v in list(pats.items())[:14]]
                              for lv, pats in sorted(per_level.items())},
        'first_headings': [(lv, tx[:50]) for _, lv, tx in heads[:30]],
    }
    if sample_lines:
        body = [l.strip() for l in lines[1:] if l.strip() and not l.startswith('<h')][:sample_lines]
        summary['sample_content_lines'] = [b[:140] for b in body]
    return summary


def candidate_titles(db, stem, limit=25):
    """כותרות מ-seforim.db שנראות קשורות לשם הקובץ, כדי לעזור למודל לבחור ספר יעד."""
    if not db:
        return []
    words = [w for w in re.split(r'[\s\-_,()"\'״׳]+', stem) if len(w) >= 3 and w not in ('מסכת', 'על', 'ספר')]
    scored = []
    for t in db.titles():
        s = sum(1 for w in words if w in t)
        if s:
            scored.append((-s, len(t), t))
    scored.sort()
    return [t for _, _, t in scored[:limit]]


def build_prompt(stem, summary, db=None, target_hint='', feedback=''):
    parts = [f'File name: {stem}', 'Heading summary (JSON):', json.dumps(summary, ensure_ascii=False, indent=1)]
    cands = candidate_titles(db, stem)
    if target_hint:
        t = db.toc_summary(target_hint) if db else None
        parts.append(f'The user says the target book is "{target_hint}".')
        if t:
            parts.append('Its TOC (level -> text), first entries:\n' + json.dumps(t, ensure_ascii=False))
        else:
            parts.append('(this title was not found in the library)')
    if cands:
        parts.append('Library titles that may be the target:\n' + json.dumps(cands, ensure_ascii=False))
        if db and not target_hint:
            for c in cands[:3]:
                t = db.toc_summary(c, limit=8)
                if t:
                    parts.append(f'TOC of "{c}": ' + json.dumps(t, ensure_ascii=False))
    if feedback:
        parts.append('Feedback on the previous attempt:\n' + feedback)
    return '\n\n'.join(parts)


def propose_profile(provider, key, model, tier, stem, lines, db=None, target_hint='', sample_lines=0,
                    feedback='', progress=None):
    """מבקש מהמודל פרופיל. מחזיר (profile, raw_text). זורק AI.AIError על כשל."""
    summary = summarize_book(lines, sample_lines)
    prompt = build_prompt(stem, summary, db, target_hint, feedback)
    raw = AI.generate(provider, key, model, SYSTEM_PROMPT, prompt, max_tokens=3000, tier=tier,
                      json_mode=True, progress=progress)
    prof = AI.parse_json_blob(raw)
    if target_hint and not prof.get('target') and not prof.get('target_from_name'):
        prof['target'] = target_hint
    return prof, raw


def refine_feedback(profile, rows, info, n_lines):
    """משוב אוטומטי למודל כשהפרופיל לא מכסה מספיק שורות."""
    cov = 100.0 * len(rows) / max(1, n_lines)
    msg = f'The proposed profile linked {len(rows)} of {n_lines} lines ({cov:.1f}%).'
    if info.get('unmatched'):
        msg += ' Headings that no rule matched (text, count): ' + json.dumps(info['unmatched'], ensure_ascii=False)
    if info.get('notes'):
        msg += ' Notes: ' + '; '.join(info['notes'])
    msg += ' Fix the rules so that the location strings match the target TOC exactly.'
    return msg
