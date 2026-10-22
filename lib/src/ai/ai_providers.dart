// חיבור לספקי AI (Gemini, Claude, OpenAI) בלי חבילות חיצוניות: dart:io בלבד. תרגום של ai_providers.py.
//
//   providers                  תיאור הספקים: שם, כתובת יצירת מפתח, מסלולים, שלבי הסבר
//   AiClient.listModels        המודלים שהמפתח באמת יכול להריץ (גם בודק שהמפתח תקין)
//   AiClient.generate          שליחת בקשה וקבלת טקסט (ניסיונות חוזרים, Retry-After, האטה במסלול חינמי)
//   parseJsonBlob / explainError

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// POST: (כתובת, כותרות, גוף) -> (קוד סטטוס, גוף התשובה). קוד 0 = תקלת רשת (הגוף = ההודעה).
typedef HttpPost = Future<(int, String)> Function(Uri url, Map<String, String> headers, String body);

/// GET באותו מבנה.
typedef HttpGet = Future<(int, String)> Function(Uri url, Map<String, String> headers);

/// שגיאת ספק, בעברית או עם הודעת HTTP גולמית (לשימוש [explainError]).
class AiError implements Exception {
  AiError(this.message, {this.code = 0, this.body = ''});
  final String message;
  final int code;
  final String body;
  @override
  String toString() => message;
}

enum AiProvider {
  gemini('gemini'),
  claude('claude'),
  openai('openai');

  const AiProvider(this.id);
  final String id;

  static AiProvider? byId(String id) {
    for (final p in values) {
      if (p.id == id) return p;
    }
    return null;
  }
}

class ProviderInfo {
  const ProviderInfo({
    required this.label,
    required this.keyUrl,
    required this.billingUrl,
    required this.tiers,
    required this.steps,
    required this.note,
  });
  final String label;
  final String keyUrl;
  final String billingUrl;

  /// מסלולים: (מזהה, תווית). ריק = אין בחירה.
  final List<(String, String)> tiers;
  final List<String> steps;
  final String note;
}

const providers = <AiProvider, ProviderInfo>{
  AiProvider.gemini: ProviderInfo(
    label: 'Gemini (Google)',
    keyUrl: 'https://aistudio.google.com/apikey',
    billingUrl: 'https://aistudio.google.com/billing',
    tiers: [('free', 'חינמי (Free tier)'), ('paid', 'בתשלום (חיוב מופעל)')],
    steps: [
      'לחץ על "פתח את דף יצירת המפתח". יפתח Google AI Studio בדפדפן.',
      'התחבר עם חשבון Google.',
      'לחץ על Create API key, ובחר פרויקט קיים או צור פרויקט חדש.',
      'העתק את המפתח שנוצר (מתחיל ב-AIza) והדבק אותו בשדה "מפתח API" כאן.',
      'בחר מסלול: "חינמי" מתאים לספר או שניים (יש מגבלת בקשות לדקה, והתוכנה תאט לבד). '
          '"בתשלום" דורש להפעיל חיוב בפרויקט ב-Google AI Studio, ומוריד את המגבלות.',
      'לחץ "בדוק מפתח ורענן מודלים", ובחר מודל מהרשימה (flash זול ומהיר, pro חזק יותר).',
    ],
    note: 'המסלול החינמי של Google עשוי להשתמש בתוכן שנשלח לשיפור המוצר. אם הספר רגיש, בחר מסלול בתשלום.',
  ),
  AiProvider.claude: ProviderInfo(
    label: 'Claude (Anthropic)',
    keyUrl: 'https://console.anthropic.com/settings/keys',
    billingUrl: 'https://console.anthropic.com/settings/billing',
    tiers: [],
    steps: [
      'לחץ על "פתח את דף יצירת המפתח". תיפתח Anthropic Console.',
      'התחבר או הירשם. ל-API אין מסלול חינמי: צריך להטעין קרדיט בדף Billing (סכום קטן מספיק).',
      'לחץ Create Key, תן שם למפתח והעתק אותו (מתחיל ב-sk-ant). הוא מוצג פעם אחת.',
      'הדבק את המפתח בשדה "מפתח API" כאן.',
      'לחץ "בדוק מפתח ורענן מודלים", ובחר מודל (haiku זול ומהיר, sonnet מאוזן, opus חזק ויקר).',
    ],
    note: 'מנוי Claude (Pro/Max) אינו כולל שימוש ב-API. ה-API מחויב בנפרד לפי שימוש.',
  ),
  AiProvider.openai: ProviderInfo(
    label: 'OpenAI (ChatGPT)',
    keyUrl: 'https://platform.openai.com/api-keys',
    billingUrl: 'https://platform.openai.com/settings/organization/billing',
    tiers: [],
    steps: [
      'לחץ על "פתח את דף יצירת המפתח". תיפתח OpenAI Platform.',
      'התחבר או הירשם. צריך להטעין קרדיט בדף Billing כדי שה-API יעבוד (מנוי ChatGPT אינו כולל API).',
      'לחץ Create new secret key, תן שם והעתק את המפתח (מתחיל ב-sk-). הוא מוצג פעם אחת.',
      'הדבק את המפתח בשדה "מפתח API" כאן.',
      'לחץ "בדוק מפתח ורענן מודלים", ובחר מודל (mini זול ומהיר).',
    ],
    note: 'ה-API מחויב בנפרד ממנוי ChatGPT.',
  ),
};

