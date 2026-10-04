const std = @import("std");
const builtin = @import("builtin");
const capabilities = @import("capabilities.zig");
const sys_allocator = @import("allocator.zig");
const sys_env = @import("env.zig");
const sys_memory = @import("memory.zig");
const elf = std.elf;
const posix = std.posix;

pub const required_capabilities = capabilities.host(&.{ .allocator, .dynamic_loading, .environment, .filesystem, .memory_mapping });

const ElfRepairLocalError = error{
    FileTooBig,
    InvalidElfImage,
    UnsupportedElfRelocation,
};

pub const ElfRepairError =
    std.Io.File.OpenError ||
    std.Io.File.StatError ||
    sys_memory.MapError ||
    ElfRepairLocalError;

const NativeElfLocalError = error{
    FileTooBig,
    InvalidElfImage,
    NativeElfUnsupported,
    NativeElfUnsupportedRelocation,
    NativeElfStringSectionNotFound,
    NativeElfSymbolSectionNotFound,
    NativeElfHashTableNotFound,
    OutOfMemory,
};

pub const NativeElfError =
    std.Io.File.OpenError ||
    std.Io.File.StatError ||
    sys_memory.MapError ||
    NativeElfLocalError;

pub const LibraryError = std.DynLib.Error || ElfRepairError || NativeElfError;
pub const OpenFirstError = LibraryError || error{NoCandidate};

pub const Library = struct {
    raw: LibraryImpl,

    pub fn open(path: []const u8) LibraryError!Library {
        if (canUseNativeElfPlatform()) {
            if (openNativeElf(path)) |library| {
                return library;
            } else |err| switch (err) {
                error.NativeElfUnsupported,
                error.NativeElfUnsupportedRelocation,
                error.NativeElfHashTableNotFound,
                error.FileNotFound,
                => {},
                else => |native_error| return native_error,
            }
        }

        var raw = try std.DynLib.open(path);
        errdefer raw.close();
        if (comptime usesStdElfDynLib()) {
            const require_repair = std.mem.indexOfScalar(u8, path, '/') != null;
            repairElfImage(path, &raw) catch |err| {
                if (require_repair) return err;
            };
        }
        return .{ .raw = .{ .std_dynlib = raw } };
    }

    pub fn openNativeElf(path: []const u8) NativeElfError!Library {
        const allocator = sys_allocator.processAllocator();
        const native_path = try resolveNativeElfOpenPath(allocator, path);
        defer allocator.free(native_path);
        return .{ .raw = .{ .native_elf = try openNativeElfShared(allocator, native_path) } };
    }

    pub fn close(self: *Library) void {
        switch (self.raw) {
            .std_dynlib => |*raw| raw.close(),
            .native_elf => |*native| native.close(),
        }
    }

    pub fn lookup(self: *Library, comptime T: type, symbol: [:0]const u8) ?T {
        return switch (self.raw) {
            .std_dynlib => |*raw| raw.lookup(T, symbol),
            .native_elf => |*native| native.lookup(T, symbol),
        };
    }

    pub fn isNativeElf(self: *const Library) bool {
        return switch (self.raw) {
            .native_elf => true,
            .std_dynlib => false,
        };
    }
};

pub fn openRuntimeFfiPlugin(path: []const u8) LibraryError!Library {
    if (runtimeFfiPluginsRequireNativeElf()) return Library.openNativeElf(path);
    return Library.open(path);
}

pub fn runtimeFfiPluginsRequireNativeElf() bool {
    return canUseNativeElfPlatform();
}

const LibraryImpl = union(enum) {
    std_dynlib: std.DynLib,
    native_elf: NativeElfHandle,
};

const NativeElfHandle = struct {
    shared: *NativeElfSharedLibrary,

    fn close(self: *NativeElfHandle) void {
        releaseNativeElfShared(self.shared);
        self.* = undefined;
    }

    fn lookup(self: *const NativeElfHandle, comptime T: type, name: [:0]const u8) ?T {
        return self.shared.library.lookup(T, name);
    }

    fn lookupAddressVersioned(self: *const NativeElfHandle, name: []const u8, version: ?[]const u8) ?usize {
        return self.shared.library.lookupAddressVersioned(name, version);
    }

    fn lookupTlsSymbolVersioned(self: *const NativeElfHandle, name: []const u8, version: ?[]const u8) ?NativeElfTlsSymbol {
        return self.shared.library.lookupTlsSymbolVersioned(name, version);
    }
};

const NativeElfSharedLibrary = struct {
    path: []u8,
    ref_count: usize,
    library: NativeElfLibrary,
};

const NativeElfRegistry = struct {
    mutex: std.atomic.Mutex = .unlocked,
    libraries: std.ArrayList(*NativeElfSharedLibrary) = .empty,

    fn lock(self: *NativeElfRegistry) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
};

var native_elf_registry: NativeElfRegistry = .{};

const NativeElfIfuncResolver = *const fn () callconv(.c) usize;

