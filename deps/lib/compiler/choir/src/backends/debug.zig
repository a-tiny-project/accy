const std = @import("std");
const ir = @import("../core/root.zig");
const sys = @import("sys");

const Allocator = std.mem.Allocator;

pub const LineInfo = struct {
    file: ?[]const u8,
    line: u32,
    column: u32,
    name: ?[]const u8,
    op_name: []const u8,
};

pub const LineEntry = struct {
    offset: u32,
    info: LineInfo,
};

const LocationView = struct {
    file: ?[]const u8 = null,
    line: u32 = 0,
    column: u32 = 0,
    name: ?[]const u8 = null,
};

const StringTable = struct {
    allocator: Allocator,
    items: std.ArrayListUnmanaged([]const u8),
    index: std.StringHashMapUnmanaged(usize),

    fn init(allocator: Allocator) StringTable {
        return .{
            .allocator = allocator,
            .items = .empty,
            .index = .{},
        };
    }

    fn deinit(self: *StringTable) void {
        for (self.items.items) |item| {
            self.allocator.free(item);
        }
        self.items.deinit(self.allocator);
        self.index.deinit(self.allocator);
    }

    fn reset(self: *StringTable) void {
        for (self.items.items) |item| {
            self.allocator.free(item);
        }
        self.items.clearRetainingCapacity();
        self.index.clearRetainingCapacity();
    }

    fn take(self: *StringTable) StringTable {
        const out = self.*;
        self.* = StringTable.init(self.allocator);
        return out;
    }

    fn intern(self: *StringTable, s: []const u8) Allocator.Error![]const u8 {
        if (s.len == 0) return s;
        if (self.index.get(s)) |idx| {
            return self.items.items[idx];
        }
        const owned = try self.allocator.dupe(u8, s);
        errdefer self.allocator.free(owned);
        try self.items.append(self.allocator, owned);
        errdefer _ = self.items.pop();
        try self.index.put(self.allocator, owned, self.items.items.len - 1);
        return owned;
    }
};

pub const LineTable = struct {
    allocator: Allocator,
    entries: []LineEntry,
    strings: StringTable,

    pub fn deinit(self: *LineTable) void {
        self.strings.deinit();
        if (self.entries.len != 0) {
            self.allocator.free(self.entries);
        }
        self.* = undefined;
    }

    pub fn isEmpty(self: *const LineTable) bool {
        return self.entries.len == 0;
    }

    pub fn lookup(self: *const LineTable, offset: u32) ?LineInfo {
        if (self.entries.len == 0) return null;

        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.entries[mid].offset > offset) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }

        if (lo == 0) return null;
        return self.entries[lo - 1].info;
    }
};

pub const LineTableBuilder = struct {
    allocator: Allocator,
    entries: std.ArrayListUnmanaged(LineEntry),
    strings: StringTable,

    pub fn init(allocator: Allocator) LineTableBuilder {
        return .{
            .allocator = allocator,
            .entries = .empty,
            .strings = StringTable.init(allocator),
        };
    }

    pub fn deinit(self: *LineTableBuilder) void {
        self.entries.deinit(self.allocator);
        self.strings.deinit();
    }

    pub fn reset(self: *LineTableBuilder) void {
        self.entries.clearRetainingCapacity();
        self.strings.reset();
    }

    /// Sizes the table for `entries` records, so recording that many allocates nothing.
    pub fn reserve(self: *LineTableBuilder, entries: usize) Allocator.Error!void {
        try self.entries.ensureTotalCapacityPrecise(self.allocator, entries);
    }

    pub fn record(self: *LineTableBuilder, offset: u32, loc: ir.Location, op_name: []const u8) Allocator.Error!void {
        const view = pickLocation(loc);

        const info = LineInfo{
            .file = if (view.file) |file| try self.strings.intern(file) else null,
            .line = view.line,
            .column = view.column,
            .name = if (view.name) |name| try self.strings.intern(name) else null,
            .op_name = try self.strings.intern(op_name),
        };

        if (self.entries.items.len > 0) {
            const last = &self.entries.items[self.entries.items.len - 1];
            if (last.offset == offset) {
                last.* = .{ .offset = offset, .info = info };
                return;
            }
            if (lineInfoEql(last.info, info)) return;
        }

        try self.entries.append(self.allocator, .{ .offset = offset, .info = info });
    }

    pub fn finish(self: *LineTableBuilder) Allocator.Error!LineTable {
        var entries: []LineEntry = &.{};
        if (self.entries.items.len != 0) {
            entries = try self.entries.toOwnedSlice(self.allocator);
        } else if (self.entries.capacity != 0) {
            self.entries.deinit(self.allocator);
        } else {
            self.entries.clearRetainingCapacity();
        }
        const strings = self.strings.take();
        self.entries = .empty;
        return .{
            .allocator = self.allocator,
            .entries = entries,
            .strings = strings,
        };
    }
};

fn lineInfoEql(a: LineInfo, b: LineInfo) bool {
    return optionalStrEql(a.file, b.file) and
        a.line == b.line and
        a.column == b.column and
        optionalStrEql(a.name, b.name) and
        std.mem.eql(u8, a.op_name, b.op_name);
}

fn optionalStrEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn pickLocation(loc: ir.Location) LocationView {
    return switch (loc) {
        .unknown => .{},
        .file => |f| .{
            .file = f.filename,
            .line = f.line,
            .column = f.column,
        },
        .file_range => |range| .{
            .file = range.filename,
            .line = range.start.line,
            .column = range.start.column,
        },
        .name => |n| blk: {
            var view = if (n.child) |child| pickLocation(child.*) else LocationView{};
            view.name = n.name;
            break :blk view;
        },
        .fused => |f| blk: {
            var fallback: LocationView = .{};
            for (f.locations) |item| {
                const view = pickLocation(item);
                if (view.file != null) break :blk view;
                if (fallback.name == null and view.name != null) {
                    fallback = view;
                }
            }
            break :blk fallback;
        },
        .call_site => |c| blk: {
            const caller = pickLocation(c.caller.*);
            if (caller.file != null or caller.name != null) break :blk caller;
            break :blk pickLocation(c.callee.*);
        },
    };
}

const dwarf = struct {
    const version: u16 = 4;
    const addr_size: u8 = 8;

    const TAG_compile_unit: u64 = 0x11;
    const TAG_subprogram: u64 = 0x2e;

    const CHILDREN_no: u8 = 0;
    const CHILDREN_yes: u8 = 1;

    const AT_name: u64 = 0x03;
    const AT_stmt_list: u64 = 0x10;
    const AT_low_pc: u64 = 0x11;
    const AT_high_pc: u64 = 0x12;
    const AT_comp_dir: u64 = 0x1b;
    const AT_decl_file: u64 = 0x3a;
    const AT_decl_line: u64 = 0x3b;

    const FORM_addr: u64 = 0x01;
    const FORM_data1: u64 = 0x0b;
    const FORM_data4: u64 = 0x06;
    const FORM_sec_offset: u64 = 0x17;
    const FORM_string: u64 = 0x08;

    const LNS_copy: u8 = 1;
    const LNS_advance_pc: u8 = 2;
    const LNS_advance_line: u8 = 3;
    const LNS_set_file: u8 = 4;
    const LNS_set_column: u8 = 5;
    const LNS_const_add_pc: u8 = 8;
    const LNS_fixed_advance_pc: u8 = 9;

    const LNE_end_sequence: u8 = 1;
    const LNE_set_address: u8 = 2;
};

