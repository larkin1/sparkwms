import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as pkgffi;

ffi.DynamicLibrary _openRustLib() {
  if (Platform.isLinux) {
    return ffi.DynamicLibrary.open('linux/lib/librust_core.so');
  }
  throw UnsupportedError('Rust core not wired for this platform yet');
}

final _bindings = _RustBindings(_openRustLib());

class RustApiException implements Exception {
  const RustApiException(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => 'RustApiException(code: $code, message: $message)';
}

class CommitPayload {
  CommitPayload({
    required String deviceId,
    required String location,
    required this.delta,
    required this.itemId,
  })  : deviceId = deviceId.trim(),
        location = location.trim() {
    if (this.deviceId.isEmpty) {
      throw ArgumentError('Device ID is required');
    }
    if (this.location.isEmpty) {
      throw ArgumentError('Location is required');
    }
    if (itemId < _i16Min || itemId > _i16Max) {
      throw ArgumentError('Item ID must fit in a 16-bit signed integer');
    }
    if (delta < _i32Min || delta > _i32Max) {
      throw ArgumentError('Delta must fit in a 32-bit signed integer');
    }
  }

  static const int _i16Min = -32768;
  static const int _i16Max = 32767;
  static const int _i32Min = -2147483648;
  static const int _i32Max = 2147483647;

  final String deviceId;
  final String location;
  final int delta;
  final int itemId;
}

class RustApi {
  RustApi._();

  static final RustApi instance = RustApi._();

  ffi.Pointer<ApiHandle>? _handle;

  bool get isInitialized => _handle != null && _handle != ffi.nullptr;

  void initialize(String connectString) {
    final trimmed = connectString.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Connect string is required');
    }
    dispose();
    _withCString(trimmed, (pointer) {
      final handle = _invokeWithError(
        'Create API handle',
        (errPtr) => _bindings.apiNew(pointer, errPtr),
      );
      if (handle == ffi.nullptr) {
        throw const RustApiException(1, 'Rust returned a null API handle');
      }
      _handle = handle;
      return null;
    });
  }

  void dispose() {
    final handle = _handle;
    if (handle != null && handle != ffi.nullptr) {
      _bindings.apiFree(handle);
    }
    _handle = null;
  }

  bool sendCommit(CommitPayload commit) {
    final handle = _ensureHandle();
    return _withCommitStruct(commit, (ffiCommit) {
      return _invokeWithError(
        'Send commit',
        (errPtr) => _bindings.apiSendCommit(handle, ffiCommit, errPtr) != 0,
      );
    });
  }

  bool exportOverview(String path) {
    final handle = _ensureHandle();
    return _withCString(path.trim(), (pointer) {
      return _invokeWithError(
        'Export overview',
        (errPtr) => _bindings.exportOverview(handle, pointer, errPtr) != 0,
      );
    });
  }

  bool exportLocations(String path) {
    final handle = _ensureHandle();
    return _withCString(path.trim(), (pointer) {
      return _invokeWithError(
        'Export locations',
        (errPtr) => _bindings.exportLocations(handle, pointer, errPtr) != 0,
      );
    });
  }

  bool exportItems(String path) {
    final handle = _ensureHandle();
    return _withCString(path.trim(), (pointer) {
      return _invokeWithError(
        'Export items',
        (errPtr) => _bindings.exportItems(handle, pointer, errPtr) != 0,
      );
    });
  }

  bool check() {
    final handle = _ensureHandle();
    return _invokeWithError(
      'Health check',
      (errPtr) => _bindings.apiCheck(handle, errPtr) != 0,
    );
  }

  bool enqueueCommit(CommitPayload commit, {String? queuePath}) {
    return _withOptionalCString(queuePath, (pathPtr) {
      return _withCommitStruct(commit, (ffiCommit) {
        return _invokeWithError(
          'Queue commit',
          (errPtr) => _bindings.queueEnqueue(pathPtr, ffiCommit, errPtr) != 0,
        );
      });
    });
  }

  int queueLength({String? queuePath}) {
    return _withOptionalCString(queuePath, (pathPtr) {
      return _invokeWithError(
        'Query queue length',
        (errPtr) => _bindings.queueLen(pathPtr, errPtr),
      );
    });
  }