const NativeElfLibrary = struct {
    allocator: std.mem.Allocator,
    memory: []align(std.heap.page_size_min) u8,
    load_bias: usize,
    strings: [*:0]u8,
    syms: [*]elf.Sym,
    symbol_count: usize,
    versyms: ?[*]elf.Versym,
    verdef: usize,
    verdef_count: usize,
    dependencies: []NativeElfHandle,
    tls: NativeElfTlsAllocation,
    fini: usize,
    fini_array: usize,
    fini_array_count: usize,

    fn openUncached(path: []const u8) NativeElfError!NativeElfLibrary {
        if (!canUseNativeElfPlatform() or !hasLibraryPathSeparator(path)) return error.NativeElfUnsupported;

        const io = std.Options.debug_io;
        var file = if (path.len > 0 and path[0] == '/')
            try std.Io.Dir.openFileAbsolute(io, path, .{})
        else
            try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        const stat = try file.stat(io);
        const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
        if (size < @sizeOf(elf.Ehdr)) return error.InvalidElfImage;
        const page_size = std.heap.pageSize();
        const file_bytes = try sys_memory.mapPrivateFile(file.handle, size, .{ .read = true }, 0);
        defer sys_memory.unmap(file_bytes);

        const eh: *const elf.Ehdr = @ptrCast(file_bytes.ptr);
        if (!std.mem.eql(u8, eh.e_ident[0..4], elf.MAGIC)) return error.InvalidElfImage;
        if (eh.e_type != elf.ET.DYN) return error.InvalidElfImage;
        if (eh.e_phentsize != @sizeOf(elf.ElfN.Phdr)) return error.InvalidElfImage;
        if (eh.e_phoff + @as(usize, eh.e_phentsize) * eh.e_phnum > size) return error.InvalidElfImage;

        var load_count: usize = 0;
        var min_vaddr: usize = std.math.maxInt(usize);
        var max_vaddr: usize = 0;
        var dynamic_vaddr: ?usize = null;
        var relro_vaddr: usize = 0;
        var relro_memsz: usize = 0;
        var relro_count: usize = 0;
        var maybe_tls_image: ?NativeElfTlsImage = null;
        var i: usize = 0;
        var ph_addr = @intFromPtr(file_bytes.ptr) + eh.e_phoff;
        while (i < eh.e_phnum) : ({
            i += 1;
            ph_addr += eh.e_phentsize;
        }) {
            const ph: *const elf.ElfN.Phdr = @ptrFromInt(ph_addr);
            switch (ph.type) {
                .LOAD => {
                    const vaddr = std.math.cast(usize, ph.vaddr) orelse return error.InvalidElfImage;
                    const memsz = std.math.cast(usize, ph.memsz) orelse return error.InvalidElfImage;
                    const filesz = std.math.cast(usize, ph.filesz) orelse return error.InvalidElfImage;
                    const offset = std.math.cast(usize, ph.offset) orelse return error.InvalidElfImage;
                    if (memsz < filesz) return error.InvalidElfImage;
                    if (offset > size or filesz > size - offset) return error.InvalidElfImage;
                    const segment_end = checkedAdd(vaddr, memsz) orelse return error.InvalidElfImage;
                    min_vaddr = @min(min_vaddr, std.mem.alignBackward(usize, vaddr, page_size));
                    max_vaddr = @max(max_vaddr, std.mem.alignForward(usize, segment_end, page_size));
                    load_count += 1;
                },
                .DYNAMIC => {
                    dynamic_vaddr = std.math.cast(usize, ph.vaddr) orelse return error.InvalidElfImage;
                },
                elf.PT.GNU_RELRO => {
                    relro_vaddr = std.math.cast(usize, ph.vaddr) orelse return error.InvalidElfImage;
                    relro_memsz = std.math.cast(usize, ph.memsz) orelse return error.InvalidElfImage;
                    relro_count += 1;
                },
                .TLS => {
                    if (maybe_tls_image != null) return error.InvalidElfImage;
                    maybe_tls_image = try NativeElfTlsImage.fromProgramHeader(ph, size);
                },
                else => {},
            }
        }

        if (load_count == 0) return error.InvalidElfImage;
        if (relro_count > 1) return error.InvalidElfImage;
        if (maybe_tls_image != null and !canUseNativeElfTls()) return error.NativeElfUnsupported;
        if (max_vaddr <= min_vaddr) return error.InvalidElfImage;
        const memory_size = max_vaddr - min_vaddr;
        const memory = try sys_memory.mapAnonymous(memory_size, .{});
        errdefer sys_memory.unmap(memory);

        const allocator = sys_allocator.processAllocator();
        const load_bias = @intFromPtr(memory.ptr) - min_vaddr;
        try loadSegments(file.handle, file_bytes, size, load_bias, eh, page_size);
        var tls = try NativeElfTlsAllocation.init(allocator, maybe_tls_image, load_bias);
        errdefer tls.deinit(allocator);
        const dynamic = dynamic_vaddr orelse return error.InvalidElfImage;

        var maybe_strings: ?[*:0]u8 = null;
        var maybe_syms: ?[*]elf.Sym = null;
        var maybe_symbol_count: ?usize = null;
        var maybe_gnu_hash: ?*elf.gnu_hash.Header = null;
        var maybe_versyms: ?[*]elf.Versym = null;
        var verdef: usize = 0;
        var verdef_count: usize = 0;
        var verneed: usize = 0;
        var verneed_count: usize = 0;
        var needed_offsets: std.ArrayList(usize) = .empty;
        defer needed_offsets.deinit(allocator);
        var maybe_runpath_offset: ?usize = null;
        var maybe_rpath_offset: ?usize = null;
        var init: usize = 0;
        var init_array: usize = 0;
        var init_array_size: usize = 0;
        var fini: usize = 0;
        var fini_array: usize = 0;
        var fini_array_size: usize = 0;
        const dynv: [*]usize = @ptrFromInt(load_bias + dynamic);
        i = 0;
        while (dynv[i] != 0) : (i += 2) {
            const value = dynv[i + 1];
            switch (dynv[i]) {
                elf.DT_NEEDED => try needed_offsets.append(allocator, value),
                elf.DT_STRTAB => maybe_strings = @ptrFromInt(load_bias + value),
                elf.DT_SYMTAB => maybe_syms = @ptrFromInt(load_bias + value),
                elf.DT_HASH => {
                    const hash: [*]const u32 = @ptrFromInt(load_bias + value);
                    maybe_symbol_count = hash[1];
                },
                elf.DT_GNU_HASH => maybe_gnu_hash = @ptrFromInt(load_bias + value),
                elf.DT_VERSYM => maybe_versyms = @ptrFromInt(load_bias + value),
                elf.DT_VERDEF => verdef = value,
                elf.DT_VERDEFNUM => verdef_count = value,
                elf.DT_VERNEED => verneed = value,
                elf.DT_VERNEEDNUM => verneed_count = value,
                elf.DT_RUNPATH => maybe_runpath_offset = value,
                elf.DT_RPATH => maybe_rpath_offset = value,
                elf.DT_INIT => init = value,
                elf.DT_INIT_ARRAY => init_array = value,
                elf.DT_INIT_ARRAYSZ => init_array_size = value,
                elf.DT_FINI => fini = value,
                elf.DT_FINI_ARRAY => fini_array = value,
                elf.DT_FINI_ARRAYSZ => fini_array_size = value,
                else => {},
            }
        }

        const strings = maybe_strings orelse return error.NativeElfStringSectionNotFound;
        const syms = maybe_syms orelse return error.NativeElfSymbolSectionNotFound;
        const symbol_count = if (maybe_gnu_hash) |gnu_hash|
            try gnuHashSymbolCount(gnu_hash)
        else
            maybe_symbol_count orelse return error.NativeElfHashTableNotFound;
        const runpath = if (maybe_runpath_offset) |offset|
            std.mem.sliceTo(strings + offset, 0)
        else
            null;
        const rpath = if (maybe_rpath_offset) |offset|
            std.mem.sliceTo(strings + offset, 0)
        else
            null;
        const dependencies = try loadNativeElfDependencies(allocator, path, strings, needed_offsets.items, rpath, runpath);
        errdefer closeNativeElfDependencies(allocator, dependencies);
        try applyNativeElfRelocations(load_bias, dynamic, syms, strings, symbol_count, maybe_versyms, verneed, verneed_count, &tls, dependencies);
        try protectNativeElfRelro(load_bias, relro_vaddr, relro_memsz, page_size);
        try runNativeElfInitializers(load_bias, init, init_array, init_array_size);

        return .{
            .allocator = allocator,
            .memory = memory,
            .load_bias = load_bias,
            .strings = strings,
            .syms = syms,
            .symbol_count = symbol_count,
            .versyms = maybe_versyms,
            .verdef = verdef,
            .verdef_count = verdef_count,
            .dependencies = dependencies,
            .tls = tls,
            .fini = fini,
            .fini_array = fini_array,
            .fini_array_count = fini_array_size / @sizeOf(usize),
        };
    }

    pub fn close(self: *NativeElfLibrary) void {
        runNativeElfFinalizers(self.load_bias, self.fini, self.fini_array, self.fini_array_count);
        self.tls.deinit(self.allocator);
        closeNativeElfDependencies(self.allocator, self.dependencies);
        sys_memory.unmap(self.memory);
        self.* = undefined;
    }

    pub fn lookup(self: *const NativeElfLibrary, comptime T: type, name: [:0]const u8) ?T {
        return if (self.lookupAddress(name)) |address| @as(T, @ptrFromInt(address)) else null;
    }

    fn lookupAddress(self: *const NativeElfLibrary, name: []const u8) ?usize {
        return self.lookupAddressVersioned(name, null);
    }

    fn lookupAddressVersioned(self: *const NativeElfLibrary, name: []const u8, version: ?[]const u8) ?usize {
        return lookupNativeElfAddress(self.load_bias, self.syms, self.strings, self.symbol_count, self.versyms, self.verdef, self.verdef_count, name, version);
    }

    fn lookupTlsSymbolVersioned(self: *const NativeElfLibrary, name: []const u8, version: ?[]const u8) ?NativeElfTlsSymbol {
        return lookupNativeElfTlsSymbol(self.load_bias, self.syms, self.strings, self.symbol_count, self.versyms, self.verdef, self.verdef_count, self.tls, name, version);
    }
};

const NativeElfTlsImage = struct {
    vaddr: usize,
    filesz: usize,
    memsz: usize,
    offset: usize,
    alignment: std.mem.Alignment,

    fn fromProgramHeader(ph: *const elf.ElfN.Phdr, file_len: usize) NativeElfError!NativeElfTlsImage {
        const vaddr = std.math.cast(usize, ph.vaddr) orelse return error.InvalidElfImage;
        const filesz = std.math.cast(usize, ph.filesz) orelse return error.InvalidElfImage;
        const memsz = std.math.cast(usize, ph.memsz) orelse return error.InvalidElfImage;
        const offset = std.math.cast(usize, ph.offset) orelse return error.InvalidElfImage;
        const alignment_value = std.math.cast(usize, ph.@"align") orelse return error.InvalidElfImage;
        if (memsz < filesz) return error.InvalidElfImage;
        if (offset > file_len or filesz > file_len - offset) return error.InvalidElfImage;
        return .{
            .vaddr = vaddr,
            .filesz = filesz,
            .memsz = memsz,
            .offset = offset,
            .alignment = try nativeElfTlsAlignment(alignment_value),
        };
    }
};

const NativeElfTlsAllocation = struct {
    module_id: usize = 0,
    payload_len: usize = 0,

    fn init(allocator: std.mem.Allocator, maybe_image: ?NativeElfTlsImage, load_bias: usize) NativeElfError!NativeElfTlsAllocation {
        const image = maybe_image orelse return .{};
        const template_address = checkedAdd(load_bias, image.vaddr) orelse return error.InvalidElfImage;
        const module_id = try native_elf_tls_registry.register(allocator, .{
            .module_id = 0,
            .template_address = template_address,
            .filesz = image.filesz,
            .memsz = image.memsz,
            .alignment = image.alignment,
        });
        return .{
            .module_id = module_id,
            .payload_len = image.memsz,
        };
    }

    fn deinit(self: *NativeElfTlsAllocation, allocator: std.mem.Allocator) void {
        if (self.module_id == 0) return;
        native_elf_tls_registry.unregister(allocator, self.module_id);
        self.* = .{};
    }

    fn active(self: *const NativeElfTlsAllocation) bool {
        return self.module_id != 0;
    }
};

const NativeElfTlsSymbol = struct {
    module_id: usize,
    offset: usize,
    payload_len: usize,
};

const NativeElfTlsRecord = struct {
    module_id: usize,
    template_address: usize,
    filesz: usize,
    memsz: usize,
    alignment: std.mem.Alignment,
    blocks: std.ArrayList(NativeElfThreadTlsBlock) = .empty,

    fn address(self: *NativeElfTlsRecord, allocator: std.mem.Allocator, thread_id: std.Thread.Id, offset: usize) NativeElfError!usize {
        for (self.blocks.items) |*block| {
            if (block.thread_id != thread_id) continue;
            return block.address(offset) orelse return error.NativeElfUnsupportedRelocation;
        }
        var block = try NativeElfThreadTlsBlock.init(allocator, self, thread_id);
        errdefer block.deinit(allocator);
        const block_address = block.address(offset) orelse return error.NativeElfUnsupportedRelocation;
        try self.blocks.append(allocator, block);
        return block_address;
    }

    fn deinit(self: *NativeElfTlsRecord, allocator: std.mem.Allocator) void {
        for (self.blocks.items) |*block| block.deinit(allocator);
        self.blocks.deinit(allocator);
        self.* = undefined;
    }
};