const ElfStringTable = struct {
    data: std.ArrayListUnmanaged(u8) = .empty,

    fn init(allocator: Allocator) !ElfStringTable {
        var table = ElfStringTable{};
        try table.data.append(allocator, 0);
        return table;
    }

    fn deinit(self: *ElfStringTable, allocator: Allocator) void {
        self.data.deinit(allocator);
    }

    fn add(self: *ElfStringTable, allocator: Allocator, name: []const u8) !u32 {
        const offset: u32 = @intCast(self.data.items.len);
        try self.data.appendSlice(allocator, name);
        try self.data.append(allocator, 0);
        return offset;
    }
};

pub const JitDebugHandle = struct {
    entry: ?*JitCodeEntry,
    object: []u8,

    pub fn deinit(self: *JitDebugHandle, allocator: Allocator) void {
        if (self.entry) |entry| {
            unregisterGdbEntry(entry);
            allocator.destroy(entry);
        }
        allocator.free(self.object);
        self.* = undefined;
    }
};

pub const JitDebugSupport = struct {
    supported: bool,
    reason: ?[]const u8,
    note: ?[]const u8,
};

pub fn jitDebugSupportFor(os_tag: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) JitDebugSupport {
    const support = (sys.capabilities.Capabilities{ .os = os_tag, .arch = arch }).jitDebugSupport();
    return .{ .supported = support.supported, .reason = support.reason, .note = support.note };
}

pub fn jitDebugSupport(arch: std.Target.Cpu.Arch) JitDebugSupport {
    return jitDebugSupportFor(sys.capabilities.current.os, arch);
}

pub fn supportsJitDebugInfo(arch: std.Target.Cpu.Arch) bool {
    return jitDebugSupport(arch).supported;
}

pub fn registerJitDebugInfo(
    allocator: Allocator,
    arch: std.Target.Cpu.Arch,
    code_addr: usize,
    code: []const u8,
    table: *const LineTable,
    func_name: []const u8,
) Allocator.Error!?JitDebugHandle {
    if (!supportsJitDebugInfo(arch) or table.isEmpty()) return null;

    const object = try buildElfDebugObject(allocator, arch, code_addr, code, table, func_name);
    errdefer allocator.free(object);

    const entry = try allocator.create(JitCodeEntry);
    errdefer allocator.destroy(entry);

    registerGdbEntry(entry, object);

    return .{
        .entry = entry,
        .object = object,
    };
}

const JitCodeEntry = extern struct {
    next: ?*JitCodeEntry,
    prev: ?*JitCodeEntry,
    symfile_addr: [*]const u8,
    symfile_size: u64,
};

const JitDescriptor = extern struct {
    version: u32,
    action_flag: u32,
    relevant_entry: ?*JitCodeEntry,
    first_entry: ?*JitCodeEntry,
};

const JitAction = enum(u32) {
    no_action = 0,
    register_fn = 1,
    unregister_fn = 2,
};

/// The GDB JIT interface descriptor. A debugger finds it by this exact symbol name and reads it
/// when it stops at `__jit_debug_register_code`. Every runtime in this process shares it, and
/// `registration_mutex` guards every change.
export var __jit_debug_descriptor: JitDescriptor = .{
    .version = 1,
    .action_flag = @backingInt(JitAction.no_action),
    .relevant_entry = null,
    .first_entry = null,
};

/// The GDB JIT interface breakpoint. A debugger finds it by this exact symbol name and stops here
/// to read `__jit_debug_descriptor`. The body keeps a call to it from being dropped, and a caller
/// reaches it through `@call(.never_inline, ...)`, so that an optimized build keeps the call.
export fn __jit_debug_register_code() callconv(.c) void {
    std.mem.doNotOptimizeAway(&__jit_debug_descriptor);
}

/// Serializes every change to the entry list and the notification that follows it. Every runtime
/// in this process registers into that one list.
var registration_mutex: sys.thread.Mutex = .{};

fn registerGdbEntry(entry: *JitCodeEntry, object: []const u8) void {
    std.debug.assert(object.len != 0);
    registration_mutex.lock();
    defer registration_mutex.unlock();
    std.debug.assert(__jit_debug_descriptor.action_flag == @backingInt(JitAction.no_action));

    entry.* = .{
        .next = __jit_debug_descriptor.first_entry,
        .prev = null,
        .symfile_addr = object.ptr,
        .symfile_size = object.len,
    };
    if (__jit_debug_descriptor.first_entry) |first| {
        first.prev = entry;
    }
    __jit_debug_descriptor.first_entry = entry;
    notifyDebugger(entry, .register_fn);
}

fn unregisterGdbEntry(entry: *JitCodeEntry) void {
    registration_mutex.lock();
    defer registration_mutex.unlock();
    std.debug.assert(__jit_debug_descriptor.action_flag == @backingInt(JitAction.no_action));

    if (entry.prev) |prev| {
        prev.next = entry.next;
    } else {
        __jit_debug_descriptor.first_entry = entry.next;
    }
    if (entry.next) |next| {
        next.prev = entry.prev;
    }
    notifyDebugger(entry, .unregister_fn);
}

/// Notifies a debugger of `action` on `entry` by calling `__jit_debug_register_code`, and leaves
/// `action_flag` at `no_action`. The caller must hold `registration_mutex`.
fn notifyDebugger(entry: *JitCodeEntry, action: JitAction) void {
    std.debug.assert(action != .no_action);
    __jit_debug_descriptor.relevant_entry = entry;
    __jit_debug_descriptor.action_flag = @backingInt(action);
    @call(.never_inline, __jit_debug_register_code, .{});
    __jit_debug_descriptor.action_flag = @backingInt(JitAction.no_action);
}

const DebugLineSection = struct {
    bytes: []u8,
    primary_name: []const u8,
    primary_dir: []const u8,
    primary_file_index: u32,
    primary_line: u32,
};

const FileEntry = struct {
    name: []const u8,
    dir_index: u32,
};

