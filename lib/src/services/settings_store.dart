import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:path/path.dart' as p;

/// הגדרות התוכנה, נשמרות בקובץ JSON בתיקיית המשתמש (פר-מחשב).
class Settings {
  String officialDb = '';
  String lastBooksDir = '';
  String lastLinksDir = '';
  String lastSaveDir = '';
  String author = '';
  ThemeMode themeMode = ThemeMode.system;

  /// בינה מלאכותית (אופציונלי): claude / gemini / openai.
  String aiProvider = 'gemini';
  String aiTier = 'free';
  Map<String, String> aiKeys = {};
  Map<String, String> aiModels = {};

  Map<String, Object?> toJson() => {
    'officialDb': officialDb,
    'lastBooksDir': lastBooksDir,
    'lastLinksDir': lastLinksDir,
    'lastSaveDir': lastSaveDir,
    'author': author,
    'themeMode': themeMode.name,
    'aiProvider': aiProvider,
    'aiTier': aiTier,
    'aiKeys': aiKeys,
    'aiModels': aiModels,
  };

  static Settings fromJson(Map<String, Object?> j) {
    final s = Settings();
    String str(String k, String d) => j[k] is String ? j[k] as String : d;
    Map<String, String> map(String k) {
      final m = j[k];
      return m is Map ? {for (final e in m.entries) '${e.key}': '${e.value}'} : {};
    }

    s.officialDb = str('officialDb', '');
    s.lastBooksDir = str('lastBooksDir', '');
    s.lastLinksDir = str('lastLinksDir', '');
    s.lastSaveDir = str('lastSaveDir', '');
    s.author = str('author', '');
    s.themeMode = ThemeMode.values.firstWhere((m) => m.name == j['themeMode'], orElse: () => ThemeMode.system);
    s.aiProvider = str('aiProvider', 'gemini');
    s.aiTier = str('aiTier', 'free');
    s.aiKeys = map('aiKeys');
    s.aiModels = map('aiModels');
    return s;
  }
}

class SettingsStore {
  SettingsStore._();

  static String configDir() {
    final env = Platform.environment;
    if (Platform.isWindows && env['APPDATA'] != null) return p.join(env['APPDATA']!, 'OtzariaLinker');
    return p.join(env['HOME'] ?? '.', 'Library', 'Application Support', 'OtzariaLinker');
  }

  static File get _file => File(p.join(configDir(), 'settings.json'));

  static Future<Settings> load() async {
    try {
      final f = _file;
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map<String, Object?>) return Settings.fromJson(j);
      }
    } catch (_) {}
    return Settings();
  }

  static Future<void> save(Settings s) async {
    final f = _file;
    await f.parent.create(recursive: true);
    // כתיבה לקובץ זמני והחלפה: הגדרות לא נהרסות אם התוכנה נסגרת באמצע
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(s.toJson()));
    await tmp.rename(f.path);
  }
}
