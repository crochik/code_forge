/// The direction of a run of text.
///
/// Deliberately named `TextDirection`, matching the enum the generated
/// `flutter_rust_bridge` binding used to expose, so that code written against
/// the Rust-backed package keeps compiling unchanged.
library;

enum TextDirection { ltr, rtl, mixed }