pub fn buildElfDebugObject(
    allocator: Allocator,
    arch: std.Target.Cpu.Arch,
    code_addr: usize,
    code: []const u8,
    table: *const LineTable,
    func_name: []const u8,
) Allocator.Error![]u8 {
    const machine = elfMachineForArch(arch) orelse return error.OutOfMemory;

    var line_section = try buildDebugLineSection(allocator, code_addr, table);
    defer allocator.free(line_section.bytes);

    const abbrev = try buildDebugAbbrev(allocator);
    defer allocator.free(abbrev);

    const debug_info = try buildDebugInfo(
        allocator,
        code_addr,
        code.len,
        &line_section,
        func_name,
    );
    defer allocator.free(debug_info);

    var shstrtab = try ElfStringTable.init(allocator);
    defer shstrtab.deinit(allocator);

    const sh_name_text = try shstrtab.add(allocator, ".text");
    const sh_name_debug_info = try shstrtab.add(allocator, ".debug_info");
    const sh_name_debug_abbrev = try shstrtab.add(allocator, ".debug_abbrev");
    const sh_name_debug_line = try shstrtab.add(allocator, ".debug_line");
    const sh_name_symtab = try shstrtab.add(allocator, ".symtab");
    const sh_name_strtab = try shstrtab.add(allocator, ".strtab");
    const sh_name_shstrtab = try shstrtab.add(allocator, ".shstrtab");

    var strtab = try ElfStringTable.init(allocator);
    defer strtab.deinit(allocator);
    const func_name_offset = try strtab.add(allocator, func_name);

    var symbols = std.ArrayListUnmanaged(std.elf.Elf64_Sym).empty;
    defer symbols.deinit(allocator);
    try symbols.append(allocator, .{
        .st_name = 0,
        .st_info = 0,
        .st_other = 0,
        .st_shndx = 0,
        .st_value = 0,
        .st_size = 0,
    });
    try symbols.append(allocator, .{
        .st_name = 0,
        .st_info = (@as(u8, std.elf.STB_LOCAL) << 4) | @as(u8, std.elf.STT_SECTION),
        .st_other = 0,
        .st_shndx = 1,
        .st_value = 0,
        .st_size = 0,
    });
    try symbols.append(allocator, .{
        .st_name = func_name_offset,
        .st_info = (@as(u8, std.elf.STB_GLOBAL) << 4) | @as(u8, std.elf.STT_FUNC),
        .st_other = 0,
        .st_shndx = 1,
        .st_value = @intCast(code_addr),
        .st_size = @intCast(code.len),
    });

    const symtab_bytes = std.mem.sliceAsBytes(symbols.items);
    const strtab_bytes = strtab.data.items;
    const shstrtab_bytes = shstrtab.data.items;

    const header_size = @sizeOf(std.elf.Elf64_Ehdr);
    const shdr_size = @sizeOf(std.elf.Elf64_Shdr);

    var offset: usize = alignForward(header_size, 16);
    const text_offset = offset;
    offset += code.len;
    offset = alignForward(offset, 8);

    const debug_info_offset = offset;
    offset += debug_info.len;
    offset = alignForward(offset, 8);

    const debug_abbrev_offset = offset;
    offset += abbrev.len;
    offset = alignForward(offset, 8);

    const debug_line_offset = offset;
    offset += line_section.bytes.len;
    offset = alignForward(offset, 8);

    const symtab_offset = offset;
    offset += symtab_bytes.len;
    offset = alignForward(offset, 8);

    const strtab_offset = offset;
    offset += strtab_bytes.len;
    offset = alignForward(offset, 8);

    const shstrtab_offset = offset;
    offset += shstrtab_bytes.len;
    offset = alignForward(offset, 8);

    const shoff = offset;
    const shnum: u16 = 8;
    const total_size = shoff + shdr_size * shnum;

    var buffer = try allocator.alloc(u8, total_size);
    @memset(buffer, 0);

    std.mem.copyForwards(u8, buffer[text_offset .. text_offset + code.len], code);
    std.mem.copyForwards(u8, buffer[debug_info_offset .. debug_info_offset + debug_info.len], debug_info);
    std.mem.copyForwards(u8, buffer[debug_abbrev_offset .. debug_abbrev_offset + abbrev.len], abbrev);
    std.mem.copyForwards(u8, buffer[debug_line_offset .. debug_line_offset + line_section.bytes.len], line_section.bytes);
    std.mem.copyForwards(u8, buffer[symtab_offset .. symtab_offset + symtab_bytes.len], symtab_bytes);
    std.mem.copyForwards(u8, buffer[strtab_offset .. strtab_offset + strtab_bytes.len], strtab_bytes);
    std.mem.copyForwards(u8, buffer[shstrtab_offset .. shstrtab_offset + shstrtab_bytes.len], shstrtab_bytes);

    var ident: [std.elf.EI_NIDENT]u8 = @splat(0);
    ident[0] = 0x7f;
    ident[1] = 'E';
    ident[2] = 'L';
    ident[3] = 'F';
    ident[std.elf.EI_CLASS] = std.elf.ELFCLASS64;
    ident[std.elf.EI_DATA] = std.elf.ELFDATA2LSB;
    ident[std.elf.EI_VERSION] = 1;

    const header = std.elf.Elf64_Ehdr{
        .e_ident = ident,
        .e_type = std.elf.ET.DYN,
        .e_machine = machine,
        .e_version = 1,
        .e_entry = 0,
        .e_phoff = 0,
        .e_shoff = @intCast(shoff),
        .e_flags = 0,
        .e_ehsize = @intCast(header_size),
        .e_phentsize = 0,
        .e_phnum = 0,
        .e_shentsize = @intCast(shdr_size),
        .e_shnum = shnum,
        .e_shstrndx = 7,
    };

    std.mem.copyForwards(u8, buffer[0..header_size], std.mem.asBytes(&header));

    var shdrs: [8]std.elf.Elf64_Shdr = undefined;
    shdrs[0] = .{
        .sh_name = 0,
        .sh_type = std.elf.SHT_NULL,
        .sh_flags = 0,
        .sh_addr = 0,
        .sh_offset = 0,
        .sh_size = 0,
        .sh_link = 0,
        .sh_info = 0,
        .sh_addralign = 0,
        .sh_entsize = 0,
    };
    shdrs[1] = .{
        .sh_name = sh_name_text,
        .sh_type = std.elf.SHT_PROGBITS,
        .sh_flags = std.elf.SHF_ALLOC | std.elf.SHF_EXECINSTR,
        .sh_addr = @intCast(code_addr),
        .sh_offset = @intCast(text_offset),
        .sh_size = @intCast(code.len),
        .sh_link = 0,
        .sh_info = 0,
        .sh_addralign = 16,
        .sh_entsize = 0,
    };
    shdrs[2] = .{
        .sh_name = sh_name_debug_info,
        .sh_type = std.elf.SHT_PROGBITS,
        .sh_flags = 0,
        .sh_addr = 0,
        .sh_offset = @intCast(debug_info_offset),
        .sh_size = @intCast(debug_info.len),
        .sh_link = 0,
        .sh_info = 0,
        .sh_addralign = 1,
        .sh_entsize = 0,
    };
    shdrs[3] = .{
        .sh_name = sh_name_debug_abbrev,
        .sh_type = std.elf.SHT_PROGBITS,
        .sh_flags = 0,
        .sh_addr = 0,
        .sh_offset = @intCast(debug_abbrev_offset),
        .sh_size = @intCast(abbrev.len),
        .sh_link = 0,
        .sh_info = 0,
        .sh_addralign = 1,
        .sh_entsize = 0,
    };
    shdrs[4] = .{
        .sh_name = sh_name_debug_line,
        .sh_type = std.elf.SHT_PROGBITS,
        .sh_flags = 0,
        .sh_addr = 0,
        .sh_offset = @intCast(debug_line_offset),
        .sh_size = @intCast(line_section.bytes.len),
        .sh_link = 0,
        .sh_info = 0,
        .sh_addralign = 1,
        .sh_entsize = 0,
    };
    shdrs[5] = .{
        .sh_name = sh_name_symtab,
        .sh_type = std.elf.SHT_SYMTAB,
        .sh_flags = 0,
        .sh_addr = 0,
        .sh_offset = @intCast(symtab_offset),
        .sh_size = @intCast(symtab_bytes.len),
        .sh_link = 6,
        .sh_info = 2,
        .sh_addralign = 8,
        .sh_entsize = @sizeOf(std.elf.Elf64_Sym),
    };
    shdrs[6] = .{
        .sh_name = sh_name_strtab,
        .sh_type = std.elf.SHT_STRTAB,
        .sh_flags = 0,
        .sh_addr = 0,
        .sh_offset = @intCast(strtab_offset),
        .sh_size = @intCast(strtab_bytes.len),
        .sh_link = 0,
        .sh_info = 0,
        .sh_addralign = 1,
        .sh_entsize = 0,
    };
    shdrs[7] = .{
        .sh_name = sh_name_shstrtab,
        .sh_type = std.elf.SHT_STRTAB,
        .sh_flags = 0,
        .sh_addr = 0,
        .sh_offset = @intCast(shstrtab_offset),
        .sh_size = @intCast(shstrtab_bytes.len),
        .sh_link = 0,
        .sh_info = 0,
        .sh_addralign = 1,
        .sh_entsize = 0,
    };

    var shdr_offset = shoff;
    for (shdrs) |shdr| {
        std.mem.copyForwards(u8, buffer[shdr_offset .. shdr_offset + shdr_size], std.mem.asBytes(&shdr));
        shdr_offset += shdr_size;
    }

    return buffer;
}

