import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:path/path.dart' as p;

/// הגדרות התוכנה, נשמרות בקובץ JSON בתיקיית המשתמש (פר-מחשב).
class Settings {
  String booksDir = '';
  String officialDb = '';
  String outDir = '';
  String outName = '';
  String displayName = 'הספרייה שלי';
  String author = '';
  String libraryId = '';
  bool autoLinks = true;
  bool dhLines = true;
  bool compress = true;
  ThemeMode themeMode = ThemeMode.system;

  /// שם ספר -> יעד שנבחר ידנית ('' = בלי קישורים).
  Map<String, String> overrides = {};

  String get outPath =>
      outDir.isEmpty || outName.isEmpty ? '' : p.join(outDir, outName.endsWith('.db') ? outName : '$outName.db');

  Map<String, Object?> toJson() => {
    'booksDir': booksDir,
    'officialDb': officialDb,
    'outDir': outDir,
    'outName': outName,
    'displayName': displayName,
    'author': author,
    'libraryId': libraryId,
    'autoLinks': autoLinks,
    'dhLines': dhLines,
    'compress': compress,
    'themeMode': themeMode.name,
    'overrides': overrides,
  };

  static Settings fromJson(Map<String, Object?> j) {
    final s = Settings();
    String str(String k, String d) => j[k] is String ? j[k] as String : d;
    bool b(String k, bool d) => j[k] is bool ? j[k] as bool : d;
    s.booksDir = str('booksDir', '');
    s.officialDb = str('officialDb', '');
    s.outDir = str('outDir', '');
    s.outName = str('outName', '');
    s.displayName = str('displayName', s.displayName);
    s.author = str('author', '');
    s.libraryId = str('libraryId', '');
    s.autoLinks = b('autoLinks', true);
    s.dhLines = b('dhLines', true);
    s.compress = b('compress', true);
    s.themeMode = ThemeMode.values.firstWhere((m) => m.name == j['themeMode'], orElse: () => ThemeMode.system);
    final o = j['overrides'];
    if (o is Map) s.overrides = {for (final e in o.entries) '${e.key}': '${e.value}'};
    return s;
  }
}

class SettingsStore {
  SettingsStore._();

  static String configDir() {
    final env = Platform.environment;
    if (Platform.isWindows && env['APPDATA'] != null) return p.join(env['APPDATA']!, 'MyLibraryOffline');
    return p.join(env['HOME'] ?? '.', 'Library', 'Application Support', 'MyLibraryOffline');
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
