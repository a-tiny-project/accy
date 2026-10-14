//! Modules a runtime holds, and the image one compile or load stages before linking.

const std = @import("std");
const backends = @import("../root.zig");
const artifact = backends.artifact;
const debug_info = backends.debug_info;
const machine = backends.machine_code;
const sys = @import("sys");

pub const Mapping = []align(std.heap.page_size_min) u8;

comptime {
    std.debug.assert(machine.max_data_alignment <= std.heap.page_size_min);
}

/// The bytes the kernel reserves for a mapping of `byte_count`. `sys.memory.mapAnonymous` rounds
/// a nonzero request up to a page, and zero reserves nothing because `link` skips the call rather
/// than mapping a page for no data. A request too large to page-align saturates to the whole
/// address space. A budget short of that refuses the saturated charge in `admitMapping`, and a
/// budget equal to it admits the charge and lets the mapping call fail.
pub fn mappedSize(byte_count: usize) u64 {
    if (byte_count == 0) return 0;
    const aligned = sys.memory.pageAlign(byte_count) orelse return std.math.maxInt(u64);
    return aligned;
}

/// Names one module compiled or loaded into a runtime.
/// Releasing the module retires its generation, so the handle stops resolving.
pub const Handle = struct {
    index: u32,
    generation: u32,
};

/// How many of one function's values a target holds in a register for some stretch of their
/// life, by register class. A value counts once however often it moves between registers or
/// reloads from its frame slot. Every other value lives in its frame slot.
pub const Homes = struct {
    /// Values held in general-purpose registers.
    general: u32,
    /// Values held in floating-point registers, which also hold vectors: on x86_64 the XMM
    /// registers, where a packed vector of integers counts here too.
    floating: u32,
};

/// How a target placed the values of a function the runtime holds.
pub const Placement = union(enum) {
    /// The target's allocator placed the function's values: these in registers, and the rest
    /// in frame slots.
    placed: Homes,
    /// The allocator took none of the function, for the operation named here, so every value
    /// lives in its frame slot. The function computes what it would in registers, more slowly.
    framed: []const u8,
    /// The host turned placement off before the compile (`Runtime.placeValues`), so every value
    /// lives in its frame slot.
    forced,
    /// The runtime did not emit the function, as for one loaded from an artifact, so nothing
    /// recorded where its values live.
    unrecorded,
};

pub const FunctionEntry = struct {
    offset: usize,
    size: usize,
    signature: artifact.Signature,
    line_table: ?debug_info.LineTable = null,
    debug_object: ?debug_info.JitDebugHandle = null,
    /// How the target placed the function's values. A framed entry owns its operation's name.
    placement: Placement = .unrecorded,

    pub fn deinit(self: *FunctionEntry, allocator: std.mem.Allocator) void {
        if (self.debug_object) |*handle| handle.deinit(allocator);
        if (self.line_table) |*table| table.deinit();
        switch (self.placement) {
            .framed => |name| allocator.free(name),
            .placed, .forced, .unrecorded => {},
        }
        self.* = undefined;
    }
};

pub const Module = struct {
    generation: u32,
    live: bool,
    code: ?sys.memory.ExecutableMapping,
    /// Read-only bytes that the code addresses through absolute relocations.
    data: ?Mapping,
    functions: std.StringHashMapUnmanaged(FunctionEntry),

    pub const staged: Module = .{
        .generation = 0,
        .live = true,
        .code = null,
        .data = null,
        .functions = .empty,
    };

    pub fn functionAddress(self: *const Module, entry: *const FunctionEntry) usize {
        const code = &self.code.?;
        std.debug.assert(entry.offset + entry.size <= code.used);
        return (code.callableAddress() catch unreachable) + entry.offset;
    }

    pub fn reservationFunctionAddress(self: *const Module, entry: *const FunctionEntry) usize {
        const code = &self.code.?;
        std.debug.assert(entry.offset + entry.size <= code.used);
        return code.reservationAddress() + entry.offset;
    }

    /// The bytes this module holds mapped, code and read-only data together. `unload` unmaps
    /// exactly those bytes, so `release` credits back the figure `install` charged.
    pub fn mappedBytes(self: *const Module) u64 {
        var total: u64 = 0;
        if (self.code) |*mapping| total += mapping.mappedBytes();
        if (self.data) |mapping| total += mapping.len;
        return total;
    }

    /// Unregisters debug objects before unmapping the code they describe, then unmaps the data.
    /// Keeps the generation.
    pub fn unload(self: *Module, allocator: std.mem.Allocator) void {
        std.debug.assert(self.live);
        var iterator = self.functions.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        self.functions.deinit(allocator);
        if (self.code) |*mapping| mapping.deinit();
        if (self.data) |mapping| sys.memory.unmap(mapping);
        self.* = .{
            .generation = self.generation,
            .live = false,
            .code = null,
            .data = null,
            .functions = .empty,
        };
    }
};