fn buildDebugLineSection(
    allocator: Allocator,
    code_addr: usize,
    table: *const LineTable,
) Allocator.Error!DebugLineSection {
    var dirs = std.ArrayListUnmanaged([]const u8).empty;
    defer dirs.deinit(allocator);
    var files = std.ArrayListUnmanaged(FileEntry).empty;
    defer files.deinit(allocator);

    var dir_index = std.StringHashMapUnmanaged(u32){};
    defer dir_index.deinit(allocator);
    var file_index = std.StringHashMapUnmanaged(u32){};
    defer file_index.deinit(allocator);

    for (table.entries) |entry| {
        const full_path = entry.info.file orelse "<unknown>";
        if (file_index.contains(full_path)) continue;

        const dir = std.fs.path.dirname(full_path) orelse "";
        const base = std.fs.path.basename(full_path);

        var dir_idx: u32 = 0;
        if (dir.len != 0) {
            if (dir_index.get(dir)) |idx| {
                dir_idx = idx;
            } else {
                try dirs.append(allocator, dir);
                dir_idx = @intCast(dirs.items.len);
                try dir_index.put(allocator, dir, dir_idx);
            }
        }

        try files.append(allocator, .{ .name = base, .dir_index = dir_idx });
        try file_index.put(allocator, full_path, @intCast(files.items.len));
    }

    if (files.items.len == 0) {
        try files.append(allocator, .{ .name = "<unknown>", .dir_index = 0 });
        try file_index.put(allocator, "<unknown>", 1);
    }

    const primary_file = files.items[0];
    const primary_name = primary_file.name;
    const primary_dir = if (primary_file.dir_index > 0) dirs.items[primary_file.dir_index - 1] else ".";

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    const unit_length_offset = out.items.len;
    try appendInt(&out, allocator, u32, 0);
    try appendInt(&out, allocator, u16, dwarf.version);
    const header_length_offset = out.items.len;
    try appendInt(&out, allocator, u32, 0);

    const header_start = out.items.len;
    try appendInt(&out, allocator, u8, 1);
    try appendInt(&out, allocator, u8, 1);
    try appendInt(&out, allocator, u8, 1);
    try appendInt(&out, allocator, u8, @bitCast(@as(i8, -5)));
    try appendInt(&out, allocator, u8, 14);
    try appendInt(&out, allocator, u8, 13);
    const std_op_lengths = [_]u8{ 0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1 };
    try out.appendSlice(allocator, &std_op_lengths);

    for (dirs.items) |dir| {
        try appendString(&out, allocator, dir);
    }
    try out.append(allocator, 0);

    for (files.items) |file| {
        try appendString(&out, allocator, file.name);
        try appendUleb128(&out, allocator, file.dir_index);
        try appendUleb128(&out, allocator, 0);
        try appendUleb128(&out, allocator, 0);
    }
    try out.append(allocator, 0);

    const header_end = out.items.len;
    const header_length: u32 = @intCast(header_end - header_start);
    const header_bytes = out.items[header_length_offset .. header_length_offset + 4];
    var header_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &header_buf, header_length, .little);
    @memcpy(header_bytes, &header_buf);

    var current_line: i64 = 1;
    var current_file: u32 = 1;
    var current_column: u32 = 0;

    for (table.entries) |entry| {
        const info = entry.info;
        const full_path = info.file orelse "<unknown>";
        const file_idx = file_index.get(full_path) orelse 1;
        if (file_idx != current_file) {
            try out.append(allocator, dwarf.LNS_set_file);
            try appendUleb128(&out, allocator, file_idx);
            current_file = file_idx;
        }

        if (info.column != current_column) {
            try out.append(allocator, dwarf.LNS_set_column);
            try appendUleb128(&out, allocator, info.column);
            current_column = info.column;
        }

        const addr = code_addr + entry.offset;
        try appendExtendedOpcode(&out, allocator, dwarf.LNE_set_address, dwarf.addr_size, addr);

        const next_line: i64 = if (info.line == 0) 1 else @intCast(info.line);
        const line_delta = next_line - current_line;
        if (line_delta != 0) {
            try out.append(allocator, dwarf.LNS_advance_line);
            try appendSleb128(&out, allocator, line_delta);
            current_line = next_line;
        }

        try out.append(allocator, dwarf.LNS_copy);
    }

    try appendExtendedOpcode(&out, allocator, dwarf.LNE_end_sequence, dwarf.addr_size, 0);

    const unit_length: u32 = @intCast(out.items.len - unit_length_offset - 4);
    const unit_bytes = out.items[unit_length_offset .. unit_length_offset + 4];
    var unit_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &unit_buf, unit_length, .little);
    @memcpy(unit_bytes, &unit_buf);

    return .{
        .bytes = try out.toOwnedSlice(allocator),
        .primary_name = primary_name,
        .primary_dir = primary_dir,
        .primary_file_index = if (files.items.len > 0) 1 else 0,
        .primary_line = if (table.entries.len > 0) @max(@as(u32, 1), table.entries[0].info.line) else 1,
    };
}

