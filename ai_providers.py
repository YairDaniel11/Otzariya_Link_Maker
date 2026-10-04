# -*- coding: utf-8 -*-
"""
חיבור לספקי AI (Claude, Gemini, OpenAI) בלי ספריות חיצוניות: רק urllib.

  PROVIDERS               תיאור הספקים: שם, כתובת יצירת מפתח, מסלולים, שלבי הסבר
  list_models(p, key)     המודלים שהמפתח באמת יכול להריץ (גם בודק שהמפתח תקין)
  generate(p, key, ...)   שליחת בקשה וקבלת טקסט (עם ניסיונות חוזרים, והאטה במסלול חינמי)
  explain_error(msg)      הסבר בעברית ומה לעשות
"""
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request

PROVIDERS = {
    'gemini': {
        'label': 'Gemini (Google)',
        'key_url': 'https://aistudio.google.com/apikey',
        'billing_url': 'https://aistudio.google.com/billing',
        'tiers': [('free', 'חינמי (Free tier)'), ('paid', 'בתשלום (חיוב מופעל)')],
        'steps': [
            'לחץ על "פתח את דף יצירת המפתח". יפתח Google AI Studio בדפדפן.',
            'התחבר עם חשבון Google.',
            'לחץ על Create API key, ובחר פרויקט קיים או צור פרויקט חדש.',
            'העתק את המפתח שנוצר (מתחיל ב-AIza) והדבק אותו בשדה "מפתח API" כאן.',
            'בחר מסלול: "חינמי" מתאים לספר או שניים (יש מגבלת בקשות לדקה, והתוכנה תאט לבד). '
            '"בתשלום" דורש להפעיל חיוב בפרויקט ב-Google AI Studio, ומוריד את המגבלות.',
            'לחץ "בדוק מפתח ורענן מודלים", ובחר מודל מהרשימה (flash זול ומהיר, pro חזק יותר).',
        ],
        'note': 'המסלול החינמי של Google עשוי להשתמש בתוכן שנשלח לשיפור המוצר. אם הספר רגיש, בחר מסלול בתשלום.',
    },
    'claude': {
        'label': 'Claude (Anthropic)',
        'key_url': 'https://console.anthropic.com/settings/keys',
        'billing_url': 'https://console.anthropic.com/settings/billing',
        'tiers': [],
        'steps': [
            'לחץ על "פתח את דף יצירת המפתח". תיפתח Anthropic Console.',
            'התחבר או הירשם. ל-API אין מסלול חינמי: צריך להטעין קרדיט בדף Billing (סכום קטן מספיק).',
            'לחץ Create Key, תן שם למפתח והעתק אותו (מתחיל ב-sk-ant). הוא מוצג פעם אחת.',
            'הדבק את המפתח בשדה "מפתח API" כאן.',
            'לחץ "בדוק מפתח ורענן מודלים", ובחר מודל (haiku זול ומהיר, sonnet מאוזן, opus חזק ויקר).',
        ],
        'note': 'מנוי Claude (Pro/Max) אינו כולל שימוש ב-API. ה-API מחויב בנפרד לפי שימוש.',
    },
    'openai': {
        'label': 'OpenAI (ChatGPT)',
        'key_url': 'https://platform.openai.com/api-keys',
        'billing_url': 'https://platform.openai.com/settings/organization/billing',
        'tiers': [],
        'steps': [
            'לחץ על "פתח את דף יצירת המפתח". תיפתח OpenAI Platform.',
            'התחבר או הירשם. צריך להטעין קרדיט בדף Billing כדי שה-API יעבוד (מנוי ChatGPT אינו כולל API).',
            'לחץ Create new secret key, תן שם והעתק את המפתח (מתחיל ב-sk-). הוא מוצג פעם אחת.',
            'הדבק את המפתח בשדה "מפתח API" כאן.',
            'לחץ "בדוק מפתח ורענן מודלים", ובחר מודל (mini זול ומהיר).',
        ],
        'note': 'ה-API מחויב בנפרד ממנוי ChatGPT.',
    },
}

RETRY_CODES = {408, 409, 425, 429, 500, 502, 503, 504, 529}
_QUOTA = re.compile(r'(quota|billing|exceeded your current|insufficient)', re.I)
_last_call = {'t': 0.0}
FREE_TIER_GAP = 6.5   # שניות בין בקשות במסלול החינמי של Gemini


