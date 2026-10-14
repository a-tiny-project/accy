//! The points where a caller enters compiled code, reported to a root module that asks.
//!
//! A test runner that declares `choirGeneratedCall` or `choirGeneratedPointer` in its root file
//! is told each time a caller is about to call compiled code, or is handed a pointer through
//! which it may. The declarations are looked up at compile time, so every other root, a
//! product's included, compiles these reports to nothing.

const root = @import("root");

/// Reports that the caller's next step is a call into compiled code.
pub inline fn calling() void {
    if (@hasDecl(root, "choirGeneratedCall")) root.choirGeneratedCall();
}

/// Reports that the caller receives a pointer to compiled code. Whether it calls through the
/// pointer is not seen.
pub inline fn lending() void {
    if (@hasDecl(root, "choirGeneratedPointer")) root.choirGeneratedPointer();
}