fn buildDebugAbbrev(allocator: Allocator) Allocator.Error![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    try appendUleb128(&out, allocator, 1);
    try appendUleb128(&out, allocator, dwarf.TAG_compile_unit);
    try out.append(allocator, dwarf.CHILDREN_yes);
    try appendUleb128(&out, allocator, dwarf.AT_name);
    try appendUleb128(&out, allocator, dwarf.FORM_string);
    try appendUleb128(&out, allocator, dwarf.AT_comp_dir);
    try appendUleb128(&out, allocator, dwarf.FORM_string);
    try appendUleb128(&out, allocator, dwarf.AT_low_pc);
    try appendUleb128(&out, allocator, dwarf.FORM_addr);
    try appendUleb128(&out, allocator, dwarf.AT_high_pc);
    try appendUleb128(&out, allocator, dwarf.FORM_addr);
    try appendUleb128(&out, allocator, dwarf.AT_stmt_list);
    try appendUleb128(&out, allocator, dwarf.FORM_sec_offset);
    try appendUleb128(&out, allocator, 0);
    try appendUleb128(&out, allocator, 0);

    try appendUleb128(&out, allocator, 2);
    try appendUleb128(&out, allocator, dwarf.TAG_subprogram);
    try out.append(allocator, dwarf.CHILDREN_no);
    try appendUleb128(&out, allocator, dwarf.AT_name);
    try appendUleb128(&out, allocator, dwarf.FORM_string);
    try appendUleb128(&out, allocator, dwarf.AT_low_pc);
    try appendUleb128(&out, allocator, dwarf.FORM_addr);
    try appendUleb128(&out, allocator, dwarf.AT_high_pc);
    try appendUleb128(&out, allocator, dwarf.FORM_addr);
    try appendUleb128(&out, allocator, dwarf.AT_decl_file);
    try appendUleb128(&out, allocator, dwarf.FORM_data1);
    try appendUleb128(&out, allocator, dwarf.AT_decl_line);
    try appendUleb128(&out, allocator, dwarf.FORM_data4);
    try appendUleb128(&out, allocator, 0);
    try appendUleb128(&out, allocator, 0);

    try appendUleb128(&out, allocator, 0);

    return out.toOwnedSlice(allocator);
}

fn buildDebugInfo(
    allocator: Allocator,
    code_addr: usize,
    code_size: usize,
    line_section: *const DebugLineSection,
    func_name: []const u8,
) Allocator.Error![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);

    const unit_length_offset = out.items.len;
    try appendInt(&out, allocator, u32, 0);
    try appendInt(&out, allocator, u16, dwarf.version);
    try appendInt(&out, allocator, u32, 0);
    try appendInt(&out, allocator, u8, dwarf.addr_size);

    try appendUleb128(&out, allocator, 1);
    const cu_name = if (line_section.primary_name.len == 0) func_name else line_section.primary_name;
    try appendString(&out, allocator, cu_name);
    try appendString(&out, allocator, line_section.primary_dir);
    try appendAddress(&out, allocator, code_addr);
    try appendAddress(&out, allocator, code_addr + code_size);
    try appendInt(&out, allocator, u32, 0);

    try appendUleb128(&out, allocator, 2);
    try appendString(&out, allocator, func_name);
    try appendAddress(&out, allocator, code_addr);
    try appendAddress(&out, allocator, code_addr + code_size);
    const decl_file: u8 = if (line_section.primary_file_index <= std.math.maxInt(u8))
        @intCast(line_section.primary_file_index)
    else
        0;
    try appendInt(&out, allocator, u8, decl_file);
    try appendInt(&out, allocator, u32, line_section.primary_line);

    try out.append(allocator, 0);

    const unit_length: u32 = @intCast(out.items.len - unit_length_offset - 4);
    const unit_bytes = out.items[unit_length_offset .. unit_length_offset + 4];
    var unit_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &unit_buf, unit_length, .little);
    @memcpy(unit_bytes, &unit_buf);

    return out.toOwnedSlice(allocator);
}

fn elfMachineForArch(arch: std.Target.Cpu.Arch) ?std.elf.EM {
    return switch (arch) {
        .x86_64 => std.elf.EM.X86_64,
        .aarch64 => std.elf.EM.AARCH64,
        else => null,
    };
}

fn appendInt(list: *std.ArrayListUnmanaged(u8), allocator: Allocator, comptime T: type, value: T) Allocator.Error!void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try list.appendSlice(allocator, &buf);
}

fn appendString(list: *std.ArrayListUnmanaged(u8), allocator: Allocator, value: []const u8) Allocator.Error!void {
    try list.appendSlice(allocator, value);
    try list.append(allocator, 0);
}

fn appendAddress(list: *std.ArrayListUnmanaged(u8), allocator: Allocator, value: usize) Allocator.Error!void {
    var buf: [dwarf.addr_size]u8 = undefined;
    std.mem.writeInt(u64, &buf, @intCast(value), .little);
    try list.appendSlice(allocator, &buf);
}

fn appendUleb128(list: *std.ArrayListUnmanaged(u8), allocator: Allocator, value: u64) Allocator.Error!void {
    var val = value;
    while (true) {
        var byte: u8 = @intCast(val & 0x7f);
        val >>= 7;
        if (val != 0) byte |= 0x80;
        try list.append(allocator, byte);
        if (val == 0) break;
    }
}

fn appendSleb128(list: *std.ArrayListUnmanaged(u8), allocator: Allocator, value: i64) Allocator.Error!void {
    var val = value;
    while (true) {
        var byte: u8 = @intCast(val & 0x7f);
        const sign_bit = (byte & 0x40) != 0;
        val >>= 7;
        const done = (val == 0 and !sign_bit) or (val == -1 and sign_bit);
        if (!done) byte |= 0x80;
        try list.append(allocator, byte);
        if (done) break;
    }
}

fn appendExtendedOpcode(
    list: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    opcode: u8,
    addr_size: u8,
    addr: usize,
) Allocator.Error!void {
    try list.append(allocator, 0);
    const payload_len: u64 = if (opcode == dwarf.LNE_set_address) 1 + addr_size else 1;
    try appendUleb128(list, allocator, payload_len);
    try list.append(allocator, opcode);
    if (opcode == dwarf.LNE_set_address) {
        var buf: [dwarf.addr_size]u8 = undefined;
        std.mem.writeInt(u64, &buf, @intCast(addr), .little);
        try list.appendSlice(allocator, &buf);
    }
}

fn alignForward(value: usize, alignment: usize) usize {
    const mask = alignment - 1;
    return (value + mask) & ~mask;
}

fn sliceSectionByName(data: []const u8, name: []const u8) ?[]const u8 {
    if (data.len < @sizeOf(std.elf.Elf64_Ehdr)) return null;
    const header = std.mem.bytesToValue(std.elf.Elf64_Ehdr, data[0..@sizeOf(std.elf.Elf64_Ehdr)]);
    const shoff: usize = @intCast(header.e_shoff);
    const shnum = header.e_shnum;
    const shstrndx = header.e_shstrndx;
    if (shnum == 0 or shstrndx >= shnum) return null;

    const shdr_size = @sizeOf(std.elf.Elf64_Shdr);
    const shstr_off = shoff + shdr_size * shstrndx;
    if (shstr_off + shdr_size > data.len) return null;
    const shstr_hdr = std.mem.bytesToValue(std.elf.Elf64_Shdr, data[shstr_off .. shstr_off + shdr_size]);
    const shstr_start: usize = @intCast(shstr_hdr.sh_offset);
    const shstr_size: usize = @intCast(shstr_hdr.sh_size);
    const shstr_end: usize = shstr_start + shstr_size;
    if (shstr_end > data.len) return null;
    const shstrtab = data[shstr_start..shstr_end];

    var idx: usize = 0;
    while (idx < shnum) : (idx += 1) {
        const shdr_off = shoff + shdr_size * idx;
        if (shdr_off + shdr_size > data.len) return null;
        const shdr = std.mem.bytesToValue(std.elf.Elf64_Shdr, data[shdr_off .. shdr_off + shdr_size]);
        const name_off: usize = @intCast(shdr.sh_name);
        if (name_off >= shstrtab.len) continue;
        const section_name = std.mem.sliceTo(shstrtab[name_off..], 0);
        if (!std.mem.eql(u8, section_name, name)) continue;
        const start: usize = @intCast(shdr.sh_offset);
        const size: usize = @intCast(shdr.sh_size);
        const end = start + size;
        if (end > data.len) return null;
        return data[start..end];
    }
    return null;
}