const NativeElfThreadTlsBlock = struct {
    module_id: usize,
    thread_id: std.Thread.Id,
    memory: []u8,
    payload_len: usize,
    alignment: std.mem.Alignment,

    fn init(allocator: std.mem.Allocator, module: *const NativeElfTlsRecord, thread_id: std.Thread.Id) NativeElfError!NativeElfThreadTlsBlock {
        const allocation_len = @max(module.memsz, 1);
        const ptr = allocator.rawAlloc(allocation_len, module.alignment, @returnAddress()) orelse return error.OutOfMemory;
        errdefer allocator.rawFree(ptr[0..allocation_len], module.alignment, @returnAddress());
        const memory = ptr[0..allocation_len];
        if (module.filesz != 0) {
            const template: [*]const u8 = @ptrFromInt(module.template_address);
            @memcpy(memory[0..module.filesz], template[0..module.filesz]);
        }
        if (module.memsz > module.filesz) {
            @memset(memory[module.filesz..module.memsz], 0);
        }
        return .{
            .module_id = module.module_id,
            .thread_id = thread_id,
            .memory = memory,
            .payload_len = module.memsz,
            .alignment = module.alignment,
        };
    }

    fn deinit(self: *NativeElfThreadTlsBlock, allocator: std.mem.Allocator) void {
        allocator.rawFree(self.memory, self.alignment, @returnAddress());
        self.* = undefined;
    }

    fn address(self: *const NativeElfThreadTlsBlock, offset: usize) ?usize {
        if (offset >= self.payload_len) return null;
        return checkedAdd(@intFromPtr(self.memory.ptr), offset);
    }
};

const NativeElfTlsRegistry = struct {
    mutex: std.atomic.Mutex = .unlocked,
    next_module_id: usize = 1,
    records: std.ArrayList(NativeElfTlsRecord) = .empty,

    fn register(self: *NativeElfTlsRegistry, allocator: std.mem.Allocator, record: NativeElfTlsRecord) NativeElfError!usize {
        self.lock();
        defer self.mutex.unlock();
        const module_id = self.next_module_id;
        const next_module_id = checkedAdd(module_id, 1) orelse return error.NativeElfUnsupported;
        var module_record = record;
        module_record.module_id = module_id;
        try self.records.append(allocator, module_record);
        self.next_module_id = next_module_id;
        return module_id;
    }

    fn unregister(self: *NativeElfTlsRegistry, allocator: std.mem.Allocator, module_id: usize) void {
        self.lock();
        defer self.mutex.unlock();
        var index: usize = 0;
        while (index < self.records.items.len) : (index += 1) {
            if (self.records.items[index].module_id == module_id) {
                var record = self.records.swapRemove(index);
                record.deinit(allocator);
                return;
            }
        }
    }

    fn address(self: *NativeElfTlsRegistry, allocator: std.mem.Allocator, module_id: usize, thread_id: std.Thread.Id, offset: usize) NativeElfError!usize {
        self.lock();
        defer self.mutex.unlock();
        for (self.records.items) |*record| {
            if (record.module_id != module_id) continue;
            return record.address(allocator, thread_id, offset);
        }
        return error.NativeElfUnsupportedRelocation;
    }

    fn lock(self: *NativeElfTlsRegistry) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
};

const NativeElfTlsIndex = extern struct {
    module_id: usize,
    offset: usize,
};

var native_elf_tls_registry: NativeElfTlsRegistry = .{};

fn nativeElfTlsGetAddr(index: *const NativeElfTlsIndex) callconv(.c) *anyopaque {
    const address = native_elf_tls_registry.address(sys_allocator.processAllocator(), index.module_id, std.Thread.getCurrentId(), index.offset) catch @trap();
    return @ptrFromInt(address);
}

fn nativeElfTlsAlignment(alignment_value: usize) NativeElfError!std.mem.Alignment {
    if (alignment_value == 0) return .@"1";
    if (!std.math.isPowerOfTwo(alignment_value)) return error.InvalidElfImage;
    return .fromByteUnits(alignment_value);
}

fn canUseNativeElfTls() bool {
    return builtin.cpu.arch == .x86_64;
}

fn lookupNativeElfAddress(
    load_bias: usize,
    syms: [*]elf.Sym,
    strings: [*:0]u8,
    symbol_count: usize,
    versyms: ?[*]elf.Versym,
    verdef: usize,
    verdef_count: usize,
    name: []const u8,
    version: ?[]const u8,
) ?usize {
    const ok_types = (1 << elf.STT_NOTYPE | 1 << elf.STT_OBJECT | 1 << elf.STT_FUNC | 1 << elf.STT_COMMON | 1 << elf.STT_GNU_IFUNC);
    const ok_binds = (1 << elf.STB_GLOBAL | 1 << elf.STB_WEAK | 1 << elf.STB_GNU_UNIQUE);

    var i: usize = 0;
    while (i < symbol_count) : (i += 1) {
        const symbol = syms[i];
        if (symbol.st_shndx == 0) continue;
        if (0 == (@as(u32, 1) << @as(u5, @intCast(nativeElfSymbolType(symbol))) & ok_types)) continue;
        if (0 == (@as(u32, 1) << @as(u5, @intCast(symbol.st_info >> 4)) & ok_binds)) continue;
        if (!std.mem.eql(u8, name, std.mem.sliceTo(strings + symbol.st_name, 0))) continue;
        if (version) |requested| {
            if (!nativeElfSymbolMatchesVersion(load_bias, strings, versyms, verdef, verdef_count, i, requested)) continue;
        } else if (!nativeElfSymbolHasDefaultVersion(versyms, i)) continue;
        return nativeElfSymbolAddress(load_bias, symbol);
    }

    return null;
}

fn nativeElfSymbolType(symbol: elf.Sym) u8 {
    return symbol.st_info & 0xf;
}

fn nativeElfSymbolBind(symbol: elf.Sym) u8 {
    return symbol.st_info >> 4;
}

fn nativeElfSymbolAddress(load_bias: usize, symbol: elf.Sym) usize {
    const address = load_bias + symbol.st_value;
    if (nativeElfSymbolType(symbol) == elf.STT_GNU_IFUNC) return @as(NativeElfIfuncResolver, @ptrFromInt(address))();
    return address;
}

fn nativeElfSymbolHasDefaultVersion(versyms: ?[*]elf.Versym, symbol_index: usize) bool {
    const table = versyms orelse return true;
    return !table[symbol_index].HIDDEN;
}

fn nativeElfSymbolMatchesVersion(
    base: usize,
    strings: [*:0]u8,
    versyms: ?[*]elf.Versym,
    verdef: usize,
    verdef_count: usize,
    symbol_index: usize,
    requested: []const u8,
) bool {
    const table = versyms orelse return false;
    const version_name = nativeElfDefinedVersionName(base, strings, table[symbol_index], verdef, verdef_count) orelse return false;
    return std.mem.eql(u8, requested, version_name);
}

fn nativeElfDefinedVersionName(base: usize, strings: [*:0]u8, versym: elf.Versym, verdef: usize, verdef_count: usize) ?[]const u8 {
    if (versym.VERSION <= @backingInt(elf.VER_NDX.GLOBAL) or verdef == 0) return null;

    var definition_addr = base + verdef;
    var index: usize = 0;
    while (index < verdef_count) : (index += 1) {
        const definition: *const elf.Verdef = @ptrFromInt(definition_addr);
        if (@backingInt(definition.ndx) == versym.VERSION) {
            const aux: *const elf.Verdaux = @ptrFromInt(definition_addr + definition.aux);
            return std.mem.sliceTo(strings + aux.name, 0);
        }
        if (definition.next == 0) break;
        definition_addr += definition.next;
    }
    return null;
}

fn lookupNativeElfTlsSymbol(
    load_bias: usize,
    syms: [*]elf.Sym,
    strings: [*:0]u8,
    symbol_count: usize,
    versyms: ?[*]elf.Versym,
    verdef: usize,
    verdef_count: usize,
    tls: NativeElfTlsAllocation,
    name: []const u8,
    version: ?[]const u8,
) ?NativeElfTlsSymbol {
    if (!tls.active()) return null;
    const ok_binds = (1 << elf.STB_GLOBAL | 1 << elf.STB_WEAK | 1 << elf.STB_GNU_UNIQUE);

    var i: usize = 0;
    while (i < symbol_count) : (i += 1) {
        const symbol = syms[i];
        if (symbol.st_shndx == 0) continue;
        if (symbol.st_info & 0xf != elf.STT_TLS) continue;
        if (0 == (@as(u32, 1) << @as(u5, @intCast(symbol.st_info >> 4)) & ok_binds)) continue;
        if (!std.mem.eql(u8, name, std.mem.sliceTo(strings + symbol.st_name, 0))) continue;
        if (version) |requested| {
            if (!nativeElfSymbolMatchesVersion(load_bias, strings, versyms, verdef, verdef_count, i, requested)) continue;
        } else if (!nativeElfSymbolHasDefaultVersion(versyms, i)) continue;
        const symbol_offset = std.math.cast(usize, symbol.st_value) orelse return null;
        if (symbol_offset >= tls.payload_len) return null;
        return .{
            .module_id = tls.module_id,
            .offset = symbol_offset,
            .payload_len = tls.payload_len,
        };
    }

    return null;
}

