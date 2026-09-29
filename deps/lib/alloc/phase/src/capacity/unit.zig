//! This test root imports the `arithmetic`, `capability`, `declaration`,
//! `signature`, and `spec` test blocks. Separate build wiring also executes
//! capacity owner tests, metadata fixture tests, and 20 negative compile cases.

test {
    _ = @import("arithmetic.zig");
    _ = @import("capability.zig");
    _ = @import("declaration.zig");
    _ = @import("signature.zig");
    _ = @import("spec.zig");
}
