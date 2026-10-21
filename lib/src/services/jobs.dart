import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../engine/errors.dart';


/// הקשר של עבודה שרצה ב-isolate: דיווח התקדמות ובדיקת ביטול.
class JobContext {
  JobContext(this._send, this._flagAddress);
  final SendPort _send;
  final int _flagAddress;
  final _clock = Stopwatch()..start();
  var _lastTitle = '';

  void progress(String title, String detail, double? fraction) {
    // מצמצם הודעות: כותרת חדשה תמיד, ועדכוני פרטים לכל היותר כל 80ms
    if (title == _lastTitle && _clock.elapsedMilliseconds < 80) return;
    _lastTitle = title;
    _clock.reset();
    _send.send((title, detail, fraction));
  }

  void checkCancel() {
    if (Pointer<Uint8>.fromAddress(_flagAddress).value != 0) throw Cancelled();
  }
}

typedef ProgressListener = void Function(String title, String detail, double? fraction);

/// מריץ [fn] על [arg] ב-isolate נפרד, כדי שהממשק לא ייתקע. [isCancelled] נבדק כמה פעמים בשנייה.
Future<T> runJob<A, T>(
  T Function(A arg, JobContext ctx) fn,
  A arg, {
  ProgressListener? onProgress,
  bool Function()? isCancelled,
}) async {
  final port = ReceivePort();
  final sub = port.listen((m) {
    if (m is (String, String, double?)) onProgress?.call(m.$1, m.$2, m.$3);
  });
  // בית אחד בזיכרון נייטיבי: הדבר היחיד ששני ה-isolates יכולים לחלוק.
  final flag = malloc.allocate<Uint8>(1)..value = 0;
  final poll = Timer.periodic(const Duration(milliseconds: 150), (_) {
    if (isCancelled?.call() ?? false) flag.value = 1;
  });
  try {
    return await _spawn(fn, arg, flag.address, port.sendPort);
  } finally {
    poll.cancel();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    port.close();
    malloc.free(flag);
  }
}

/// ה-closure נוצר כאן ולא ב-[runJob] בכוונה: closure שומר את ההקשר שבו נוצר, ושם יש אובייקטים שאי אפשר לשלוח.
Future<T> _spawn<A, T>(T Function(A, JobContext) fn, A arg, int flag, SendPort send) =>
    Isolate.run(() => fn(arg, JobContext(send, flag)));
