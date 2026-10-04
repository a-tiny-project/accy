const std = @import("std");
const backends = @import("root.zig");
const aarch64 = @import("aarch64/test.zig");
const artifact = @import("artifact/test.zig");
const execution = @import("execution/test.zig");
const gpu = @import("gpu/test.zig");
const regalloc = @import("regalloc/test.zig");
const wasm = @import("wasm/test.zig");
const x86_64 = @import("x64/test.zig");

test {
    std.testing.refAllDecls(backends.artifact);
    std.testing.refAllDecls(backends.aarch64);
    std.testing.refAllDecls(backends.contract);
    std.testing.refAllDecls(backends.debug_info);
    std.testing.refAllDecls(backends.elf_object);
    std.testing.refAllDecls(backends.execution);
    std.testing.refAllDecls(backends.interface);
    std.testing.refAllDecls(backends.machine_code);
    std.testing.refAllDecls(backends.regalloc);
    std.testing.refAllDecls(backends.signature);
    std.testing.refAllDecls(backends.target);
    std.testing.refAllDecls(backends.translation);
    std.testing.refAllDecls(backends.wasm);
    std.testing.refAllDecls(backends.x86_64);
    _ = aarch64;
    _ = artifact;
    _ = execution;
    _ = gpu;
    _ = regalloc;
    _ = wasm;
    _ = x86_64;
    _ = @import("macho/test.zig");
}
