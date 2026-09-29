const std = @import("std");
const ir = @import("../core/root.zig");

const magic = "SLIRBC1\x00";
pub const format_version: u32 = 12;
pub const minimum_readable_version: u32 = format_version;
pub const maximum_readable_version: u32 = format_version;
pub const default_dialect_version: u32 = 0;
pub const default_dialect_flags: u32 = 0;
const current_endianness: u8 = 1;

pub const FormatVersionStatus = enum {
    readable,
    unsupported_older,
    unsupported_newer,
};

pub const FormatCompatibility = struct {
    version: u32,
    minimum_readable: u32 = minimum_readable_version,
    maximum_readable: u32 = maximum_readable_version,
    status: FormatVersionStatus,

    pub fn readable(self: FormatCompatibility) bool {
        return self.status == .readable;
    }
};

pub const ContainerHeader = struct {
    version: u32,
    endianness: u8,
    ptr_size: u8,
    flags: u16,
    section_table_offset: u64,
    section_count: u64,
    file_hash: u64,

    pub fn compatibility(self: ContainerHeader) FormatCompatibility {
        return classifyFormatVersion(self.version);
    }
};

pub fn classifyFormatVersion(version: u32) FormatCompatibility {
    return .{
        .version = version,
        .status = if (version < minimum_readable_version)
            .unsupported_older
        else if (version > maximum_readable_version)
            .unsupported_newer
        else
            .readable,
    };
}

pub const SectionKind = enum(u32) {
    strings = 1,
    dialects = 2,
    types = 3,
    attributes = 4,
    locations = 5,
    module = 6,
    resources = 7,
};

const SectionMeta = struct {
    kind: u32,
    flags: u32,
    offset: u64,
    size: u64,
};

const SectionData = struct {
    kind: u32,
    flags: u32,
    data: []const u8,
};

pub const DialectEntry = struct {
    name: []const u8,
    version: u32,
    flags: u32,

    pub fn usesDefaultVersion(self: DialectEntry) bool {
        return self.version == default_dialect_version and self.flags == default_dialect_flags;
    }
};

pub const Resource = struct {
    namespace: []const u8,
    name: []const u8,
    type_id: []const u8,
    data: []const u8,
};

pub const DecodedTables = struct {
    allocator: std.mem.Allocator,
    format: FormatCompatibility,
    strings: []const []const u8,
    dialects: []const DialectEntry,
    types: []const ir.Type,
    attrs: []const ir.Attribute,
    locs: []const ir.Location,
    loc_slices: std.ArrayList([]const ir.Location),

    pub fn deinit(self: *DecodedTables) void {
        for (self.loc_slices.items) |slice| {
            self.allocator.free(@constCast(slice));
        }
        self.loc_slices.deinit(self.allocator);

        for (self.strings) |str| {
            self.allocator.free(@constCast(str));
        }
        self.allocator.free(self.strings);
        self.allocator.free(self.dialects);
        self.allocator.free(self.types);
        self.allocator.free(self.attrs);
        self.allocator.free(self.locs);
    }
};

pub const DecodedModule = struct {
    module: *ir.Operation,
    tables: DecodedTables,
    resources: []const Resource = &.{},

    pub fn format(self: *const DecodedModule) FormatCompatibility {
        return self.tables.format;
    }

    pub fn deinit(self: *DecodedModule) void {
        freeResources(self.tables.allocator, self.resources);
        self.tables.deinit();
    }
};

pub const FlatModuleDecoder = struct {
    allocator: std.mem.Allocator,
    tables: DecodedTables,
    resources: []const Resource,
    decoder: ModuleDecoder,
    reader: SliceReader,
    module_name: []const u8,
    module_location: ir.Location,
    operations_remaining: usize,
    value_base: usize = 0,
    current: ?*ir.Operation = null,

    pub fn init(
        allocator: std.mem.Allocator,
        ctx: *ir.Context,
        bytes: []const u8,
    ) !FlatModuleDecoder {
        const sections = try parseSections(bytes);
        const module_bytes = sections.module orelse return error.MissingModule;

        var tables = try decodeTablesFromSections(allocator, ctx, sections);
        errdefer tables.deinit();

        const resources = try decodeResourcesSection(allocator, sections.resources);
        errdefer freeResources(allocator, resources);

        var decoder = ModuleDecoder.init(allocator, ctx, &tables);
        errdefer decoder.deinit();

        var reader = SliceReader.init(module_bytes);
        const envelope = try decodeFlatModuleEnvelope(&decoder, &reader);
        return .{
            .allocator = allocator,
            .tables = tables,
            .resources = resources,
            .decoder = decoder,
            .reader = reader,
            .module_name = envelope.name,
            .module_location = envelope.location,
            .operations_remaining = envelope.operation_count,
        };
    }

    pub fn deinit(self: *FlatModuleDecoder) void {
        self.releaseCurrent();
        self.decoder.deinit();
        freeResources(self.allocator, self.resources);
        self.tables.deinit();
        self.* = undefined;
    }

    pub fn format(self: *const FlatModuleDecoder) FormatCompatibility {
        return self.tables.format;
    }

    pub fn name(self: *const FlatModuleDecoder) []const u8 {
        return self.module_name;
    }

    pub fn location(self: *const FlatModuleDecoder) ir.Location {
        return self.module_location;
    }

    pub fn next(self: *FlatModuleDecoder) !?*ir.Operation {
        self.releaseCurrent();
        if (self.operations_remaining == 0) {
            if (self.reader.offset != self.reader.bytes.len) {
                return error.InvalidModule;
            }
            return null;
        }
        self.decoder.value_base = self.value_base;
        const op = try decodeOperation(
            &self.decoder,
            &self.reader,
            null,
            null,
        );
        self.current = op;
        self.operations_remaining -= 1;
        return op;
    }

    fn releaseCurrent(self: *FlatModuleDecoder) void {
        const op = self.current orelse return;
        op.erase();
        self.value_base = std.math.add(
            usize,
            self.value_base,
            self.decoder.values.items.len,
        ) catch unreachable;
        self.decoder.values.clearRetainingCapacity();
        self.current = null;
    }
};

const StringTable = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]const u8),
    map: std.StringHashMap(u32),

    pub fn init(allocator: std.mem.Allocator) StringTable {
        return .{
            .allocator = allocator,
            .items = .empty,
            .map = std.StringHashMap(u32).init(allocator),
        };
    }

    pub fn deinit(self: *StringTable) void {
        for (self.items.items) |value| {
            self.allocator.free(@constCast(value));
        }
        self.items.deinit(self.allocator);
        self.map.deinit();
    }

    pub fn intern(self: *StringTable, value: []const u8) !u32 {
        if (self.map.get(value)) |id| return id;
        const id = std.math.cast(u32, self.items.items.len) orelse return error.TableLimit;
        try self.items.ensureUnusedCapacity(self.allocator, 1);
        try self.map.ensureUnusedCapacity(1);
        const owned = try self.allocator.dupe(u8, value);
        self.items.appendAssumeCapacity(owned);
        self.map.putAssumeCapacity(owned, id);
        return id;
    }
};

fn stringAllocationScenario(allocator: std.mem.Allocator) !void {
    var table = StringTable.init(allocator);
    defer table.deinit();
    errdefer std.debug.assert(table.items.items.len == table.map.count());
    for ([_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i" }, 0..) |value, ordinal| {
        try std.testing.expectEqual(ordinal, try table.intern(value));
    }
    try std.testing.expectEqual(0, try table.intern("a"));
}

test "bytecode string interning owns a consistent prefix across allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, stringAllocationScenario, .{});
}

const DialectRecord = struct {
    name_id: u32,
    version: u32,
    flags: u32,
};

const DialectTable = struct {
    items: std.ArrayList(DialectRecord),
    map: std.AutoHashMap(u32, u32),

    pub fn init(allocator: std.mem.Allocator) DialectTable {
        return .{
            .items = .empty,
            .map = std.AutoHashMap(u32, u32).init(allocator),
        };
    }

    pub fn deinit(self: *DialectTable, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.map.deinit();
    }

    pub fn intern(self: *DialectTable, allocator: std.mem.Allocator, name_id: u32) !u32 {
        if (self.map.get(name_id)) |id| return id;
        try self.items.append(allocator, .{
            .name_id = name_id,
            .version = default_dialect_version,
            .flags = default_dialect_flags,
        });
        const id: u32 = @intCast(self.items.items.len - 1);
        try self.map.put(name_id, id);
        return id;
    }
};

pub const TableBuilder = struct {
    allocator: std.mem.Allocator,
    strings: StringTable,
    dialects: DialectTable,
    types: std.ArrayList(ir.Type),
    attrs: std.ArrayList(ir.Attribute),
    locs: std.ArrayList(ir.Location),

    pub fn init(allocator: std.mem.Allocator) TableBuilder {
        return .{
            .allocator = allocator,
            .strings = StringTable.init(allocator),
            .dialects = DialectTable.init(allocator),
            .types = .empty,
            .attrs = .empty,
            .locs = .empty,
        };
    }

    pub fn deinit(self: *TableBuilder) void {
        self.locs.deinit(self.allocator);
        self.attrs.deinit(self.allocator);
        self.types.deinit(self.allocator);
        self.dialects.deinit(self.allocator);
        self.strings.deinit();
    }

    pub fn internString(self: *TableBuilder, value: []const u8) !u32 {
        return self.strings.intern(value);
    }

    pub fn internDialect(self: *TableBuilder, name: []const u8) !u32 {
        const name_id = try self.internString(name);
        return self.dialects.intern(self.allocator, name_id);
    }

    pub fn internType(self: *TableBuilder, typ: ir.Type) !u32 {
        if (findTypeIndex(self.types.items, typ)) |id| return id;
        const storage = typ.getDialectStorage() orelse return error.UnsupportedType;
        const dialect = dialectNamespace(storage.name);
        if (dialect.len > 0) {
            _ = try self.internDialect(dialect);
            const type_name = dialectTypeName(storage.name);
            _ = try self.internString(type_name);
        } else {
            _ = try self.internDialect(storage.name);
        }
        if (storage.param_key.len > 0) {
            _ = try self.internString(storage.param_key);
        }

        try self.types.append(self.allocator, typ);
        return @intCast(self.types.items.len - 1);
    }

    pub fn internAttribute(self: *TableBuilder, attr: ir.Attribute) !u32 {
        if (findAttrIndex(self.attrs.items, attr)) |id| return id;
        if (attr.abstract.name.len == 0) return error.UnsupportedAttribute;

        const dialect = dialectNamespace(attr.abstract.name);
        if (dialect.len > 0) {
            _ = try self.internDialect(dialect);
        }
        const attr_name = dialectTypeName(attr.abstract.name);
        _ = try self.internString(attr_name);

        const is_typed = std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.integer) or
            std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.float_) or
            std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.bool_) or
            std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.string) or
            std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.symbol_ref) or
            std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.string_list) or
            std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.type_list) or
            std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.array);
        if (!is_typed) {
            _ = attr.cast(ir.Attribute.DialectAttr) orelse return error.UnsupportedAttribute;
        }
        if (std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.type_list)) {
            const type_list_attr = attr.cast(ir.Attribute.TypeListAttr) orelse return error.UnsupportedAttribute;
            for (type_list_attr.values) |typ| {
                _ = try self.internType(typ);
            }
        }
        if (std.mem.eql(u8, attr.abstract.name, ir.builtin_attr_names.array)) {
            const array_attr = attr.cast(ir.Attribute.ArrayAttr) orelse return error.UnsupportedAttribute;
            for (array_attr.values) |child| {
                _ = try self.internAttribute(child);
            }
        }

        try self.attrs.append(self.allocator, attr);
        return @intCast(self.attrs.items.len - 1);
    }

    pub fn internLocation(self: *TableBuilder, loc: ir.Location) !u32 {
        if (findLocationIndex(self.locs.items, loc)) |id| return id;

        switch (loc) {
            .unknown => {},
            .file => |file_loc| {
                _ = try self.internString(file_loc.filename);
            },
            .file_range => |file_range| {
                _ = try self.internString(file_range.filename);
            },
            .name => |name_loc| {
                _ = try self.internString(name_loc.name);
                if (name_loc.child) |child| {
                    _ = try self.internLocation(child.*);
                }
            },
            .fused => |fused| {
                for (fused.locations) |child_loc| {
                    _ = try self.internLocation(child_loc);
                }
            },
            .call_site => |call_site| {
                _ = try self.internLocation(call_site.callee.*);
                _ = try self.internLocation(call_site.caller.*);
            },
        }

        try self.locs.append(self.allocator, loc);
        return @intCast(self.locs.items.len - 1);
    }
};

pub fn encodeTables(allocator: std.mem.Allocator, builder: *TableBuilder) ![]u8 {
    var sections: std.ArrayList(SectionData) = .empty;
    defer {
        for (sections.items) |section| {
            allocator.free(@constCast(section.data));
        }
        sections.deinit(allocator);
    }

    const strings_data = try encodeStringsSection(allocator, builder);
    try sections.append(allocator, .{ .kind = @backingInt(SectionKind.strings), .flags = 0, .data = strings_data });

    const dialects_data = try encodeDialectsSection(allocator, builder);
    try sections.append(allocator, .{ .kind = @backingInt(SectionKind.dialects), .flags = 0, .data = dialects_data });

    const types_data = try encodeTypesSection(allocator, builder);
    try sections.append(allocator, .{ .kind = @backingInt(SectionKind.types), .flags = 0, .data = types_data });

    const attrs_data = try encodeAttributesSection(allocator, builder);
    try sections.append(allocator, .{ .kind = @backingInt(SectionKind.attributes), .flags = 0, .data = attrs_data });

    const locs_data = try encodeLocationsSection(allocator, builder);
    try sections.append(allocator, .{ .kind = @backingInt(SectionKind.locations), .flags = 0, .data = locs_data });

    return try writeContainer(allocator, sections.items);
}

