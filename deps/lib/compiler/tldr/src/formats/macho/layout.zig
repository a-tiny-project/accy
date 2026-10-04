const std = @import("std");
const root = @import("../../root.zig");
const macho = @import("root.zig");
const Allocator = std.mem.Allocator;
const Error = root.Error;
const Policy = root.model.MachOExecutablePolicy;
const alloc_phase = @import("alloc_phase");

pub const vm_page_bytes = 16384;
pub const wrapper_bytes = 20;
/// Header, text, const, text relocations, symbols and strings.
pub const source_region_count = 6;

/// Disjoint file costs. External dyld/libSystem/cache residency is unknown and
/// deliberately absent; PAGEZERO/VM reservations are not initialized file bytes.
pub const ByteCounts = struct {
    initialized_text: u64 = 0,
    readonly_data: u64 = 0,
    retained_text_slots: u64 = 0,
    startup_wrapper: u64 = wrapper_bytes,
    pointer_cells: u64 = 0,
    headers_commands: u64 = 0,
    symbols_strings: u64 = 0,
    fixup_streams: u64 = 0,
    signature: u64 = 0,
    file_padding: u64 = 0,
    file: u64 = 0,
    pagezero_reservation: u64 = 0,
    mapped_vm: u64 = 0,
    bss_reservation: u64 = 0,

    pub fn ownedFileBytes(self: ByteCounts) u64 {
        return self.initialized_text + self.readonly_data + self.retained_text_slots +
            self.startup_wrapper + self.pointer_cells + self.headers_commands +
            self.symbols_strings + self.fixup_streams + self.signature + self.file_padding;
    }
};

const InputObject = struct {
    input: root.Input,
    object: macho.Object,
    text_offset: u64 = 0,
    const_offset: u64 = 0,
};
const SymbolRef = struct { input: usize, symbol: usize };
const OutputSymbol = struct { source: SymbolRef, string_offset: u32 };
const Cell = struct {
    input: usize,
    neighborhood: macho.fixup.Neighborhood,
    target: union(macho.fixup.CellKind) { rebase: SymbolRef, bind: usize },
};

