pub const dialect = @import("dialect.zig");
pub const conversion = @import("conversion.zig");
pub const ptx = @import("ptx.zig");

pub const NvptxDialect = dialect.NvptxDialect;

pub const gpu_to_nvptx_pass_name = conversion.gpu_to_nvptx_pass_name;
pub const gpu_to_nvptx_pass_description = conversion.gpu_to_nvptx_pass_description;
pub const legal_dialects = conversion.legal_dialects;
pub const illegal_ops = conversion.illegal_ops;
pub const conversion_pattern_entries = conversion.conversion_pattern_entries;
pub const conversion_patterns = conversion.conversion_patterns;
pub const target_spec = conversion.target_spec;
pub const createGpuToNvptxPass = conversion.createGpuToNvptxPass;
pub const pass_registration = conversion.pass_registration;