pub fn encodeModule(allocator: std.mem.Allocator, module: *ir.Operation) ![]u8 {
    return encodeModuleWithResources(allocator, module, &.{});
}

pub fn encodeModuleWithResources(
    allocator: std.mem.Allocator,
    module: *ir.Operation,
    resources: []const Resource,
) ![]u8 {
    var builder = TableBuilder.init(allocator);
    defer builder.deinit();

    _ = try builder.internLocation(ir.Location.getUnknown());
    try collectOperationTables(&builder, module);

    var sections: std.ArrayList(SectionData) = .empty;
    defer {
        for (sections.items) |section| {
            allocator.free(@constCast(section.data));
        }
        sections.deinit(allocator);
    }

    try appendOwnedSection(
        allocator,
        &sections,
        @backingInt(SectionKind.strings),
        try encodeStringsSection(allocator, &builder),
    );

    try appendOwnedSection(
        allocator,
        &sections,
        @backingInt(SectionKind.dialects),
        try encodeDialectsSection(allocator, &builder),
    );

    try appendOwnedSection(
        allocator,
        &sections,
        @backingInt(SectionKind.types),
        try encodeTypesSection(allocator, &builder),
    );

    try appendOwnedSection(
        allocator,
        &sections,
        @backingInt(SectionKind.attributes),
        try encodeAttributesSection(allocator, &builder),
    );

    try appendOwnedSection(
        allocator,
        &sections,
        @backingInt(SectionKind.locations),
        try encodeLocationsSection(allocator, &builder),
    );

    try appendOwnedSection(
        allocator,
        &sections,
        @backingInt(SectionKind.module),
        try encodeModuleSection(allocator, &builder, module),
    );

    if (resources.len != 0) {
        try appendOwnedSection(
            allocator,
            &sections,
            @backingInt(SectionKind.resources),
            try encodeResourcesSection(allocator, resources),
        );
    }

    return try writeContainer(allocator, sections.items);
}

fn appendOwnedSection(
    allocator: std.mem.Allocator,
    sections: *std.ArrayList(SectionData),
    kind: u32,
    data: []const u8,
) !void {
    errdefer allocator.free(@constCast(data));
    try sections.append(allocator, .{ .kind = kind, .flags = 0, .data = data });
}

pub fn decodeTables(allocator: std.mem.Allocator, ctx: *ir.Context, bytes: []const u8) !DecodedTables {
    const sections = try parseSections(bytes);
    return decodeTablesFromSections(allocator, ctx, sections);
}

fn decodeTablesFromSections(
    allocator: std.mem.Allocator,
    ctx: *ir.Context,
    sections: ParsedSections,
) !DecodedTables {
    const strings_bytes = sections.strings orelse return error.MissingStrings;
    const strings = try decodeStrings(allocator, strings_bytes);
    errdefer freeStringTable(allocator, strings);

    const dialects = try decodeDialects(allocator, sections.dialects, strings);
    errdefer allocator.free(dialects);

    const types = try decodeTypes(allocator, ctx, sections.types, strings, dialects);
    errdefer allocator.free(types);

    const attrs = try decodeAttributes(allocator, ctx, sections.attrs, strings, dialects, types);
    errdefer allocator.free(attrs);

    var loc_slices: std.ArrayList([]const ir.Location) = .empty;
    errdefer {
        for (loc_slices.items) |slice| {
            allocator.free(@constCast(slice));
        }
        loc_slices.deinit(allocator);
    }

    const locs = try decodeLocations(allocator, sections.locs, strings, &loc_slices);
    errdefer allocator.free(locs);

    return .{
        .allocator = allocator,
        .format = sections.header.compatibility(),
        .strings = strings,
        .dialects = dialects,
        .types = types,
        .attrs = attrs,
        .locs = locs,
        .loc_slices = loc_slices,
    };
}

pub fn decodeModule(allocator: std.mem.Allocator, ctx: *ir.Context, bytes: []const u8) !DecodedModule {
    const sections = try parseSections(bytes);
    const module_bytes = sections.module orelse return error.MissingModule;

    var tables = try decodeTablesFromSections(allocator, ctx, sections);
    errdefer tables.deinit();

    const resources = try decodeResourcesSection(allocator, sections.resources);
    errdefer freeResources(allocator, resources);

    const module_op = try decodeModuleSection(allocator, ctx, module_bytes, &tables);
    return .{
        .module = module_op,
        .tables = tables,
        .resources = resources,
    };
}

fn headerSize() u64 {
    return 8 + 4 + 1 + 1 + 2 + 8 + 8 + 8;
}

fn sectionEntrySize() u64 {
    return 4 + 4 + 8 + 8;
}

fn writeContainer(allocator: std.mem.Allocator, sections: []const SectionData) ![]u8 {
    const section_count: u64 = @intCast(sections.len);
    const table_offset = headerSize();
    const table_size = section_count * sectionEntrySize();

    var metas = try allocator.alloc(SectionMeta, sections.len);
    defer allocator.free(metas);

    var cursor = table_offset + table_size;
    for (sections, 0..) |section, idx| {
        metas[idx] = .{
            .kind = section.kind,
            .flags = section.flags,
            .offset = cursor,
            .size = @intCast(section.data.len),
        };
        cursor += @intCast(section.data.len);
    }

    var writer = BufferWriter.init(allocator);
    errdefer writer.deinit();

    try writer.writeAll(magic);
    try writer.writeU32(format_version);
    try writer.writeByte(current_endianness);
    try writer.writeByte(@intCast(@sizeOf(usize)));
    try writer.writeU16(0);
    try writer.writeU64(table_offset);
    try writer.writeU64(section_count);
    try writer.writeU64(0);

    for (metas) |meta| {
        try writer.writeU32(meta.kind);
        try writer.writeU32(meta.flags);
        try writer.writeU64(meta.offset);
        try writer.writeU64(meta.size);
    }

    for (sections) |section| {
        try writer.writeAll(section.data);
    }

    return writer.toOwnedSlice();
}

pub fn inspectHeader(bytes: []const u8) !ContainerHeader {
    var reader = SliceReader.init(bytes);
    return readHeader(&reader);
}

fn readHeader(reader: *SliceReader) !ContainerHeader {
    const got_magic = try reader.readBytes(magic.len);
    if (!std.mem.eql(u8, got_magic, magic)) return error.InvalidHeader;

    return .{
        .version = try reader.readU32(),
        .endianness = try reader.readByte(),
        .ptr_size = try reader.readByte(),
        .flags = try reader.readU16(),
        .section_table_offset = try reader.readU64(),
        .section_count = try reader.readU64(),
        .file_hash = try reader.readU64(),
    };
}

pub const ParsedSections = struct {
    header: ContainerHeader,
    strings: ?[]const u8,
    dialects: ?[]const u8,
    types: ?[]const u8,
    attrs: ?[]const u8,
    locs: ?[]const u8,
    module: ?[]const u8,
    resources: ?[]const u8,
};

pub fn parseSections(bytes: []const u8) !ParsedSections {
    var header_reader = SliceReader.init(bytes);
    const header = try readHeader(&header_reader);

    if (!header.compatibility().readable()) return error.UnsupportedVersion;
    if (header.endianness != current_endianness) return error.UnsupportedEndianness;

    const bytes_len_u64: u64 = @intCast(bytes.len);
    const section_table_size = std.math.mul(
        u64,
        header.section_count,
        sectionEntrySize(),
    ) catch return error.InvalidSectionTable;
    const section_table_end = std.math.add(
        u64,
        header.section_table_offset,
        section_table_size,
    ) catch return error.InvalidSectionTable;
    if (section_table_end > bytes_len_u64) return error.InvalidSectionTable;

    var sections = ParsedSections{
        .header = header,
        .strings = null,
        .dialects = null,
        .types = null,
        .attrs = null,
        .locs = null,
        .module = null,
        .resources = null,
    };

    const table_offset: usize = @intCast(header.section_table_offset);
    var table_reader = SliceReader.init(bytes[table_offset..]);
    var i: u64 = 0;
    while (i < header.section_count) : (i += 1) {
        const kind_raw = try table_reader.readU32();
        const flags = try table_reader.readU32();
        const offset = try table_reader.readU64();
        const size = try table_reader.readU64();
        _ = flags;

        const end_u64 = std.math.add(
            u64,
            offset,
            size,
        ) catch return error.InvalidSection;
        if (end_u64 > bytes_len_u64) return error.InvalidSection;
        const start: usize = @intCast(offset);
        const end: usize = @intCast(end_u64);
        const slice = bytes[start..end];

        switch (kind_raw) {
            @backingInt(SectionKind.strings) => {
                if (sections.strings != null) return error.DuplicateSection;
                sections.strings = slice;
            },
            @backingInt(SectionKind.dialects) => {
                if (sections.dialects != null) return error.DuplicateSection;
                sections.dialects = slice;
            },
            @backingInt(SectionKind.types) => {
                if (sections.types != null) return error.DuplicateSection;
                sections.types = slice;
            },
            @backingInt(SectionKind.attributes) => {
                if (sections.attrs != null) return error.DuplicateSection;
                sections.attrs = slice;
            },
            @backingInt(SectionKind.locations) => {
                if (sections.locs != null) return error.DuplicateSection;
                sections.locs = slice;
            },
            @backingInt(SectionKind.module) => {
                if (sections.module != null) return error.DuplicateSection;
                sections.module = slice;
            },
            @backingInt(SectionKind.resources) => {
                if (sections.resources != null) return error.DuplicateSection;
                sections.resources = slice;
            },
            else => {},
        }
    }

    return sections;
}

fn encodeStringsSection(allocator: std.mem.Allocator, builder: *TableBuilder) ![]u8 {
    var writer = BufferWriter.init(allocator);
    errdefer writer.deinit();

    try writer.writeULEB(builder.strings.items.items.len);
    for (builder.strings.items.items) |value| {
        try writer.writeBytes(value);
    }

    return writer.toOwnedSlice();
}

fn encodeDialectsSection(allocator: std.mem.Allocator, builder: *TableBuilder) ![]u8 {
    var writer = BufferWriter.init(allocator);
    errdefer writer.deinit();

    try writer.writeULEB(builder.dialects.items.items.len);
    for (builder.dialects.items.items) |dialect| {
        try writer.writeULEB(dialect.name_id);
        try writer.writeULEB(dialect.version);
        try writer.writeULEB(dialect.flags);
    }

    return writer.toOwnedSlice();
}

fn encodeTypesSection(allocator: std.mem.Allocator, builder: *TableBuilder) ![]u8 {
    var writer = BufferWriter.init(allocator);
    errdefer writer.deinit();

    try writer.writeULEB(builder.types.items.len);
    for (builder.types.items) |typ| {
        try encodeType(builder, &writer, typ);
    }

    return writer.toOwnedSlice();
}

fn encodeAttributesSection(allocator: std.mem.Allocator, builder: *TableBuilder) ![]u8 {
    var writer = BufferWriter.init(allocator);
    errdefer writer.deinit();

    try writer.writeULEB(builder.attrs.items.len);
    for (builder.attrs.items) |attr| {
        try encodeAttribute(builder, &writer, attr);
    }

    return writer.toOwnedSlice();
}

fn encodeLocationsSection(allocator: std.mem.Allocator, builder: *TableBuilder) ![]u8 {
    var writer = BufferWriter.init(allocator);
    errdefer writer.deinit();

    try writer.writeULEB(builder.locs.items.len);
    for (builder.locs.items) |loc| {
        try encodeLocation(builder, &writer, loc);
    }

    return writer.toOwnedSlice();
}

fn encodeResourcesSection(
    allocator: std.mem.Allocator,
    resources: []const Resource,
) ![]u8 {
    var writer = BufferWriter.init(allocator);
    errdefer writer.deinit();

    try writer.writeULEB(resources.len);
    for (resources) |resource| {
        try writer.writeBytes(resource.namespace);
        try writer.writeBytes(resource.name);
        try writer.writeBytes(resource.type_id);
        try writer.writeBytes(resource.data);
    }

    return writer.toOwnedSlice();
}

fn decodeResourcesSection(
    allocator: std.mem.Allocator,
    bytes_opt: ?[]const u8,
) ![]const Resource {
    const bytes = bytes_opt orelse return &.{};

    var reader = SliceReader.init(bytes);
    const count = try reader.readULEBToUsize();
    if (count == 0) {
        if (reader.offset != bytes.len) return error.InvalidSection;
        return &.{};
    }

    const resources = try allocator.alloc(Resource, count);
    var initialized: usize = 0;
    errdefer {
        for (resources[0..initialized]) |resource| {
            allocator.free(@constCast(resource.namespace));
            allocator.free(@constCast(resource.name));
            allocator.free(@constCast(resource.type_id));
            allocator.free(@constCast(resource.data));
        }
        if (resources.len != 0) allocator.free(resources);
    }

    while (initialized < count) : (initialized += 1) {
        const namespace = try reader.readBytesWithLen();
        const name = try reader.readBytesWithLen();
        const type_id = try reader.readBytesWithLen();
        const data = try reader.readBytesWithLen();
        const namespace_owned = try allocator.dupe(u8, namespace);
        errdefer allocator.free(namespace_owned);
        const name_owned = try allocator.dupe(u8, name);
        errdefer allocator.free(name_owned);
        const type_id_owned = try allocator.dupe(u8, type_id);
        errdefer allocator.free(type_id_owned);
        const data_owned = try allocator.dupe(u8, data);
        errdefer allocator.free(data_owned);
        resources[initialized] = .{
            .namespace = namespace_owned,
            .name = name_owned,
            .type_id = type_id_owned,
            .data = data_owned,
        };
    }
    if (reader.offset != bytes.len) return error.InvalidSection;

    return resources;
}