  bool startCommitManager(String connectString, {String? queuePath}) {
    final trimmed = connectString.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Connect string is required');
    }
    return _withCString(trimmed, (connectPtr) {
      return _withOptionalCString(queuePath, (pathPtr) {
        return _invokeWithError(
          'Start commit manager',
          (errPtr) => _bindings.startCommitManager(connectPtr, pathPtr, errPtr) != 0,
        );
      });
    });
  }

  ffi.Pointer<ApiHandle> _ensureHandle() {
    final handle = _handle;
    if (handle == null || handle == ffi.nullptr) {
      throw StateError('API handle has not been initialized.');
    }
    return handle;
  }
}

T _withCommitStruct<T>(CommitPayload commit, T Function(FfiCommit) action) {
  final commitPtr = pkgffi.calloc<FfiCommit>();
  final devicePtr = commit.deviceId.toNativeUtf8();
  final locationPtr = commit.location.toNativeUtf8();
  try {
    commitPtr.ref
      ..deviceId = devicePtr.cast()
      ..location = locationPtr.cast()
      ..delta = commit.delta
      ..itemId = commit.itemId;
    return action(commitPtr.ref);
  } finally {
    pkgffi.calloc.free(commitPtr);
    pkgffi.malloc.free(devicePtr);
    pkgffi.malloc.free(locationPtr);
  }
}

T _withCString<T>(String value, T Function(ffi.Pointer<ffi.Char>) action) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError('Value cannot be empty');
  }
  final ptr = trimmed.toNativeUtf8();
  try {
    return action(ptr.cast());
  } finally {
    pkgffi.malloc.free(ptr);
  }
}

T _withOptionalCString<T>(String? value, T Function(ffi.Pointer<ffi.Char>) action) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return action(ffi.nullptr);
  }
  return _withCString(trimmed, action);
}

T _invokeWithError<T>(String context, T Function(ffi.Pointer<FfiError>) action) {
  final errPtr = pkgffi.calloc<FfiError>();
  try {
    final result = action(errPtr);
    _handleError(errPtr, context);
    return result;
  } finally {
    pkgffi.calloc.free(errPtr);
  }
}

void _handleError(ffi.Pointer<FfiError> errPtr, String context) {
  final code = errPtr.ref.code;
  final messagePtr = errPtr.ref.message;
  if (code == 0) {
    if (messagePtr != ffi.nullptr) {
      _bindings.stringFree(messagePtr);
      errPtr.ref.message = ffi.nullptr;
    }
    return;
  }
  final message = messagePtr == ffi.nullptr
      ? 'Unknown error'
      : messagePtr.cast<pkgffi.Utf8>().toDartString();
  if (messagePtr != ffi.nullptr) {
    _bindings.stringFree(messagePtr);
    errPtr.ref.message = ffi.nullptr;
  }
  throw RustApiException(code, '$context failed: $message');
}

class ApiHandle extends ffi.Opaque {}

class FfiCommit extends ffi.Struct {
  external ffi.Pointer<ffi.Char> deviceId;
  external ffi.Pointer<ffi.Char> location;

  @ffi.Int32()
  external int delta;

  @ffi.Int16()
  external int itemId;
}

class FfiError extends ffi.Struct {
  @ffi.Int32()
  external int code;

  external ffi.Pointer<ffi.Char> message;
}

class _RustBindings {
  _RustBindings(this._lib);

  final ffi.DynamicLibrary _lib;

  late final ffi.Pointer<ApiHandle> Function(
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<FfiError>,
  ) apiNew = _lib.lookupFunction<
      ffi.Pointer<ApiHandle> Function(
        ffi.Pointer<ffi.Char>,
        ffi.Pointer<FfiError>,
      ),
      ffi.Pointer<ApiHandle> Function(
        ffi.Pointer<ffi.Char>,
        ffi.Pointer<FfiError>,
      )>('sparkwms_api_new');

  late final void Function(ffi.Pointer<ApiHandle>) apiFree = _lib.lookupFunction<
      ffi.Void Function(ffi.Pointer<ApiHandle>),
      void Function(ffi.Pointer<ApiHandle>)>('sparkwms_api_free');

