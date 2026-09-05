/// Compatibility shim for the entry point the Rust-backed build required.
///
/// The Rust-backed package needed `await RustLib.init()` before the first
/// widget was built, to open the dynamic library and start the
/// `flutter_rust_bridge` isolate. There is no library to open any more, so
/// [init] does nothing — but it is kept, with its original name and signature,
/// so that an app written against the Rust-backed package runs unchanged.
library;

class RustLib {
  const RustLib._();

  /// Does nothing. Present so existing call sites keep compiling.
  ///
  /// Safe to call more than once, and safe not to call at all.
  static Future<void> init() async {}

  /// Does nothing. The editing core holds no external resources.
  static void dispose() {}
}