class AIError(RuntimeError):
    pass


def _http(url, payload=None, headers=None, timeout=120, method=None):
    data = json.dumps(payload).encode('utf-8') if payload is not None else None
    h = {'Content-Type': 'application/json'}
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=h, method=method or ('POST' if data else 'GET'))
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode('utf-8'))
    except urllib.error.HTTPError as e:
        body = ''
        try:
            body = e.read().decode('utf-8', 'replace')
            msg = json.loads(body).get('error', {})
            msg = msg.get('message', body) if isinstance(msg, dict) else str(msg)
        except Exception:
            msg = body
        err = AIError(f'HTTP {e.code}: {msg[:400]}')
        err.code, err.body = e.code, body
        raise err from None
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        err = AIError(f'תקלת רשת: {e}')
        err.code, err.body = 0, ''
        raise err from None


def _retry_after(e):
    m = None
    for pat in (r'"retryDelay"\s*:\s*"?([\d.]+)s', r'retry in ([\d.]+)'):
        m = re.search(pat, getattr(e, 'body', '') or '')
        if m:
            return min(max(int(float(m.group(1))) + 2, 2), 90)
    return None


def _post(url, payload, headers, retries=4, progress=None, timeout=120):
    last = None
    for attempt in range(retries + 1):
        try:
            return _http(url, payload, headers, timeout)
        except AIError as e:
            last = e
            code = getattr(e, 'code', 0)
            if (code and code not in RETRY_CODES) or attempt == retries:
                raise
            if _QUOTA.search(str(e)) and 'retry' not in (getattr(e, 'body', '') or '').lower():
                raise  # חריגת מכסה אמיתית: אין טעם להמתין
            wait = _retry_after(e) or min(2 ** attempt * 3, 45)
            if progress:
                progress(f'הספק עמוס ({str(e)[:70]}). ממתין {wait} שניות ומנסה שוב')
            time.sleep(wait)
    raise last


# ───────────────────────────── רשימת מודלים ─────────────────────────────
def _models_gemini(key):
    data = _http('https://generativelanguage.googleapis.com/v1beta/models?pageSize=200&key=' + urllib.parse.quote(key))
    out = []
    for m in data.get('models', []):
        if 'generateContent' not in (m.get('supportedGenerationMethods') or []):
            continue
        n = m['name'].split('/')[-1]
        if not n.startswith('gemini-') or re.search(r'(image|tts|audio|embedding|vision|live|native|thinking|robotics)', n):
            continue
        out.append(n)

    def rank(n):
        mm = re.match(r'gemini-(\d+(?:\.\d+)?)', n)
        ver = float(mm.group(1)) if mm else 0.0
        kind = 0 if 'flash' in n else 1 if 'pro' in n else 2
        return (-ver, 1 if ('preview' in n or 'exp' in n) else 0, kind, n)

    return sorted(set(out), key=rank)


def _models_claude(key):
    data = _http('https://api.anthropic.com/v1/models?limit=100', headers={'x-api-key': key, 'anthropic-version': '2023-06-01'})
    return [m['id'] for m in data.get('data', [])]


def _models_openai(key):
    data = _http('https://api.openai.com/v1/models', headers={'Authorization': 'Bearer ' + key})
    out = [m['id'] for m in data.get('data', [])]
    out = [n for n in out if re.match(r'(gpt-|o\d)', n)
           and not re.search(r'(audio|realtime|image|tts|transcribe|embedding|moderation|instruct|search|codex|vision)', n)]
    return sorted(set(out), reverse=True)


def list_models(provider, key):
    """מחזיר רשימת מודלים. זורק AIError אם המפתח לא תקין."""
    key = (key or '').strip()
    if not key:
        raise AIError('לא הוזן מפתח API')
    return {'gemini': _models_gemini, 'claude': _models_claude, 'openai': _models_openai}[provider](key)


def default_model(provider, models):
    """ברירת מחדל זולה ומהירה מתוך הרשימה."""
    prefs = {'gemini': ('flash',), 'claude': ('haiku', 'sonnet'), 'openai': ('mini',)}[provider]
    for p in prefs:
        for m in models:
            if p in m and 'preview' not in m and 'exp' not in m:
                return m
    return models[0] if models else ''