/// Construction owns structural scratch through the supplied allocator. All
/// input descriptors/names/bytes and policy strings remain borrowed through write.
pub const Layout = struct {
    options: root.LinkOptions,
    policy: Policy,
    objects: std.ArrayListUnmanaged(InputObject) = .empty,
    definitions: std.StringHashMapUnmanaged(SymbolRef) = .{},
    cells: std.ArrayListUnmanaged(Cell) = .empty,
    symbols: std.ArrayListUnmanaged(OutputSymbol) = .empty,
    strings: std.ArrayListUnmanaged(u8) = .empty,
    rebases: std.ArrayListUnmanaged(u8) = .empty,
    binds: std.ArrayListUnmanaged(u8) = .empty,
    symbol_groups: [3]u32 = @splat(0),
    entry: SymbolRef = undefined,
    counts: ByteCounts = .{},
    commands_bytes: u32 = 0,
    text_offset: u64 = 0,
    text_bytes: u64 = wrapper_bytes,
    const_offset: u64 = 0,
    const_bytes: u64 = 0,
    text_segment_bytes: u64 = 0,
    data_offset: u64 = 0,
    data_segment_bytes: u64 = 0,
    linkedit_offset: u64 = 0,
    rebase_offset: u32 = 0,
    bind_offset: u32 = 0,
    symbol_offset: u32 = 0,
    string_offset: u32 = 0,
    signature_plan: macho.signature.Plan = undefined,
    uuid_offset: usize = 0,

    pub fn init(allocator: Allocator, inputs: []const root.Input, options: root.LinkOptions) Error!Layout {
        const policy = try validatePolicy(options);
        if (inputs.len == 0) return error.NoAllocSections;
        var self: Layout = .{ .options = options, .policy = policy };
        errdefer self.deinit(allocator);
        for (inputs) |input| {
            try validateContainer(input.bytes);
            var object = try macho.parseObject(allocator, input.bytes);
            errdefer object.deinit(allocator);
            try validateSections(object);
            try validateSourceExtents(input.bytes, object);
            try self.objects.append(allocator, .{
                .input = input,
                .object = object,
            });
        }
        try self.indexSymbols(allocator);
        self.entry = self.definitions.get(options.entry_symbol) orelse return error.MissingEntrySymbol;
        const entry_symbol = self.objects.items[self.entry.input].object.symbols[self.entry.symbol];
        if (entry_symbol.section_index != 1) return error.MissingEntrySymbol;
        for (self.objects.items, 0..) |object, index| try self.collectCells(allocator, object, index);
        try self.collectOutputSymbols(allocator);
        try self.place();
        try self.makeStreams(allocator);
        try self.placeLinkedit();
        return self;
    }

    pub fn deinit(self: *Layout, allocator: Allocator) void {
        for (self.objects.items) |*object| object.object.deinit(allocator);
        self.objects.deinit(allocator);
        self.definitions.deinit(allocator);
        self.cells.deinit(allocator);
        self.symbols.deinit(allocator);
        self.strings.deinit(allocator);
        self.rebases.deinit(allocator);
        self.binds.deinit(allocator);
        self.* = undefined;
    }

    pub fn byteCounts(self: *const Layout) ByteCounts {
        return self.counts;
    }

    pub fn requiredBytes(self: *const Layout) usize {
        return @intCast(self.counts.file);
    }

    /// Writes an exact-size caller-owned buffer disjoint from all construction
    /// scratch and borrowed input storage. No allocation and no post-signing write.
    pub fn write(self: *const Layout, out: []u8) Error!void {
        if (out.len != self.requiredBytes()) return error.InvalidRange;
        std.debug.assert(self.counts.file == self.counts.ownedFileBytes());
        @memset(out, 0);
        try self.writeHeaders(out);
        self.writeWrapper(out);
        for (self.objects.items) |input| {
            const text = sectionBytes(input.input.bytes, input.object.sections[0]);
            const readonly = sectionBytes(input.input.bytes, input.object.sections[1]);
            @memcpy(out[@intCast(input.text_offset)..][0..text.len], text);
            @memcpy(out[@intCast(input.const_offset)..][0..readonly.len], readonly);
        }
        for (self.cells.items, 0..) |cell, index| {
            const input = self.objects.items[cell.input];
            const instruction_file = input.text_offset + cell.neighborhood.start;
            const cell_file = self.data_offset + index * 8;
            const original = macho.fixup.word(out, @intCast(instruction_file));
            const relocated = try macho.fixup.redirectedLdr(
                original,
                try add(self.options.image_base, instruction_file),
                try add(self.options.image_base, cell_file),
            );
            macho.fixup.putWord(out, @intCast(instruction_file), relocated);
            switch (cell.target) {
                .rebase => |reference| put(u64, out, cell_file, self.symbolAddress(reference)),
                .bind => {}, // Eager dyld bind writes only this RW/non-X DATA cell.
            }
        }
        @memcpy(out[self.rebase_offset..][0..self.rebases.items.len], self.rebases.items);
        @memcpy(out[self.bind_offset..][0..self.binds.items.len], self.binds.items);
        @memcpy(out[self.string_offset..][0..self.strings.items.len], self.strings.items);
        self.writeSymbols(out);
        // Hash all deterministic pre-signature bytes with UUID still zero. Then
        // freeze the UUID as part of the bytes covered by the CodeDirectory.
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(out[0..self.signature_plan.code_limit], &digest, .{});
        @memcpy(out[self.uuid_offset..][0..16], digest[0..16]);
        self.signature_plan.write(out);
    }

    fn indexSymbols(self: *Layout, allocator: Allocator) Error!void {
        for (self.objects.items, 0..) |input, input_index| {
            for (input.object.symbols, 0..) |symbol, symbol_index| {
                try validateName(symbol.name);
                if (symbol.kind & ~@as(u8, 0x0f) != 0) return error.UnsupportedMachOInputProtocol;
                const kind = symbol.kind & 0x0e;
                if (kind == 0) {
                    if (!symbol.external or symbol.section_index != 0 or symbol.value != 0) {
                        return error.UnsupportedMachOInputProtocol;
                    }
                    continue;
                }
                if (kind != 0x0e or symbol.section_index == 0 or symbol.section_index > 2) {
                    return error.UnsupportedMachOInputProtocol;
                }
                const section = input.object.sections[symbol.section_index - 1];
                if (symbol.value < section.address or symbol.value - section.address >= section.size) {
                    return error.InvalidRange;
                }
                if (symbol.section_index == 1 and (symbol.value - section.address) % 4 != 0) return error.InvalidAlignment;
                if (symbol.external) {
                    const result = try self.definitions.getOrPut(allocator, symbol.name);
                    if (result.found_existing) return error.DuplicateSymbol;
                    result.value_ptr.* = .{ .input = input_index, .symbol = symbol_index };
                }
            }
        }
        // Undefined records also require a real definition or an explicit trusted
        // import, even when the containing function is not the chosen entry graph.
        for (self.objects.items) |input| for (input.object.symbols) |symbol| {
            if (symbol.section_index == 0 and !self.definitions.contains(symbol.name)) {
                _ = try self.importIndex(symbol.name);
            }
        };
    }

    fn collectCells(self: *Layout, allocator: Allocator, input: InputObject, input_index: usize) Error!void {
        const text = sectionBytes(input.input.bytes, input.object.sections[0]);
        const owners = try allocator.alloc(u8, text.len / 4);
        defer allocator.free(owners);
        @memset(owners, 0);
        for (input.object.symbols) |symbol| {
            if (symbol.section_index != 1) continue;
            const offset: usize = @intCast(symbol.value - input.object.sections[0].address);
            owners[offset / 4] = 4; // A symbol may start, but never bisect, a neighborhood.
        }
        for (input.object.relocations) |relocation| {
            if (relocation.section_index != 0 or relocation.kind != 0 or relocation.pc_relative or
                relocation.length != 3 or !relocation.external or relocation.address < 0)
            {
                return error.UnsupportedRelocation;
            }
            const slot: usize = @intCast(relocation.address);
            const neighborhood = try macho.fixup.neighborhood(text, slot);
            for (owners[neighborhood.start / 4 .. neighborhood.end / 4], 0..) |*owner, index| {
                if (owner.* != 0 and !(owner.* == 4 and index == 0)) return error.AmbiguousMachOLiteral;
                owner.* = if (index * 4 + neighborhood.start >= slot) 2 else 3;
            }
            owners[neighborhood.start / 4] = 1;
            const source = input.object.symbols[relocation.symbol_number];
            const target: @FieldType(Cell, "target") = if (source.section_index != 0)
                .{ .rebase = .{ .input = input_index, .symbol = relocation.symbol_number } }
            else if (self.definitions.get(source.name)) |definition|
                .{ .rebase = definition }
            else
                .{ .bind = try self.importIndex(source.name) };
            try self.cells.append(allocator, .{ .input = input_index, .neighborhood = neighborhood, .target = target });
        }
        try macho.fixup.census(text, owners);
    }

    fn importIndex(self: *const Layout, name: []const u8) Error!usize {
        for (self.policy.imports, 0..) |import, index| {
            if (std.mem.eql(u8, name, import.name)) return index;
        }
        if (self.options.diagnostics) |diagnostics| diagnostics.recordUndefinedSymbol("Mach-O arm64 product", name);
        return error.UndefinedSymbol;
    }

    fn collectOutputSymbols(self: *Layout, allocator: Allocator) Error!void {
        try self.strings.append(allocator, 0);
        // Preserve original order within the three LC_DYSYMTAB partitions.
        for (0..3) |group| {
            for (self.objects.items, 0..) |input, input_index| {
                for (input.object.symbols, 0..) |symbol, symbol_index| {
                    const symbol_group: usize = if (!symbol.external) 0 else if (symbol.section_index != 0 or self.definitions.contains(symbol.name)) 1 else 2;
                    if (group != symbol_group) continue;
                    const string_offset = try asU32(self.strings.items.len);
                    try self.strings.appendSlice(allocator, symbol.name);
                    try self.strings.append(allocator, 0);
                    try self.symbols.append(allocator, .{
                        .source = .{ .input = input_index, .symbol = symbol_index },
                        .string_offset = string_offset,
                    });
                    self.symbol_groups[group] = std.math.add(u32, self.symbol_groups[group], 1) catch
                        return error.SectionLayoutOverflow;
                }
            }
        }
    }

    fn place(self: *Layout) Error!void {
        // Four segments; TEXT has text/const sections, DATA has pointer cells.
        self.commands_bytes = try asU32(72 * 4 + 80 * 3 + 48 + 24 + 80 + 24 + 24 + 24 + 16 +
            try alignedCommandBytes(12, "/usr/lib/dyld") +
            try alignedCommandBytes(24, self.policy.libSystem_install_name));
        self.counts.headers_commands = 32 + self.commands_bytes;
        self.uuid_offset = @intCast(self.counts.headers_commands - 32);
        self.text_offset = try aligned(self.counts.headers_commands, 16);
        var text_end = try add(self.text_offset, wrapper_bytes);
        for (self.objects.items) |*input| {
            text_end = try aligned(text_end, @as(u64, 1) << @intCast(input.object.sections[0].alignment_shift));
            input.text_offset = text_end;
            text_end = try add(text_end, input.object.sections[0].size);
            self.counts.initialized_text = try add(self.counts.initialized_text, input.object.sections[0].size);
        }
        self.text_bytes = text_end - self.text_offset;
        self.const_offset = try aligned(text_end, 8);
        var const_end = self.const_offset;
        for (self.objects.items) |*input| {
            const_end = try aligned(const_end, @as(u64, 1) << @intCast(input.object.sections[1].alignment_shift));
            input.const_offset = const_end;
            const_end = try add(const_end, input.object.sections[1].size);
            self.counts.readonly_data = try add(self.counts.readonly_data, input.object.sections[1].size);
        }
        self.const_bytes = const_end - self.const_offset;
        _ = try add(self.options.image_base, const_end);
        self.text_segment_bytes = try aligned(const_end, vm_page_bytes);
        self.data_offset = self.text_segment_bytes;
        self.counts.pointer_cells = try multiply(self.cells.items.len, 8);
        self.counts.retained_text_slots = self.counts.pointer_cells;
        self.counts.initialized_text -= self.counts.retained_text_slots;
        self.data_segment_bytes = try aligned(self.counts.pointer_cells, vm_page_bytes);
        // A zero-cell DATA segment still has a supported ordered dyld segment index.
        self.linkedit_offset = try add(self.data_offset, self.data_segment_bytes);
        self.counts.pagezero_reservation = self.options.image_base;
        // Check all LDR ranges before allocating or writing any output.
        for (self.cells.items, 0..) |cell, index| {
            const input = self.objects.items[cell.input];
            const source = input.text_offset + cell.neighborhood.start;
            _ = try macho.fixup.redirectedLdr(0x58000000, try add(self.options.image_base, source), try add(self.options.image_base, self.data_offset + index * 8));
        }
        const entry = self.symbolAddress(self.entry);
        const call = try add(self.options.image_base, self.text_offset + 8);
        const displacement: i128 = @as(i128, entry) - @as(i128, call);
        if (@mod(displacement, 4) != 0 or displacement < -134217728 or displacement > 134217724) {
            return error.RelocationOverflow;
        }
    }

    fn makeStreams(self: *Layout, allocator: Allocator) Error!void {
        // dyld classic pointer64 fixups are restricted to RW/non-X segment2.
        try self.rebases.append(allocator, 0x11); // SET_TYPE_IMM POINTER.
        for (self.cells.items, 0..) |cell, index| switch (cell.target) {
            .rebase => {
                try self.rebases.append(allocator, 0x22); // SET_SEGMENT_AND_OFFSET_ULEB.
                try macho.fixup.appendUleb(allocator, &self.rebases, index * 8);
                try self.rebases.append(allocator, 0x51); // DO_REBASE_IMM_TIMES 1.
            },
            .bind => |import| {
                try self.binds.appendSlice(allocator, &.{ 0x11, 0x40 }); // Library1; symbol flags0.
                try self.binds.appendSlice(allocator, self.policy.imports[import].name);
                try self.binds.appendSlice(allocator, &.{ 0, 0x51, 0x72 }); // POINTER, DATA segment2.
                try macho.fixup.appendUleb(allocator, &self.binds, index * 8);
                try self.binds.append(allocator, 0x90); // DO_BIND.
            },
        };
        try self.rebases.append(allocator, 0);
        try self.binds.append(allocator, 0);
    }

    fn placeLinkedit(self: *Layout) Error!void {
        self.rebase_offset = try asU32(self.linkedit_offset);
        self.bind_offset = try asU32(try add(self.rebase_offset, self.rebases.items.len));
        self.symbol_offset = try asU32(try aligned(try add(self.bind_offset, self.binds.items.len), 8));
        self.string_offset = try asU32(try add(self.symbol_offset, try multiply(self.symbols.items.len, 16)));
        const signature_offset = try aligned(try add(self.string_offset, self.strings.items.len), 16);
        self.signature_plan = try macho.signature.Plan.init(self.policy.signature_identifier, signature_offset, self.text_segment_bytes);
        self.counts.signature = self.signature_plan.signature_bytes;
        self.counts.fixup_streams = try add(self.rebases.items.len, self.binds.items.len);
        self.counts.symbols_strings = try add(try multiply(self.symbols.items.len, 16), self.strings.items.len);
        self.counts.file = try add(signature_offset, self.counts.signature);
        _ = try asU32(self.counts.file);
        _ = try add(self.options.image_base, try aligned(self.counts.file, vm_page_bytes));
        self.counts.mapped_vm = try aligned(self.counts.file, vm_page_bytes);
        const initialized = self.counts.initialized_text + self.counts.readonly_data + self.counts.retained_text_slots +
            self.counts.startup_wrapper + self.counts.pointer_cells + self.counts.headers_commands +
            self.counts.symbols_strings + self.counts.fixup_streams + self.counts.signature;
        std.debug.assert(initialized <= self.counts.file);
        self.counts.file_padding = self.counts.file - initialized;
    }

    fn symbolAddress(self: *const Layout, reference: SymbolRef) u64 {
        const input = self.objects.items[reference.input];
        const symbol = input.object.symbols[reference.symbol];
        const section = input.object.sections[symbol.section_index - 1];
        const file = if (symbol.section_index == 1) input.text_offset else input.const_offset;
        return self.options.image_base + file + (symbol.value - section.address);
    }

    fn writeSymbols(self: *const Layout, out: []u8) void {
        for (self.symbols.items, 0..) |record, index| {
            const symbol = self.objects.items[record.source.input].object.symbols[record.source.symbol];
            const offset = self.symbol_offset + index * 16;
            put(u32, out, offset, record.string_offset);
            out[offset + 4] = symbol.kind;
            out[offset + 5] = symbol.section_index;
            if (symbol.section_index == 0) {
                // Undefined object references satisfied by another input become
                // definitions, not imports. Local records always retain their owner.
                if (self.definitions.get(symbol.name)) |reference| {
                    const definition = self.objects.items[reference.input].object.symbols[reference.symbol];
                    out[offset + 4] = 0x0f;
                    out[offset + 5] = definition.section_index;
                    put(u64, out, offset + 8, self.symbolAddress(reference));
                } else put(u16, out, offset + 6, 0x0100); // Library ordinal1.
            } else put(u64, out, offset + 8, self.symbolAddress(record.source));
        }
    }

    fn writeWrapper(self: *const Layout, out: []u8) void {
        const offset: usize = @intCast(self.text_offset);
        const displacement: i128 = @as(i128, self.symbolAddress(self.entry)) -
            @as(i128, self.options.image_base + self.text_offset + 8);
        const words: i26 = @intCast(@divExact(displacement, 4));
        macho.fixup.putWord(out, offset, 0xa9bf7bfd); // STP x29,x30,[sp,#-16]!.
        macho.fixup.putWord(out, offset + 4, 0x910003fd); // MOV x29,sp.
        macho.fixup.putWord(out, offset + 8, 0x94000000 | @as(u32, @as(u26, @bitCast(words))));
        macho.fixup.putWord(out, offset + 12, 0xa8c17bfd); // LDP x29,x30,[sp],#16.
        macho.fixup.putWord(out, offset + 16, 0xd65f03c0);
    }

    fn writeHeaders(self: *const Layout, out: []u8) Error!void {
        put(u32, out, 0, 0xfeedfacf);
        put(u32, out, 4, 0x0100000c);
        put(u32, out, 8, 0); // CPU_SUBTYPE_ARM64_ALL.
        put(u32, out, 12, 2); // MH_EXECUTE.
        put(u32, out, 16, 13);
        put(u32, out, 20, self.commands_bytes);
        put(u32, out, 24, 0x00200085); // PIE | TWOLEVEL | DYLDLINK | NOUNDEFS.
        var cursor: usize = 32;
        segment(out, cursor, "__PAGEZERO", 0, self.options.image_base, 0, 0, 0, 0, 0);
        cursor += 72;
        segment(out, cursor, "__TEXT", self.options.image_base, self.text_segment_bytes, 0, self.text_segment_bytes, 5, 5, 2);
        writeSection(out, cursor + 72, "__text", "__TEXT", self.options.image_base + self.text_offset, self.text_bytes, self.text_offset, 4, 0x80000400);
        writeSection(out, cursor + 152, "__const", "__TEXT", self.options.image_base + self.const_offset, self.const_bytes, self.const_offset, 3, 0);
        cursor += 232;
        segment(out, cursor, "__DATA", self.options.image_base + self.data_offset, self.data_segment_bytes, self.data_offset, self.data_segment_bytes, 3, 3, 1);
        writeSection(out, cursor + 72, "__data", "__DATA", self.options.image_base + self.data_offset, self.counts.pointer_cells, self.data_offset, 3, 0);
        cursor += 152;
        const linkedit_bytes = self.counts.file - self.linkedit_offset;
        segment(out, cursor, "__LINKEDIT", self.options.image_base + self.linkedit_offset, try aligned(linkedit_bytes, vm_page_bytes), self.linkedit_offset, linkedit_bytes, 1, 1, 0);
        cursor += 72;
        command(out, cursor, 0x80000022, 48); // LC_DYLD_INFO_ONLY.
        put(u32, out, cursor + 8, self.rebase_offset);
        put(u32, out, cursor + 12, @intCast(self.rebases.items.len));
        put(u32, out, cursor + 16, self.bind_offset);
        put(u32, out, cursor + 20, @intCast(self.binds.items.len));
        cursor += 48;
        command(out, cursor, 2, 24); // LC_SYMTAB.
        put(u32, out, cursor + 8, self.symbol_offset);
        put(u32, out, cursor + 12, @intCast(self.symbols.items.len));
        put(u32, out, cursor + 16, self.string_offset);
        put(u32, out, cursor + 20, @intCast(self.strings.items.len));
        cursor += 24;
        command(out, cursor, 0x0b, 80); // LC_DYSYMTAB: remaining unused tables are zero.
        var symbol_start: u32 = 0;
        for (self.symbol_groups, 0..) |count, group| {
            put(u32, out, cursor + 8 + group * 8, symbol_start);
            put(u32, out, cursor + 12 + group * 8, count);
            symbol_start += count;
        }
        cursor += 80;
        cursor += stringCommand(out, cursor, 0x0e, 12, "/usr/lib/dyld");
        const library_cursor = cursor;
        cursor += stringCommand(out, cursor, 0x0c, 24, self.policy.libSystem_install_name);
        put(u32, out, library_cursor + 16, 0x00010000); // Dylib current/compatibility1.0.0.
        put(u32, out, library_cursor + 20, 0x00010000);
        command(out, cursor, 0x80000028, 24); // LC_MAIN entryoff is a file offset.
        put(u64, out, cursor + 8, self.text_offset);
        cursor += 24;
        command(out, cursor, 0x32, 24); // LC_BUILD_VERSION, PLATFORM_MACOS, no tools.
        put(u32, out, cursor + 8, 1);
        put(u32, out, cursor + 12, version(self.policy.minimum_macos));
        put(u32, out, cursor + 16, version(self.policy.sdk_version));
        cursor += 24;
        command(out, cursor, 0x1b, 24); // LC_UUID; write fills digest after metadata.
        std.debug.assert(self.uuid_offset == cursor + 8);
        cursor += 24;
        command(out, cursor, 0x1d, 16); // LC_CODE_SIGNATURE, already reserved before hashes.
        put(u32, out, cursor + 8, self.signature_plan.code_limit);
        put(u32, out, cursor + 12, self.signature_plan.signature_bytes);
        cursor += 16;
        std.debug.assert(cursor == self.counts.headers_commands);
    }
};