fn freeResources(allocator: std.mem.Allocator, resources: []const Resource) void {
    for (resources) |resource| {
        allocator.free(@constCast(resource.namespace));
        allocator.free(@constCast(resource.name));
        allocator.free(@constCast(resource.type_id));
        allocator.free(@constCast(resource.data));
    }
    if (resources.len != 0) allocator.free(@constCast(resources));
}

fn decodeStrings(allocator: std.mem.Allocator, bytes: []const u8) ![]const []const u8 {
    var reader = SliceReader.init(bytes);
    const count = try reader.readULEBToUsize();

    const strings = try allocator.alloc([]const u8, count);
    var initialized: usize = 0;
    errdefer {
        for (strings[0..initialized]) |value| allocator.free(value);
        allocator.free(strings);
    }
    for (strings) |*slot| {
        const slice = try reader.readBytesWithLen();
        const owned = try allocator.dupe(u8, slice);
        slot.* = owned;
        initialized += 1;
    }

    return strings;
}

fn decodeDialects(
    allocator: std.mem.Allocator,
    bytes_opt: ?[]const u8,
    strings: []const []const u8,
) ![]const DialectEntry {
    if (bytes_opt == null) return allocator.alloc(DialectEntry, 0);

    var reader = SliceReader.init(bytes_opt.?);
    const count = try reader.readULEBToUsize();
    const dialects = try allocator.alloc(DialectEntry, count);
    errdefer allocator.free(dialects);
    for (dialects) |*slot| {
        const name_id = try reader.readULEBToUsize();
        const version = try reader.readULEBToU32();
        const flags = try reader.readULEBToU32();
        if (name_id >= strings.len) return error.InvalidTable;
        slot.* = .{
            .name = strings[name_id],
            .version = version,
            .flags = flags,
        };
    }

    return dialects;
}

fn decodeTypes(
    allocator: std.mem.Allocator,
    ctx: *ir.Context,
    bytes_opt: ?[]const u8,
    strings: []const []const u8,
    dialects: []const DialectEntry,
) ![]const ir.Type {
    if (bytes_opt == null) return allocator.alloc(ir.Type, 0);

    var reader = SliceReader.init(bytes_opt.?);
    const count = try reader.readULEBToUsize();
    const types = try allocator.alloc(ir.Type, count);
    errdefer allocator.free(types);
    for (types) |*slot| {
        slot.* = try decodeType(ctx, &reader, strings, dialects, types);
    }

    return types;
}

fn decodeAttributes(
    allocator: std.mem.Allocator,
    ctx: *ir.Context,
    bytes_opt: ?[]const u8,
    strings: []const []const u8,
    dialects: []const DialectEntry,
    types: []const ir.Type,
) ![]const ir.Attribute {
    if (bytes_opt == null) return allocator.alloc(ir.Attribute, 0);

    var reader = SliceReader.init(bytes_opt.?);
    const count = try reader.readULEBToUsize();
    const attrs = try allocator.alloc(ir.Attribute, count);
    errdefer allocator.free(attrs);
    for (attrs, 0..) |*slot, index| {
        slot.* = try decodeAttribute(allocator, ctx, &reader, strings, dialects, types, attrs[0..index]);
    }

    return attrs;
}

fn decodeLocations(
    allocator: std.mem.Allocator,
    bytes_opt: ?[]const u8,
    strings: []const []const u8,
    loc_slices: *std.ArrayList([]const ir.Location),
) ![]const ir.Location {
    if (bytes_opt == null) return allocator.alloc(ir.Location, 0);

    var reader = SliceReader.init(bytes_opt.?);
    const count = try reader.readULEBToUsize();
    const locs = try allocator.alloc(ir.Location, count);
    errdefer allocator.free(locs);

    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        locs[idx] = try decodeLocation(allocator, &reader, strings, locs, loc_slices);
    }

    return locs;
}

fn freeStringTable(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |value| {
        allocator.free(@constCast(value));
    }
    allocator.free(strings);
}

fn decodeType(
    ctx: *ir.Context,
    reader: *SliceReader,
    strings: []const []const u8,
    dialects: []const DialectEntry,
    decoded: []const ir.Type,
) !ir.Type {
    _ = decoded;
    const kind = try reader.readByte();
    switch (kind) {
        @backingInt(TypeKind.builtin_scalar) => {
            const scalar_kind = std.enums.fromInt(BuiltinScalarKind, try reader.readByte()) orelse
                return error.UnsupportedType;
            const width = try reader.readByte();
            const name = builtinScalarName(scalar_kind, width) orelse return error.UnsupportedType;
            return ctx.getDialectTypeFromName(name);
        },
        @backingInt(TypeKind.dialect) => {
            const dialect_id = try reader.readULEBToUsize();
            const type_name_id = try reader.readULEBToUsize();
            const has_key = (try reader.readByte()) != 0;
            const key_id = if (has_key) try reader.readULEBToUsize() else 0;
            if (dialect_id >= dialects.len) return error.InvalidTable;
            if (type_name_id >= strings.len) return error.InvalidTable;
            if (has_key and key_id >= strings.len) return error.InvalidTable;

            const dialect = dialects[dialect_id].name;
            const type_name = strings[type_name_id];
            const param_key = if (has_key) strings[key_id] else "";
            const allocator = ir.context.transientAllocator(ctx);
            const full_name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ dialect, type_name });
            defer allocator.free(full_name);
            return ctx.getDialectTypeFromNameWithKey(full_name, param_key);
        },
        @backingInt(TypeKind.dialect_only) => {
            const dialect_id = try reader.readULEBToUsize();
            const has_key = (try reader.readByte()) != 0;
            const key_id = if (has_key) try reader.readULEBToUsize() else 0;
            if (dialect_id >= dialects.len) return error.InvalidTable;
            if (has_key and key_id >= strings.len) return error.InvalidTable;

            const dialect = dialects[dialect_id].name;
            const param_key = if (has_key) strings[key_id] else "";
            return ctx.getDialectTypeFromNameWithKey(dialect, param_key);
        },
        else => return error.UnsupportedType,
    }
}

fn decodeAttribute(
    allocator: std.mem.Allocator,
    ctx: *ir.Context,
    reader: *SliceReader,
    strings: []const []const u8,
    dialects: []const DialectEntry,
    types: []const ir.Type,
    decoded: []const ir.Attribute,
) !ir.Attribute {
    const kind = try reader.readByte();
    switch (kind) {
        @backingInt(AttrKind.integer) => {
            const value = try reader.readSLEB();
            const width = try reader.readByte();
            const is_signed = (try reader.readByte()) != 0;
            return ctx.getIntegerAttr(value, width, is_signed);
        },
        @backingInt(AttrKind.float_) => {
            const bits = try reader.readU64();
            const width = try reader.readByte();
            return ctx.getFloatAttr(@bitCast(bits), width);
        },
        @backingInt(AttrKind.bool_) => {
            const value = (try reader.readByte()) != 0;
            return ctx.getBoolAttr(value);
        },
        @backingInt(AttrKind.string) => {
            const value = try reader.readBytesWithLen();
            return ctx.getStringAttr(value);
        },
        @backingInt(AttrKind.symbol_ref) => {
            const root_reference = try reader.readBytesWithLen();
            const count = try reader.readULEBToUsize();
            const nested_references = try allocator.alloc([]const u8, count);
            defer allocator.free(nested_references);
            for (nested_references) |*slot| {
                slot.* = try reader.readBytesWithLen();
            }
            return ctx.getSymbolRefAttr(root_reference, nested_references);
        },
        @backingInt(AttrKind.string_list) => {
            const count = try reader.readULEBToUsize();
            const values = try allocator.alloc([]const u8, count);
            defer allocator.free(values);
            for (values) |*slot| {
                slot.* = try reader.readBytesWithLen();
            }
            return ctx.getStringListAttr(values);
        },
        @backingInt(AttrKind.type_list) => {
            const count = try reader.readULEBToUsize();
            const values = try allocator.alloc(ir.Type, count);
            defer allocator.free(values);
            for (values) |*slot| {
                const type_id = try reader.readULEBToUsize();
                if (type_id >= types.len) return error.InvalidTable;
                slot.* = types[type_id];
            }
            return ctx.getTypeListAttr(values);
        },
        @backingInt(AttrKind.array) => {
            const count = try reader.readULEBToUsize();
            const values = try allocator.alloc(ir.Attribute, count);
            defer allocator.free(values);
            for (values) |*slot| {
                const attr_id = try reader.readULEBToUsize();
                if (attr_id >= decoded.len) return error.InvalidTable;
                slot.* = decoded[attr_id];
            }
            return ctx.getArrayAttr(values);
        },
        @backingInt(AttrKind.dialect) => {
            const dialect_id = try reader.readULEBToUsize();
            const name_id = try reader.readULEBToUsize();
            const payload = try reader.readBytesWithLen();
            if (dialect_id >= dialects.len) return error.InvalidTable;
            if (name_id >= strings.len) return error.InvalidTable;

            const dialect = dialects[dialect_id].name;
            const attr_name = strings[name_id];
            const transient_allocator = ir.context.transientAllocator(ctx);
            const full_name = try std.fmt.allocPrint(transient_allocator, "{s}.{s}", .{ dialect, attr_name });
            defer transient_allocator.free(full_name);

            return ctx.getDialectAttr(full_name, payload);
        },
        else => return error.UnsupportedAttribute,
    }
}

fn decodeLocation(
    allocator: std.mem.Allocator,
    reader: *SliceReader,
    strings: []const []const u8,
    locs: []const ir.Location,
    loc_slices: *std.ArrayList([]const ir.Location),
) !ir.Location {
    const kind = try reader.readByte();
    switch (kind) {
        @backingInt(LocationKind.unknown) => return ir.Location.getUnknown(),
        @backingInt(LocationKind.file) => {
            const name_id = try reader.readULEBToUsize();
            const line = try reader.readULEBToU32();
            const column = try reader.readULEBToU32();
            if (name_id >= strings.len) return error.InvalidTable;
            return ir.Location.getFile(strings[name_id], line, column);
        },
        @backingInt(LocationKind.file_range) => {
            const name_id = try reader.readULEBToUsize();
            const start_byte = try reader.readULEB();
            const start_line = try reader.readULEBToU32();
            const start_column = try reader.readULEBToU32();
            const end_byte = try reader.readULEB();
            const end_line = try reader.readULEBToU32();
            const end_column = try reader.readULEBToU32();
            if (name_id >= strings.len or start_byte > end_byte) return error.InvalidTable;
            return ir.Location.getFileRange(
                strings[name_id],
                .{ .byte = start_byte, .line = start_line, .column = start_column },
                .{ .byte = end_byte, .line = end_line, .column = end_column },
            );
        },
        @backingInt(LocationKind.name) => {
            const name_id = try reader.readULEBToUsize();
            const has_child = (try reader.readByte()) != 0;
            if (name_id >= strings.len) return error.InvalidTable;
            if (has_child) {
                const child_id = try reader.readULEBToUsize();
                if (child_id >= locs.len) return error.InvalidTable;
                return ir.Location.getName(strings[name_id], &locs[child_id]);
            }
            return ir.Location.getName(strings[name_id], null);
        },
        @backingInt(LocationKind.fused) => {
            const count = try reader.readULEBToUsize();
            const fused_locs = try allocator.alloc(ir.Location, count);
            errdefer allocator.free(fused_locs);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const loc_id = try reader.readULEBToUsize();
                if (loc_id >= locs.len) return error.InvalidTable;
                fused_locs[i] = locs[loc_id];
            }
            try loc_slices.append(allocator, fused_locs);
            return .{ .fused = .{ .locations = fused_locs, .metadata = null } };
        },
        @backingInt(LocationKind.call_site) => {
            const callee_id = try reader.readULEBToUsize();
            const caller_id = try reader.readULEBToUsize();
            if (callee_id >= locs.len or caller_id >= locs.len) return error.InvalidTable;
            return .{ .call_site = .{ .callee = &locs[callee_id], .caller = &locs[caller_id] } };
        },
        else => return error.UnsupportedLocation,
    }
}

fn encodeType(builder: *TableBuilder, writer: *BufferWriter, typ: ir.Type) !void {
    const storage = typ.getDialectStorage() orelse return error.UnsupportedType;
    if (builtinScalarFromName(storage.name)) |builtin| {
        if (storage.param_key.len > 0) return error.UnsupportedType;
        try writer.writeByte(@backingInt(TypeKind.builtin_scalar));
        try writer.writeByte(@backingInt(builtin.kind));
        try writer.writeByte(builtin.width);
        return;
    }
    const dialect = dialectNamespace(storage.name);
    if (dialect.len == 0) {
        try writer.writeByte(@backingInt(TypeKind.dialect_only));
        const dialect_id = try builder.internDialect(storage.name);
        try writer.writeULEB(dialect_id);
        if (storage.param_key.len > 0) {
            try writer.writeByte(1);
            try writer.writeULEB(try builder.internString(storage.param_key));
        } else {
            try writer.writeByte(0);
        }
        return;
    }
    try writer.writeByte(@backingInt(TypeKind.dialect));
    const dialect_id = try builder.internDialect(dialect);
    try writer.writeULEB(dialect_id);
    const type_name = dialectTypeName(storage.name);
    try writer.writeULEB(try builder.internString(type_name));
    if (storage.param_key.len > 0) {
        try writer.writeByte(1);
        try writer.writeULEB(try builder.internString(storage.param_key));
    } else {
        try writer.writeByte(0);
    }
}

