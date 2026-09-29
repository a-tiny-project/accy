pub const emitter = @import("emitter/root.zig");
pub const dialect = @import("dialect.zig");
pub const conversion = @import("conversion.zig");

pub const Capability = dialect.Capability;
pub const AddressingModel = dialect.AddressingModel;
pub const MemoryModel = dialect.MemoryModel;
pub const ExecutionModel = dialect.ExecutionModel;
pub const StorageClass = dialect.StorageClass;
pub const SpirvDialect = dialect.SpirvDialect;

pub const gpu_to_spirv_pass_name = conversion.gpu_to_spirv_pass_name;
pub const gpu_to_spirv_pass_description = conversion.gpu_to_spirv_pass_description;
pub const legal_dialects = conversion.legal_dialects;
pub const illegal_ops = conversion.illegal_ops;
pub const conversion_pattern_entries = conversion.conversion_pattern_entries;
pub const conversion_patterns = conversion.conversion_patterns;
pub const target_spec = conversion.target_spec;
pub const createGpuToSpirvPass = conversion.createGpuToSpirvPass;
pub const pass_registration = conversion.pass_registration;