const retryCodes = {408, 409, 425, 429, 500, 502, 503, 504, 529};
final _quota = RegExp(r'(quota|billing|exceeded your current|insufficient)', caseSensitive: false);

/// שניות בין בקשות במסלול החינמי של Gemini.
const freeTierGap = 6.5;

// ───────────────────────────── שכבת HTTP אמיתית ─────────────────────────────

Future<(int, String)> _send(String method, Uri url, Map<String, String> headers, String? body) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final req = await c.openUrl(method, url).timeout(const Duration(seconds: 30));
    headers.forEach(req.headers.set);
    if (body != null) {
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      req.add(utf8.encode(body));
    }
    final resp = await req.close().timeout(const Duration(seconds: 120));
    final text = await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 120));
    // Retry-After מהכותרת מועבר בגוף, כדי שהמנגנון הרגיל ימתין כמה שהשרת ביקש
    final ra = resp.headers.value('retry-after');
    if (resp.statusCode >= 400 && ra != null && double.tryParse(ra) != null) {
      return (resp.statusCode, '$text\nretry in $ra');
    }
    return (resp.statusCode, text);
  } on TimeoutException {
    return (0, 'תם הזמן לבקשה');
  } on SocketException catch (e) {
    return (0, e.message);
  } on HttpException catch (e) {
    return (0, e.message);
  } on HandshakeException catch (e) {
    return (0, e.message);
  } finally {
    c.close(force: true);
  }
}

Future<(int, String)> defaultHttpPost(Uri url, Map<String, String> headers, String body) =>
    _send('POST', url, headers, body);

Future<(int, String)> defaultHttpGet(Uri url, Map<String, String> headers) => _send('GET', url, headers, null);

// ───────────────────────────── לקוח ─────────────────────────────

class AiClient {
  AiClient({HttpPost? post, HttpGet? get, Future<void> Function(Duration)? sleep})
    : _post = post ?? defaultHttpPost,
      _get = get ?? defaultHttpGet,
      _sleep = sleep ?? Future.delayed;

  final HttpPost _post;
  final HttpGet _get;
  final Future<void> Function(Duration) _sleep;

  /// זמן הבקשה האחרונה (להאטה במסלול החינמי); משותף לכל הלקוחות.
  static DateTime _lastCall = DateTime.fromMillisecondsSinceEpoch(0);