const ValidationError = error{
    OutOfMemory,
    InvalidElfHeader,
    InvalidElfSection,
    OverlappingSections,
    MissingSection,
    InvalidSymtab,
    InvalidDebugLine,
    InvalidDebugInfo,
};

const ElfSection = struct {
    index: usize,
    header: std.elf.Elf64_Shdr,
    name: []const u8,
};

const ElfView = struct {
    allocator: Allocator,
    header: std.elf.Elf64_Ehdr,
    sections: []ElfSection,
    shstrtab: []const u8,

    fn deinit(self: *ElfView) void {
        self.allocator.free(self.sections);
        self.* = undefined;
    }

    fn findSection(self: *const ElfView, name: []const u8) ?ElfSection {
        for (self.sections) |section| {
            if (std.mem.eql(u8, section.name, name)) return section;
        }
        return null;
    }
};

const ByteReader = struct {
    data: []const u8,
    offset: usize = 0,

    const ReadError = error{Truncated};

    fn init(data: []const u8) ByteReader {
        return .{ .data = data, .offset = 0 };
    }

    fn readBytes(self: *ByteReader, len: usize) ReadError![]const u8 {
        if (self.offset + len > self.data.len) return error.Truncated;
        const out = self.data[self.offset .. self.offset + len];
        self.offset += len;
        return out;
    }

    fn readInt(self: *ByteReader, comptime T: type) ReadError!T {
        const bytes = try self.readBytes(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
    }

    fn readByte(self: *ByteReader) ReadError!u8 {
        return self.readInt(u8);
    }

    fn readCString(self: *ByteReader) ReadError![]const u8 {
        if (self.offset >= self.data.len) return error.Truncated;
        const start = self.offset;
        const rel = std.mem.indexOfScalar(u8, self.data[start..], 0) orelse return error.Truncated;
        self.offset = start + rel + 1;
        return self.data[start .. start + rel];
    }

    fn readUleb(self: *ByteReader) ReadError!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const byte = try self.readByte();
            result |= (@as(u64, byte & 0x7f) << shift);
            if ((byte & 0x80) == 0) break;
            shift += 7;
            if (shift >= 63) return error.Truncated;
        }
        return result;
    }

    fn readSleb(self: *ByteReader) ReadError!i64 {
        var result: i64 = 0;
        var shift: u6 = 0;
        var byte: u8 = 0;
        while (true) {
            byte = try self.readByte();
            result |= (@as(i64, byte & 0x7f) << shift);
            shift += 7;
            if ((byte & 0x80) == 0) break;
            if (shift >= 63) return error.Truncated;
        }
        if ((shift < 64) and ((byte & 0x40) != 0)) {
            result |= -(@as(i64, 1) << shift);
        }
        return result;
    }
};

fn parseElfView(allocator: Allocator, data: []const u8) ValidationError!ElfView {
    if (data.len < @sizeOf(std.elf.Elf64_Ehdr)) return ValidationError.InvalidElfHeader;
    const header = std.mem.bytesToValue(std.elf.Elf64_Ehdr, data[0..@sizeOf(std.elf.Elf64_Ehdr)]);

    const shoff: usize = @intCast(header.e_shoff);
    const shnum: usize = header.e_shnum;
    const shentsize: usize = header.e_shentsize;
    if (shnum == 0 or shentsize != @sizeOf(std.elf.Elf64_Shdr)) return ValidationError.InvalidElfHeader;
    if (header.e_shstrndx >= header.e_shnum) return ValidationError.InvalidElfHeader;
    if (shoff + shentsize * shnum > data.len) return ValidationError.InvalidElfSection;

    const shstr_off = shoff + shentsize * header.e_shstrndx;
    if (shstr_off + shentsize > data.len) return ValidationError.InvalidElfSection;
    const shstr_hdr = std.mem.bytesToValue(std.elf.Elf64_Shdr, data[shstr_off .. shstr_off + shentsize]);
    const shstr_start: usize = @intCast(shstr_hdr.sh_offset);
    const shstr_size: usize = @intCast(shstr_hdr.sh_size);
    const shstr_end = shstr_start + shstr_size;
    if (shstr_end > data.len) return ValidationError.InvalidElfSection;
    const shstrtab = data[shstr_start..shstr_end];

    var sections = try allocator.alloc(ElfSection, shnum);
    errdefer allocator.free(sections);

    var idx: usize = 0;
    while (idx < shnum) : (idx += 1) {
        const shdr_off = shoff + shentsize * idx;
        if (shdr_off + shentsize > data.len) return ValidationError.InvalidElfSection;
        const shdr = std.mem.bytesToValue(std.elf.Elf64_Shdr, data[shdr_off .. shdr_off + shentsize]);
        const name_off: usize = @intCast(shdr.sh_name);
        if (name_off >= shstrtab.len) return ValidationError.InvalidElfSection;
        const name = std.mem.sliceTo(shstrtab[name_off..], 0);
        sections[idx] = .{ .index = idx, .header = shdr, .name = name };
    }

    return .{
        .allocator = allocator,
        .header = header,
        .sections = sections,
        .shstrtab = shstrtab,
    };
}

fn validateElfHeader(header: std.elf.Elf64_Ehdr, arch: std.Target.Cpu.Arch) ValidationError!void {
    if (header.e_ident[0] != 0x7f or header.e_ident[1] != 'E' or header.e_ident[2] != 'L' or header.e_ident[3] != 'F') {
        return ValidationError.InvalidElfHeader;
    }
    if (header.e_ident[std.elf.EI_CLASS] != std.elf.ELFCLASS64) return ValidationError.InvalidElfHeader;
    if (header.e_ident[std.elf.EI_DATA] != std.elf.ELFDATA2LSB) return ValidationError.InvalidElfHeader;
    if (header.e_ident[std.elf.EI_VERSION] != 1) return ValidationError.InvalidElfHeader;
    if (header.e_ehsize != @sizeOf(std.elf.Elf64_Ehdr)) return ValidationError.InvalidElfHeader;
    if (header.e_shentsize != @sizeOf(std.elf.Elf64_Shdr)) return ValidationError.InvalidElfHeader;
    const machine = elfMachineForArch(arch) orelse return ValidationError.InvalidElfHeader;
    if (header.e_machine != machine) return ValidationError.InvalidElfHeader;
    if (header.e_shstrndx >= header.e_shnum) return ValidationError.InvalidElfHeader;
}