# ───────────────────────────── שליחת בקשה ─────────────────────────────
def generate(provider, key, model, system, user, max_tokens=4000, tier='paid', json_mode=False, progress=None):
    """שולח בקשה אחת ומחזיר את הטקסט שהמודל החזיר."""
    key = (key or '').strip()
    if not key:
        raise AIError('לא הוזן מפתח API')
    if not model:
        raise AIError('לא נבחר מודל')
    if provider == 'gemini':
        if tier == 'free':  # מסלול חינמי: מגבלת בקשות לדקה, מאטים מראש
            gap = FREE_TIER_GAP - (time.time() - _last_call['t'])
            if gap > 0:
                time.sleep(gap)
        cfg = {'temperature': 0.1, 'maxOutputTokens': max_tokens}
        if json_mode:
            cfg['responseMimeType'] = 'application/json'
        data = _post(f'https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key=' + urllib.parse.quote(key),
                     {'systemInstruction': {'parts': [{'text': system}]},
                      'contents': [{'role': 'user', 'parts': [{'text': user}]}],
                      'generationConfig': cfg}, {}, progress=progress)
        _last_call['t'] = time.time()
        try:
            return ''.join(p.get('text', '') for p in data['candidates'][0]['content']['parts'])
        except (KeyError, IndexError):
            raise AIError('המודל לא החזיר תשובה (ייתכן שנחסם). נסה מודל אחר.') from None
    if provider == 'claude':
        data = _post('https://api.anthropic.com/v1/messages',
                     {'model': model, 'max_tokens': max_tokens, 'temperature': 0.1, 'system': system,
                      'messages': [{'role': 'user', 'content': user}]},
                     {'x-api-key': key, 'anthropic-version': '2023-06-01'}, progress=progress)
        return ''.join(b.get('text', '') for b in data.get('content', []) if b.get('type') == 'text')
    if provider == 'openai':
        payload = {'model': model, 'messages': [{'role': 'system', 'content': system}, {'role': 'user', 'content': user}]}
        if json_mode:
            payload['response_format'] = {'type': 'json_object'}
        data = _post('https://api.openai.com/v1/chat/completions', payload, {'Authorization': 'Bearer ' + key}, progress=progress)
        return data['choices'][0]['message']['content'] or ''
    raise AIError('ספק לא מוכר: ' + provider)


def parse_json_blob(text):
    text = (text or '').strip()
    text = re.sub(r'^```(?:json)?|```$', '', text, flags=re.M).strip()
    i, j = text.find('{'), text.rfind('}')
    if i == -1 or j == -1:
        raise AIError('המודל לא החזיר JSON')
    try:
        return json.loads(text[i:j + 1])
    except json.JSONDecodeError as e:
        raise AIError(f'ה-JSON של המודל פגום: {e}') from None


def explain_error(msg):
    """הסבר בעברית על שגיאת ספק, ומה אפשר לעשות."""
    s = str(msg)
    low = s.lower()
    if '429' in s or 'quota' in low or 'rate' in low:
        return ('חרגת ממכסת הבקשות של הספק (לרוב מגבלת המסלול החינמי).\n\n'
                'מה אפשר לעשות:\n• להמתין דקה ולנסות שוב.\n• לבחור מודל אחר ("רענן מודלים"): המכסה נמדדת לכל מודל.\n'
                '• לעבור למסלול בתשלום, או לספק אחר.')
    if 'insufficient' in low or 'billing' in low or 'credit' in low:
        return 'אין קרדיט או חיוב פעיל בחשבון. צריך להטעין קרדיט או להפעיל חיוב בדף ה-Billing של הספק.'
    if '503' in s or 'high demand' in low or 'overload' in low:
        return 'השרת של הספק עמוס כרגע. נסה שוב בעוד כמה דקות, או בחר מודל אחר.'
    if '404' in s:
        return 'המודל שנבחר אינו זמין למפתח הזה. לחץ "בדוק מפתח ורענן מודלים" ובחר מהרשימה.'
    if '401' in s or '403' in s or 'api key' in low or 'api_key' in low or 'invalid' in low:
        return 'המפתח נדחה. ודא שהעתקת אותו במלואו, ושהוא שייך לספק שנבחר (מפתח של Google לא יעבוד עם Claude ולהיפך).'
    if 'רשת' in s:
        return 'אין חיבור לשרת של הספק. בדוק חיבור לאינטרנט (בחלק מהרשתות הסינון חוסם את האתרים האלה).'
    return ''