pub fn validatePolicy(options: root.LinkOptions) Error!Policy {
    const policy = options.macho_executable orelse return error.MissingMachOExecutablePolicy;
    if (options.output_kind != .executable) return error.UnsupportedOutputKind;
    if (options.target.object_format != .macho or options.target.architecture != .aarch64 or
        options.target.endianness != .little or options.target.pointer_width_bits != 64)
        return error.UnsupportedArchitecture;
    if (options.incremental_mode != .off) return error.UnsupportedMachOIncremental;
    if (!options.pie or options.page_size != vm_page_bytes or options.image_base == 0 or
        options.image_base % vm_page_bytes != 0 or options.gc_sections or options.icf != .off or
        options.strip_debug or options.build_id != .none or options.soname != null or
        options.export_dynamic or options.eh_frame_header or options.mapped_output_file != null)
        return error.UnsupportedMachOExecutablePolicy;
    if (options.dynamic_linker) |path| if (!std.mem.eql(u8, path, "/usr/lib/dyld")) {
        return error.UnsupportedMachOExecutablePolicy;
    };
    if (!std.mem.eql(u8, policy.libSystem_install_name, "/usr/lib/libSystem.B.dylib") or
        version(policy.minimum_macos) < 0x000b0400 or version(policy.sdk_version) < version(policy.minimum_macos))
        return error.UnsupportedMachOExecutablePolicy;
    try validateName(policy.signature_identifier);
    if (policy.imports.len != 1 or !std.mem.eql(u8, policy.imports[0].name, "_getpid")) {
        return error.UnsupportedMachOExecutablePolicy;
    }
    return policy;
}