fn encodeAttribute(builder: *TableBuilder, writer: *BufferWriter, attr: ir.Attribute) !void {
    if (attr.abstract.name.len == 0) return error.UnsupportedAttribute;
    const full_name = attr.abstract.name;

    if (std.mem.eql(u8, full_name, ir.builtin_attr_names.integer)) {
        const int_attr = attr.cast(ir.Attribute.IntegerAttr) orelse return error.UnsupportedAttribute;
        try writer.writeByte(@backingInt(AttrKind.integer));
        try writer.writeSLEB(int_attr.value);
        try writer.writeByte(int_attr.width);
        try writer.writeByte(if (int_attr.is_signed) 1 else 0);
        return;
    } else if (std.mem.eql(u8, full_name, ir.builtin_attr_names.float_)) {
        const float_attr = attr.cast(ir.Attribute.FloatAttr) orelse return error.UnsupportedAttribute;
        try writer.writeByte(@backingInt(AttrKind.float_));
        try writer.writeU64(@bitCast(float_attr.value));
        try writer.writeByte(float_attr.width);
        return;
    } else if (std.mem.eql(u8, full_name, ir.builtin_attr_names.bool_)) {
        const bool_attr = attr.cast(ir.Attribute.BoolAttr) orelse return error.UnsupportedAttribute;
        try writer.writeByte(@backingInt(AttrKind.bool_));
        try writer.writeByte(if (bool_attr.value) 1 else 0);
        return;
    } else if (std.mem.eql(u8, full_name, ir.builtin_attr_names.string)) {
        const str_attr = attr.cast(ir.Attribute.StringAttr) orelse return error.UnsupportedAttribute;
        try writer.writeByte(@backingInt(AttrKind.string));
        try writer.writeBytes(str_attr.value);
        return;
    } else if (std.mem.eql(u8, full_name, ir.builtin_attr_names.symbol_ref)) {
        const symbol_ref_attr = attr.cast(ir.Attribute.SymbolRefAttr) orelse return error.UnsupportedAttribute;
        try writer.writeByte(@backingInt(AttrKind.symbol_ref));
        try writer.writeBytes(symbol_ref_attr.root_reference);
        try writer.writeULEB(symbol_ref_attr.nested_references.len);
        for (symbol_ref_attr.nested_references) |nested| {
            try writer.writeBytes(nested);
        }
        return;
    } else if (std.mem.eql(u8, full_name, ir.builtin_attr_names.string_list)) {
        const str_list_attr = attr.cast(ir.Attribute.StringListAttr) orelse return error.UnsupportedAttribute;
        try writer.writeByte(@backingInt(AttrKind.string_list));
        try writer.writeULEB(str_list_attr.values.len);
        for (str_list_attr.values) |value| {
            try writer.writeBytes(value);
        }
        return;
    } else if (std.mem.eql(u8, full_name, ir.builtin_attr_names.type_list)) {
        const type_list_attr = attr.cast(ir.Attribute.TypeListAttr) orelse return error.UnsupportedAttribute;
        try writer.writeByte(@backingInt(AttrKind.type_list));
        try writer.writeULEB(type_list_attr.values.len);
        for (type_list_attr.values) |typ| {
            try writer.writeULEB(try lookupTypeId(builder, typ));
        }
        return;
    } else if (std.mem.eql(u8, full_name, ir.builtin_attr_names.array)) {
        const array_attr = attr.cast(ir.Attribute.ArrayAttr) orelse return error.UnsupportedAttribute;
        try writer.writeByte(@backingInt(AttrKind.array));
        try writer.writeULEB(array_attr.values.len);
        for (array_attr.values) |child| {
            try writer.writeULEB(try lookupAttrId(builder, child));
        }
        return;
    }

    const dialect = dialectNamespace(full_name);
    const dialect_id = if (dialect.len > 0)
        try builder.internDialect(dialect)
    else
        0;
    const attr_name = dialectTypeName(full_name);
    const attr_name_id = try builder.internString(attr_name);

    const dialect_attr = attr.cast(ir.Attribute.DialectAttr) orelse return error.UnsupportedAttribute;

    try writer.writeByte(@backingInt(AttrKind.dialect));
    try writer.writeULEB(dialect_id);
    try writer.writeULEB(attr_name_id);
    try writer.writeBytes(dialect_attr.payload);
}

fn encodeLocation(builder: *TableBuilder, writer: *BufferWriter, loc: ir.Location) !void {
    switch (loc) {
        .unknown => {
            try writer.writeByte(@backingInt(LocationKind.unknown));
        },
        .file => |file_loc| {
            try writer.writeByte(@backingInt(LocationKind.file));
            try writer.writeULEB(try builder.internString(file_loc.filename));
            try writer.writeULEB(file_loc.line);
            try writer.writeULEB(file_loc.column);
        },
        .file_range => |range| {
            try writer.writeByte(@backingInt(LocationKind.file_range));
            try writer.writeULEB(try builder.internString(range.filename));
            try writer.writeULEB(range.start.byte);
            try writer.writeULEB(range.start.line);
            try writer.writeULEB(range.start.column);
            try writer.writeULEB(range.end.byte);
            try writer.writeULEB(range.end.line);
            try writer.writeULEB(range.end.column);
        },
        .name => |name_loc| {
            try writer.writeByte(@backingInt(LocationKind.name));
            try writer.writeULEB(try builder.internString(name_loc.name));
            if (name_loc.child) |child| {
                try writer.writeByte(1);
                try writer.writeULEB(try builder.internLocation(child.*));
            } else {
                try writer.writeByte(0);
            }
        },
        .fused => |fused| {
            try writer.writeByte(@backingInt(LocationKind.fused));
            try writer.writeULEB(fused.locations.len);
            for (fused.locations) |child_loc| {
                try writer.writeULEB(try builder.internLocation(child_loc));
            }
        },
        .call_site => |call_site| {
            try writer.writeByte(@backingInt(LocationKind.call_site));
            try writer.writeULEB(try builder.internLocation(call_site.callee.*));
            try writer.writeULEB(try builder.internLocation(call_site.caller.*));
        },
    }
}

fn collectOperationTables(builder: *TableBuilder, op: *ir.Operation) anyerror!void {
    _ = try builder.internString(op.name.name);
    _ = try builder.internLocation(op.location);

    for (op.results.items) |result| {
        _ = try builder.internType(result.type);
    }
    for (op.operands.items) |operand| {
        _ = try builder.internType(operand.value.type);
    }
    for (op.getRawDictionaryAttrs()) |attr| {
        _ = try builder.internString(attr.name);
        _ = try builder.internAttribute(attr.value);
    }
    if (try op.getPropertiesAsAttr()) |properties| {
        _ = try builder.internAttribute(properties);
    }

    for (op.regions.items) |*region| {
        var blocks = region.getBlocks();
        while (blocks.next()) |block| {
            for (block.arguments.items, 0..) |arg, index| {
                _ = try builder.internType(arg.type);
                _ = try builder.internLocation(block.getArgumentLocation(index).?);
            }

            var current: ?*ir.Operation = if (block.operations.head) |any_ptr|
                @ptrCast(@alignCast(any_ptr))
            else
                null;
            while (current) |child| {
                try collectOperationTables(builder, child);
                current = child.next_op;
            }
        }
    }
}

fn lookupStringId(builder: *TableBuilder, value: []const u8) !u32 {
    return builder.strings.map.get(value) orelse error.MissingTableEntry;
}

fn lookupTypeId(builder: *TableBuilder, typ: ir.Type) !u32 {
    return findTypeIndex(builder.types.items, typ) orelse error.MissingTableEntry;
}

fn lookupAttrId(builder: *TableBuilder, attr: ir.Attribute) !u32 {
    return findAttrIndex(builder.attrs.items, attr) orelse error.MissingTableEntry;
}

fn lookupLocationId(builder: *TableBuilder, loc: ir.Location) !u32 {
    return findLocationIndex(builder.locs.items, loc) orelse error.MissingTableEntry;
}

const ModuleEncoder = struct {
    allocator: std.mem.Allocator,
    builder: *TableBuilder,
    value_ids: std.AutoHashMap(*ir.Value, u32),
    next_value_id: u32,

    pub fn init(allocator: std.mem.Allocator, builder: *TableBuilder) !ModuleEncoder {
        return .{
            .allocator = allocator,
            .builder = builder,
            .value_ids = std.AutoHashMap(*ir.Value, u32).init(allocator),
            .next_value_id = 0,
        };
    }

    pub fn deinit(self: *ModuleEncoder) void {
        self.value_ids.deinit();
    }

    pub fn defineValue(self: *ModuleEncoder, value: *ir.Value) !u32 {
        if (self.value_ids.get(value)) |id| return id;
        const id = self.next_value_id;
        self.next_value_id += 1;
        try self.value_ids.put(value, id);
        return id;
    }

    pub fn getValueId(self: *ModuleEncoder, value: *ir.Value) !u32 {
        return self.value_ids.get(value) orelse error.InvalidModule;
    }
};

fn encodeModuleSection(
    allocator: std.mem.Allocator,
    builder: *TableBuilder,
    module: *ir.Operation,
) ![]u8 {
    var encoder = try ModuleEncoder.init(allocator, builder);
    defer encoder.deinit();

    var writer = BufferWriter.init(allocator);
    errdefer writer.deinit();

    try encodeOperation(&encoder, &writer, module, null);

    return writer.toOwnedSlice();
}

fn indexRegionBlocks(
    encoder: *ModuleEncoder,
    region: *ir.Region,
    blocks: *std.ArrayList(*ir.Block),
    block_ids: *std.AutoHashMap(*ir.Block, u32),
) anyerror!void {
    var iter = region.getBlocks();
    while (iter.next()) |block| {
        const id: u32 = @intCast(blocks.items.len);
        try blocks.append(encoder.allocator, block);
        try block_ids.put(block, id);
    }
}

fn encodeBlockArguments(encoder: *ModuleEncoder, writer: *BufferWriter, block: *ir.Block) anyerror!void {
    try writer.writeULEB(block.arguments.items.len);
    for (block.arguments.items, 0..) |arg, index| {
        try writer.writeULEB(try lookupTypeId(encoder.builder, arg.type));
        try writer.writeULEB(try lookupLocationId(
            encoder.builder,
            block.getArgumentLocation(index).?,
        ));
        _ = try encoder.defineValue(arg);
    }
}

fn countBlockOps(block: *ir.Block) usize {
    var count: usize = 0;
    var current: ?*ir.Operation = if (block.operations.head) |any_ptr|
        @ptrCast(@alignCast(any_ptr))
    else
        null;
    while (current) |op| {
        count += 1;
        current = op.next_op;
    }
    return count;
}

fn encodeOperation(
    encoder: *ModuleEncoder,
    writer: *BufferWriter,
    op: *ir.Operation,
    block_ids: ?*const std.AutoHashMap(*ir.Block, u32),
) anyerror!void {
    const name_id = try lookupStringId(encoder.builder, op.name.name);
    const loc_id = try lookupLocationId(encoder.builder, op.location);

    try writer.writeULEB(name_id);
    try writer.writeULEB(loc_id);

    try writer.writeULEB(op.results.items.len);
    for (op.results.items) |result| {
        try writer.writeULEB(try lookupTypeId(encoder.builder, result.type));
    }

    try writer.writeULEB(op.operands.items.len);
    for (op.operands.items) |operand| {
        const value_id = try encoder.getValueId(operand.value);
        try writer.writeULEB(value_id);
    }

    const attrs = op.getRawDictionaryAttrs();
    try writer.writeULEB(attrs.len);
    for (attrs) |attr| {
        const attr_name_id = try lookupStringId(encoder.builder, attr.name);
        const attr_id = try lookupAttrId(encoder.builder, attr.value);
        try writer.writeULEB(attr_name_id);
        try writer.writeULEB(attr_id);
    }

    if (try op.getPropertiesAsAttr()) |properties| {
        try writer.writeByte(1);
        try writer.writeULEB(try lookupAttrId(encoder.builder, properties));
    } else {
        try writer.writeByte(0);
    }

    try writer.writeULEB(op.successors.items.len);
    if (op.successors.items.len > 0) {
        const map = block_ids orelse return error.InvalidModule;
        for (op.successors.items) |succ| {
            const block_id = map.get(succ) orelse return error.InvalidModule;
            try writer.writeULEB(block_id);
        }
    }

    try writer.writeULEB(op.regions.items.len);

    for (op.results.items) |*result| {
        _ = try encoder.defineValue(result);
    }

    for (op.regions.items) |*region| {
        var region_blocks: std.ArrayList(*ir.Block) = .empty;
        defer region_blocks.deinit(encoder.allocator);

        var region_block_ids = std.AutoHashMap(*ir.Block, u32).init(encoder.allocator);
        defer region_block_ids.deinit();

        try indexRegionBlocks(encoder, region, &region_blocks, &region_block_ids);
        try writer.writeULEB(region_blocks.items.len);

        for (region_blocks.items) |block| {
            try encodeBlockArguments(encoder, writer, block);

            const op_count = countBlockOps(block);
            try writer.writeULEB(op_count);

            var current: ?*ir.Operation = if (block.operations.head) |any_ptr|
                @ptrCast(@alignCast(any_ptr))
            else
                null;
            while (current) |child| {
                try encodeOperation(encoder, writer, child, &region_block_ids);
                current = child.next_op;
            }
        }
    }
}

const ModuleDecoder = struct {
    allocator: std.mem.Allocator,
    ctx: *ir.Context,
    strings: []const []const u8,
    types: []const ir.Type,
    attrs: []const ir.Attribute,
    locs: []const ir.Location,
    values: std.ArrayList(*ir.Value),
    value_base: usize,

    pub fn init(allocator: std.mem.Allocator, ctx: *ir.Context, tables: *DecodedTables) ModuleDecoder {
        return .{
            .allocator = allocator,
            .ctx = ctx,
            .strings = tables.strings,
            .types = tables.types,
            .attrs = tables.attrs,
            .locs = tables.locs,
            .values = .empty,
            .value_base = 0,
        };
    }

    pub fn deinit(self: *ModuleDecoder) void {
        self.values.deinit(self.allocator);
    }
};

