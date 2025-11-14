import 'dart:ffi' as ffi;
import 'dart:io';

ffi.DynamicLibrary _openRustLib() {
  if (Platform.isLinux) {
    // We copied the .so to linux/lib
    return ffi.DynamicLibrary.open('linux/lib/librust_core.so');
  }
  throw UnsupportedError('Rust core not wired for this platform yet');
}

final _lib = _openRustLib();

final _add = _lib.lookupFunction<
    ffi.Int32 Function(ffi.Int32, ffi.Int32),
    int Function(int, int)>('add');

int rustAdd(int a, int b) => _add(a, b);
