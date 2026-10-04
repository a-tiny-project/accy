const std = @import("std");
const choir = @import("../../../../root.zig");

const ir = choir.ir;
const codegen = @import("codegen.zig");

pub const Emitter = struct {
    codegen: codegen.SpirvCodegen,

    pub fn init(allocator: std.mem.Allocator) Emitter {
        return .{ .codegen = codegen.SpirvCodegen.init(allocator) };
    }

    pub fn deinit(self: *Emitter) void {
        self.codegen.deinit();
    }

    pub fn setFloatControls(self: *Emitter, controls: codegen.FloatControls) void {
        self.codegen.float_controls = controls;
    }

    pub fn emitModuleBytes(self: *Emitter, module: *ir.Operation) codegen.SpirvCodegenError![]u8 {
        return self.codegen.emitModuleBytes(module);
    }

    pub fn emitModuleWords(self: *Emitter, module: *ir.Operation) codegen.SpirvCodegenError![]u32 {
        return self.codegen.emitModuleWords(module);
    }
};

test {
    const std_testing = std.testing;
    std_testing.refAllDecls(@This());
}
