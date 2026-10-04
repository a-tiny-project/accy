const std = @import("std");

const Allocator = std.mem.Allocator;

pub const CallRelocation = struct {
    offset: usize,
    target: []const u8,
};

pub const data_symbol_attr_names = struct {
    pub const name = "choir.backend.data_symbol.name";
    pub const bytes = "choir.backend.data_symbol.bytes";
    pub const alignment = "choir.backend.data_symbol.alignment";
};

/// Largest alignment a data symbol may request.
/// A JIT data mapping starts on a page boundary, so an offset aligned within the mapping is also
/// aligned in memory for any alignment up to one page.
pub const max_data_alignment = 4096;

pub const DataSymbolError = error{ InvalidDataSymbol, ConflictingDataSymbol };

pub const DataSymbolBinding = enum {
    local,
    global,
};

/// The section a data symbol lands in.
pub const DataSection = enum {
    /// Mapped read-only.
    rodata,
    /// Mapped writable, with the bytes the file carries.
    data,
    /// Mapped writable and zero, with no bytes in the file at all.
    bss,

    /// Reports whether the object file carries this section's bytes.
    pub fn carriesBytes(self: DataSection) bool {
        return self != .bss;
    }
};

/// Storage that code addresses by name.
///
/// A `.bss` symbol is the same kind as any other and differs only in where its bytes come from:
/// the loader supplies them, so the file carries none and `reserved_size` states the extent that
/// `bytes.len` cannot. Keeping one kind is what lets one `DataSymbolSet` hold every global a
/// module declares, whichever section it lands in.
pub const DataSymbol = struct {
    name: []const u8,
    /// Bytes the file carries verbatim. Empty exactly when the section is `.bss`.
    bytes: []const u8 = &.{},
    /// How many bytes the symbol occupies, when that is not the byte count.
    ///
    /// Absent means the size IS `bytes.len`, which is the only reading available for a section
    /// the file carries bytes for. It is required for `.bss`, where there are no bytes to count,
    /// and a zero here is a refusal rather than an empty symbol.
    reserved_size: ?usize = null,
    alignment: usize = 1,
    binding: DataSymbolBinding = .local,
    section: DataSection = .rodata,

    /// The number of bytes the symbol occupies once loaded.
    pub fn size(self: DataSymbol) usize {
        return self.reserved_size orelse self.bytes.len;
    }

    /// Reports whether the symbol has a nonempty name, a power-of-two alignment no larger than
    /// `max_data_alignment`, and content its section can hold: bytes for `.rodata` and `.data`,
    /// a stated nonzero size and no bytes for `.bss`.
    pub fn isValid(self: DataSymbol) bool {
        if (self.name.len == 0) return false;
        if (self.alignment == 0 or self.alignment > max_data_alignment) return false;
        if (!std.math.isPowerOfTwo(self.alignment)) return false;
        if (self.section.carriesBytes()) {
            if (self.bytes.len == 0) return false;
            if (self.reserved_size) |reserved| return reserved == self.bytes.len;
            return true;
        }
        if (self.bytes.len != 0) return false;
        const reserved = self.reserved_size orelse return false;
        return reserved != 0;
    }

    pub fn eql(self: DataSymbol, other: DataSymbol) bool {
        return std.mem.eql(u8, self.name, other.name) and
            std.mem.eql(u8, self.bytes, other.bytes) and
            self.size() == other.size() and
            self.alignment == other.alignment and
            self.binding == other.binding and
            self.section == other.section;
    }
};

/// Data symbols in first-insertion order, one per name.
/// The set borrows each symbol's name and bytes, so both must outlive the set.
pub const DataSymbolSet = struct {
    symbols: std.StringArrayHashMapUnmanaged(DataSymbol) = .empty,

    pub fn deinit(self: *DataSymbolSet, allocator: Allocator) void {
        self.symbols.deinit(allocator);
        self.* = undefined;
    }

    /// Adds `symbol` unless an equal symbol already holds its name.
    /// Fails when `symbol` is invalid, or when its name already holds different bytes,
    /// alignment, or binding.
    pub fn put(
        self: *DataSymbolSet,
        allocator: Allocator,
        symbol: DataSymbol,
    ) (Allocator.Error || DataSymbolError)!void {
        if (!symbol.isValid()) return error.InvalidDataSymbol;
        const entry = try self.symbols.getOrPut(allocator, symbol.name);
        if (!entry.found_existing) {
            entry.value_ptr.* = symbol;
            return;
        }
        if (!entry.value_ptr.eql(symbol)) return error.ConflictingDataSymbol;
    }

    pub fn items(self: *const DataSymbolSet) []const DataSymbol {
        return self.symbols.values();
    }

    pub fn indexOf(self: *const DataSymbolSet, name: []const u8) ?usize {
        return self.symbols.getIndex(name);
    }

    pub fn clearRetainingCapacity(self: *DataSymbolSet) void {
        self.symbols.clearRetainingCapacity();
    }
};

/// Places data symbols in order, each at the first offset after the previous symbol that its
/// alignment allows.
pub const DataLayout = struct {
    offsets: []usize,
    size: usize,
    alignment: usize,

    pub const Error = Allocator.Error || error{ InvalidDataSymbol, DataTooLarge };

    pub fn init(allocator: Allocator, symbols: []const DataSymbol) Error!DataLayout {
        const offsets = try allocator.alloc(usize, symbols.len);
        errdefer allocator.free(offsets);
        var size: usize = 0;
        var alignment: usize = 1;
        for (symbols, offsets) |symbol, *offset| {
            if (!symbol.isValid()) return error.InvalidDataSymbol;
            const mask = symbol.alignment - 1;
            const padded = std.math.add(usize, size, mask) catch return error.DataTooLarge;
            offset.* = padded & ~mask;
            std.debug.assert(offset.* >= size);
            std.debug.assert(std.mem.isAligned(offset.*, symbol.alignment));
            size = std.math.add(usize, offset.*, symbol.size()) catch return error.DataTooLarge;
            alignment = @max(alignment, symbol.alignment);
        }
        return .{ .offsets = offsets, .size = size, .alignment = alignment };
    }

    pub fn deinit(self: *DataLayout, allocator: Allocator) void {
        allocator.free(self.offsets);
        self.* = undefined;
    }

    /// Copies each symbol to its offset in `out` and zeroes the padding between symbols.
    ///
    /// A symbol whose section carries no bytes contributes none, and the memset above has
    /// already left its run at the zero the loader would have supplied.
    pub fn write(self: *const DataLayout, symbols: []const DataSymbol, out: []u8) void {
        std.debug.assert(symbols.len == self.offsets.len);
        std.debug.assert(out.len >= self.size);
        @memset(out[0..self.size], 0);
        for (symbols, self.offsets) |symbol, offset| {
            std.debug.assert(offset + symbol.size() <= self.size);
            @memcpy(out[offset..][0..symbol.bytes.len], symbol.bytes);
        }
    }
};

pub const DataRelocation = struct {
    offset: usize,
    target: []const u8,
    addend: i64 = 0,
    width_bits: u16 = 64,
};

pub const MachineCode = struct {
    code: []u8,
    relocations: []CallRelocation,
    data_symbols: []DataSymbol = &.{},
    data_relocations: []DataRelocation = &.{},

    pub fn deinit(self: *MachineCode, allocator: Allocator) void {
        allocator.free(self.code);
        allocator.free(self.relocations);
        allocator.free(self.data_symbols);
        allocator.free(self.data_relocations);
    }
};
