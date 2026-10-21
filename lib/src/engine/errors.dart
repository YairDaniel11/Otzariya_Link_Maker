/// שגיאה עם הודעה מובנת למשתמש (מוצגת כמות שהיא).
class AppError implements Exception {
  AppError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// המשתמש לחץ "עצור".
class Cancelled implements Exception {}
