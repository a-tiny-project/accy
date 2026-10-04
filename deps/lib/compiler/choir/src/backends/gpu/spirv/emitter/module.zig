const std = @import("std");
const SpirvOp = @import("ops.zig").SpirvOp;
const ExecutionMode = @import("spec.zig").ExecutionMode;
const Decoration = @import("spec.zig").Decoration;

pub const Version = struct {
    pub const v10: u32 = 0x00010000;
    pub const v13: u32 = 0x00010300;
};

pub const Header = struct {
    pub const magic: u32 = 0x07230203;
    pub const version: u32 = Version.v10;
    pub const generator: u32 = 0;
    pub const schema: u32 = 0;
};

pub const Section = std.ArrayListUnmanaged(u32);

pub const Builder = struct {
    allocator: std.mem.Allocator,
    version: u32,
    next_id: u32,
    capabilities: Section,
    extensions: Section,
    ext_inst_imports: Section,
    memory_model: Section,
    entry_points: Section,
    execution_modes: Section,
    annotations: Section,
    types: Section,
    globals: Section,
    functions: Section,
    glsl_std_450_id: u32,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .version = Header.version,
            .next_id = 1,
            .capabilities = .empty,
            .extensions = .empty,
            .ext_inst_imports = .empty,
            .memory_model = .empty,
            .entry_points = .empty,
            .execution_modes = .empty,
            .annotations = .empty,
            .types = .empty,
            .globals = .empty,
            .functions = .empty,
            .glsl_std_450_id = 0,
        };
    }

    pub fn deinit(self: *Builder) void {
        self.capabilities.deinit(self.allocator);
        self.extensions.deinit(self.allocator);
        self.ext_inst_imports.deinit(self.allocator);
        self.memory_model.deinit(self.allocator);
        self.entry_points.deinit(self.allocator);
        self.execution_modes.deinit(self.allocator);
        self.annotations.deinit(self.allocator);
        self.types.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        self.functions.deinit(self.allocator);
    }

    pub fn importGlslStd450(self: *Builder) !u32 {
        if (self.glsl_std_450_id != 0) return self.glsl_std_450_id;
        const id = self.newId();
        const set_name = "GLSL.std.450";
        const total_len = set_name.len + 1;
        const string_words = (total_len + 3) / 4;
        const word_count: u32 = @intCast(2 + string_words);
        const first_word: u32 = (word_count << 16) | SpirvOp.ExtInstImport;
        try self.ext_inst_imports.append(self.allocator, first_word);
        try self.ext_inst_imports.append(self.allocator, id);
        try self.emitString(&self.ext_inst_imports, set_name);
        self.glsl_std_450_id = id;
        return id;
    }

    pub fn newId(self: *Builder) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    pub fn emit(self: *Builder, section: *Section, opcode: u16, operands: []const u32) !void {
        const word_count: u32 = @intCast(operands.len + 1);
        const first_word: u32 = (word_count << 16) | opcode;
        try section.append(self.allocator, first_word);
        if (operands.len > 0) {
            try section.appendSlice(self.allocator, operands);
        }
        if (section == &self.functions and isFloatArithmetic(opcode)) {
            std.debug.assert(operands.len >= 2);
            try self.emitNoContraction(operands[1]);
        }
    }

    pub fn emitNoContraction(self: *Builder, result_id: u32) !void {
        try self.annotations.appendSlice(self.allocator, &.{
            (@as(u32, 3) << 16) | SpirvOp.Decorate,
            result_id,
            Decoration.NoContraction,
        });
    }

    fn isFloatArithmetic(opcode: u16) bool {
        return switch (opcode) {
            SpirvOp.FNegate,
            SpirvOp.FAdd,
            SpirvOp.FSub,
            SpirvOp.FMul,
            SpirvOp.FDiv,
            SpirvOp.GroupNonUniformFAdd,
            SpirvOp.GroupNonUniformFMin,
            SpirvOp.GroupNonUniformFMax,
            SpirvOp.DPdxFine,
            SpirvOp.DPdyFine,
            SpirvOp.FwidthFine,
            => true,
            else => false,
        };
    }

    fn emitString(self: *Builder, section: *Section, str: []const u8) !void {
        const total_len = str.len + 1;
        const word_len = (total_len + 3) / 4;
        try section.ensureTotalCapacity(self.allocator, section.items.len + word_len);

        var i: usize = 0;
        while (i < word_len) : (i += 1) {
            var word: u32 = 0;
            var j: usize = 0;
            while (j < 4) : (j += 1) {
                const idx = i * 4 + j;
                var byte: u8 = 0;
                if (idx < str.len) {
                    byte = str[idx];
                } else if (idx == str.len) {
                    byte = 0;
                }
                const shift: u5 = @intCast(8 * j);
                word |= (@as(u32, byte) << shift);
            }
            section.appendAssumeCapacity(word);
        }
    }

    pub fn emitCapability(self: *Builder, cap: u32) !void {
        try self.emit(&self.capabilities, SpirvOp.Capability, &.{cap});
    }

    pub fn emitExtension(self: *Builder, name: []const u8) !void {
        const string_words = (name.len + 1 + 3) / 4;
        const word_count: u32 = @intCast(1 + string_words);
        try self.extensions.append(self.allocator, (word_count << 16) | SpirvOp.Extension);
        try self.emitString(&self.extensions, name);
    }

    pub fn requireVersion(self: *Builder, version: u32) void {
        if (version > self.version) {
            self.version = version;
        }
    }

    pub fn emitMemoryModel(self: *Builder, addressing_model: u32, memory_model: u32) !void {
        try self.emit(&self.memory_model, SpirvOp.MemoryModel, &.{ addressing_model, memory_model });
    }

    pub fn emitEntryPoint(
        self: *Builder,
        exec_model: u32,
        func_id: u32,
        name: []const u8,
        interface_ids: []const u32,
    ) !void {
        var operands = Section.empty;
        defer operands.deinit(self.allocator);

        try operands.append(self.allocator, exec_model);
        try operands.append(self.allocator, func_id);

        try self.emitString(&operands, name);
        if (interface_ids.len > 0) {
            try operands.appendSlice(self.allocator, interface_ids);
        }

        try self.emit(&self.entry_points, SpirvOp.EntryPoint, operands.items);
    }

    pub fn emitExecutionModeLocalSize(self: *Builder, func_id: u32, x: u32, y: u32, z: u32) !void {
        try self.emit(&self.execution_modes, SpirvOp.ExecutionMode, &.{
            func_id,
            ExecutionMode.LocalSize,
            x,
            y,
            z,
        });
    }

    pub fn emitExecutionMode(self: *Builder, func_id: u32, mode: u32) !void {
        try self.emit(&self.execution_modes, SpirvOp.ExecutionMode, &.{ func_id, mode });
    }

    pub fn emitFloatExecutionMode(self: *Builder, func_id: u32, mode: u32, width: u32) !void {
        switch (width) {
            16, 32, 64 => {},
            else => unreachable,
        }
        try self.emit(&self.execution_modes, SpirvOp.ExecutionMode, &.{ func_id, mode, width });
    }

    pub fn toWords(self: *Builder, allocator: std.mem.Allocator) ![]u32 {
        var out: Section = .empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, &.{
            Header.magic,
            self.version,
            Header.generator,
            self.next_id,
            Header.schema,
        });

        const sections = [_]*Section{
            &self.capabilities,
            &self.extensions,
            &self.ext_inst_imports,
            &self.memory_model,
            &self.entry_points,
            &self.execution_modes,
            &self.annotations,
            &self.types,
            &self.globals,
            &self.functions,
        };

        for (sections) |section| {
            if (section.items.len > 0) {
                try out.appendSlice(allocator, section.items);
            }
        }

        return out.toOwnedSlice(allocator);
    }
};

fn containsOpcode(words: []const u32, opcode: u16) bool {
    var i: usize = 5;
    while (i < words.len) {
        const word = words[i];
        const word_count = word >> 16;
        const op: u16 = @intCast(word & 0xffff);
        if (op == opcode) return true;
        if (word_count == 0) return false;
        i += word_count;
    }
    return false;
}
