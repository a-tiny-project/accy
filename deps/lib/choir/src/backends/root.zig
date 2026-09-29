const sys = @import("sys");
const supports_x86_64_backend = sys.capabilities.current.supportsX86_64Execution();

pub const artifact = @import("artifact/root.zig");
pub const aarch64 = @import("aarch64/root.zig");
pub const contract = @import("contract.zig");
pub const debug_info = @import("debug.zig");
pub const elf_object = @import("elf.zig");
pub const gpu = @import("gpu/root.zig");
pub const interface = @import("interface.zig");
pub const machine_code = @import("machine.zig");
pub const regalloc = @import("regalloc/root.zig");
pub const signature = @import("signature.zig");
pub const target = @import("target.zig");
pub const translation = @import("translation.zig");
pub const wasm = @import("wasm/root.zig");
pub const x86_64 = if (supports_x86_64_backend)
    @import("x64/root.zig")
else
    struct {
        pub const registers = @import("x64/registers/root.zig");
    };

pub const ConversionLegalitySpec = target.ConversionLegalitySpec;
pub const ConversionPatternEntry = target.ConversionPatternEntry;
pub const ConversionRewriteFn = target.ConversionRewriteFn;
pub const TargetSpec = target.TargetSpec;