  late final int Function(
    ffi.Pointer<ApiHandle>,
    FfiCommit,
    ffi.Pointer<FfiError>,
  ) apiSendCommit = _lib.lookupFunction<
      ffi.Uint8 Function(
        ffi.Pointer<ApiHandle>,
        FfiCommit,
        ffi.Pointer<FfiError>,
      ),
      int Function(
        ffi.Pointer<ApiHandle>,
        FfiCommit,
        ffi.Pointer<FfiError>,
      )>('sparkwms_api_send_commit');

  late final int Function(
    ffi.Pointer<ApiHandle>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<FfiError>,
  ) exportOverview = _lib.lookupFunction<
      ffi.Uint8 Function(
        ffi.Pointer<ApiHandle>,
        ffi.Pointer<ffi.Char>,
        ffi.Pointer<FfiError>,
      ),
      int Function(
        ffi.Pointer<ApiHandle>,
        ffi.Pointer<ffi.Char>,
        ffi.Pointer<FfiError>,
      )>('sparkwms_api_export_overview');

  late final int Function(
    ffi.Pointer<ApiHandle>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<FfiError>,
  ) exportLocations = _lib.lookupFunction<
      ffi.Uint8 Function(
        ffi.Pointer<ApiHandle>,
        ffi.Pointer<ffi.Char>,
        ffi.Pointer<FfiError>,
      ),
      int Function(
        ffi.Pointer<ApiHandle>,
        ffi.Pointer<ffi.Char>,
        ffi.Pointer<FfiError>,
      )>('sparkwms_api_export_locations');

  late final int Function(
    ffi.Pointer<ApiHandle>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<FfiError>,
  ) exportItems = _lib.lookupFunction<
      ffi.Uint8 Function(
        ffi.Pointer<ApiHandle>,
        ffi.Pointer<ffi.Char>,
        ffi.Pointer<FfiError>,
      ),
      int Function(
        ffi.Pointer<ApiHandle>,
        ffi.Pointer<ffi.Char>,
        ffi.Pointer<FfiError>,
      )>('sparkwms_api_export_items');

  late final int Function(
    ffi.Pointer<ApiHandle>,
    ffi.Pointer<FfiError>,
  ) apiCheck = _lib.lookupFunction<
      ffi.Uint8 Function(
        ffi.Pointer<ApiHandle>,
        ffi.Pointer<FfiError>,
      ),
      int Function(
        ffi.Pointer<ApiHandle>,
        ffi.Pointer<FfiError>,
      )>('sparkwms_api_check');

  late final int Function(
    ffi.Pointer<ffi.Char>,
    FfiCommit,
    ffi.Pointer<FfiError>,
  ) queueEnqueue = _lib.lookupFunction<
      ffi.Uint8 Function(
        ffi.Pointer<ffi.Char>,
        FfiCommit,
        ffi.Pointer<FfiError>,
      ),
      int Function(
        ffi.Pointer<ffi.Char>,
        FfiCommit,
        ffi.Pointer<FfiError>,
      )>('sparkwms_queue_enqueue');

  late final int Function(
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<FfiError>,
  ) queueLen = _lib.lookupFunction<
      ffi.Int32 Function(
        ffi.Pointer<ffi.Char>,
        ffi.Pointer<FfiError>,
      ),
      int Function(
        ffi.Pointer<ffi.Char>,
        ffi.Pointer<FfiError>,
      )>('sparkwms_queue_len');

  late final int Function(
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<FfiError>,
  ) startCommitManager = _lib.lookupFunction<
      ffi.Uint8 Function(
        ffi.Pointer<ffi.Char>,
        ffi.Pointer<ffi.Char>,
        ffi.Pointer<FfiError>,
      ),
      int Function(
        ffi.Pointer<ffi.Char>,
        ffi.Pointer<ffi.Char>,
        ffi.Pointer<FfiError>,
      )>('sparkwms_start_commit_manager');

  late final void Function(ffi.Pointer<ffi.Char>) stringFree = _lib.lookupFunction<
      ffi.Void Function(ffi.Pointer<ffi.Char>),
      void Function(ffi.Pointer<ffi.Char>)>('sparkwms_string_free');
}