fn gnuHashSymbolCount(header: *elf.gnu_hash.Header) NativeElfError!usize {
    const header_offset = @intFromPtr(header);
    const bloom_offset = header_offset + @sizeOf(elf.gnu_hash.Header);
    const buckets_offset = bloom_offset + header.bloom_size * @sizeOf(usize);
    const chain_offset = buckets_offset + header.nbuckets * @sizeOf(u32);
    const buckets: [*]const u32 = @ptrFromInt(buckets_offset);
    const chains: [*]const elf.gnu_hash.ChainEntry = @ptrFromInt(chain_offset);

    var symbol_count: usize = header.symoffset;
    for (buckets[0..header.nbuckets]) |bucket| {
        if (bucket == 0) continue;
        if (bucket < header.symoffset) return error.InvalidElfImage;
        var chain_index: usize = bucket - header.symoffset;
        while (true) : (chain_index += 1) {
            symbol_count = @max(symbol_count, chain_index + header.symoffset + 1);
            if (chains[chain_index].end_of_chain) break;
        }
    }
    return symbol_count;
}

fn canUseNativeElfPlatform() bool {
    return builtin.os.tag == .linux;
}

fn hasLibraryPathSeparator(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, '/') != null;
}

fn loadSegments(
    file_handle: std.posix.fd_t,
    file_bytes: []align(std.heap.page_size_min) const u8,
    file_len: usize,
    load_bias: usize,
    eh: *const elf.Ehdr,
    page_size: usize,
) NativeElfError!void {
    var i: usize = 0;
    var ph_addr = @intFromPtr(file_bytes.ptr) + eh.e_phoff;
    while (i < eh.e_phnum) : ({
        i += 1;
        ph_addr += eh.e_phentsize;
    }) {
        const ph: *const elf.ElfN.Phdr = @ptrFromInt(ph_addr);
        if (ph.type != .LOAD) continue;

        const vaddr = std.math.cast(usize, ph.vaddr) orelse return error.InvalidElfImage;
        const memsz = std.math.cast(usize, ph.memsz) orelse return error.InvalidElfImage;
        const filesz = std.math.cast(usize, ph.filesz) orelse return error.InvalidElfImage;
        const offset = std.math.cast(usize, ph.offset) orelse return error.InvalidElfImage;
        if (offset > file_len or filesz > file_len - offset) return error.InvalidElfImage;
        const segment_addr = checkedAdd(load_bias, vaddr) orelse return error.InvalidElfImage;
        const map_addr = std.mem.alignBackward(usize, segment_addr, page_size);
        const page_delta = segment_addr - map_addr;
        const map_len = std.mem.alignForward(usize, checkedAdd(page_delta, memsz) orelse return error.InvalidElfImage, page_size);
        const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(map_addr);
        const writable = ph.flags.W;

        if (!writable and memsz == filesz) {
            const file_offset = std.mem.alignBackward(usize, offset, page_size);
            if (page_delta != offset - file_offset) return error.InvalidElfImage;
            _ = try sys_memory.mapPrivateFileFixed(
                file_handle,
                ptr,
                map_len,
                elfToProtection(ph.flags),
                file_offset,
            );
        } else {
            const segment = try sys_memory.mapAnonymousFixed(
                ptr,
                map_len,
                .{ .read = true, .write = true, .execute = writable and ph.flags.X },
            );
            @memcpy(segment[page_delta..][0..filesz], file_bytes[offset..][0..filesz]);
            if (memsz > filesz) {
                @memset(segment[page_delta + filesz .. page_delta + memsz], 0);
            }
            if (!writable) {
                try protectNativeElfMemory(segment, elfToProtection(ph.flags));
            }
        }
    }
}

test "native ELF loader zero fills read-only segment tails" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var image: [std.heap.page_size_max * 2]u8 align(std.heap.page_size_min) = @splat(0);
    const eh: *elf.Ehdr = @ptrCast(&image);
    eh.e_phoff = @sizeOf(elf.Ehdr);
    eh.e_phentsize = @sizeOf(elf.ElfN.Phdr);
    eh.e_phnum = 1;

    const ph: *elf.ElfN.Phdr = @ptrCast(@alignCast(image[@sizeOf(elf.Ehdr)..].ptr));
    const page_size = std.heap.pageSize();
    const source_offset = page_size;
    const source = [_]u8{ 0x10, 0x20, 0x30, 0x40 };
    @memcpy(image[source_offset..][0..source.len], &source);
    ph.* = .{
        .type = .LOAD,
        .flags = .{ .R = true },
        .offset = source_offset,
        .vaddr = 0,
        .paddr = 0,
        .filesz = source.len,
        .memsz = page_size,
        .@"align" = page_size,
    };

    const memory = try sys_memory.mapAnonymous(page_size, .{});
    defer sys_memory.unmap(memory);
    try loadSegments(-1, &image, image.len, @intFromPtr(memory.ptr), eh, page_size);
    try std.testing.expectEqualSlices(u8, &source, memory[0..source.len]);
    try std.testing.expect(std.mem.allEqual(u8, memory[source.len..page_size], 0));
}

fn loadNativeElfDependencies(
    allocator: std.mem.Allocator,
    owner_path: []const u8,
    strings: [*:0]u8,
    needed_offsets: []const usize,
    rpath: ?[]const u8,
    runpath: ?[]const u8,
) NativeElfError![]NativeElfHandle {
    var dependencies: std.ArrayList(NativeElfHandle) = .empty;
    errdefer {
        for (dependencies.items) |*dependency| dependency.close();
        dependencies.deinit(allocator);
    }

    for (needed_offsets) |offset| {
        const needed_name = std.mem.sliceTo(strings + offset, 0);
        const dependency_path = try resolveNeededLibrary(allocator, owner_path, needed_name, rpath, runpath);
        defer allocator.free(dependency_path);
        try dependencies.append(allocator, try openNativeElfShared(allocator, dependency_path));
    }

    return dependencies.toOwnedSlice(allocator);
}

fn openNativeElfShared(allocator: std.mem.Allocator, path: []const u8) NativeElfError!NativeElfHandle {
    if (retainNativeElfShared(path)) |handle| return handle;

    var library = try NativeElfLibrary.openUncached(path);
    errdefer library.close();

    const stored_path = try allocator.dupe(u8, path);
    errdefer allocator.free(stored_path);

    const shared = try allocator.create(NativeElfSharedLibrary);
    errdefer allocator.destroy(shared);
    shared.* = .{
        .path = stored_path,
        .ref_count = 1,
        .library = library,
    };

    native_elf_registry.lock();
    defer native_elf_registry.mutex.unlock();
    for (native_elf_registry.libraries.items) |existing| {
        if (std.mem.eql(u8, existing.path, path)) {
            existing.ref_count += 1;
            library.close();
            allocator.free(stored_path);
            allocator.destroy(shared);
            return .{ .shared = existing };
        }
    }
    try native_elf_registry.libraries.append(allocator, shared);
    return .{ .shared = shared };
}

fn retainNativeElfShared(path: []const u8) ?NativeElfHandle {
    native_elf_registry.lock();
    defer native_elf_registry.mutex.unlock();
    for (native_elf_registry.libraries.items) |shared| {
        if (!std.mem.eql(u8, shared.path, path)) continue;
        shared.ref_count += 1;
        return .{ .shared = shared };
    }
    return null;
}

fn resolveNativeElfOpenPath(allocator: std.mem.Allocator, path: []const u8) NativeElfError![]u8 {
    if (!canUseNativeElfPlatform()) return error.NativeElfUnsupported;
    if (hasLibraryPathSeparator(path)) return allocator.dupe(u8, path);
    if (path.len == 0) return error.FileNotFound;
    return resolvePathlessLibrary(allocator, path);
}

fn releaseNativeElfShared(shared: *NativeElfSharedLibrary) void {
    const allocator = sys_allocator.processAllocator();
    var owned: ?*NativeElfSharedLibrary = null;
    native_elf_registry.lock();
    if (shared.ref_count > 1) {
        shared.ref_count -= 1;
    } else {
        const index = for (native_elf_registry.libraries.items, 0..) |candidate, index| {
            if (candidate == shared) break index;
        } else native_elf_registry.libraries.items.len;
        if (index < native_elf_registry.libraries.items.len) {
            _ = native_elf_registry.libraries.swapRemove(index);
        }
        owned = shared;
    }
    native_elf_registry.mutex.unlock();

    if (owned) |library| {
        library.library.close();
        allocator.free(library.path);
        allocator.destroy(library);
    }
}

fn closeNativeElfDependencies(allocator: std.mem.Allocator, dependencies: []NativeElfHandle) void {
    for (dependencies) |*dependency| dependency.close();
    allocator.free(dependencies);
}

fn resolveNeededLibrary(
    allocator: std.mem.Allocator,
    owner_path: []const u8,
    needed_name: []const u8,
    rpath: ?[]const u8,
    runpath: ?[]const u8,
) NativeElfError![]u8 {
    if (hasLibraryPathSeparator(needed_name)) return allocator.dupe(u8, needed_name);

    if (rpath != null and runpath == null) {
        if (try resolveLibraryInSearchPath(allocator, owner_path, needed_name, rpath.?)) |path| return path;
    }

    if (sys_env.getConstant("LD_LIBRARY_PATH")) |paths| {
        if (try resolveLibraryInSearchPath(allocator, owner_path, needed_name, paths)) |path| return path;
    }

    if (runpath) |paths| {
        if (try resolveLibraryInSearchPath(allocator, owner_path, needed_name, paths)) |path| return path;
    }

    const origin = std.fs.path.dirname(owner_path) orelse ".";
    const origin_candidate = try std.fs.path.join(allocator, &.{ origin, needed_name });
    if (pathExists(origin_candidate)) return origin_candidate;
    allocator.free(origin_candidate);

    return resolveDefaultLibrary(allocator, needed_name);
}