const FlatModuleEnvelope = struct {
    name: []const u8,
    location: ir.Location,
    operation_count: usize,
};

fn decodeFlatModuleEnvelope(
    decoder: *ModuleDecoder,
    reader: *SliceReader,
) !FlatModuleEnvelope {
    const name_id = try reader.readULEBToUsize();
    const loc_id = try reader.readULEBToUsize();
    if (name_id >= decoder.strings.len or loc_id >= decoder.locs.len) {
        return error.InvalidTable;
    }
    if (try reader.readULEBToUsize() != 0) return error.InvalidModule;
    if (try reader.readULEBToUsize() != 0) return error.InvalidModule;

    const attr_count = try reader.readULEBToUsize();
    var attr_index: usize = 0;
    while (attr_index < attr_count) : (attr_index += 1) {
        const attr_name_id = try reader.readULEBToUsize();
        const attr_id = try reader.readULEBToUsize();
        if (attr_name_id >= decoder.strings.len or
            attr_id >= decoder.attrs.len)
        {
            return error.InvalidTable;
        }
    }

    const has_properties = try reader.readByte();
    if (has_properties > 1) return error.InvalidModule;
    if (has_properties == 1) {
        const property_id = try reader.readULEBToUsize();
        if (property_id >= decoder.attrs.len) return error.InvalidTable;
    }
    if (try reader.readULEBToUsize() != 0) return error.InvalidModule;
    if (try reader.readULEBToUsize() != 1) return error.InvalidModule;
    if (try reader.readULEBToUsize() != 1) return error.InvalidModule;
    if (try reader.readULEBToUsize() != 0) return error.InvalidModule;

    return .{
        .name = decoder.strings[name_id],
        .location = decoder.locs[loc_id],
        .operation_count = try reader.readULEBToUsize(),
    };
}

fn decodeModuleSection(
    allocator: std.mem.Allocator,
    ctx: *ir.Context,
    bytes: []const u8,
    tables: *DecodedTables,
) !*ir.Operation {
    var decoder = ModuleDecoder.init(allocator, ctx, tables);
    defer decoder.deinit();

    var reader = SliceReader.init(bytes);
    const module_op = try decodeOperation(&decoder, &reader, null, null);
    errdefer module_op.erase();
    if (reader.offset != bytes.len) return error.InvalidModule;
    return module_op;
}

fn createRegionBlocks(decoder: *ModuleDecoder, reader: *SliceReader, region: *ir.Region) anyerror!std.ArrayList(*ir.Block) {
    const block_count = try reader.readULEBToUsize();

    var blocks: std.ArrayList(*ir.Block) = .empty;
    errdefer blocks.deinit(decoder.allocator);

    var i: usize = 0;
    while (i < block_count) : (i += 1) {
        const block = try region.addBlock();
        try blocks.append(decoder.allocator, block);
    }

    return blocks;
}

fn decodeBlockArguments(decoder: *ModuleDecoder, reader: *SliceReader, block: *ir.Block) anyerror!void {
    const arg_count = try reader.readULEBToUsize();
    if (arg_count > 0) {
        try block.arguments.ensureTotalCapacity(block.allocator, arg_count);
    }
    const arg_start = block.arguments.items.len;
    var arg_idx: usize = 0;
    while (arg_idx < arg_count) : (arg_idx += 1) {
        const type_id = try reader.readULEBToUsize();
        const loc_id = try reader.readULEBToUsize();
        if (type_id >= decoder.types.len or loc_id >= decoder.locs.len) return error.InvalidTable;
        _ = try block.addArgument(decoder.types[type_id], decoder.locs[loc_id]);
    }
    for (block.arguments.items[arg_start..]) |arg| {
        try decoder.values.append(decoder.allocator, arg);
    }
}

fn decodeOperation(
    decoder: *ModuleDecoder,
    reader: *SliceReader,
    blocks: ?[]const *ir.Block,
    parent_block: ?*ir.Block,
) anyerror!*ir.Operation {
    const name_id = try reader.readULEBToUsize();
    const loc_id = try reader.readULEBToUsize();
    if (name_id >= decoder.strings.len or loc_id >= decoder.locs.len) return error.InvalidTable;

    const result_count = try reader.readULEBToUsize();
    var result_types: []ir.Type = &.{};
    if (result_count > 0) {
        result_types = try reader.readTypeList(decoder.allocator, result_count, decoder.types);
    }
    defer if (result_types.len > 0) decoder.allocator.free(result_types);

    const operand_count = try reader.readULEBToUsize();
    var operands: []*ir.Value = &.{};
    defer if (operands.len > 0) decoder.allocator.free(operands);
    if (operand_count > 0) {
        operands = try decoder.allocator.alloc(*ir.Value, operand_count);
        var op_idx: usize = 0;
        while (op_idx < operand_count) : (op_idx += 1) {
            const value_id = try reader.readULEBToUsize();
            if (value_id < decoder.value_base) return error.InvalidModule;
            const local_value_id = value_id - decoder.value_base;
            if (local_value_id >= decoder.values.items.len) {
                return error.InvalidModule;
            }
            operands[op_idx] = decoder.values.items[local_value_id];
        }
    }
    const attr_count = try reader.readULEBToUsize();
    var attrs: []ir.NamedAttribute = &.{};
    defer if (attrs.len > 0) decoder.allocator.free(attrs);
    if (attr_count > 0) {
        attrs = try decoder.allocator.alloc(ir.NamedAttribute, attr_count);
        var attr_idx: usize = 0;
        while (attr_idx < attr_count) : (attr_idx += 1) {
            const attr_name_id = try reader.readULEBToUsize();
            const attr_id = try reader.readULEBToUsize();
            if (attr_name_id >= decoder.strings.len or attr_id >= decoder.attrs.len) return error.InvalidTable;
            attrs[attr_idx] = .{
                .name = decoder.strings[attr_name_id],
                .value = decoder.attrs[attr_id],
            };
        }
    }
    const has_properties = try reader.readByte();
    if (has_properties > 1) return error.InvalidModule;
    const properties = if (has_properties == 1) blk: {
        const property_id = try reader.readULEBToUsize();
        if (property_id >= decoder.attrs.len) return error.InvalidTable;
        break :blk decoder.attrs[property_id];
    } else null;

    const succ_count = try reader.readULEBToUsize();
    var successors: []*ir.Block = &.{};
    defer if (successors.len > 0) decoder.allocator.free(successors);
    if (succ_count > 0) {
        const block_list = blocks orelse return error.InvalidModule;
        successors = try decoder.allocator.alloc(*ir.Block, succ_count);
        var succ_idx: usize = 0;
        while (succ_idx < succ_count) : (succ_idx += 1) {
            const block_id = try reader.readULEBToUsize();
            if (block_id >= block_list.len) return error.InvalidModule;
            successors[succ_idx] = block_list[block_id];
        }
    }
    const region_count = try reader.readULEBToUsize();

    var state = ir.Operation.State.init(decoder.strings[name_id], decoder.locs[loc_id]);
    if (operand_count > 0) state.addOperands(operands);
    if (result_count > 0) state.addTypes(result_types);
    if (attr_count > 0) state.addRawAttributes(attrs);
    if (properties) |payload| try state.setPropertiesAttr(payload);
    if (succ_count > 0) state.addSuccessors(successors);
    var region_idx: usize = 0;
    while (region_idx < region_count) : (region_idx += 1) {
        state.addRegion();
    }

    const op = try decoder.ctx.createOperation(state);
    errdefer op.erase();
    if (parent_block) |block| {
        try block.addOperation(op);
    }

    for (op.results.items) |*result| {
        try decoder.values.append(decoder.allocator, result);
    }

    region_idx = 0;
    while (region_idx < region_count) : (region_idx += 1) {
        const region = op.getRegion(region_idx) orelse return error.InvalidModule;
        var region_blocks = try createRegionBlocks(decoder, reader, region);
        defer region_blocks.deinit(decoder.allocator);

        for (region_blocks.items) |block| {
            try decodeBlockArguments(decoder, reader, block);

            const op_count = try reader.readULEBToUsize();
            var op_idx: usize = 0;
            while (op_idx < op_count) : (op_idx += 1) {
                _ = try decodeOperation(decoder, reader, region_blocks.items, block);
            }
        }
    }

    return op;
}

pub const TypeKind = enum(u8) {
    dialect = 0,
    builtin_scalar = 1,
    dialect_only = 2,
};

pub const BuiltinScalarKind = enum(u8) {
    index = 0,
    bool_ = 1,
    integer = 2,
    float_ = 3,
};

fn builtinScalarFromName(name: []const u8) ?struct { kind: BuiltinScalarKind, width: u8 } {
    if (std.mem.eql(u8, name, "arith.index")) return .{ .kind = .index, .width = 0 };
    if (std.mem.eql(u8, name, "arith.bool")) return .{ .kind = .bool_, .width = 1 };
    if (std.mem.eql(u8, name, "arith.i8")) return .{ .kind = .integer, .width = 8 };
    if (std.mem.eql(u8, name, "arith.i16")) return .{ .kind = .integer, .width = 16 };
    if (std.mem.eql(u8, name, "arith.i32")) return .{ .kind = .integer, .width = 32 };
    if (std.mem.eql(u8, name, "arith.i64")) return .{ .kind = .integer, .width = 64 };
    if (std.mem.eql(u8, name, "arith.f16")) return .{ .kind = .float_, .width = 16 };
    if (std.mem.eql(u8, name, "arith.f32")) return .{ .kind = .float_, .width = 32 };
    if (std.mem.eql(u8, name, "arith.f64")) return .{ .kind = .float_, .width = 64 };
    return null;
}

fn builtinScalarName(kind: BuiltinScalarKind, width: u8) ?[]const u8 {
    return switch (kind) {
        .index => "arith.index",
        .bool_ => "arith.bool",
        .integer => switch (width) {
            8 => "arith.i8",
            16 => "arith.i16",
            32 => "arith.i32",
            64 => "arith.i64",
            else => null,
        },
        .float_ => switch (width) {
            16 => "arith.f16",
            32 => "arith.f32",
            64 => "arith.f64",
            else => null,
        },
    };
}

pub const AttrKind = enum(u8) {
    dialect = 0,
    integer = 1,
    float_ = 2,
    bool_ = 3,
    string = 4,
    type_list = 5,
    string_list = 6,
    symbol_ref = 7,
    array = 8,
};

pub const LocationKind = enum(u8) {
    unknown = 0,
    file = 1,
    name = 2,
    fused = 3,
    call_site = 4,
    file_range = 5,
};

fn findTypeIndex(list: []const ir.Type, typ: ir.Type) ?u32 {
    for (list, 0..) |item, idx| {
        if (item.eql(typ)) return @intCast(idx);
    }
    return null;
}

fn findAttrIndex(list: []const ir.Attribute, attr: ir.Attribute) ?u32 {
    for (list, 0..) |item, idx| {
        if (attrEqual(item, attr)) return @intCast(idx);
    }
    return null;
}

fn findLocationIndex(list: []const ir.Location, loc: ir.Location) ?u32 {
    for (list, 0..) |item, idx| {
        if (locationEqual(item, loc)) return @intCast(idx);
    }
    return null;
}

fn attrEqual(a: ir.Attribute, b: ir.Attribute) bool {
    return a.eql(b);
}

fn locationEqual(a: ir.Location, b: ir.Location) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    switch (a) {
        .unknown => return true,
        .file => |lhs| {
            const rhs = b.file;
            return lhs.line == rhs.line and lhs.column == rhs.column and std.mem.eql(u8, lhs.filename, rhs.filename);
        },
        .file_range => |lhs| {
            const rhs = b.file_range;
            return lhs.start.byte == rhs.start.byte and
                lhs.start.line == rhs.start.line and
                lhs.start.column == rhs.start.column and
                lhs.end.byte == rhs.end.byte and
                lhs.end.line == rhs.end.line and
                lhs.end.column == rhs.end.column and
                std.mem.eql(u8, lhs.filename, rhs.filename);
        },
        .name => |lhs| {
            const rhs = b.name;
            if (!std.mem.eql(u8, lhs.name, rhs.name)) return false;
            if (lhs.child == null and rhs.child == null) return true;
            if (lhs.child == null or rhs.child == null) return false;
            return locationEqual(lhs.child.?.*, rhs.child.?.*);
        },
        .fused => |lhs| {
            const rhs = b.fused;
            if (lhs.locations.len != rhs.locations.len) return false;
            for (lhs.locations, 0..) |loc, idx| {
                if (!locationEqual(loc, rhs.locations[idx])) return false;
            }
            return true;
        },
        .call_site => |lhs| {
            const rhs = b.call_site;
            return locationEqual(lhs.callee.*, rhs.callee.*) and locationEqual(lhs.caller.*, rhs.caller.*);
        },
    }
}

fn dialectNamespace(full_name: []const u8) []const u8 {
    const op_name = ir.Operation.OperationName.init(full_name);
    return op_name.getDialectNamespace();
}

fn dialectTypeName(full_name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, full_name, ".")) |idx| {
        return full_name[idx + 1 ..];
    }
    return full_name;
}

const BufferWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) BufferWriter {
        return .{ .allocator = allocator, .buffer = .empty };
    }

    pub fn deinit(self: *BufferWriter) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn toOwnedSlice(self: *BufferWriter) ![]u8 {
        return self.buffer.toOwnedSlice(self.allocator);
    }

    pub fn writeAll(self: *BufferWriter, bytes: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    pub fn writeByte(self: *BufferWriter, value: u8) !void {
        try self.buffer.append(self.allocator, value);
    }

    pub fn writeU16(self: *BufferWriter, value: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, value, .little);
        try self.writeAll(buf[0..]);
    }

    pub fn writeU32(self: *BufferWriter, value: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .little);
        try self.writeAll(buf[0..]);
    }

    pub fn writeU64(self: *BufferWriter, value: u64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, value, .little);
        try self.writeAll(buf[0..]);
    }

    pub fn writeULEB(self: *BufferWriter, value: anytype) !void {
        const v64: u64 = @intCast(value);
        var v = v64;
        while (true) {
            var byte: u8 = @intCast(v & 0x7f);
            v >>= 7;
            if (v != 0) byte |= 0x80;
            try self.writeByte(byte);
            if (v == 0) break;
        }
    }

    pub fn writeSLEB(self: *BufferWriter, value: i64) !void {
        var more = true;
        var v = value;
        while (more) {
            var byte: u8 = @intCast(v & 0x7f);
            const sign_bit = (byte & 0x40) != 0;
            v >>= 7;
            if ((v == 0 and !sign_bit) or (v == -1 and sign_bit)) {
                more = false;
            } else {
                byte |= 0x80;
            }
            try self.writeByte(byte);
        }
    }

    pub fn writeBytes(self: *BufferWriter, bytes: []const u8) !void {
        try self.writeULEB(bytes.len);
        try self.writeAll(bytes);
    }
};

pub const SliceReader = struct {
    bytes: []const u8,
    offset: usize,

    pub fn init(bytes: []const u8) SliceReader {
        return .{ .bytes = bytes, .offset = 0 };
    }

    pub fn readByte(self: *SliceReader) !u8 {
        if (self.offset >= self.bytes.len) return error.EndOfStream;
        const value = self.bytes[self.offset];
        self.offset += 1;
        return value;
    }

    pub fn readBytes(self: *SliceReader, len: usize) ![]const u8 {
        if (len > self.bytes.len - self.offset) return error.EndOfStream;
        const end = self.offset + len;
        const slice = self.bytes[self.offset..end];
        self.offset = end;
        return slice;
    }

    pub fn readBytesWithLen(self: *SliceReader) ![]const u8 {
        const len = try self.readULEBToUsize();
        return self.readBytes(len);
    }

    pub fn readU16(self: *SliceReader) !u16 {
        const slice = try self.readBytes(2);
        var buf: [2]u8 = undefined;
        std.mem.copyForwards(u8, buf[0..], slice);
        return std.mem.readInt(u16, &buf, .little);
    }

    pub fn readU32(self: *SliceReader) !u32 {
        const slice = try self.readBytes(4);
        var buf: [4]u8 = undefined;
        std.mem.copyForwards(u8, buf[0..], slice);
        return std.mem.readInt(u32, &buf, .little);
    }

    pub fn readU64(self: *SliceReader) !u64 {
        const slice = try self.readBytes(8);
        var buf: [8]u8 = undefined;
        std.mem.copyForwards(u8, buf[0..], slice);
        return std.mem.readInt(u64, &buf, .little);
    }

    pub fn readULEB(self: *SliceReader) !u64 {
        var result: u64 = 0;
        var shift: u8 = 0;
        while (true) {
            const byte = try self.readByte();
            const payload = byte & 0x7f;
            if (shift == 63) {
                if (payload > 1) return error.InvalidLEB128;
                result |= @as(u64, payload) << 63;
            } else {
                const bit_shift: u6 = @intCast(shift);
                result |= @as(u64, payload) << bit_shift;
            }
            if ((byte & 0x80) == 0) return result;
            if (shift >= 63) return error.InvalidLEB128;
            shift += 7;
        }
    }

    pub fn readSLEB(self: *SliceReader) !i64 {
        var result: u64 = 0;
        var shift: u8 = 0;
        while (true) {
            const byte = try self.readByte();
            const payload = byte & 0x7f;
            if (shift == 63) {
                if (payload == 0x7f) {
                    result |= @as(u64, 1) << 63;
                } else if (payload != 0) {
                    return error.InvalidLEB128;
                }
            } else {
                const bit_shift: u6 = @intCast(shift);
                result |= @as(u64, payload) << bit_shift;
            }
            if ((byte & 0x80) == 0) {
                const used = shift + 7;
                if (used < 64 and (byte & 0x40) != 0) {
                    const sign_shift: u6 = @intCast(used);
                    result |= @as(u64, std.math.maxInt(u64)) << sign_shift;
                }
                return @bitCast(result);
            }
            if (shift >= 63) return error.InvalidLEB128;
            shift += 7;
        }
    }

    pub fn readULEBToU32(self: *SliceReader) !u32 {
        const value = try self.readULEB();
        if (value > std.math.maxInt(u32)) return error.InvalidTable;
        return @intCast(value);
    }

    pub fn readULEBToUsize(self: *SliceReader) !usize {
        const value = try self.readULEB();
        if (value > std.math.maxInt(usize)) return error.InvalidTable;
        return @intCast(value);
    }

    pub fn readTypeList(
        self: *SliceReader,
        allocator: std.mem.Allocator,
        count: usize,
        types: []const ir.Type,
    ) ![]ir.Type {
        const list = try allocator.alloc(ir.Type, count);
        errdefer allocator.free(list);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const type_id = try self.readULEBToUsize();
            if (type_id >= types.len) return error.InvalidTable;
            list[i] = types[type_id];
        }
        return list;
    }
};

const BytecodeProperties = struct {
    payload: ?ir.Attribute = null,

    fn from(storage: *anyopaque) *@This() {
        return @ptrCast(@alignCast(storage));
    }

    fn fromConst(storage: *const anyopaque) *const @This() {
        return @ptrCast(@alignCast(storage));
    }

    fn init(storage: *anyopaque, _: std.mem.Allocator) anyerror!void {
        from(storage).* = .{};
    }

    fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}

    fn get(_: *const ir.Operation, storage: *const anyopaque, name: []const u8) ?ir.Attribute {
        const payload = fromConst(storage).payload orelse return null;
        const values = payload.cast(ir.Attribute.ArrayAttr).?.values;
        if (std.mem.eql(u8, name, "left")) return values[0];
        if (std.mem.eql(u8, name, "right")) return values[1];
        return null;
    }

    fn getProperties(_: *const ir.Operation, storage: *const anyopaque) ?ir.Attribute {
        return fromConst(storage).payload;
    }

    fn setProperties(_: *ir.Operation, storage: *anyopaque, attr: ir.Attribute) anyerror!void {
        const array = attr.cast(ir.Attribute.ArrayAttr) orelse return error.InvalidTestProperties;
        if (array.values.len != 2) return error.InvalidTestProperties;
        from(storage).payload = attr;
    }

    fn copyProperties(dest: *anyopaque, source: *const anyopaque) anyerror!void {
        from(dest).* = fromConst(source).*;
    }

    const model = ir.OperationPropertiesModel{
        .name = "test.bytecode.properties",
        .size = @sizeOf(@This()),
        .alignment = std.mem.Alignment.fromByteUnits(@alignOf(@This())),
        .init = init,
        .deinit = deinit,
        .getInherentAttr = get,
        .getPropertiesAsAttr = getProperties,
        .setPropertiesFromAttr = setProperties,
        .copyProperties = copyProperties,
    };
};

fn registerBytecodeProperties(context: *ir.Context) !void {
    try context.allowUnregistered();
    _ = try context.registerOperation("test.bytecode_properties", .{});
    try context.registerOperationInherentAttributeNames(
        "test.bytecode_properties",
        &.{ "left", "right" },
    );
    try context.registerOperationPropertiesModel(
        "test.bytecode_properties",
        BytecodeProperties.model,
    );
}

test "bytecode qualification refuses unqualified property models despite conversion hooks" {
    const qualification = @import("root.zig").qualification;
    const allocator = std.testing.allocator;
    var source_context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer source_context.deinit(allocator);
    try registerBytecodeProperties(&source_context);
    var decode_context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer decode_context.deinit(allocator);
    try registerBytecodeProperties(&decode_context);
    const left = try source_context.getI64Attr(11);
    const right = try source_context.getI64Attr(22);
    const payload = try source_context.getArrayAttr(&.{ left, right });
    var state = ir.Operation.State.init("test.bytecode_properties", .unknown);
    try state.setPropertiesAttr(payload);
    const source = try source_context.createOperation(state);
    try std.testing.expectError(error.UnencodableProduct, qualification.encode(
        allocator,
        source,
        &.{},
        &decode_context,
        .{ .operations = 10, .entities = 10, .fields = 100, .depth = 16 },
    ));
}

test "bytecode tables round-trip" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    var builder = TableBuilder.init(allocator);
    defer builder.deinit();

    const i32_type = try test_dialect.TestDialect.getI32Type(&ctx);
    const f64_type = try test_dialect.TestDialect.getF64Type(&ctx);
    const dialect_type = try ctx.getDialectTypeFromNameWithKey("test.ty", "key");

    _ = try builder.internType(i32_type);
    _ = try builder.internType(f64_type);
    _ = try builder.internType(dialect_type);

    const unit_attr = try test_dialect.TestDialect.getUnitAttr(&ctx);
    const bool_attr = try test_dialect.TestDialect.getBoolAttr(&ctx, true);
    const int_attr = try test_dialect.TestDialect.getIntegerAttr(&ctx, 42);
    const string_attr = try test_dialect.TestDialect.getStringAttr(&ctx, "hello");
    const symbol_ref_attr = try ctx.getSymbolRefAttr("module", &.{ "nested", "leaf" });
    const string_list_attr = try ctx.getStringListAttr(&.{ "ctx", "value_out" });
    const type_attr = try test_dialect.TestDialect.getTypeAttr(&ctx, i32_type);
    const type_list_attr = try ctx.getTypeListAttr(&.{ i32_type, dialect_type });
    const array_attr = try ctx.getArrayAttr(&.{ string_attr, symbol_ref_attr, type_list_attr });

    _ = try builder.internAttribute(unit_attr);
    _ = try builder.internAttribute(bool_attr);
    _ = try builder.internAttribute(int_attr);
    _ = try builder.internAttribute(string_attr);
    _ = try builder.internAttribute(symbol_ref_attr);
    _ = try builder.internAttribute(string_list_attr);
    _ = try builder.internAttribute(type_attr);
    _ = try builder.internAttribute(type_list_attr);
    _ = try builder.internAttribute(array_attr);

    var child_loc = ir.Location.getFile("test.ir", 3, 9);
    const range_loc = ir.Location.getFileRange(
        "model.gen",
        .{ .byte = 4, .line = 2, .column = 3 },
        .{ .byte = 9, .line = 2, .column = 8 },
    );
    const name_loc = ir.Location.getName("generated", &child_loc);
    const unknown_loc = ir.Location.getUnknown();

    _ = try builder.internLocation(name_loc);
    _ = try builder.internLocation(unknown_loc);
    _ = try builder.internLocation(range_loc);

    const bytes = try encodeTables(allocator, &builder);
    defer allocator.free(bytes);

    var decode_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer decode_ctx.deinit(allocator);
    try decode_ctx.allowUnregistered();

    var tables = try decodeTables(allocator, &decode_ctx, bytes);
    defer tables.deinit();

    try testing.expect(tables.format.readable());
    try testing.expectEqual(format_version, tables.format.version);
    try testing.expectEqual(@as(usize, 2), tables.dialects.len);
    try testing.expect(hasDialect(tables.dialects, "builtin"));
    try testing.expect(hasDialect(tables.dialects, "test"));
    for (tables.dialects) |dialect| {
        try testing.expect(dialect.usesDefaultVersion());
    }

    const decoded_i32 = try test_dialect.TestDialect.getI32Type(&decode_ctx);
    const decoded_f64 = try test_dialect.TestDialect.getF64Type(&decode_ctx);
    const decoded_dialect = try decode_ctx.getDialectTypeFromNameWithKey("test.ty", "key");

    try testing.expect(hasType(tables.types, decoded_i32));
    try testing.expect(hasType(tables.types, decoded_f64));
    try testing.expect(hasType(tables.types, decoded_dialect));

    const decoded_unit = try test_dialect.TestDialect.getUnitAttr(&decode_ctx);
    const decoded_bool = try test_dialect.TestDialect.getBoolAttr(&decode_ctx, true);
    const decoded_int = try test_dialect.TestDialect.getIntegerAttr(&decode_ctx, 42);
    const decoded_string = try test_dialect.TestDialect.getStringAttr(&decode_ctx, "hello");
    const decoded_symbol_ref = try decode_ctx.getSymbolRefAttr("module", &.{ "nested", "leaf" });
    const decoded_string_list = try decode_ctx.getStringListAttr(&.{ "ctx", "value_out" });
    const decoded_type = try test_dialect.TestDialect.getTypeAttr(&decode_ctx, decoded_i32);
    const decoded_type_list = try decode_ctx.getTypeListAttr(&.{ decoded_i32, decoded_dialect });
    const decoded_array = try decode_ctx.getArrayAttr(&.{ decoded_string, decoded_symbol_ref, decoded_type_list });

    try testing.expect(hasAttr(tables.attrs, decoded_unit));
    try testing.expect(hasAttr(tables.attrs, decoded_bool));
    try testing.expect(hasAttr(tables.attrs, decoded_int));
    try testing.expect(hasAttr(tables.attrs, decoded_string));
    try testing.expect(hasAttr(tables.attrs, decoded_symbol_ref));
    try testing.expect(hasAttr(tables.attrs, decoded_string_list));
    try testing.expect(hasAttr(tables.attrs, decoded_type));
    try testing.expect(hasAttr(tables.attrs, decoded_type_list));
    try testing.expect(hasAttr(tables.attrs, decoded_array));

    try testing.expect(hasLocation(tables.locs, name_loc));
    try testing.expect(hasLocation(tables.locs, unknown_loc));
    try testing.expect(hasLocation(tables.locs, range_loc));
}