fn validateContainer(bytes: []const u8) Error!void {
    if (bytes.len < 448) return error.InvalidObject;
    if (macho.fixup.word(bytes, 0) != 0xfeedfacf or macho.fixup.word(bytes, 4) != 0x0100000c or
        macho.fixup.word(bytes, 8) != 0 or macho.fixup.word(bytes, 12) != 1 or
        macho.fixup.word(bytes, 16) != 2 or macho.fixup.word(bytes, 20) != 416 or
        macho.fixup.word(bytes, 24) != 0 or macho.fixup.word(bytes, 28) != 0 or
        macho.fixup.word(bytes, 32) != 0x19 or macho.fixup.word(bytes, 36) != 392 or
        macho.fixup.word(bytes, 424) != 2 or macho.fixup.word(bytes, 428) != 24)
        return error.UnsupportedMachOInputProtocol;
    const symbols = macho.fixup.word(bytes, 436);
    const offset = macho.fixup.word(bytes, 432);
    const table_bytes = try multiply(symbols, 16);
    if (offset > bytes.len or table_bytes > bytes.len - offset) return error.InvalidRange;
    for (0..symbols) |index| {
        if (std.mem.readInt(u16, bytes[offset + index * 16 + 6 ..][0..2], .little) != 0) {
            return error.UnsupportedMachOInputProtocol;
        }
    }
}