fn resolvePathlessLibrary(allocator: std.mem.Allocator, name: []const u8) NativeElfError![]u8 {
    if (sys_env.getConstant("LD_LIBRARY_PATH")) |paths| {
        if (try resolveLibraryInSearchPath(allocator, ".", name, paths)) |path| return path;
    }
    return resolveDefaultLibrary(allocator, name);
}

fn resolveLibraryInSearchPath(
    allocator: std.mem.Allocator,
    owner_path: []const u8,
    name: []const u8,
    search_path: []const u8,
) NativeElfError!?[]u8 {
    var iterator = std.mem.splitScalar(u8, search_path, ':');
    while (iterator.next()) |entry| {
        const path_entry = if (entry.len == 0) "." else entry;
        const expanded = try expandLibrarySearchEntry(allocator, owner_path, path_entry);
        defer allocator.free(expanded);
        const candidate = try std.fs.path.join(allocator, &.{ expanded, name });
        if (pathExists(candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn resolveDefaultLibrary(allocator: std.mem.Allocator, name: []const u8) NativeElfError![]u8 {
    for (nativeDefaultLibraryDirectories()) |directory| {
        const candidate = try std.fs.path.join(allocator, &.{ directory, name });
        if (pathExists(candidate)) return candidate;
        allocator.free(candidate);
    }
    return error.FileNotFound;
}

const generic_library_directories = [_][]const u8{
    "/lib",
    "/usr/lib",
    "/usr/local/lib",
    "/lib64",
    "/usr/lib64",
    "/usr/local/lib64",
};

const x86_64_linux_library_directories = [_][]const u8{
    "/lib/x86_64-linux-gnu",
    "/usr/lib/x86_64-linux-gnu",
    "/usr/local/lib/x86_64-linux-gnu",
    "/lib",
    "/usr/lib",
    "/usr/local/lib",
    "/lib64",
    "/usr/lib64",
    "/usr/local/lib64",
};

const x86_linux_library_directories = [_][]const u8{
    "/lib/i386-linux-gnu",
    "/usr/lib/i386-linux-gnu",
    "/lib/i686-linux-gnu",
    "/usr/lib/i686-linux-gnu",
    "/lib",
    "/usr/lib",
    "/usr/local/lib",
};

const aarch64_linux_library_directories = [_][]const u8{
    "/lib/aarch64-linux-gnu",
    "/usr/lib/aarch64-linux-gnu",
    "/usr/local/lib/aarch64-linux-gnu",
    "/lib",
    "/usr/lib",
    "/usr/local/lib",
};

const arm_linux_library_directories = [_][]const u8{
    "/lib/arm-linux-gnueabihf",
    "/usr/lib/arm-linux-gnueabihf",
    "/lib/arm-linux-gnueabi",
    "/usr/lib/arm-linux-gnueabi",
    "/lib",
    "/usr/lib",
    "/usr/local/lib",
};

const riscv64_linux_library_directories = [_][]const u8{
    "/lib/riscv64-linux-gnu",
    "/usr/lib/riscv64-linux-gnu",
    "/usr/local/lib/riscv64-linux-gnu",
    "/lib",
    "/usr/lib",
    "/usr/local/lib",
};

const powerpc64le_linux_library_directories = [_][]const u8{
    "/lib/powerpc64le-linux-gnu",
    "/usr/lib/powerpc64le-linux-gnu",
    "/usr/local/lib/powerpc64le-linux-gnu",
    "/lib",
    "/usr/lib",
    "/usr/local/lib",
};

const s390x_linux_library_directories = [_][]const u8{
    "/lib/s390x-linux-gnu",
    "/usr/lib/s390x-linux-gnu",
    "/usr/local/lib/s390x-linux-gnu",
    "/lib",
    "/usr/lib",
    "/usr/local/lib",
};

const loongarch64_linux_library_directories = [_][]const u8{
    "/lib/loongarch64-linux-gnu",
    "/usr/lib/loongarch64-linux-gnu",
    "/usr/local/lib/loongarch64-linux-gnu",
    "/lib",
    "/usr/lib",
    "/usr/local/lib",
};

fn nativeDefaultLibraryDirectories() []const []const u8 {
    if (comptime builtin.os.tag != .linux) return &generic_library_directories;
    return switch (builtin.cpu.arch) {
        .x86_64 => &x86_64_linux_library_directories,
        .x86 => &x86_linux_library_directories,
        .aarch64, .aarch64_be => &aarch64_linux_library_directories,
        .arm, .armeb, .thumb, .thumbeb => &arm_linux_library_directories,
        .riscv64, .riscv64be => &riscv64_linux_library_directories,
        .powerpc64le => &powerpc64le_linux_library_directories,
        .s390x => &s390x_linux_library_directories,
        .loongarch64 => &loongarch64_linux_library_directories,
        else => &generic_library_directories,
    };
}

fn nativeDefaultLibraryDirectoriesContain(path: []const u8) bool {
    for (nativeDefaultLibraryDirectories()) |directory| {
        if (std.mem.eql(u8, directory, path)) return true;
    }
    return false;
}

fn expandLibrarySearchEntry(
    allocator: std.mem.Allocator,
    owner_path: []const u8,
    entry: []const u8,
) NativeElfError![]u8 {
    if (!std.mem.startsWith(u8, entry, "$ORIGIN")) return allocator.dupe(u8, entry);

    const origin = std.fs.path.dirname(owner_path) orelse ".";
    if (entry.len == "$ORIGIN".len) return allocator.dupe(u8, origin);
    if (entry.len > "$ORIGIN".len and entry["$ORIGIN".len] == '/') {
        return std.fs.path.join(allocator, &.{ origin, entry["$ORIGIN".len + 1 ..] });
    }
    return allocator.dupe(u8, entry);
}

fn pathExists(path: []const u8) bool {
    const io = std.Options.debug_io;
    var file = if (path.len > 0 and path[0] == '/')
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn applyNativeElfRelocations(
    base: usize,
    dynamic_vaddr: usize,
    syms: [*]elf.Sym,
    strings: [*:0]u8,
    symbol_count: usize,
    versyms: ?[*]elf.Versym,
    verneed: usize,
    verneed_count: usize,
    tls: *const NativeElfTlsAllocation,
    dependencies: []const NativeElfHandle,
) NativeElfError!void {
    var rela: usize = 0;
    var rela_size: usize = 0;
    var rela_entry_size: usize = @sizeOf(elf.Rela);
    var rel: usize = 0;
    var rel_size: usize = 0;
    var rel_entry_size: usize = @sizeOf(elf.Rel);
    var relr: usize = 0;
    var relr_size: usize = 0;
    var relr_entry_size: usize = @sizeOf(elf.Relr);
    var jmprel: usize = 0;
    var pltrel_size: usize = 0;
    var pltrel: usize = elf.DT_RELA;

    const dynv: [*]usize = @ptrFromInt(base + dynamic_vaddr);
    var i: usize = 0;
    while (dynv[i] != 0) : (i += 2) {
        switch (dynv[i]) {
            elf.DT_RELA => rela = dynv[i + 1],
            elf.DT_RELASZ => rela_size = dynv[i + 1],
            elf.DT_RELAENT => rela_entry_size = dynv[i + 1],
            elf.DT_REL => rel = dynv[i + 1],
            elf.DT_RELSZ => rel_size = dynv[i + 1],
            elf.DT_RELENT => rel_entry_size = dynv[i + 1],
            elf.DT_RELR => relr = dynv[i + 1],
            elf.DT_RELRSZ => relr_size = dynv[i + 1],
            elf.DT_RELRENT => relr_entry_size = dynv[i + 1],
            elf.DT_JMPREL => jmprel = dynv[i + 1],
            elf.DT_PLTRELSZ => pltrel_size = dynv[i + 1],
            elf.DT_PLTREL => pltrel = dynv[i + 1],
            else => {},
        }
    }

    if (rel != 0) {
        if (rel_entry_size != @sizeOf(elf.Rel)) return error.NativeElfUnsupportedRelocation;
        const rels: []const elf.Rel = @ptrCast(@alignCast(
            @as([*]align(@alignOf(elf.Rel)) const u8, @ptrFromInt(base + rel))[0..rel_size],
        ));
        for (rels) |r| {
            try applyNativeElfRel(base, syms, strings, symbol_count, versyms, verneed, verneed_count, tls, dependencies, r);
        }
    }

    if (rela != 0) {
        if (rela_entry_size != @sizeOf(elf.Rela)) return error.NativeElfUnsupportedRelocation;
        const relas: []const elf.Rela = @ptrCast(@alignCast(
            @as([*]align(@alignOf(elf.Rela)) const u8, @ptrFromInt(base + rela))[0..rela_size],
        ));
        for (relas) |r| {
            try applyNativeElfRela(base, syms, strings, symbol_count, versyms, verneed, verneed_count, tls, dependencies, r);
        }
    }

    if (jmprel != 0 or pltrel_size != 0) {
        switch (pltrel) {
            elf.DT_REL => {
                if (pltrel_size % @sizeOf(elf.Rel) != 0) return error.NativeElfUnsupportedRelocation;
                const rels: []const elf.Rel = @ptrCast(@alignCast(
                    @as([*]align(@alignOf(elf.Rel)) const u8, @ptrFromInt(base + jmprel))[0..pltrel_size],
                ));
                for (rels) |r| {
                    try applyNativeElfRel(base, syms, strings, symbol_count, versyms, verneed, verneed_count, tls, dependencies, r);
                }
            },
            elf.DT_RELA => {
                if (pltrel_size % @sizeOf(elf.Rela) != 0) return error.NativeElfUnsupportedRelocation;
                const relas: []const elf.Rela = @ptrCast(@alignCast(
                    @as([*]align(@alignOf(elf.Rela)) const u8, @ptrFromInt(base + jmprel))[0..pltrel_size],
                ));
                for (relas) |r| {
                    try applyNativeElfRela(base, syms, strings, symbol_count, versyms, verneed, verneed_count, tls, dependencies, r);
                }
            },
            else => return error.NativeElfUnsupportedRelocation,
        }
    }

    if (relr != 0) {
        applyRelativeRelrRelocations(base, relr, relr_size, relr_entry_size) catch return error.NativeElfUnsupportedRelocation;
    }
}

fn applyNativeElfRel(
    base: usize,
    syms: [*]elf.Sym,
    strings: [*:0]u8,
    symbol_count: usize,
    versyms: ?[*]elf.Versym,
    verneed: usize,
    verneed_count: usize,
    tls: *const NativeElfTlsAllocation,
    dependencies: []const NativeElfHandle,
    relocation: elf.Rel,
) NativeElfError!void {
    const target: *usize = @ptrFromInt(base + relocation.r_offset);
    switch (relocation.r_type()) {
        relativeRelocationKind() => target.* += base,
        else => try applyNativeElfSymbolRelocation(base, syms, strings, symbol_count, versyms, verneed, verneed_count, tls, dependencies, relocation.r_sym(), relocation.r_type(), relocation.r_offset, 0),
    }
}

fn applyNativeElfRela(
    base: usize,
    syms: [*]elf.Sym,
    strings: [*:0]u8,
    symbol_count: usize,
    versyms: ?[*]elf.Versym,
    verneed: usize,
    verneed_count: usize,
    tls: *const NativeElfTlsAllocation,
    dependencies: []const NativeElfHandle,
    relocation: elf.Rela,
) NativeElfError!void {
    if (irelativeRelocationKind()) |irelative_kind| {
        if (relocation.r_type() == irelative_kind) {
            if (relocation.r_sym() != 0) return error.NativeElfUnsupportedRelocation;
            const resolver_address = try addSigned(base, relocation.r_addend);
            @as(*usize, @ptrFromInt(base + relocation.r_offset)).* = @as(NativeElfIfuncResolver, @ptrFromInt(resolver_address))();
            return;
        }
    }
    switch (relocation.r_type()) {
        relativeRelocationKind() => @as(*usize, @ptrFromInt(base + relocation.r_offset)).* = try addSigned(base, relocation.r_addend),
        else => try applyNativeElfSymbolRelocation(base, syms, strings, symbol_count, versyms, verneed, verneed_count, tls, dependencies, relocation.r_sym(), relocation.r_type(), relocation.r_offset, relocation.r_addend),
    }
}

fn applyNativeElfSymbolRelocation(
    base: usize,
    syms: [*]elf.Sym,
    strings: [*:0]u8,
    symbol_count: usize,
    versyms: ?[*]elf.Versym,
    verneed: usize,
    verneed_count: usize,
    tls: *const NativeElfTlsAllocation,
    dependencies: []const NativeElfHandle,
    symbol_index: usize,
    relocation_kind: u32,
    offset: usize,
    addend: isize,
) NativeElfError!void {
    const absolute_kind = absoluteRelocationKind();
    const glob_dat_kind = globDatRelocationKind();
    const jump_slot_kind = jumpSlotRelocationKind();
    if (try applyNativeElfTlsRelocation(base, syms, strings, symbol_count, versyms, verneed, verneed_count, tls, dependencies, symbol_index, relocation_kind, offset, addend)) return;
    if ((absolute_kind == null or relocation_kind != absolute_kind.?) and
        (glob_dat_kind == null or relocation_kind != glob_dat_kind.?) and
        (jump_slot_kind == null or relocation_kind != jump_slot_kind.?))
    {
        return error.NativeElfUnsupportedRelocation;
    }
    if (symbol_index >= symbol_count) return error.NativeElfUnsupportedRelocation;

    const symbol = syms[symbol_index];
    const name = std.mem.sliceTo(strings + symbol.st_name, 0);
    const address = if (symbol.st_shndx != 0)
        nativeElfSymbolAddress(base, symbol)
    else blk: {
        if (nativeElfBuiltinSymbolAddress(name)) |address| break :blk address;
        const version = try nativeElfNeededVersionName(base, strings, versyms, verneed, verneed_count, symbol_index);
        if (resolveNativeElfDependencySymbol(dependencies, name, version)) |address| break :blk address;
        if (nativeElfSymbolBind(symbol) == elf.STB_WEAK) break :blk 0;
        return error.NativeElfUnsupportedRelocation;
    };
    @as(*usize, @ptrFromInt(base + offset)).* = try addSigned(address, addend);
}

fn applyNativeElfTlsRelocation(
    base: usize,
    syms: [*]elf.Sym,
    strings: [*:0]u8,
    symbol_count: usize,
    versyms: ?[*]elf.Versym,
    verneed: usize,
    verneed_count: usize,
    tls: *const NativeElfTlsAllocation,
    dependencies: []const NativeElfHandle,
    symbol_index: usize,
    relocation_kind: u32,
    offset: usize,
    addend: isize,
) NativeElfError!bool {
    if (tlsModuleRelocationKind()) |module_kind| {
        if (relocation_kind == module_kind) {
            if (symbol_index == 0) {
                if (!tls.active()) return error.NativeElfUnsupportedRelocation;
                @as(*usize, @ptrFromInt(base + offset)).* = try addSigned(tls.module_id, addend);
                return true;
            }
            const symbol = try nativeElfRelocationTlsSymbol(base, syms, strings, symbol_count, versyms, verneed, verneed_count, tls, dependencies, symbol_index);
            @as(*usize, @ptrFromInt(base + offset)).* = try addSigned(symbol.module_id, addend);
            return true;
        }
    }
    if (tlsOffsetRelocationKind()) |offset_kind| {
        if (relocation_kind == offset_kind) {
            const symbol = try nativeElfRelocationTlsSymbol(base, syms, strings, symbol_count, versyms, verneed, verneed_count, tls, dependencies, symbol_index);
            const tls_offset = try addSigned(symbol.offset, addend);
            if (tls_offset >= symbol.payload_len) return error.NativeElfUnsupportedRelocation;
            @as(*usize, @ptrFromInt(base + offset)).* = tls_offset;
            return true;
        }
    }
    return false;
}

fn nativeElfRelocationTlsSymbol(
    base: usize,
    syms: [*]elf.Sym,
    strings: [*:0]u8,
    symbol_count: usize,
    versyms: ?[*]elf.Versym,
    verneed: usize,
    verneed_count: usize,
    tls: *const NativeElfTlsAllocation,
    dependencies: []const NativeElfHandle,
    symbol_index: usize,
) NativeElfError!NativeElfTlsSymbol {
    if (symbol_index >= symbol_count) return error.NativeElfUnsupportedRelocation;
    const symbol = syms[symbol_index];
    if (symbol.st_shndx != 0) {
        if (!tls.active()) return error.NativeElfUnsupportedRelocation;
        if (symbol.st_info & 0xf != elf.STT_TLS) return error.NativeElfUnsupportedRelocation;
        const symbol_offset = std.math.cast(usize, symbol.st_value) orelse return error.NativeElfUnsupportedRelocation;
        if (symbol_offset >= tls.payload_len) return error.NativeElfUnsupportedRelocation;
        return .{
            .module_id = tls.module_id,
            .offset = symbol_offset,
            .payload_len = tls.payload_len,
        };
    }

    const name = std.mem.sliceTo(strings + symbol.st_name, 0);
    if (symbol.st_info & 0xf != elf.STT_TLS) return error.NativeElfUnsupportedRelocation;
    const version = try nativeElfNeededVersionName(base, strings, versyms, verneed, verneed_count, symbol_index);
    return resolveNativeElfDependencyTlsSymbol(dependencies, name, version) orelse error.NativeElfUnsupportedRelocation;
}

fn nativeElfBuiltinSymbolAddress(name: []const u8) ?usize {
    if (canUseNativeElfTls() and std.mem.eql(u8, name, "__tls_get_addr")) return @intFromPtr(&nativeElfTlsGetAddr);
    return null;
}

fn resolveNativeElfDependencySymbol(dependencies: []const NativeElfHandle, name: []const u8, version: ?[]const u8) ?usize {
    for (dependencies) |*dependency| {
        if (dependency.lookupAddressVersioned(name, version)) |address| return address;
    }
    for (dependencies) |*dependency| {
        if (resolveNativeElfDependencySymbol(dependency.shared.library.dependencies, name, version)) |address| return address;
    }
    return null;
}

fn resolveNativeElfDependencyTlsSymbol(dependencies: []const NativeElfHandle, name: []const u8, version: ?[]const u8) ?NativeElfTlsSymbol {
    for (dependencies) |*dependency| {
        if (dependency.lookupTlsSymbolVersioned(name, version)) |symbol| return symbol;
    }
    for (dependencies) |*dependency| {
        if (resolveNativeElfDependencyTlsSymbol(dependency.shared.library.dependencies, name, version)) |symbol| return symbol;
    }
    return null;
}

const ElfVerneed = if (@sizeOf(usize) == 8) elf.Elf64_Verneed else elf.Elf32_Verneed;

fn nativeElfNeededVersionName(
    base: usize,
    strings: [*:0]u8,
    versyms: ?[*]elf.Versym,
    verneed: usize,
    verneed_count: usize,
    symbol_index: usize,
) NativeElfError!?[]const u8 {
    const table = versyms orelse return null;
    const requested = table[symbol_index];
    if (requested.VERSION <= @backingInt(elf.VER_NDX.GLOBAL)) return null;
    if (verneed == 0) return error.NativeElfUnsupportedRelocation;

    var need_addr = base + verneed;
    var need_index: usize = 0;
    while (need_index < verneed_count) : (need_index += 1) {
        const need: *const ElfVerneed = @ptrFromInt(need_addr);
        var aux_addr = need_addr + need.vn_aux;
        var aux_index: usize = 0;
        while (aux_index < need.vn_cnt) : (aux_index += 1) {
            const aux: *const elf.Vernaux = @ptrFromInt(aux_addr);
            if (aux.other == requested.VERSION) return std.mem.sliceTo(strings + aux.name, 0);
            if (aux.next == 0) break;
            aux_addr += aux.next;
        }
        if (need.vn_next == 0) break;
        need_addr += need.vn_next;
    }
    return error.NativeElfUnsupportedRelocation;
}

fn runNativeElfInitializers(base: usize, init: usize, init_array: usize, init_array_size: usize) NativeElfError!void {
    if (init != 0) callNativeElfInit(base + init);
    if (init_array_size % @sizeOf(usize) != 0) return error.InvalidElfImage;
    const count = init_array_size / @sizeOf(usize);
    if (count == 0) return;
    const functions: [*]const usize = @ptrFromInt(base + init_array);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (functions[index] != 0) callNativeElfInit(functions[index]);
    }
}

fn runNativeElfFinalizers(base: usize, fini: usize, fini_array: usize, fini_array_count: usize) void {
    if (fini_array_count != 0) {
        const functions: [*]const usize = @ptrFromInt(base + fini_array);
        var index = fini_array_count;
        while (index > 0) {
            index -= 1;
            if (functions[index] != 0) callNativeElfInit(functions[index]);
        }
    }
    if (fini != 0) callNativeElfInit(base + fini);
}

fn protectNativeElfRelro(base: usize, relro_vaddr: usize, relro_memsz: usize, page_size: usize) NativeElfError!void {
    if (relro_memsz == 0) return;
    const relro_start = checkedAdd(base, relro_vaddr) orelse return error.InvalidElfImage;
    const relro_end = checkedAdd(relro_start, relro_memsz) orelse return error.InvalidElfImage;
    const page_start = std.mem.alignBackward(usize, relro_start, page_size);
    const page_end = std.mem.alignForward(usize, relro_end, page_size);
    if (page_end <= page_start) return;
    const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(page_start);
    try protectNativeElfMemory(ptr[0 .. page_end - page_start], .{ .read = true });
}

fn protectNativeElfMemory(
    memory: []align(std.heap.page_size_min) u8,
    protection: sys_memory.Protection,
) NativeElfError!void {
    sys_memory.protect(memory, protection) catch |err| switch (err) {
        error.InvalidMapping => return error.InvalidElfImage,
        error.OutOfMemory => return error.OutOfMemory,
        error.AccessDenied, error.PermissionDenied, error.UnsupportedPlatform, error.ProtectFailed => return error.NativeElfUnsupported,
    };
}

fn callNativeElfInit(address: usize) void {
    const InitFn = *const fn () callconv(.c) void;
    @as(InitFn, @ptrFromInt(address))();
}

fn elfToProtection(flags: elf.PF) sys_memory.Protection {
    return .{ .read = flags.R, .write = flags.W, .execute = flags.X };
}

fn checkedAdd(left: usize, right: usize) ?usize {
    const result, const overflow = @addWithOverflow(left, right);
    if (overflow != 0) return null;
    return result;
}

fn addSigned(base: usize, addend: isize) NativeElfError!usize {
    if (addend >= 0) return checkedAdd(base, @intCast(addend)) orelse error.InvalidElfImage;
    if (addend == std.math.minInt(isize)) return error.InvalidElfImage;
    const magnitude: usize = @intCast(-addend);
    if (base < magnitude) return error.InvalidElfImage;
    return base - magnitude;
}

pub const LibraryCandidate = struct {
    os: ?std.Target.Os.Tag = null,
    name: []const u8,

    pub fn matchesHost(self: LibraryCandidate) bool {
        return self.os == null or self.os.? == builtin.os.tag;
    }
};

const cuda_driver_candidates = [_]LibraryCandidate{
    .{ .os = .linux, .name = "libcuda.so.1" },
    .{ .os = .linux, .name = "libcuda.so" },
};

const vulkan_loader_candidates = [_]LibraryCandidate{
    .{ .os = .linux, .name = "libvulkan.so.1" },
    .{ .os = .linux, .name = "libvulkan.so" },
    .{ .os = .macos, .name = "libvulkan.1.dylib" },
    .{ .os = .windows, .name = "vulkan-1.dll" },
};

const x11_library_candidates = [_]LibraryCandidate{
    .{ .os = .linux, .name = "libX11.so.6" },
    .{ .os = .linux, .name = "libX11.so" },
};

pub fn cudaDriverCandidates() []const LibraryCandidate {
    return &cuda_driver_candidates;
}

pub fn vulkanLoaderCandidates() []const LibraryCandidate {
    return &vulkan_loader_candidates;
}

pub fn x11LibraryCandidates() []const LibraryCandidate {
    return &x11_library_candidates;
}

pub fn hasHostCandidate(candidates: []const LibraryCandidate) bool {
    for (candidates) |candidate| {
        if (candidate.matchesHost()) return true;
    }
    return false;
}

pub fn openFirst(candidates: []const LibraryCandidate) OpenFirstError!Library {
    var matched = false;
    var last_error: ?LibraryError = null;

    for (candidates) |candidate| {
        if (!candidate.matchesHost()) continue;
        matched = true;
        return Library.open(candidate.name) catch |err| {
            last_error = err;
            continue;
        };
    }

    if (!matched) return error.NoCandidate;
    return last_error.?;
}

pub fn openFirstNativeElfOnLinux(candidates: []const LibraryCandidate) OpenFirstError!Library {
    var matched = false;
    var last_error: ?LibraryError = null;

    for (candidates) |candidate| {
        if (!candidate.matchesHost()) continue;
        matched = true;
        if (comptime builtin.os.tag == .linux) {
            return Library.openNativeElf(candidate.name) catch |err| {
                last_error = err;
                continue;
            };
        }
        return Library.open(candidate.name) catch |err| {
            last_error = err;
            continue;
        };
    }

    if (!matched) return error.NoCandidate;
    return last_error.?;
}

pub fn isLoadable(candidates: []const LibraryCandidate) bool {
    var library = openFirst(candidates) catch return false;
    library.close();
    return true;
}

pub fn openSystemLibrary(candidates: []const LibraryCandidate) OpenFirstError!Library {
    if (comptime usesStdElfDynLib()) return openFirstNativeElfOnLinux(candidates);

    var matched = false;
    var last_error: ?LibraryError = null;
    for (candidates) |candidate| {
        if (!candidate.matchesHost()) continue;
        matched = true;
        const raw = openHostSystemLibrary(candidate.name) catch |err| {
            last_error = err;
            continue;
        };
        return .{ .raw = .{ .std_dynlib = raw } };
    }

    if (!matched) return error.NoCandidate;
    return last_error.?;
}

fn openHostSystemLibrary(name: []const u8) LibraryError!std.DynLib {
    return std.DynLib.open(name) catch |err| {
        if (comptime builtin.os.tag != .linux) return err;
        if (std.mem.indexOfScalar(u8, name, '/') != null) return err;

        const allocator = sys_allocator.processAllocator();
        const path = try resolvePathlessLibrary(allocator, name);
        defer allocator.free(path);
        return std.DynLib.open(path);
    };
}

pub fn openCudaDriver() OpenFirstError!Library {
    return openSystemLibrary(cudaDriverCandidates());
}

pub fn openVulkanLoader() OpenFirstError!Library {
    return openSystemLibrary(vulkanLoaderCandidates());
}

pub fn openX11Library() OpenFirstError!Library {
    return openSystemLibrary(x11LibraryCandidates());
}

pub fn isCudaDriverLoadable() bool {
    var library = openCudaDriver() catch return false;
    library.close();
    return true;
}

pub fn isVulkanLoaderLoadable() bool {
    var library = openVulkanLoader() catch return false;
    library.close();
    return true;
}

test "library candidates are host-filtered" {
    const other_os: std.Target.Os.Tag = switch (builtin.os.tag) {
        .linux => .macos,
        else => .linux,
    };

    try std.testing.expect(hasHostCandidate(&.{
        .{ .os = other_os, .name = "sys_missing_library" },
        .{ .os = builtin.os.tag, .name = "sys_missing_library" },
    }));
    try std.testing.expect(!hasHostCandidate(&.{
        .{ .os = other_os, .name = "sys_missing_library" },
    }));
}

test "openFirst reports missing host candidates" {
    const other_os: std.Target.Os.Tag = switch (builtin.os.tag) {
        .linux => .macos,
        else => .linux,
    };

    try std.testing.expectError(error.NoCandidate, openFirst(&.{
        .{ .os = other_os, .name = "sys_missing_library" },
    }));
}

test "openSystemLibrary reports missing host candidates" {
    const other_os: std.Target.Os.Tag = switch (builtin.os.tag) {
        .linux => .macos,
        else => .linux,
    };

    try std.testing.expectError(error.NoCandidate, openSystemLibrary(&.{
        .{ .os = other_os, .name = "sys_missing_library" },
    }));
}

test "native-on-Linux openFirst reports missing host candidates" {
    const other_os: std.Target.Os.Tag = switch (builtin.os.tag) {
        .linux => .macos,
        else => .linux,
    };

    try std.testing.expectError(error.NoCandidate, openFirstNativeElfOnLinux(&.{
        .{ .os = other_os, .name = "sys_missing_library" },
    }));
}

test "native default library directories include linux multiarch paths" {
    if (builtin.os.tag != .linux) return;

    switch (builtin.cpu.arch) {
        .x86_64 => {
            try std.testing.expect(nativeDefaultLibraryDirectoriesContain("/lib/x86_64-linux-gnu"));
            try std.testing.expect(nativeDefaultLibraryDirectoriesContain("/usr/lib/x86_64-linux-gnu"));
        },
        .aarch64, .aarch64_be => {
            try std.testing.expect(nativeDefaultLibraryDirectoriesContain("/lib/aarch64-linux-gnu"));
            try std.testing.expect(nativeDefaultLibraryDirectoriesContain("/usr/lib/aarch64-linux-gnu"));
        },
        .riscv64, .riscv64be => {
            try std.testing.expect(nativeDefaultLibraryDirectoriesContain("/lib/riscv64-linux-gnu"));
            try std.testing.expect(nativeDefaultLibraryDirectoriesContain("/usr/lib/riscv64-linux-gnu"));
        },
        else => {},
    }
}

fn usesStdElfDynLib() bool {
    return builtin.os.tag == .linux and (!builtin.link_libc or builtin.abi == .musl and builtin.link_mode == .static);
}

fn repairElfImage(path: []const u8, raw: *std.DynLib) ElfRepairError!void {
    if (comptime !usesStdElfDynLib()) {
        return;
    }

    const io = std.Options.debug_io;
    var file = if (path.len > 0 and path[0] == '/')
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    if (size < @sizeOf(elf.Ehdr)) return error.InvalidElfImage;
    const file_bytes = try sys_memory.mapPrivateFile(file.handle, size, .{ .read = true }, 0);
    defer sys_memory.unmap(file_bytes);

    const eh: *const elf.Ehdr = @ptrCast(file_bytes.ptr);
    if (!std.mem.eql(u8, eh.e_ident[0..4], elf.MAGIC)) return error.InvalidElfImage;
    if (eh.e_type != elf.ET.DYN) return error.InvalidElfImage;
    if (eh.e_phoff + @as(usize, eh.e_phentsize) * eh.e_phnum > size) return error.InvalidElfImage;

    const base = @intFromPtr(raw.inner.memory.ptr);
    const file_addr = @intFromPtr(file_bytes.ptr);
    var dynamic_vaddr: ?usize = null;
    var i: usize = 0;
    var ph_addr = file_addr + eh.e_phoff;
    while (i < eh.e_phnum) : ({
        i += 1;
        ph_addr += eh.e_phentsize;
    }) {
        const ph: *const elf.ElfN.Phdr = @ptrFromInt(ph_addr);
        switch (ph.type) {
            .LOAD => if (ph.flags.W) {
                if (ph.memsz < ph.filesz) return error.InvalidElfImage;
                if (ph.offset + ph.filesz > size) return error.InvalidElfImage;
                const segment: [*]u8 = @ptrFromInt(base + ph.vaddr);
                const source = file_bytes[ph.offset..][0..ph.filesz];
                @memcpy(segment[0..ph.filesz], source);
                if (ph.memsz > ph.filesz) {
                    @memset(segment[ph.filesz..ph.memsz], 0);
                }
            },
            .DYNAMIC => dynamic_vaddr = ph.vaddr,
            else => {},
        }
    }

    try applyElfRelativeRelocations(base, dynamic_vaddr orelse return error.InvalidElfImage);
}

fn applyElfRelativeRelocations(base: usize, dynamic_vaddr: usize) ElfRepairError!void {
    var rela: usize = 0;
    var rela_size: usize = 0;
    var rela_entry_size: usize = @sizeOf(elf.Rela);
    var rel: usize = 0;
    var rel_size: usize = 0;
    var rel_entry_size: usize = @sizeOf(elf.Rel);
    var relr: usize = 0;
    var relr_size: usize = 0;
    var relr_entry_size: usize = @sizeOf(elf.Relr);

    const dynv: [*]usize = @ptrFromInt(base + dynamic_vaddr);
    var i: usize = 0;
    while (dynv[i] != 0) : (i += 2) {
        switch (dynv[i]) {
            elf.DT_RELA => rela = dynv[i + 1],
            elf.DT_RELASZ => rela_size = dynv[i + 1],
            elf.DT_RELAENT => rela_entry_size = dynv[i + 1],
            elf.DT_REL => rel = dynv[i + 1],
            elf.DT_RELSZ => rel_size = dynv[i + 1],
            elf.DT_RELENT => rel_entry_size = dynv[i + 1],
            elf.DT_RELR => relr = dynv[i + 1],
            elf.DT_RELRSZ => relr_size = dynv[i + 1],
            elf.DT_RELRENT => relr_entry_size = dynv[i + 1],
            else => {},
        }
    }

    if (rel != 0) {
        if (rel_entry_size != @sizeOf(elf.Rel)) return error.UnsupportedElfRelocation;
        const rels: []const elf.Rel = @ptrCast(@alignCast(
            @as([*]align(@alignOf(elf.Rel)) const u8, @ptrFromInt(base + rel))[0..rel_size],
        ));
        for (rels) |r| {
            if (r.r_type() != relativeRelocationKind()) continue;
            @as(*usize, @ptrFromInt(base + r.r_offset)).* += base;
        }
    }

    if (rela != 0) {
        if (rela_entry_size != @sizeOf(elf.Rela)) return error.UnsupportedElfRelocation;
        const relas: []const elf.Rela = @ptrCast(@alignCast(
            @as([*]align(@alignOf(elf.Rela)) const u8, @ptrFromInt(base + rela))[0..rela_size],
        ));
        for (relas) |r| {
            if (r.r_type() != relativeRelocationKind()) continue;
            @as(*usize, @ptrFromInt(base + r.r_offset)).* = base + @as(usize, @bitCast(r.r_addend));
        }
    }

    if (relr != 0) {
        applyRelativeRelrRelocations(base, relr, relr_size, relr_entry_size) catch return error.UnsupportedElfRelocation;
    }
}

fn applyRelativeRelrRelocations(base: usize, relr: usize, relr_size: usize, relr_entry_size: usize) error{UnsupportedRelrRelocation}!void {
    if (relr_entry_size != @sizeOf(elf.Relr)) return error.UnsupportedRelrRelocation;
    const relrs: []const elf.Relr = @ptrCast(
        @as([*]align(@alignOf(elf.Relr)) const u8, @ptrFromInt(base + relr))[0..relr_size],
    );
    var current: [*]usize = undefined;
    for (relrs) |r| {
        if ((r & 1) == 0) {
            current = @ptrFromInt(base + r);
            current[0] += base;
            current += 1;
        } else {
            var bit: usize = 1;
            while (bit < @bitSizeOf(elf.Relr)) : (bit += 1) {
                const shift: std.math.Log2Int(elf.Relr) = @intCast(bit);
                if (((r >> shift) & 1) != 0) current[bit - 1] += base;
            }
            current += @bitSizeOf(elf.Relr) - 1;
        }
    }
}

fn relativeRelocationKind() u32 {
    return switch (builtin.cpu.arch) {
        .x86 => 8,
        .x86_64 => 8,
        .arc, .arceb => 56,
        .arm, .armeb, .thumb, .thumbeb => 23,
        .aarch64, .aarch64_be => 1027,
        .alpha => 27,
        .csky => 9,
        .hexagon => 35,
        .kvx => 39,
        .loongarch32, .loongarch64 => 3,
        .m68k => 22,
        .microblaze, .microblazeel => 16,
        .mips, .mipsel, .mips64, .mips64el => 128,
        .or1k => 21,
        .powerpc, .powerpcle, .powerpc64, .powerpc64le => 22,
        .riscv32, .riscv32be, .riscv64, .riscv64be => 3,
        .s390x => 12,
        .sh, .sheb => 165,
        .sparc, .sparc64 => 22,
        else => @compileError("missing relative relocation kind"),
    };
}

fn absoluteRelocationKind() ?u32 {
    return switch (builtin.cpu.arch) {
        .x86, .x86_64 => 1,
        .aarch64, .aarch64_be => 257,
        else => null,
    };
}

fn globDatRelocationKind() ?u32 {
    return switch (builtin.cpu.arch) {
        .x86, .x86_64 => 6,
        .aarch64, .aarch64_be => 1025,
        else => null,
    };
}

fn jumpSlotRelocationKind() ?u32 {
    return switch (builtin.cpu.arch) {
        .x86, .x86_64 => 7,
        .aarch64, .aarch64_be => 1026,
        else => null,
    };
}

fn irelativeRelocationKind() ?u32 {
    return switch (builtin.cpu.arch) {
        .x86_64 => @backingInt(elf.R_X86_64.IRELATIVE),
        else => null,
    };
}

fn tlsModuleRelocationKind() ?u32 {
    return switch (builtin.cpu.arch) {
        .x86_64 => @backingInt(elf.R_X86_64.DTPMOD64),
        else => null,
    };
}

fn tlsOffsetRelocationKind() ?u32 {
    return switch (builtin.cpu.arch) {
        .x86_64 => @backingInt(elf.R_X86_64.DTPOFF64),
        else => null,
    };
}