test "bytecode round-trips builtin scalar types" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const arith = @import("../dialects/root.zig").ArithDialect;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    var builder = TableBuilder.init(allocator);
    defer builder.deinit();

    const i32_type = try arith.getI32Type(&ctx);
    const f32_type = try arith.getScalarType(&ctx, .f32);
    const index_type = try arith.getIndexType(&ctx);
    const bool_type = try arith.getScalarType(&ctx, .bool);

    _ = try builder.internType(i32_type);
    _ = try builder.internType(f32_type);
    _ = try builder.internType(index_type);
    _ = try builder.internType(bool_type);

    const bytes = try encodeTables(allocator, &builder);
    defer allocator.free(bytes);

    var decode_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer decode_ctx.deinit(allocator);
    _ = try arith.getI32Type(&decode_ctx);

    var tables = try decodeTables(allocator, &decode_ctx, bytes);
    defer tables.deinit();

    const decoded_i32 = try arith.getI32Type(&decode_ctx);
    const decoded_f32 = try arith.getScalarType(&decode_ctx, .f32);
    const decoded_index = try arith.getIndexType(&decode_ctx);
    const decoded_bool = try arith.getScalarType(&decode_ctx, .bool);

    try testing.expect(hasType(tables.types, decoded_i32));
    try testing.expect(hasType(tables.types, decoded_f32));
    try testing.expect(hasType(tables.types, decoded_index));
    try testing.expect(hasType(tables.types, decoded_bool));
}

fn testTableContainer(allocator: std.mem.Allocator, replacement: ?SectionData) ![]u8 {
    var sections = [_]SectionData{
        .{ .kind = @backingInt(SectionKind.strings), .flags = 0, .data = "\x02\x01s\x01t" },
        .{ .kind = @backingInt(SectionKind.dialects), .flags = 0, .data = "\x01\x00\x00\x00" },
        .{ .kind = @backingInt(SectionKind.types), .flags = 0, .data = "\x01\x01\x02\x20" },
        .{ .kind = @backingInt(SectionKind.attributes), .flags = 0, .data = "\x01\x03\x01" },
        .{ .kind = @backingInt(SectionKind.locations), .flags = 0, .data = "\x02\x00\x03\x01\x00" },
        .{ .kind = @backingInt(SectionKind.module), .flags = 0, .data = "" },
    };
    if (replacement) |value| {
        for (&sections) |*section| {
            if (section.kind == value.kind) section.* = value;
        }
    }
    return writeContainer(allocator, &sections);
}

test "bytecode table decoders release partial malformed containers" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { kind: SectionKind, data: []const u8, err: anyerror }{
        .{ .kind = .strings, .data = "\x02\x01a", .err = error.EndOfStream },
        .{ .kind = .dialects, .data = "\x02\x00\x00\x00", .err = error.EndOfStream },
        .{ .kind = .types, .data = "\x02\x01\x02\x20", .err = error.EndOfStream },
        .{ .kind = .attributes, .data = "\x02\x03\x01", .err = error.EndOfStream },
        .{ .kind = .locations, .data = "\x02\x00", .err = error.EndOfStream },
        .{ .kind = .locations, .data = "\x02\x00\x03\x02\x00", .err = error.EndOfStream },
        .{ .kind = .locations, .data = "\x03\x00\x03\x01\x00", .err = error.EndOfStream },
        .{ .kind = .dialects, .data = "\x01\x02\x00\x00", .err = error.InvalidTable },
        .{ .kind = .locations, .data = "\x02\x00\x03\x01\x02", .err = error.InvalidTable },
    };
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();
    for (cases) |case| {
        const bytes = try testTableContainer(allocator, .{
            .kind = @backingInt(case.kind),
            .flags = 0,
            .data = case.data,
        });
        defer allocator.free(bytes);
        try std.testing.expectError(case.err, decodeTables(allocator, &ctx, bytes));
        try std.testing.expectError(case.err, decodeModule(allocator, &ctx, bytes));
    }
}

test "bytecode table decoders reject every invalid scalar tag" {
    const allocator = std.testing.allocator;
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    for (4..256) |tag| {
        const types = [_]u8{ 1, @backingInt(TypeKind.builtin_scalar), @intCast(tag), 32 };
        const bytes = try testTableContainer(allocator, .{
            .kind = @backingInt(SectionKind.types),
            .flags = 0,
            .data = &types,
        });
        defer allocator.free(bytes);
        try std.testing.expectError(error.UnsupportedType, decodeTables(allocator, &ctx, bytes));
        try std.testing.expectError(error.UnsupportedType, decodeModule(allocator, &ctx, bytes));
    }
}

test "bytecode table decoders release every failed allocation" {
    const allocator = std.testing.allocator;
    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();
    const bytes = try testTableContainer(allocator, null);
    defer allocator.free(bytes);
    try std.testing.checkAllAllocationFailures(allocator, testTableAllocationFailure, .{ &ctx, bytes });
}

fn testTableAllocationFailure(
    allocator: std.mem.Allocator,
    ctx: *ir.Context,
    bytes: []const u8,
) !void {
    var tables = try decodeTables(allocator, ctx, bytes);
    defer tables.deinit();
    try std.testing.expectEqual(@as(usize, 2), tables.strings.len);
    try std.testing.expectEqual(@as(usize, 1), tables.dialects.len);
    try std.testing.expectEqual(@as(usize, 1), tables.types.len);
    try std.testing.expectEqual(@as(usize, 1), tables.attrs.len);
    try std.testing.expectEqual(@as(usize, 2), tables.locs.len);
    try std.testing.expectEqual(@as(usize, 1), tables.locs[1].fused.locations.len);
    try std.testing.expectEqual(@as(usize, 1), tables.loc_slices.items.len);
}

test "bytecode encoding is deterministic" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    var builder = TableBuilder.init(allocator);
    defer builder.deinit();

    const i32_type = try test_dialect.TestDialect.getI32Type(&ctx);
    const attr = try test_dialect.TestDialect.getIntegerAttr(&ctx, 7);
    _ = try builder.internType(i32_type);
    _ = try builder.internAttribute(attr);
    _ = try builder.internLocation(ir.Location.getUnknown());

    const bytes1 = try encodeTables(allocator, &builder);
    defer allocator.free(bytes1);
    const bytes2 = try encodeTables(allocator, &builder);
    defer allocator.free(bytes2);

    try testing.expectEqualSlices(u8, bytes1, bytes2);
}

test "bytecode rejects invalid magic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    var builder = TableBuilder.init(allocator);
    defer builder.deinit();

    const bytes = try encodeTables(allocator, &builder);
    defer allocator.free(bytes);

    var corrupted = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted);
    corrupted[0] = 'X';

    try testing.expectError(error.InvalidHeader, decodeTables(allocator, &ctx, corrupted));
}

test "bytecode rejects overflowed section ranges" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    var builder = TableBuilder.init(allocator);
    defer builder.deinit();

    const bytes = try encodeTables(allocator, &builder);
    defer allocator.free(bytes);

    var section_count = try allocator.dupe(u8, bytes);
    defer allocator.free(section_count);
    const section_count_offset = magic.len + 4 + 1 + 1 + 2 + 8;
    std.mem.writeInt(
        u64,
        section_count[section_count_offset..][0..8],
        std.math.maxInt(u64),
        .little,
    );
    try testing.expectError(
        error.InvalidSectionTable,
        decodeTables(allocator, &ctx, section_count),
    );

    var table_offset = try allocator.dupe(u8, bytes);
    defer allocator.free(table_offset);
    const table_offset_offset = magic.len + 4 + 1 + 1 + 2;
    std.mem.writeInt(
        u64,
        table_offset[table_offset_offset..][0..8],
        std.math.maxInt(u64),
        .little,
    );
    try testing.expectError(
        error.InvalidSectionTable,
        decodeTables(allocator, &ctx, table_offset),
    );

    var section_range = try allocator.dupe(u8, bytes);
    defer allocator.free(section_range);
    const first_section_offset: usize = @intCast(headerSize() + 8);
    std.mem.writeInt(
        u64,
        section_range[first_section_offset..][0..8],
        std.math.maxInt(u64),
        .little,
    );
    std.mem.writeInt(
        u64,
        section_range[first_section_offset + 8 ..][0..8],
        1,
        .little,
    );
    try testing.expectError(
        error.InvalidSection,
        decodeTables(allocator, &ctx, section_range),
    );
}

test "bytecode reader rejects overflowing lengths" {
    var empty = SliceReader.init("");
    try std.testing.expectError(
        error.EndOfStream,
        empty.readBytes(std.math.maxInt(usize)),
    );

    const continued = [_]u8{
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
        0x80,
    };
    var unsigned_reader = SliceReader.init(&continued);
    try std.testing.expectError(
        error.InvalidLEB128,
        unsigned_reader.readULEB(),
    );
    var signed_reader = SliceReader.init(&continued);
    try std.testing.expectError(
        error.InvalidLEB128,
        signed_reader.readSLEB(),
    );
}

test "bytecode exposes format version policy" {
    const current = classifyFormatVersion(format_version);
    try std.testing.expect(current.readable());
    try std.testing.expectEqual(FormatVersionStatus.readable, current.status);
    try std.testing.expectEqual(format_version, current.version);
    try std.testing.expectEqual(minimum_readable_version, current.minimum_readable);
    try std.testing.expectEqual(maximum_readable_version, current.maximum_readable);

    const older = classifyFormatVersion(minimum_readable_version - 1);
    try std.testing.expect(!older.readable());
    try std.testing.expectEqual(FormatVersionStatus.unsupported_older, older.status);

    const newer = classifyFormatVersion(maximum_readable_version + 1);
    try std.testing.expect(!newer.readable());
    try std.testing.expectEqual(FormatVersionStatus.unsupported_newer, newer.status);
}

test "bytecode inspects and rejects unsupported versions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    var builder = TableBuilder.init(allocator);
    defer builder.deinit();

    const bytes = try encodeTables(allocator, &builder);
    defer allocator.free(bytes);

    const header = try inspectHeader(bytes);
    try testing.expectEqual(format_version, header.version);
    try testing.expect(header.compatibility().readable());

    const corrupted_future = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted_future);
    writeTestVersion(corrupted_future, maximum_readable_version + 1);
    const future_header = try inspectHeader(corrupted_future);
    try testing.expectEqual(FormatVersionStatus.unsupported_newer, future_header.compatibility().status);
    try testing.expectError(error.UnsupportedVersion, decodeTables(allocator, &ctx, corrupted_future));

    const corrupted_previous = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted_previous);
    writeTestVersion(corrupted_previous, minimum_readable_version - 1);
    const previous_header = try inspectHeader(corrupted_previous);
    try testing.expectEqual(FormatVersionStatus.unsupported_older, previous_header.compatibility().status);
    try testing.expectError(error.UnsupportedVersion, decodeTables(allocator, &ctx, corrupted_previous));

    const corrupted_old = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted_old);
    writeTestVersion(corrupted_old, 3);
    try testing.expectError(error.UnsupportedVersion, decodeTables(allocator, &ctx, corrupted_old));
}

test "bytecode ignores unknown sections" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    var builder = TableBuilder.init(allocator);
    defer builder.deinit();
    _ = try builder.internLocation(ir.Location.getUnknown());

    const strings_data = try encodeStringsSection(allocator, &builder);
    defer allocator.free(strings_data);
    const dialects_data = try encodeDialectsSection(allocator, &builder);
    defer allocator.free(dialects_data);
    const types_data = try encodeTypesSection(allocator, &builder);
    defer allocator.free(types_data);
    const attrs_data = try encodeAttributesSection(allocator, &builder);
    defer allocator.free(attrs_data);
    const locs_data = try encodeLocationsSection(allocator, &builder);
    defer allocator.free(locs_data);

    const unknown_payload = try allocator.dupe(u8, "junk");
    defer allocator.free(unknown_payload);

    const sections = [_]SectionData{
        .{ .kind = @backingInt(SectionKind.strings), .flags = 0, .data = strings_data },
        .{ .kind = @backingInt(SectionKind.dialects), .flags = 0, .data = dialects_data },
        .{ .kind = @backingInt(SectionKind.types), .flags = 0, .data = types_data },
        .{ .kind = @backingInt(SectionKind.attributes), .flags = 0, .data = attrs_data },
        .{ .kind = @backingInt(SectionKind.locations), .flags = 0, .data = locs_data },
        .{ .kind = 99, .flags = 0, .data = unknown_payload },
    };

    const bytes = try writeContainer(allocator, &sections);
    defer allocator.free(bytes);

    var tables = try decodeTables(allocator, &ctx, bytes);
    defer tables.deinit();

    try testing.expectEqual(@as(usize, 1), tables.locs.len);
}