fn validateSections(object: macho.Object) Error!void {
    if (object.sections.len != 4) return error.UnsupportedMachOInputProtocol;
    const names = [_][]const u8{ "__text", "__const", "__data", "__bss" };
    const segments = [_][]const u8{ "__TEXT", "__TEXT", "__DATA", "__DATA" };
    for (object.sections, 0..) |source, index| {
        if (!std.mem.eql(u8, source.name, names[index]) or !std.mem.eql(u8, source.segment_name, segments[index]) or
            source.alignment_shift > 14 or source.flags != (if (index == 0) @as(u32, 0x400) else if (index == 3) @as(u32, 1) else 0))
            return error.UnsupportedMachOInputProtocol;
        if (index > 1 and source.size != 0) return error.UnsupportedMachOInputProtocol;
        if (index != 0 and source.relocation_count != 0) return error.UnsupportedRelocation;
    }
    if (object.sections[0].size == 0 or object.sections[0].size % 4 != 0) return error.NoAllocSections;
}

fn validateSourceExtents(bytes: []const u8, object: macho.Object) Error!void {
    const Region = struct { start: u64, size: u64 };
    const text = object.sections[0];
    const readonly = object.sections[1];
    const regions: [source_region_count]Region = .{
        .{ .start = 0, .size = 448 },
        .{ .start = text.offset, .size = text.size },
        .{ .start = readonly.offset, .size = readonly.size },
        .{ .start = text.relocation_offset, .size = try multiply(text.relocation_count, 8) },
        .{ .start = macho.fixup.word(bytes, 432), .size = try multiply(macho.fixup.word(bytes, 436), 16) },
        .{ .start = macho.fixup.word(bytes, 440), .size = macho.fixup.word(bytes, 444) },
    };
    for (regions, 0..) |region, index| {
        const end = try add(region.start, region.size);
        if (end > bytes.len) return error.InvalidRange;
        if (region.size == 0) continue;
        for (regions[0..index]) |previous| {
            if (previous.size != 0 and region.start < try add(previous.start, previous.size) and
                previous.start < end) return error.UnsupportedMachOInputProtocol;
        }
    }
    for ([_]macho.Section{ text, readonly }) |source| {
        const alignment = @as(u64, 1) << @intCast(source.alignment_shift);
        if (source.offset % alignment != 0 or source.address % alignment != 0) return error.InvalidAlignment;
    }
    if (text.relocation_offset % 4 != 0 or macho.fixup.word(bytes, 432) % 8 != 0) {
        return error.InvalidAlignment;
    }
}