  static String _errMessage(int code, String body) {
    var msg = body;
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final e = j['error'];
        msg = e is Map ? '${e['message'] ?? body}' : (e != null ? '$e' : body);
      }
    } on FormatException {
      // גוף שאינו JSON
    }
    return 'HTTP $code: ${msg.length > 400 ? msg.substring(0, 400) : msg}';
  }

  Future<Object?> _request(Uri url, Map<String, String> headers, [Object? payload]) async {
    final (code, text) = payload == null ? await _get(url, headers) : await _post(url, headers, jsonEncode(payload));
    if (code == 0) throw AiError('תקלת רשת: $text');
    if (code < 200 || code >= 300) throw AiError(_errMessage(code, text), code: code, body: text);
    try {
      return jsonDecode(text);
    } on FormatException {
      throw AiError('תשובה לא תקינה מהשרת של הספק', code: code, body: text);
    }
  }

  static int? _retryAfter(AiError e) {
    for (final pat in [RegExp(r'"retryDelay"\s*:\s*"?([\d.]+)s'), RegExp(r'retry in ([\d.]+)')]) {
      final m = pat.firstMatch(e.body);
      if (m != null) return (double.parse(m[1]!).toInt() + 2).clamp(2, 90);
    }
    return null;
  }

  Future<Map> _postRetry(
    Uri url,
    Map<String, String> headers,
    Object payload, {
    int retries = 4,
    void Function(String)? progress,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        final r = await _request(url, headers, payload);
        return r is Map ? r : throw AiError('תשובה לא צפויה מהספק');
      } on AiError catch (e) {
        if ((e.code != 0 && !retryCodes.contains(e.code)) || attempt == retries) rethrow;
        if (_quota.hasMatch(e.message) && !e.body.toLowerCase().contains('retry')) rethrow; // חריגת מכסה אמיתית
        final wait = _retryAfter(e) ?? (3 * (1 << attempt)).clamp(0, 45);
        final m = e.message;
        progress?.call('הספק עמוס (${m.length > 70 ? m.substring(0, 70) : m}). ממתין $wait שניות ומנסה שוב');
        await _sleep(Duration(seconds: wait));
      }
    }
  }

  // ─────────────── רשימת מודלים ───────────────

  Future<List<String>> _modelsGemini(String key) async {
    final data = await _request(
      Uri.parse('https://generativelanguage.googleapis.com/v1beta/models?pageSize=200&key=${Uri.encodeQueryComponent(key)}'),
      {},
    );
    final bad = RegExp(r'(image|tts|audio|embedding|vision|live|native|thinking|robotics)');
    final out = <String>{};
    for (final m in (data is Map ? data['models'] as List? : null) ?? const []) {
      if (m is! Map) continue;
      final meth = m['supportedGenerationMethods'];
      if (meth is! List || !meth.contains('generateContent')) continue;
      final n = '${m['name']}'.split('/').last;
      if (!n.startsWith('gemini-') || bad.hasMatch(n)) continue;
      out.add(n);
    }
    // מיון: גרסה יורדת, יציב לפני preview/exp, flash לפני pro, ואז לפי שם
    (double, int, int) rank(String n) {
      final mm = RegExp(r'gemini-(\d+(?:\.\d+)?)').firstMatch(n);
      final ver = mm != null ? double.parse(mm[1]!) : 0.0;
      final kind = n.contains('flash') ? 0 : (n.contains('pro') ? 1 : 2);
      return (-ver, (n.contains('preview') || n.contains('exp')) ? 1 : 0, kind);
    }

    return out.toList()..sort((a, b) {
      final ra = rank(a), rb = rank(b);
      var c = ra.$1.compareTo(rb.$1);
      if (c == 0) c = ra.$2.compareTo(rb.$2);
      if (c == 0) c = ra.$3.compareTo(rb.$3);
      return c != 0 ? c : a.compareTo(b);
    });
  }

  Future<List<String>> _modelsClaude(String key) async {
    final data = await _request(Uri.parse('https://api.anthropic.com/v1/models?limit=100'), {
      'x-api-key': key,
      'anthropic-version': '2023-06-01',
    });
    return [
      for (final m in (data is Map ? data['data'] as List? : null) ?? const [])
        if (m is Map && m['id'] is String) m['id'] as String,
    ];
  }

  Future<List<String>> _modelsOpenai(String key) async {
    final data = await _request(Uri.parse('https://api.openai.com/v1/models'), {'Authorization': 'Bearer $key'});
    final bad = RegExp(r'(audio|realtime|image|tts|transcribe|embedding|moderation|instruct|search|codex|vision)');
    final out = <String>{
      for (final m in (data is Map ? data['data'] as List? : null) ?? const [])
        if (m is Map && m['id'] is String && RegExp(r'^(gpt-|o\d)').hasMatch(m['id']) && !bad.hasMatch(m['id']))
          m['id'] as String,
    };
    return out.toList()..sort((a, b) => b.compareTo(a));
  }

  /// רשימת המודלים. זורק [AiError] אם המפתח לא תקין.
  Future<List<String>> listModels(AiProvider provider, String key) {
    key = key.trim();
    if (key.isEmpty) throw AiError('לא הוזן מפתח API');
    return switch (provider) {
      AiProvider.gemini => _modelsGemini(key),
      AiProvider.claude => _modelsClaude(key),
      AiProvider.openai => _modelsOpenai(key),
    };
  }

  // ─────────────── שליחת בקשה ───────────────

  /// שולח בקשה אחת ומחזיר את הטקסט שהמודל החזיר. [tier]: 'free' מאט במסלול החינמי של Gemini.
  Future<String> generate(
    AiProvider provider,
    String key,
    String model,
    String system,
    String user, {
    int maxTokens = 4000,
    String tier = 'paid',
    bool jsonMode = false,
    void Function(String)? progress,
  }) async {
    key = key.trim();
    if (key.isEmpty) throw AiError('לא הוזן מפתח API');
    if (model.isEmpty) throw AiError('לא נבחר מודל');
    switch (provider) {
      case AiProvider.gemini:
        if (tier == 'free') {
          final gap = freeTierGap - DateTime.now().difference(_lastCall).inMilliseconds / 1000;
          if (gap > 0) await _sleep(Duration(milliseconds: (gap * 1000).round()));
        }
        final data = await _postRetry(
          Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=${Uri.encodeQueryComponent(key)}',
          ),
          {},
          {
            'systemInstruction': {
              'parts': [
                {'text': system},
              ],
            },
            'contents': [
              {
                'role': 'user',
                'parts': [
                  {'text': user},
                ],
              },
            ],
            'generationConfig': {
              'temperature': 0.1,
              'maxOutputTokens': maxTokens,
              if (jsonMode) 'responseMimeType': 'application/json',
            },
          },
          progress: progress,
        );
        _lastCall = DateTime.now();
        try {
          final parts = (data['candidates'] as List).first['content']['parts'] as List;
          return parts.map((p) => (p as Map)['text'] ?? '').join();
        } catch (_) {
          throw AiError('המודל לא החזיר תשובה (ייתכן שנחסם). נסה מודל אחר.');
        }
      case AiProvider.claude:
        final data = await _postRetry(
          Uri.parse('https://api.anthropic.com/v1/messages'),
          {'x-api-key': key, 'anthropic-version': '2023-06-01'},
          {
            'model': model,
            'max_tokens': maxTokens,
            'temperature': 0.1,
            'system': system,
            'messages': [
              {'role': 'user', 'content': user},
            ],
          },
          progress: progress,
        );
        return [
          for (final b in (data['content'] as List?) ?? const [])
            if (b is Map && b['type'] == 'text') '${b['text'] ?? ''}',
        ].join();
      case AiProvider.openai:
        final data = await _postRetry(
          Uri.parse('https://api.openai.com/v1/chat/completions'),
          {'Authorization': 'Bearer $key'},
          {
            'model': model,
            'messages': [
              {'role': 'system', 'content': system},
              {'role': 'user', 'content': user},
            ],
            if (jsonMode) 'response_format': {'type': 'json_object'},
          },
          progress: progress,
        );
        try {
          return '${(data['choices'] as List).first['message']['content'] ?? ''}';
        } catch (_) {
          throw AiError('המודל לא החזיר תשובה. נסה מודל אחר.');
        }
    }
  }
}