test "bytecode module round-trip" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);
    try ctx.allowUnregistered();

    const loc = ir.Location.getUnknown();
    const argument_loc = ir.Location.getFileRange(
        "roundtrip.mlir",
        .{ .byte = 4, .line = 2, .column = 3 },
        .{ .byte = 9, .line = 2, .column = 8 },
    );
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);
    const module_region = module_op.getBody();
    const entry_block = module_op.getBodyBlock();

    const i32_type = try test_dialect.TestDialect.getI32Type(&ctx);
    _ = try entry_block.addArgument(i32_type, argument_loc);
    _ = try entry_block.addArgument(i32_type, loc);
    const arg0 = entry_block.getArgument(0).?;
    const arg1 = entry_block.getArgument(1).?;

    const answer_attr = try test_dialect.TestDialect.getIntegerAttr(&ctx, 42);
    const add_attrs = [_]ir.NamedAttribute{.{ .name = "answer", .value = answer_attr }};

    var add_state = ir.Operation.State.init("test.add", loc);
    add_state.addOperands(&.{ arg0, arg1 });
    add_state.addTypes(&.{i32_type});
    add_state.addAttributes(&add_attrs);
    const add_op = try ctx.createOperation(add_state);
    try entry_block.addOperation(add_op);

    var use_state = ir.Operation.State.init("test.use", loc);
    use_state.addOperands(&.{add_op.getResult(0).?});
    const use_op = try ctx.createOperation(use_state);
    try entry_block.addOperation(use_op);

    const second_block = try module_region.addBlock();

    var br_state = ir.Operation.State.init("test.br", loc);
    br_state.addSuccessors(&.{second_block});
    const br_op = try ctx.createOperation(br_state);
    try entry_block.addOperation(br_op);

    var nested_state = ir.Operation.State.init("test.with_region", loc);
    nested_state.addRegion();
    const nested_op = try ctx.createOperation(nested_state);
    try entry_block.addOperation(nested_op);

    const nested_region = nested_op.getRegion(0).?;
    const nested_block = try nested_region.addBlock();
    const inner_state = ir.Operation.State.init("test.inner", loc);
    const inner_op = try ctx.createOperation(inner_state);
    try nested_block.addOperation(inner_op);

    const bytes = try encodeModule(allocator, module_op.op);
    defer allocator.free(bytes);

    var decode_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer decode_ctx.deinit(allocator);
    try decode_ctx.allowUnregistered();

    var decoded = try decodeModule(allocator, &decode_ctx, bytes);
    defer decoded.deinit();

    try testing.expect(decoded.format().readable());
    try testing.expectEqual(format_version, decoded.format().version);
    const decoded_module = decoded.module;
    try testing.expectEqualStrings("test.module", decoded_module.name.name);
    try testing.expectEqual(@as(usize, 0), decoded.resources.len);

    const decoded_region = decoded_module.getRegion(0).?;
    var block_iter = decoded_region.getBlocks();
    const decoded_entry = block_iter.next() orelse return error.TestExpectedBlock;
    const decoded_second = block_iter.next() orelse return error.TestExpectedBlock;
    try testing.expect(block_iter.next() == null);

    try testing.expectEqual(@as(usize, 2), decoded_entry.getNumArguments());
    const decoded_i32 = try test_dialect.TestDialect.getI32Type(&decode_ctx);
    try testing.expect(decoded_entry.getArgument(0).?.type.eql(decoded_i32));
    try testing.expect(decoded_entry.getArgument(1).?.type.eql(decoded_i32));
    try testing.expect(decoded_entry.getArgumentLocation(0).?.eql(argument_loc));
    try testing.expect(decoded_entry.getArgumentLocation(1).?.eql(loc));

    const head_any = decoded_entry.operations.head orelse return error.TestExpectedOp;
    const op_add: *ir.Operation = @ptrCast(@alignCast(head_any));
    try testing.expectEqualStrings("test.add", op_add.name.name);

    const decoded_answer = op_add.getAttr("answer") orelse return error.TestExpectedAttr;
    const decoded_value = test_dialect.TestDialect.getIntegerValue(decoded_answer) orelse return error.TestExpectedAttr;
    try testing.expectEqual(@as(i64, 42), decoded_value);

    const op_use = op_add.next_op orelse return error.TestExpectedOp;
    try testing.expectEqualStrings("test.use", op_use.name.name);
    try testing.expect(op_use.getOperand(0).? == op_add.getResult(0).?);

    const op_br = op_use.next_op orelse return error.TestExpectedOp;
    try testing.expectEqualStrings("test.br", op_br.name.name);
    try testing.expectEqual(@as(usize, 1), op_br.getNumSuccessors());
    try testing.expect(op_br.getSuccessor(0).? == decoded_second);

    const op_nested = op_br.next_op orelse return error.TestExpectedOp;
    try testing.expectEqualStrings("test.with_region", op_nested.name.name);
    try testing.expectEqual(@as(usize, 1), op_nested.getNumRegions());

    const nested_region_dec = op_nested.getRegion(0).?;
    const nested_entry = nested_region_dec.getEntryBlock() orelse return error.TestExpectedBlock;
    const nested_head = nested_entry.operations.head orelse return error.TestExpectedOp;
    const decoded_inner: *ir.Operation = @ptrCast(@alignCast(nested_head));
    try testing.expectEqualStrings("test.inner", decoded_inner.name.name);
}

test "bytecode flat module decoder retains one top-level operation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const dialects = @import("../dialects/root.zig");

    var encode_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer encode_ctx.deinit(allocator);
    try dialects.registerChoirDialect(&encode_ctx);
    try encode_ctx.allowUnregistered();

    const loc = ir.Location.getUnknown();
    const module = try dialects.BuiltinDialect.ModuleOp.create(
        &encode_ctx,
        loc,
    );
    const int = try dialects.ArithDialect.getScalarType(&encode_ctx, .i32);
    var first_state = ir.Operation.State.init("test.first", loc);
    first_state.addTypes(&.{int});
    try module.getBodyBlock().addOperation(
        try encode_ctx.createOperation(first_state),
    );
    var second_state = ir.Operation.State.init("test.second", loc);
    second_state.addTypes(&.{int});
    try module.getBodyBlock().addOperation(
        try encode_ctx.createOperation(second_state),
    );

    const bytes = try encodeModule(allocator, module.op);
    defer allocator.free(bytes);

    var decode_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer decode_ctx.deinit(allocator);
    try dialects.registerChoirDialect(&decode_ctx);
    try decode_ctx.allowUnregistered();

    var decoded = try FlatModuleDecoder.init(
        allocator,
        &decode_ctx,
        bytes,
    );
    defer decoded.deinit();
    try testing.expectEqualStrings(
        dialects.BuiltinDialect.ModuleOp.operation_name,
        decoded.name(),
    );
    try testing.expectEqualStrings("test.first", (try decoded.next()).?.name.name);
    try testing.expectEqual(@as(usize, 1), decode_ctx.operationCount());
    try testing.expectEqualStrings("test.second", (try decoded.next()).?.name.name);
    try testing.expectEqual(@as(usize, 1), decode_ctx.operationCount());
    try testing.expect((try decoded.next()) == null);
    try testing.expectEqual(@as(usize, 0), decode_ctx.operationCount());
}

test "bytecode flat module decoder rejects cross-operation values" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const dialects = @import("../dialects/root.zig");

    var encode_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer encode_ctx.deinit(allocator);
    try dialects.registerChoirDialect(&encode_ctx);
    try encode_ctx.allowUnregistered();

    const loc = ir.Location.getUnknown();
    const module = try dialects.BuiltinDialect.ModuleOp.create(
        &encode_ctx,
        loc,
    );
    const int = try dialects.ArithDialect.getScalarType(&encode_ctx, .i32);
    var producer_state = ir.Operation.State.init("test.producer", loc);
    producer_state.addTypes(&.{int});
    const producer = try encode_ctx.createOperation(producer_state);
    try module.getBodyBlock().addOperation(producer);
    var consumer_state = ir.Operation.State.init("test.consumer", loc);
    consumer_state.addOperands(&.{producer.getResult(0).?});
    try module.getBodyBlock().addOperation(
        try encode_ctx.createOperation(consumer_state),
    );

    const bytes = try encodeModule(allocator, module.op);
    defer allocator.free(bytes);

    var decode_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer decode_ctx.deinit(allocator);
    try dialects.registerChoirDialect(&decode_ctx);
    try decode_ctx.allowUnregistered();

    var decoded = try FlatModuleDecoder.init(
        allocator,
        &decode_ctx,
        bytes,
    );
    defer decoded.deinit();
    try testing.expectEqualStrings(
        "test.producer",
        (try decoded.next()).?.name.name,
    );
    try testing.expectError(error.InvalidModule, decoded.next());
}

test "bytecode round-trips read-only properties and raw shadows" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var encode_context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer encode_context.deinit(allocator);
    try registerBytecodeProperties(&encode_context);

    const left = try encode_context.getI64Attr(11);
    const right = try encode_context.getI64Attr(22);
    const payload = try encode_context.getArrayAttr(&.{ left, right });
    const raw_left = try encode_context.getI64Attr(99);
    const note = try encode_context.getStringAttr("kept");
    const raw_attributes = [_]ir.NamedAttribute{
        .{ .name = "left", .value = raw_left },
        .{ .name = "debug.note", .value = note },
    };
    var state = ir.Operation.State.init("test.bytecode_properties", ir.Location.getUnknown());
    state.addRawAttributes(&raw_attributes);
    try state.setPropertiesAttr(payload);
    const source = try encode_context.createOperation(state);

    const encoded = try encodeModule(allocator, source);
    defer allocator.free(encoded);

    var decode_context = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer decode_context.deinit(allocator);
    try registerBytecodeProperties(&decode_context);
    var decoded = try decodeModule(allocator, &decode_context, encoded);
    defer decoded.deinit();

    const decoded_left = decoded.module.getAttr("left") orelse return error.TestExpectedAttr;
    const decoded_right = decoded.module.getAttr("right") orelse return error.TestExpectedAttr;
    try testing.expectEqual(@as(i64, 11), decoded_left.cast(ir.Attribute.IntegerAttr).?.value);
    try testing.expectEqual(@as(i64, 22), decoded_right.cast(ir.Attribute.IntegerAttr).?.value);
    try testing.expectEqual(@as(usize, 2), decoded.module.getRawDictionaryAttrs().len);
    try testing.expectEqual(
        @as(i64, 99),
        decoded.module.raw_dictionary_attrs.get("left").?.cast(ir.Attribute.IntegerAttr).?.value,
    );
    try testing.expectEqualStrings(
        "kept",
        decoded.module.getAttrAs(ir.Attribute.StringAttr, "debug.note").?.value,
    );

    const reencoded = try encodeModule(allocator, decoded.module);
    defer allocator.free(reencoded);
    try testing.expectEqualSlices(u8, encoded, reencoded);
}

test "bytecode module round-trips resources" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const test_dialect = @import("../dialects/fixture/root.zig");

    var ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer ctx.deinit(allocator);

    const loc = ir.Location.getUnknown();
    const module_op = try test_dialect.TestDialect.ModuleOp.create(&ctx, loc);

    const resources = [_]Resource{
        .{
            .namespace = "choir.artifact",
            .name = "manifest",
            .type_id = "choir.backends.artifact.Manifest/v1",
            .data = "{\"target\":\"x86_64\"}",
        },
        .{
            .namespace = "accy.artifact",
            .name = "kernel-metadata",
            .type_id = "accy.cuda.KernelMetadata/v1",
            .data = "entry=add_f32",
        },
    };

    const bytes = try encodeModuleWithResources(allocator, module_op.op, &resources);
    defer allocator.free(bytes);

    var decode_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer decode_ctx.deinit(allocator);
    try test_dialect.registerTestDialect(&decode_ctx);

    var decoded = try decodeModule(allocator, &decode_ctx, bytes);
    defer decoded.deinit();

    try testing.expectEqualStrings("test.module", decoded.module.name.name);
    try testing.expectEqual(resources.len, decoded.resources.len);
    for (resources, decoded.resources) |expected, actual| {
        try testing.expectEqualStrings(expected.namespace, actual.namespace);
        try testing.expectEqualStrings(expected.name, actual.name);
        try testing.expectEqualStrings(expected.type_id, actual.type_id);
        try testing.expectEqualStrings(expected.data, actual.data);
    }
}

test "bytecode round-trips undotted dialect type names" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const arith = @import("../dialects/root.zig").ArithDialect;
    const root_dialects = @import("../dialects/root.zig");
    const MemrefDialect = root_dialects.MemrefDialect;
    const interfaces = ir.interfaces;

    var enc_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer enc_ctx.deinit(allocator);
    try root_dialects.registerChoirDialect(&enc_ctx);

    const f32_type = try arith.getScalarType(&enc_ctx, .f32);
    const memref_type = try MemrefDialect.getMemrefType1D(&enc_ctx, 1024, f32_type, .host);

    var builder = TableBuilder.init(allocator);
    defer builder.deinit();
    _ = try builder.internType(memref_type);

    const bytes = try encodeTables(allocator, &builder);
    defer allocator.free(bytes);

    var dec_ctx = try ir.Context.init(allocator, ir.Context.Limits.testing);
    defer dec_ctx.deinit(allocator);
    try dec_ctx.requireRegistered();
    try root_dialects.registerChoirDialect(&dec_ctx);

    var tables = try decodeTables(allocator, &dec_ctx, bytes);
    defer tables.deinit();

    try testing.expectEqual(@as(usize, 1), tables.types.len);
    const decoded = tables.types[0];

    const storage = decoded.getDialectStorage() orelse return error.TestExpectedDialectStorage;
    try testing.expectEqualStrings("memref", storage.name);
    try testing.expectEqualStrings("1024,arith.f32,host", storage.param_key);

    try testing.expect((try dec_ctx.getTypeParamPayload(decoded, MemrefDialect.MemrefTypePayload)) != null);
    try testing.expect(dec_ctx.typeInterface(decoded, interfaces.ShapedTypeInterface) != null);

    try testing.expect(hasDialect(tables.dialects, "memref"));
}

fn hasType(types: []const ir.Type, needle: ir.Type) bool {
    for (types) |item| {
        if (item.eql(needle)) return true;
    }
    return false;
}

fn writeTestVersion(bytes: []u8, version: u32) void {
    std.mem.writeInt(u32, bytes[magic.len..][0..4], version, .little);
}

fn hasDialect(dialects: []const DialectEntry, needle: []const u8) bool {
    for (dialects) |item| {
        if (std.mem.eql(u8, item.name, needle)) return true;
    }
    return false;
}

fn hasAttr(attrs: []const ir.Attribute, needle: ir.Attribute) bool {
    for (attrs) |item| {
        if (attrEqual(item, needle)) return true;
    }
    return false;
}

fn hasLocation(locs: []const ir.Location, needle: ir.Location) bool {
    for (locs) |item| {
        if (locationEqual(item, needle)) return true;
    }
    return false;
}
