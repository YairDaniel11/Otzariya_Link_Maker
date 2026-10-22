import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:zstandard_native/zstandard_native_bindings.dart';

class ZstdException implements Exception {
  ZstdException(this.message);
  final String message;
  @override
  String toString() => message;
}

DynamicLibrary? _lib;

/// libzstd של הפלאגין zstandard. בבדיקות (`flutter test`) הפלאגין אינו טעון: נתיב מפורש ב-ZSTD_LIB_PATH.
DynamicLibrary openZstd() {
  final cached = _lib;
  if (cached != null) return cached;
  final override = Platform.environment['ZSTD_LIB_PATH'];
  try {
    final DynamicLibrary lib;
    if (override != null && override.isNotEmpty) {
      lib = DynamicLibrary.open(override);
    } else if (Platform.isWindows) {
      lib = DynamicLibrary.open('zstandard_windows.dll');
    } else if (Platform.isMacOS) {
      lib = DynamicLibrary.open('zstandard_macos.framework/zstandard_macos');
    } else if (Platform.isLinux) {
      lib = DynamicLibrary.open('libzstandard_linux.so');
    } else {
      throw ZstdException('zstd אינו נתמך בפלטפורמה הזו');
    }
    return _lib = lib;
  } on ArgumentError catch (e) {
    throw ZstdException('ספריית zstd אינה זמינה: $e');
  }
}

/// חוצץ נייטיב שגדל לפי הצורך.
class _Buffer {
  Pointer<Uint8> ptr = nullptr;
  int cap = 0;

  Pointer<Uint8> reserve(int n) {
    if (n <= cap && ptr != nullptr) return ptr;
    if (ptr != nullptr) malloc.free(ptr);
    cap = n < 4096 ? 4096 : n + n ~/ 4;
    ptr = malloc<Uint8>(cap);
    return ptr;
  }

  void free() {
    if (ptr != nullptr) malloc.free(ptr);
    ptr = nullptr;
    cap = 0;
  }
}

/// מפענח שורות דחוסות של seforim.db: כל מסגרת בוחרת מילון לפי ה-dictID שבה (כמו באוצריא).
class ZstdLineDecoder {
  ZstdLineDecoder(Iterable<Uint8List> dictionaries) {
    _z = ZstandardNativeBindings(openZstd());
    for (final d in dictionaries) {
      final native = malloc<Uint8>(d.length);
      try {
        native.asTypedList(d.length).setAll(0, d);
        final dd = _z.ZSTD_createDDict(native.cast(), d.length);
        if (dd == nullptr) throw ZstdException('טעינת מילון zstd נכשלה');
        _ddicts[_z.ZSTD_getDictID_fromDDict(dd)] = dd;
      } finally {
        malloc.free(native);
      }
    }
    _dctx = _z.ZSTD_createDCtx();
    if (_dctx == nullptr) throw ZstdException('יצירת הקשר zstd נכשלה');
  }

  late final ZstandardNativeBindings _z;
  final _ddicts = <int, Pointer<ZSTD_DDict>>{};
  late final Pointer<ZSTD_DCtx> _dctx;
  final _in = _Buffer();
  final _out = _Buffer();

  /// טקסט של ערך עמודה: TEXT מוחזר כמו שהוא, BLOB מפוענח.
  String text(Object? value) => switch (value) {
    null => '',
    final String s => s,
    final Uint8List b => utf8.decode(decompress(b), allowMalformed: true),
    _ => '$value',
  };

  Uint8List decompress(Uint8List frame) {
    final src = _in.reserve(frame.length);
    src.asTypedList(frame.length).setAll(0, frame);
    final size = _z.ZSTD_getFrameContentSize(src.cast(), frame.length);
    if (size < 0 || size > 64 * 1024 * 1024) throw ZstdException('מסגרת zstd לא תקינה');
    final id = _z.ZSTD_getDictID_fromFrame(src.cast(), frame.length);
    final dst = _out.reserve(size == 0 ? 1 : size);
    final int written;
    if (id == 0) {
      written = _z.ZSTD_decompressDCtx(_dctx, dst.cast(), size, src.cast(), frame.length);
    } else {
      final dd = _ddicts[id];
      if (dd == null) throw ZstdException('מילון $id חסר ב-zstd_dict');
      written = _z.ZSTD_decompress_usingDDict(_dctx, dst.cast(), size, src.cast(), frame.length, dd);
    }
    if (_z.ZSTD_isError(written) != 0) {
      throw ZstdException('פענוח zstd נכשל: ${_z.ZSTD_getErrorName(written).cast<Utf8>().toDartString()}');
    }
    return Uint8List.fromList(dst.asTypedList(written));
  }

  void close() {
    for (final d in _ddicts.values) {
      _z.ZSTD_freeDDict(d);
    }
    _ddicts.clear();
    _z.ZSTD_freeDCtx(_dctx);
    _in.free();
    _out.free();
  }
}

/// דוחס שורות עם מילון (המילון של הספרייה הרשמית), כך שכל מסגרת נושאת את ה-dictID וגודל התוכן.
class ZstdLineEncoder {
  ZstdLineEncoder(Uint8List dictionary, {int level = 19}) {
    _z = ZstandardNativeBindings(openZstd());
    final native = malloc<Uint8>(dictionary.length);
    try {
      native.asTypedList(dictionary.length).setAll(0, dictionary);
      // ZSTD_createCDict מעתיק את המילון, אפשר לשחרר מיד.
      _cdict = _z.ZSTD_createCDict(native.cast(), dictionary.length, level);
    } finally {
      malloc.free(native);
    }
    if (_cdict == nullptr) throw ZstdException('יצירת מילון דחיסה נכשלה');
    _cctx = _z.ZSTD_createCCtx();
    if (_cctx == nullptr) throw ZstdException('יצירת הקשר דחיסה נכשלה');
  }

  late final ZstandardNativeBindings _z;
  late final Pointer<ZSTD_CDict> _cdict;
  late final Pointer<ZSTD_CCtx> _cctx;
  final _in = _Buffer();
  final _out = _Buffer();

  Uint8List compress(Uint8List data) {
    final src = _in.reserve(data.length);
    if (data.isNotEmpty) src.asTypedList(data.length).setAll(0, data);
    final bound = _z.ZSTD_compressBound(data.length);
    final dst = _out.reserve(bound);
    final n = _z.ZSTD_compress_usingCDict(_cctx, dst.cast(), bound, src.cast(), data.length, _cdict);
    if (_z.ZSTD_isError(n) != 0) {
      throw ZstdException('דחיסת zstd נכשלה: ${_z.ZSTD_getErrorName(n).cast<Utf8>().toDartString()}');
    }
    return Uint8List.fromList(dst.asTypedList(n));
  }

  Uint8List compressText(String s) => compress(utf8.encode(s));

  void close() {
    _z.ZSTD_freeCDict(_cdict);
    _z.ZSTD_freeCCtx(_cctx);
    _in.free();
    _out.free();
  }
}
