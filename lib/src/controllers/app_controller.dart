import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../engine/errors.dart';
import '../engine/seforim_db.dart';
import '../services/jobs.dart';
import '../services/settings_store.dart';

/// פעולה ארוכה שרצה עכשיו.
class Activity {
  Activity(this.title);
  String title;
  String detail = '';
  double? progress;
  bool cancelled = false;
}

class AppController extends ChangeNotifier {
  /// [persist] = false בבדיקות: לא נוגעים בהגדרות האמיתיות של המחשב.
  AppController({this.persist = true});

  final bool persist;
  Settings settings = Settings();
  bool loaded = false;

  /// שגיאה בקובץ seforim.db (null = תקין או לא נבחר).
  String? officialError;

  Activity? activity;
  List<String>? officialTitles;

  String? lastMessage;
  bool lastMessageIsError = false;

  bool get busy => activity != null;
  ThemeMode get themeMode => settings.themeMode;
  bool get hasOfficial => settings.officialDb.isNotEmpty && officialError == null;

  Future<void> init() async {
    if (persist) {
      settings = await SettingsStore.load();
      if (settings.officialDb.isEmpty || !File(settings.officialDb).existsSync()) {
        settings.officialDb = findSeforimDb() ?? settings.officialDb;
      }
    }
    _validateOfficial();
    loaded = true;
    notifyListeners();
    await save();
  }

  /// שומר את ההגדרות (מסכים יכולים לקרוא לזה אחרי שינוי ב-[settings]).
  Future<void> save() => persist ? SettingsStore.save(settings).catchError((_) {}) : Future.value();

  void changed() {
    notifyListeners();
    save();
  }

  void showMessage(String msg, {bool error = false}) {
    lastMessage = msg;
    lastMessageIsError = error;
    notifyListeners();
  }

  void clearMessage() {
    lastMessage = null;
    notifyListeners();
  }

  // ─── הגדרות ───────────────────────────────────────────────────────

  void setThemeMode(ThemeMode m) {
    settings.themeMode = m;
    changed();
  }

  void setAuthor(String v) {
    settings.author = v.trim();
    changed();
  }

  void _validateOfficial() {
    officialError = settings.officialDb.isEmpty ? null : SeforimDb.validate(settings.officialDb);
  }

  void setOfficialDb(String path) {
    settings.officialDb = path;
    officialTitles = null;
    _validateOfficial();
    changed();
  }

  /// מחפש את seforim.db במיקומים המוכרים. מחזיר false אם לא נמצא.
  bool detectOfficial() {
    final f = findSeforimDb();
    if (f == null) return false;
    setOfficialDb(f);
    return true;
  }

  // ─── פעולות ארוכות ─────────────────────────────────────────────────

  void cancelActivity() {
    activity?.cancelled = true;
    notifyListeners();
  }

  /// מריץ פעולה ארוכה עם כרטיס התקדמות וכפתור "עצור". שגיאות מוצגות כהודעה.
  Future<T?> run<T>(
    String title,
    Future<T> Function(ProgressListener onProgress, bool Function() cancelled) job,
  ) async {
    if (busy) return null;
    final a = activity = Activity(title);
    lastMessage = null;
    notifyListeners();
    try {
      return await job((t, d, f) {
        a
          ..title = t
          ..detail = d
          ..progress = f;
        notifyListeners();
      }, () => a.cancelled);
    } on Cancelled {
      showMessage('הפעולה בוטלה.');
      return null;
    } on AppError catch (e) {
      showMessage(e.message, error: true);
      return null;
    } catch (e) {
      showMessage('שגיאה: $e', error: true);
      return null;
    } finally {
      activity = null;
      notifyListeners();
    }
  }

  /// שמות הספרים בספרייה הרשמית (לבחירת יעד).
  Future<List<String>> loadTitles() async {
    final cached = officialTitles;
    if (cached != null) return cached;
    if (!hasOfficial) return const [];
    final titles = await runJob(titlesJob, settings.officialDb);
    officialTitles = titles;
    return titles;
  }

  /// פותח את סייר הקבצים על הקובץ או התיקייה.
  static Future<void> reveal(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', File(path).existsSync() ? ['/select,', path] : [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', File(path).existsSync() ? ['-R', path] : [path]);
      } else {
        await Process.run('xdg-open', [File(path).existsSync() ? p.dirname(path) : path]);
      }
    } catch (_) {}
  }
}