fn sectionBytes(bytes: []const u8, source: macho.Section) []const u8 {
    return bytes[source.offset..][0..@intCast(source.size)];
}

fn validateName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > std.math.maxInt(u32) or std.mem.indexOfScalar(u8, name, 0) != null) {
        return error.UnsupportedMachOInputProtocol;
    }
}

pub fn add(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch error.SectionLayoutOverflow;
}

pub fn multiply(left: u64, right: u64) Error!u64 {
    return std.math.mul(u64, left, right) catch error.SectionLayoutOverflow;
}

pub fn aligned(value: u64, alignment: u64) Error!u64 {
    return (try add(value, alignment - 1)) & ~(alignment - 1);
}

fn asU32(value: anytype) Error!u32 {
    return std.math.cast(u32, value) orelse error.SectionLayoutOverflow;
}

fn version(value: Policy.Version) u32 {
    return (@as(u32, value.major) << 16) | (@as(u32, value.minor) << 8) | value.patch;
}

fn alignedCommandBytes(header: u64, name: []const u8) Error!u64 {
    return aligned(try add(header, try add(name.len, 1)), 8);
}

pub fn put(comptime T: type, bytes: []u8, offset: anytype, value: T) void {
    const start: usize = @intCast(offset);
    std.mem.writeInt(T, bytes[start..][0..@sizeOf(T)], value, .little);
}