/// ברירת מחדל זולה ומהירה מתוך הרשימה ('' אם ריקה).
String defaultModel(AiProvider provider, List<String> models) {
  final prefs = switch (provider) {
    AiProvider.gemini => ['flash'],
    AiProvider.claude => ['haiku', 'sonnet'],
    AiProvider.openai => ['mini'],
  };
  for (final p in prefs) {
    for (final m in models) {
      if (m.contains(p) && !m.contains('preview') && !m.contains('exp')) return m;
    }
  }
  return models.isEmpty ? '' : models.first;
}

final _fence = RegExp(r'^```(?:json)?|```$', multiLine: true);

/// מחלץ אובייקט JSON מתשובת מודל (גם בתוך בלוק ```json).
Map<String, dynamic> parseJsonBlob(String text) {
  text = text.trim().replaceAll(_fence, '').trim();
  final i = text.indexOf('{'), j = text.lastIndexOf('}');
  if (i == -1 || j == -1 || j < i) throw AiError('המודל לא החזיר JSON');
  try {
    final r = jsonDecode(text.substring(i, j + 1));
    if (r is Map<String, dynamic>) return r;
    throw AiError('המודל לא החזיר אובייקט JSON');
  } on FormatException catch (e) {
    throw AiError('ה-JSON של המודל פגום: ${e.message}');
  }
}