fn validateSectionRanges(view: *const ElfView, data_len: usize) ValidationError!void {
    for (view.sections) |section| {
        const size: usize = @intCast(section.header.sh_size);
        const start: usize = @intCast(section.header.sh_offset);
        if (size == 0) continue;
        const end = start + size;
        if (end > data_len) return ValidationError.InvalidElfSection;
    }

    var i: usize = 0;
    while (i < view.sections.len) : (i += 1) {
        const a = view.sections[i];
        const a_size: usize = @intCast(a.header.sh_size);
        if (a_size == 0) continue;
        const a_start: usize = @intCast(a.header.sh_offset);
        const a_end = a_start + a_size;

        var j: usize = i + 1;
        while (j < view.sections.len) : (j += 1) {
            const b = view.sections[j];
            const b_size: usize = @intCast(b.header.sh_size);
            if (b_size == 0) continue;
            const b_start: usize = @intCast(b.header.sh_offset);
            const b_end = b_start + b_size;
            if (a_start < b_end and b_start < a_end) {
                return ValidationError.OverlappingSections;
            }
        }
    }
}

fn validateSymtab(
    view: *const ElfView,
    data: []const u8,
    func_name: []const u8,
    code_addr: usize,
    code_len: usize,
) ValidationError!void {
    const symtab = view.findSection(".symtab") orelse return ValidationError.MissingSection;
    const strtab = view.findSection(".strtab") orelse return ValidationError.MissingSection;

    if (symtab.header.sh_link != strtab.index) return ValidationError.InvalidSymtab;
    if (symtab.header.sh_entsize != @sizeOf(std.elf.Elf64_Sym)) return ValidationError.InvalidSymtab;
    if ((symtab.header.sh_size % @sizeOf(std.elf.Elf64_Sym)) != 0) return ValidationError.InvalidSymtab;

    const sym_offset: usize = @intCast(symtab.header.sh_offset);
    const sym_size: usize = @intCast(symtab.header.sh_size);
    if (sym_offset + sym_size > data.len) return ValidationError.InvalidSymtab;
    const sym_count = sym_size / @sizeOf(std.elf.Elf64_Sym);
    if (sym_count == 0) return ValidationError.InvalidSymtab;

    const str_offset: usize = @intCast(strtab.header.sh_offset);
    const str_size: usize = @intCast(strtab.header.sh_size);
    if (str_offset + str_size > data.len) return ValidationError.InvalidSymtab;
    const strtab_bytes = data[str_offset .. str_offset + str_size];

    const first_global = symtab.header.sh_info;
    if (first_global == 0 or first_global > sym_count) return ValidationError.InvalidSymtab;

    var found_func = false;
    var idx: usize = 0;
    while (idx < sym_count) : (idx += 1) {
        const start = sym_offset + idx * @sizeOf(std.elf.Elf64_Sym);
        const sym = std.mem.bytesToValue(std.elf.Elf64_Sym, data[start .. start + @sizeOf(std.elf.Elf64_Sym)]);
        const bind = sym.st_info >> 4;
        if (idx < first_global and bind != std.elf.STB_LOCAL) return ValidationError.InvalidSymtab;
        if (idx >= first_global and bind == std.elf.STB_LOCAL) return ValidationError.InvalidSymtab;

        if (sym.st_name != 0) {
            const name_off: usize = @intCast(sym.st_name);
            if (name_off >= strtab_bytes.len) return ValidationError.InvalidSymtab;
            const name = std.mem.sliceTo(strtab_bytes[name_off..], 0);
            if (std.mem.eql(u8, name, func_name)) {
                const typ = sym.st_info & 0x0f;
                if (typ != std.elf.STT_FUNC) return ValidationError.InvalidSymtab;
                if (sym.st_value != code_addr) return ValidationError.InvalidSymtab;
                if (sym.st_size != code_len) return ValidationError.InvalidSymtab;
                found_func = true;
            }
        }
    }

    if (!found_func) return ValidationError.InvalidSymtab;
}

fn validateDebugLine(section: []const u8) ValidationError!void {
    var reader = ByteReader.init(section);
    const unit_length = reader.readInt(u32) catch return ValidationError.InvalidDebugLine;
    if (unit_length + 4 != section.len) return ValidationError.InvalidDebugLine;
    const version = reader.readInt(u16) catch return ValidationError.InvalidDebugLine;
    if (version != dwarf.version) return ValidationError.InvalidDebugLine;
    const header_length = reader.readInt(u32) catch return ValidationError.InvalidDebugLine;
    const header_end = reader.offset + header_length;
    if (header_end > section.len) return ValidationError.InvalidDebugLine;

    _ = reader.readByte() catch return ValidationError.InvalidDebugLine;
    _ = reader.readByte() catch return ValidationError.InvalidDebugLine;
    _ = reader.readByte() catch return ValidationError.InvalidDebugLine;
    _ = reader.readByte() catch return ValidationError.InvalidDebugLine;
    _ = reader.readByte() catch return ValidationError.InvalidDebugLine;
    const opcode_base = reader.readByte() catch return ValidationError.InvalidDebugLine;
    if (opcode_base == 0) return ValidationError.InvalidDebugLine;
    const std_op_lengths = reader.readBytes(opcode_base - 1) catch return ValidationError.InvalidDebugLine;

    if (header_end < reader.offset) return ValidationError.InvalidDebugLine;
    reader.offset = header_end;

    var last_was_end_sequence = false;
    while (reader.offset < section.len) {
        const opcode = reader.readByte() catch return ValidationError.InvalidDebugLine;
        if (opcode == 0) {
            const payload_len = reader.readUleb() catch return ValidationError.InvalidDebugLine;
            if (payload_len == 0) return ValidationError.InvalidDebugLine;
            if (reader.offset + payload_len > section.len) return ValidationError.InvalidDebugLine;
            const subopcode = reader.readByte() catch return ValidationError.InvalidDebugLine;
            const remaining = payload_len - 1;
            if (subopcode == dwarf.LNE_end_sequence) {
                if (remaining != 0) return ValidationError.InvalidDebugLine;
                last_was_end_sequence = true;
            } else {
                last_was_end_sequence = false;
            }
            reader.offset += remaining;
            continue;
        }

        last_was_end_sequence = false;
        if (opcode < opcode_base) {
            switch (opcode) {
                dwarf.LNS_copy => {},
                dwarf.LNS_advance_pc => {
                    _ = reader.readUleb() catch return ValidationError.InvalidDebugLine;
                },
                dwarf.LNS_advance_line => {
                    _ = reader.readSleb() catch return ValidationError.InvalidDebugLine;
                },
                dwarf.LNS_set_file => {
                    _ = reader.readUleb() catch return ValidationError.InvalidDebugLine;
                },
                dwarf.LNS_set_column => {
                    _ = reader.readUleb() catch return ValidationError.InvalidDebugLine;
                },
                dwarf.LNS_const_add_pc => {},
                dwarf.LNS_fixed_advance_pc => {
                    _ = reader.readInt(u16) catch return ValidationError.InvalidDebugLine;
                },
                else => {
                    const op_index: usize = opcode - 1;
                    if (op_index >= std_op_lengths.len) return ValidationError.InvalidDebugLine;
                    var count = std_op_lengths[op_index];
                    while (count > 0) : (count -= 1) {
                        _ = reader.readUleb() catch return ValidationError.InvalidDebugLine;
                    }
                },
            }
            continue;
        }
    }

    if (!last_was_end_sequence) return ValidationError.InvalidDebugLine;
    if (reader.offset != section.len) return ValidationError.InvalidDebugLine;
}