/// One function a target emitted, borrowed from the target's compiler until it discards the
/// function, or until `takeCode` hands `code` over. Offsets are relative to `code`.
pub const Emitted = struct {
    code: []const u8,
    calls: []const machine.CallRelocation,
    data: []const machine.DataSymbol,
    data_relocations: []const machine.DataRelocation,
    /// Whether the code outgrew the bytes the target reserved for it before emitting, so
    /// that its buffer grew by copies. The target's reservation rests on a measured ratio
    /// rather than a bound, and the runtime counts these in `code_fallbacks`.
    outgrew_reservation: bool,
    /// How the target placed the function's values, never `.unrecorded`. A `.framed` name is the
    /// operation's own, borrowed like the rest, and the runtime copies it. A framed function
    /// computes what it would in registers, more slowly, and the runtime counts these in
    /// `framed_functions`.
    placement: Placement,
};

/// One module's code and data symbols, with every relocation still unpatched.
pub const Image = struct {
    code: []const u8,
    calls: []const machine.CallRelocation,
    data: *const machine.DataSymbolSet,
    data_relocations: []const machine.DataRelocation,
};

/// Concatenates emitted functions into one image.
pub const ImageBuilder = struct {
    code: std.ArrayListUnmanaged(u8) = .empty,
    calls: std.ArrayListUnmanaged(machine.CallRelocation) = .empty,
    data: machine.DataSymbolSet = .{},
    data_relocations: std.ArrayListUnmanaged(machine.DataRelocation) = .empty,

    pub fn deinit(self: *ImageBuilder, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
        self.calls.deinit(allocator);
        self.data.deinit(allocator);
        self.data_relocations.deinit(allocator);
        self.* = undefined;
    }

    /// Appends one emitted function, rebases its relocations, and merges its data symbols.
    /// Returns the function's offset in the image.
    ///
    /// It takes ownership of `code`, the bytes `emitted` describes, which the target handed
    /// over with `takeCode`. The first function's buffer becomes the image's code as it is,
    /// so a module of one function is never copied. A later function is copied after the
    /// ones before it, and its buffer freed.
    pub fn append(
        self: *ImageBuilder,
        allocator: std.mem.Allocator,
        emitted: Emitted,
        code: []u8,
    ) (std.mem.Allocator.Error || machine.DataSymbolError)!usize {
        std.debug.assert(code.len != 0);
        std.debug.assert(code.len == emitted.code.len);
        const offset = self.code.items.len;
        if (self.code.capacity == 0) {
            self.code = .fromOwnedSlice(code);
        } else {
            defer allocator.free(code);
            try self.code.appendSlice(allocator, code);
        }
        for (emitted.calls) |relocation| {
            var rebased = relocation;
            rebased.offset += offset;
            try self.calls.append(allocator, rebased);
        }
        for (emitted.data) |symbol| try self.data.put(allocator, symbol);
        for (emitted.data_relocations) |relocation| {
            var rebased = relocation;
            rebased.offset += offset;
            try self.data_relocations.append(allocator, rebased);
        }
        std.debug.assert(self.code.items.len == offset + code.len);
        return offset;
    }

    pub fn image(self: *const ImageBuilder) Image {
        return .{
            .code = self.code.items,
            .calls = self.calls.items,
            .data = &self.data,
            .data_relocations = self.data_relocations.items,
        };
    }
};