/// הסבר בעברית על שגיאת ספק ומה אפשר לעשות ('' אם אין הסבר).
String explainError(Object msg) {
  final s = msg.toString();
  final low = s.toLowerCase();
  if (s.contains('429') || low.contains('quota') || low.contains('rate')) {
    return 'חרגת ממכסת הבקשות של הספק (לרוב מגבלת המסלול החינמי).\n\n'
        'מה אפשר לעשות:\n• להמתין דקה ולנסות שוב.\n• לבחור מודל אחר ("רענן מודלים"): המכסה נמדדת לכל מודל.\n'
        '• לעבור למסלול בתשלום, או לספק אחר.';
  }
  if (low.contains('insufficient') || low.contains('billing') || low.contains('credit')) {
    return 'אין קרדיט או חיוב פעיל בחשבון. צריך להטעין קרדיט או להפעיל חיוב בדף ה-Billing של הספק.';
  }
  if (s.contains('503') || low.contains('high demand') || low.contains('overload')) {
    return 'השרת של הספק עמוס כרגע. נסה שוב בעוד כמה דקות, או בחר מודל אחר.';
  }
  if (s.contains('404')) {
    return 'המודל שנבחר אינו זמין למפתח הזה. לחץ "בדוק מפתח ורענן מודלים" ובחר מהרשימה.';
  }
  if (s.contains('401') ||
      s.contains('403') ||
      low.contains('api key') ||
      low.contains('api_key') ||
      low.contains('invalid')) {
    return 'המפתח נדחה. ודא שהעתקת אותו במלואו, ושהוא שייך לספק שנבחר (מפתח של Google לא יעבוד עם Claude ולהיפך).';
  }
  if (s.contains('רשת')) {
    return 'אין חיבור לשרת של הספק. בדוק חיבור לאינטרנט (בחלק מהרשתות הסינון חוסם את האתרים האלה).';
  }
  return '';
}