fn command(out: []u8, offset: usize, kind: u32, size: u32) void {
    put(u32, out, offset, kind);
    put(u32, out, offset + 4, size);
}

fn writeName(out: []u8, offset: usize, value: []const u8) void {
    @memcpy(out[offset..][0..value.len], value);
}

fn segment(out: []u8, offset: usize, label: []const u8, vm: u64, vm_size: u64, file: u64, file_size: u64, maximum: u32, initial: u32, sections: u32) void {
    command(out, offset, 0x19, 72 + sections * 80);
    writeName(out, offset + 8, label);
    put(u64, out, offset + 24, vm);
    put(u64, out, offset + 32, vm_size);
    put(u64, out, offset + 40, file);
    put(u64, out, offset + 48, file_size);
    put(u32, out, offset + 56, maximum);
    put(u32, out, offset + 60, initial);
    put(u32, out, offset + 64, sections);
}

fn writeSection(out: []u8, offset: usize, label: []const u8, segment_label: []const u8, address: u64, size: u64, file: u64, alignment: u32, flags: u32) void {
    writeName(out, offset, label);
    writeName(out, offset + 16, segment_label);
    put(u64, out, offset + 32, address);
    put(u64, out, offset + 40, size);
    put(u32, out, offset + 48, @intCast(file));
    put(u32, out, offset + 52, alignment);
    put(u32, out, offset + 64, flags);
}

fn stringCommand(out: []u8, offset: usize, kind: u32, header: usize, value: []const u8) usize {
    const size = std.mem.alignForward(usize, header + value.len + 1, 8);
    command(out, offset, kind, @intCast(size));
    put(u32, out, offset + 8, @intCast(header));
    writeName(out, offset + header, value);
    return size;
}

comptime {
    // Construction scratch follows actual inputs. The sealed write phase allocates
    // nothing; this declaration makes the construction owner's dynamic demand explicit.
    alloc_phase.capacity.declareDynamicUnbounded("tldr.macho_executable_layout", Layout);
}