fn validateDebugInfo(
    section: []const u8,
    code_addr: usize,
    code_len: usize,
    func_name: []const u8,
    expected_file: []const u8,
    expected_dir: []const u8,
    expected_line: u32,
) ValidationError!void {
    var reader = ByteReader.init(section);
    const unit_length = reader.readInt(u32) catch return ValidationError.InvalidDebugInfo;
    if (unit_length + 4 != section.len) return ValidationError.InvalidDebugInfo;
    const version = reader.readInt(u16) catch return ValidationError.InvalidDebugInfo;
    if (version != dwarf.version) return ValidationError.InvalidDebugInfo;
    const abbrev_offset = reader.readInt(u32) catch return ValidationError.InvalidDebugInfo;
    if (abbrev_offset != 0) return ValidationError.InvalidDebugInfo;
    const addr_size = reader.readByte() catch return ValidationError.InvalidDebugInfo;
    if (addr_size != dwarf.addr_size) return ValidationError.InvalidDebugInfo;

    const cu_abbrev = reader.readUleb() catch return ValidationError.InvalidDebugInfo;
    if (cu_abbrev != 1) return ValidationError.InvalidDebugInfo;

    const cu_name = reader.readCString() catch return ValidationError.InvalidDebugInfo;
    const comp_dir = reader.readCString() catch return ValidationError.InvalidDebugInfo;
    const low_pc = reader.readInt(u64) catch return ValidationError.InvalidDebugInfo;
    const high_pc = reader.readInt(u64) catch return ValidationError.InvalidDebugInfo;
    const stmt_list = reader.readInt(u32) catch return ValidationError.InvalidDebugInfo;
    if (!std.mem.eql(u8, cu_name, expected_file)) return ValidationError.InvalidDebugInfo;
    if (!std.mem.eql(u8, comp_dir, expected_dir)) return ValidationError.InvalidDebugInfo;
    if (low_pc != code_addr or high_pc != code_addr + code_len) return ValidationError.InvalidDebugInfo;
    if (stmt_list != 0) return ValidationError.InvalidDebugInfo;

    const sub_abbrev = reader.readUleb() catch return ValidationError.InvalidDebugInfo;
    if (sub_abbrev != 2) return ValidationError.InvalidDebugInfo;
    const sub_name = reader.readCString() catch return ValidationError.InvalidDebugInfo;
    if (!std.mem.eql(u8, sub_name, func_name)) return ValidationError.InvalidDebugInfo;
    const sub_low = reader.readInt(u64) catch return ValidationError.InvalidDebugInfo;
    const sub_high = reader.readInt(u64) catch return ValidationError.InvalidDebugInfo;
    const decl_file = reader.readInt(u8) catch return ValidationError.InvalidDebugInfo;
    const decl_line = reader.readInt(u32) catch return ValidationError.InvalidDebugInfo;
    if (sub_low != code_addr or sub_high != code_addr + code_len) return ValidationError.InvalidDebugInfo;
    if (decl_file == 0) return ValidationError.InvalidDebugInfo;
    if (decl_line != expected_line) return ValidationError.InvalidDebugInfo;

    const terminator = reader.readUleb() catch return ValidationError.InvalidDebugInfo;
    if (terminator != 0) return ValidationError.InvalidDebugInfo;
    if (reader.offset != section.len) return ValidationError.InvalidDebugInfo;
}

fn validateElfDebugObject(
    allocator: Allocator,
    data: []const u8,
    arch: std.Target.Cpu.Arch,
    code_addr: usize,
    code_len: usize,
    func_name: []const u8,
    expected_file: []const u8,
    expected_dir: []const u8,
    expected_line: u32,
) ValidationError!void {
    var view = try parseElfView(allocator, data);
    defer view.deinit();

    try validateElfHeader(view.header, arch);
    try validateSectionRanges(&view, data.len);
    try validateSymtab(&view, data, func_name, code_addr, code_len);

    const debug_line = view.findSection(".debug_line") orelse return ValidationError.MissingSection;
    const debug_info = view.findSection(".debug_info") orelse return ValidationError.MissingSection;
    const debug_abbrev = view.findSection(".debug_abbrev") orelse return ValidationError.MissingSection;

    if (debug_abbrev.header.sh_size == 0) return ValidationError.InvalidDebugInfo;

    const line_offset: usize = @intCast(debug_line.header.sh_offset);
    const line_size: usize = @intCast(debug_line.header.sh_size);
    const info_offset: usize = @intCast(debug_info.header.sh_offset);
    const info_size: usize = @intCast(debug_info.header.sh_size);
    if (line_offset + line_size > data.len) return ValidationError.InvalidDebugLine;
    if (info_offset + info_size > data.len) return ValidationError.InvalidDebugInfo;

    try validateDebugLine(data[line_offset .. line_offset + line_size]);
    try validateDebugInfo(
        data[info_offset .. info_offset + info_size],
        code_addr,
        code_len,
        func_name,
        expected_file,
        expected_dir,
        expected_line,
    );
}

const registration_worker_entries = 8;

/// One thread of the registration race test. It registers or unregisters its own entries once
/// every worker of its party has arrived.
const RegistrationWorker = struct {
    object: []const u8,
    started: *std.atomic.Value(usize),
    party: usize,
    unregistering: bool = false,
    entries: [registration_worker_entries]JitCodeEntry = undefined,

    fn run(self: *RegistrationWorker) void {
        _ = self.started.fetchAdd(1, .acq_rel);
        while (self.started.load(.acquire) < self.party) std.atomic.spinLoopHint();
        if (!self.unregistering) {
            for (&self.entries) |*entry| registerGdbEntry(entry, self.object);
            return;
        }
        var remaining = self.entries.len;
        while (remaining != 0) : (remaining -= 1) {
            unregisterGdbEntry(&self.entries[remaining - 1]);
        }
    }
};

/// Runs one register or unregister phase across `workers`, and joins every thread it spawns.
fn runRegistrationPhase(workers: []RegistrationWorker, unregistering: bool) !void {
    var started = std.atomic.Value(usize).init(0);
    var threads: [8]sys.thread.JoinHandle = undefined;
    std.debug.assert(workers.len <= threads.len);
    for (workers) |*worker| {
        worker.started = &started;
        worker.party = workers.len;
        worker.unregistering = unregistering;
    }

    var spawned: usize = 0;
    errdefer {
        _ = started.fetchAdd(workers.len - spawned, .acq_rel);
        for (threads[0..spawned]) |thread| thread.join();
    }
    while (spawned < workers.len) : (spawned += 1) {
        threads[spawned] = try sys.thread.spawn(RegistrationWorker.run, .{&workers[spawned]});
    }
    for (threads[0..workers.len]) |thread| thread.join();
}

/// Returns the length of the entry list. Fails when a link disagrees with its neighbor or when the
/// list holds more than `limit` entries.
fn registeredEntryCount(limit: usize) error{CorruptEntryList}!usize {
    var length: usize = 0;
    var previous: ?*JitCodeEntry = null;
    var node = __jit_debug_descriptor.first_entry;
    while (node) |entry| : (node = entry.next) {
        if (entry.prev != previous) return error.CorruptEntryList;
        length += 1;
        if (length > limit) return error.CorruptEntryList;
        previous = entry;
    }
    return length;
}
