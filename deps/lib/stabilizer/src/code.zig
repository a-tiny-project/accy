const std = @import("std");

const config = @import("config.zig");
const Marsaglia = @import("rng.zig").Marsaglia;

const Allocator = std.mem.Allocator;
const CodeConfig = config.CodeConfig;

pub const FunctionId = u32;
pub const LocationId = u32;

pub const FunctionOptions = struct {
    code_size: usize,
    table_size: usize = 0,
    table_adjacent: bool = false,
    stack_pad_unit: ?u8 = null,
};

pub const FunctionImageOptions = struct {
    code: []const u8,
    table: []const u8 = &.{},
    table_adjacent: bool = false,
    stack_pad_unit: ?u8 = null,
    stack_pad_table_offsets: []const usize = &.{},
};

pub const FunctionRangeOptions = struct {
    code_base: [*]const u8,
    code_limit: [*]const u8,
    table_base: ?[*]const u8 = null,
    table_size: usize = 0,
    table_adjacent: bool = false,
    stack_pad: ?*const u8 = null,
};

pub const FunctionEntryState = enum {
    trap,
    forwarding,
};

pub const FunctionStackPad = struct {
    unit: u8,
    bytes: usize,
};

pub const FunctionLocation = struct {
    id: LocationId,
    function: FunctionId,
    base: usize,
    size: usize,
    contents: []u8 = &.{},
    defunct: bool = false,
    marked: bool = false,
};

const FunctionImage = struct {
    code: []u8,
    table: []u8,
    stack_pad_table_offsets: []usize,
    stack_pad_address: ?usize,
    table_adjacent: bool,

    fn deinit(self: *FunctionImage, allocator: Allocator) void {
        if (self.code.len > 0) allocator.free(self.code);
        if (self.table.len > 0) allocator.free(self.table);
        if (self.stack_pad_table_offsets.len > 0) allocator.free(self.stack_pad_table_offsets);
        self.* = undefined;
    }
};

const CodeFunction = struct {
    id: FunctionId,
    options: FunctionOptions,
    image: ?FunctionImage = null,
    entry: FunctionEntryState = .trap,
    stack_pad_unit: ?u8 = null,
    current: ?LocationId = null,
    original_base: usize,
};

pub const CodeRandomizer = struct {
    allocator: Allocator,
    config: CodeConfig,
    rng: Marsaglia,
    functions: std.ArrayListUnmanaged(CodeFunction) = .empty,
    locations: std.ArrayListUnmanaged(FunctionLocation) = .empty,
    live: std.ArrayListUnmanaged(FunctionId) = .empty,
    next_function_id: FunctionId = 1,
    next_location_id: LocationId = 1,
    next_original_base: usize = 0x0800_0000,
    next_base: usize = 0x1000_0000,
    next_stack_pad_address: usize = 0x3000_0000,
    rerandomizing: bool = false,

    pub fn init(allocator: Allocator, code_config: CodeConfig, seed: u64) CodeRandomizer {
        return .{
            .allocator = allocator,
            .config = normalizeCodeConfig(code_config),
            .rng = Marsaglia.init(seed),
        };
    }

    pub fn deinit(self: *CodeRandomizer) void {
        for (self.functions.items) |*function| {
            if (function.image) |*image| image.deinit(self.allocator);
        }
        for (self.locations.items) |location| self.destroyLocation(location);
        self.functions.deinit(self.allocator);
        self.locations.deinit(self.allocator);
        self.live.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn registerFunction(self: *CodeRandomizer, options: FunctionOptions) !FunctionId {
        if (!self.config.enabled) return error.CodeRandomizationDisabled;
        const normalized = normalizeFunctionOptions(options);
        const id = self.next_function_id;
        self.next_function_id += 1;
        errdefer self.next_function_id -= 1;
        const previous_original_base = self.next_original_base;
        const original_base = self.allocateOriginalBase(normalized.code_size);
        errdefer self.next_original_base = previous_original_base;
        try self.functions.append(self.allocator, .{
            .id = id,
            .options = normalized,
            .stack_pad_unit = normalized.stack_pad_unit,
            .original_base = original_base,
        });
        return id;
    }

    pub fn registerFunctionImage(self: *CodeRandomizer, image_options: FunctionImageOptions) !FunctionId {
        if (!self.config.enabled) return error.CodeRandomizationDisabled;
        if (image_options.code.len == 0) return error.EmptyFunctionImage;
        for (image_options.stack_pad_table_offsets) |offset| {
            if (offset % @sizeOf(usize) != 0) return error.InvalidStackPadTableOffset;
            if (offset > image_options.table.len or image_options.table.len - offset < @sizeOf(usize)) {
                return error.InvalidStackPadTableOffset;
            }
        }

        const code = try self.allocator.dupe(u8, image_options.code);
        errdefer self.allocator.free(code);
        const table = try self.allocator.dupe(u8, image_options.table);
        errdefer self.allocator.free(table);
        const stack_pad_table_offsets = try self.allocator.dupe(usize, image_options.stack_pad_table_offsets);
        errdefer self.allocator.free(stack_pad_table_offsets);

        const id = self.next_function_id;
        self.next_function_id += 1;
        errdefer self.next_function_id -= 1;
        const previous_original_base = self.next_original_base;
        const original_base = self.allocateOriginalBase(image_options.code.len);
        errdefer self.next_original_base = previous_original_base;
        try self.functions.append(self.allocator, .{
            .id = id,
            .options = .{
                .code_size = image_options.code.len,
                .table_size = image_options.table.len,
                .table_adjacent = image_options.table_adjacent,
                .stack_pad_unit = image_options.stack_pad_unit,
            },
            .image = .{
                .code = code,
                .table = table,
                .stack_pad_table_offsets = stack_pad_table_offsets,
                .stack_pad_address = null,
                .table_adjacent = image_options.table_adjacent,
            },
            .stack_pad_unit = image_options.stack_pad_unit,
            .original_base = original_base,
        });
        return id;
    }

    pub fn registerFunctionRange(self: *CodeRandomizer, range_options: FunctionRangeOptions) !FunctionId {
        if (!self.config.enabled) return error.CodeRandomizationDisabled;
        const code_start = @intFromPtr(range_options.code_base);
        const code_end = @intFromPtr(range_options.code_limit);
        if (code_end <= code_start) return error.InvalidFunctionRange;
        const code_bytes = range_options.code_base[0 .. code_end - code_start];
        const table_bytes = if (range_options.table_size == 0)
            &.{}
        else if (range_options.table_base) |table_base|
            table_base[0..range_options.table_size]
        else
            return error.InvalidFunctionTableRange;

        var stack_pad_table_offsets: std.ArrayListUnmanaged(usize) = .empty;
        defer stack_pad_table_offsets.deinit(self.allocator);
        const stack_pad_unit = if (range_options.stack_pad) |stack_pad| blk: {
            try collectStackPadTableOffsets(
                self.allocator,
                table_bytes,
                @intFromPtr(stack_pad),
                &stack_pad_table_offsets,
            );
            break :blk stack_pad.*;
        } else null;

        return self.registerFunctionImage(.{
            .code = code_bytes,
            .table = table_bytes,
            .table_adjacent = range_options.table_adjacent,
            .stack_pad_unit = stack_pad_unit,
            .stack_pad_table_offsets = stack_pad_table_offsets.items,
        });
    }

    pub fn allocationSize(self: *const CodeRandomizer, id: FunctionId) ?usize {
        const function = self.findFunctionConst(id) orelse return null;
        return functionAllocationSize(function.options);
    }

    pub fn entryState(self: *const CodeRandomizer, id: FunctionId) ?FunctionEntryState {
        const function = self.findFunctionConst(id) orelse return null;
        return function.entry;
    }

    pub fn functionCount(self: *const CodeRandomizer) usize {
        return self.functions.items.len;
    }

    pub fn stackPadUnit(self: *const CodeRandomizer, id: FunctionId) ?u8 {
        const function = self.findFunctionConst(id) orelse return null;
        return function.stack_pad_unit;
    }

    pub fn stackPad(self: *const CodeRandomizer, id: FunctionId) ?FunctionStackPad {
        const unit = self.stackPadUnit(id) orelse return null;
        return .{
            .unit = unit,
            .bytes = @as(usize, unit) * config.stack_alignment,
        };
    }

    pub fn stackPadAddress(self: *const CodeRandomizer, id: FunctionId) ?usize {
        const function = self.findFunctionConst(id) orelse return null;
        const image = function.image orelse return null;
        return image.stack_pad_address;
    }

    pub fn originalBase(self: *const CodeRandomizer, id: FunctionId) ?usize {
        const function = self.findFunctionConst(id) orelse return null;
        return function.original_base;
    }

    pub fn adjustAddress(self: *const CodeRandomizer, address: usize) usize {
        for (self.locations.items) |location| {
            if (address >= location.base and address < location.base + location.size) {
                const function = self.findFunctionConst(location.function) orelse return address;
                return function.original_base + (address - location.base);
            }
        }
        return address;
    }

    pub fn enterFunction(self: *CodeRandomizer, id: FunctionId, roots: []const usize) !?*FunctionLocation {
        const function = self.findFunction(id) orelse return error.UnknownFunction;
        return switch (function.entry) {
            .trap => try self.trap(id, roots),
            .forwarding => self.currentLocation(id),
        };
    }

    pub fn relocate(self: *CodeRandomizer, id: FunctionId) !*FunctionLocation {
        if (!self.config.enabled) return error.CodeRandomizationDisabled;
        const function = self.findFunction(id) orelse return error.UnknownFunction;
        const old_current = function.current;
        const allocation_size = functionAllocationSize(function.options);
        var contents = try self.copyFunctionContents(function, allocation_size);
        errdefer if (contents.len > 0) self.allocator.free(contents);
        const base = self.allocateCodeBase(allocation_size);
        const location_id = self.next_location_id;
        self.next_location_id += 1;
        var location_id_committed = false;
        errdefer {
            if (!location_id_committed) self.next_location_id -= 1;
        }
        try self.locations.append(self.allocator, .{
            .id = location_id,
            .function = id,
            .base = base,
            .size = allocation_size,
            .contents = contents,
        });
        contents = &.{};
        location_id_committed = true;
        if (old_current) |current_id| {
            if (self.findLocation(current_id)) |location| location.defunct = true;
        }
        function.current = location_id;
        function.entry = .forwarding;
        if (function.stack_pad_unit != null) {
            function.stack_pad_unit = self.rng.nextByte();
        }
        try self.markLive(id);
        return &self.locations.items[self.locations.items.len - 1];
    }

    pub fn beginRerandomization(self: *CodeRandomizer) void {
        _ = self.beginRerandomizationAt(0);
    }

    pub fn trapRegisteredFunctions(self: *CodeRandomizer) void {
        if (!self.config.enabled) return;
        for (self.functions.items) |*function| {
            function.entry = .trap;
        }
        self.live.clearRetainingCapacity();
        self.rerandomizing = false;
    }

    pub fn beginRerandomizationAt(self: *CodeRandomizer, instruction_pointer: usize) usize {
        var forwarded_instruction_pointer = instruction_pointer;
        if (!self.config.enabled) return forwarded_instruction_pointer;
        for (self.live.items) |id| {
            if (self.findFunction(id)) |function| {
                if (forwarded_instruction_pointer == function.original_base) {
                    if (function.current) |location_id| {
                        if (self.findLocation(location_id)) |location| {
                            forwarded_instruction_pointer = location.base;
                        }
                    }
                }
                function.entry = .trap;
            }
        }
        self.live.clearRetainingCapacity();
        self.rerandomizing = true;
        return forwarded_instruction_pointer;
    }

    pub fn trap(self: *CodeRandomizer, id: FunctionId, roots: []const usize) !*FunctionLocation {
        if (!self.config.enabled) return error.CodeRandomizationDisabled;
        if (self.rerandomizing) {
            for (roots) |root| self.markAddress(root);
            self.sweep();
            self.rerandomizing = false;
        }
        return self.relocate(id);
    }

    pub fn markAddress(self: *CodeRandomizer, address: usize) void {
        if (!self.config.enabled) return;
        for (self.locations.items) |*location| {
            if (address >= location.base and address < location.base + location.size) {
                location.marked = true;
            }
        }
    }

    pub fn sweep(self: *CodeRandomizer) void {
        if (!self.config.enabled) return;
        var index: usize = 0;
        while (index < self.locations.items.len) {
            const location = &self.locations.items[index];
            if (location.defunct and !location.marked) {
                self.destroyLocation(location.*);
                _ = self.locations.swapRemove(index);
            } else {
                location.marked = false;
                index += 1;
            }
        }
    }

    pub fn currentLocation(self: *CodeRandomizer, id: FunctionId) ?*FunctionLocation {
        const function = self.findFunction(id) orelse return null;
        const location_id = function.current orelse return null;
        return self.findLocation(location_id);
    }

    pub fn locationCount(self: *const CodeRandomizer) usize {
        return self.locations.items.len;
    }

    fn allocateCodeBase(self: *CodeRandomizer, size: usize) usize {
        const jitter = self.rng.bounded(self.config.shuffle_slots) * self.config.alignment;
        const base = std.mem.alignForward(usize, self.next_base + jitter, self.config.alignment);
        self.next_base = base + std.mem.alignForward(usize, size, self.config.alignment) + self.config.alignment;
        return base;
    }

    fn allocateOriginalBase(self: *CodeRandomizer, size: usize) usize {
        const base = std.mem.alignForward(usize, self.next_original_base, self.config.alignment);
        self.next_original_base = base + std.mem.alignForward(usize, size, self.config.alignment) + self.config.alignment;
        return base;
    }

    fn copyFunctionContents(self: *CodeRandomizer, function: *CodeFunction, allocation_size: usize) ![]u8 {
        const image = if (function.image) |*image| image else return &.{};
        const contents = try self.allocator.alloc(u8, allocation_size);
        errdefer self.allocator.free(contents);
        @memset(contents, 0);

        if (function.current) |current_id| {
            if (self.findLocation(current_id)) |location| {
                if (location.contents.len > 0) {
                    const copy_len = @min(contents.len, location.contents.len);
                    @memcpy(contents[0..copy_len], location.contents[0..copy_len]);
                    return contents;
                }
            }
        }

        self.patchStackPadTable(function, image);
        @memcpy(contents[0..image.code.len], image.code);
        if (image.table_adjacent and image.table.len > 0) {
            @memcpy(contents[image.code.len..][0..image.table.len], image.table);
        }
        return contents;
    }

    fn destroyLocation(self: *CodeRandomizer, location: FunctionLocation) void {
        if (location.contents.len > 0) self.allocator.free(location.contents);
    }

    fn patchStackPadTable(self: *CodeRandomizer, function: *CodeFunction, image: *FunctionImage) void {
        if (function.stack_pad_unit == null or image.stack_pad_table_offsets.len == 0) return;
        if (image.stack_pad_address == null) {
            image.stack_pad_address = self.allocateStackPadAddress();
        }
        const address = image.stack_pad_address.?;
        for (image.stack_pad_table_offsets) |offset| {
            std.mem.writeInt(usize, image.table[offset..][0..@sizeOf(usize)], address, .little);
        }
    }

    fn allocateStackPadAddress(self: *CodeRandomizer) usize {
        const address = self.next_stack_pad_address;
        self.next_stack_pad_address += @sizeOf(usize);
        return address;
    }

    fn markLive(self: *CodeRandomizer, id: FunctionId) !void {
        for (self.live.items) |live_id| if (live_id == id) return;
        try self.live.append(self.allocator, id);
    }

    fn findFunction(self: *CodeRandomizer, id: FunctionId) ?*CodeFunction {
        for (self.functions.items) |*function| if (function.id == id) return function;
        return null;
    }

    fn findFunctionConst(self: *const CodeRandomizer, id: FunctionId) ?*const CodeFunction {
        for (self.functions.items) |*function| if (function.id == id) return function;
        return null;
    }

    fn findLocation(self: *CodeRandomizer, id: LocationId) ?*FunctionLocation {
        for (self.locations.items) |*location| if (location.id == id) return location;
        return null;
    }
};

fn normalizeCodeConfig(code_config: CodeConfig) CodeConfig {
    var out = code_config;
    if (out.shuffle_slots == 0) out.shuffle_slots = 1;
    if (out.alignment == 0) out.alignment = config.code_alignment;
    out.alignment = std.math.ceilPowerOfTwoAssert(usize, out.alignment);
    if (out.interval_ms == 0) out.interval_ms = config.rerandomize_interval_ms;
    return out;
}

fn normalizeFunctionOptions(options: FunctionOptions) FunctionOptions {
    var out = options;
    if (out.code_size == 0) out.code_size = 1;
    return out;
}

fn functionAllocationSize(options: FunctionOptions) usize {
    return if (options.table_adjacent) options.code_size + options.table_size else options.code_size;
}

fn collectStackPadTableOffsets(
    allocator: Allocator,
    table: []const u8,
    stack_pad_address: usize,
    offsets: *std.ArrayListUnmanaged(usize),
) !void {
    var offset: usize = 0;
    while (offset + @sizeOf(usize) <= table.len) : (offset += @sizeOf(usize)) {
        const value = std.mem.readInt(usize, table[offset..][0..@sizeOf(usize)], .little);
        if (value == stack_pad_address) try offsets.append(allocator, offset);
    }
}

test "code randomizer registers upstream function ranges" {
    var code = CodeRandomizer.init(std.testing.allocator, .{ .shuffle_slots = 4 }, 55);
    defer code.deinit();

    const image = [_]u8{ 0xaa, 0xbb, 0xcc };
    var stack_pad: u8 = 7;
    const stack_pad_address = @intFromPtr(&stack_pad);
    var table = @as([(@sizeOf(usize) * 3)]u8, @splat(0));
    std.mem.writeInt(usize, table[0..@sizeOf(usize)], 0x1111, .little);
    std.mem.writeInt(usize, table[@sizeOf(usize)..][0..@sizeOf(usize)], stack_pad_address, .little);
    std.mem.writeInt(usize, table[@sizeOf(usize) * 2 ..][0..@sizeOf(usize)], stack_pad_address, .little);

    const function = try code.registerFunctionRange(.{
        .code_base = image[0..].ptr,
        .code_limit = image[0..].ptr + image.len,
        .table_base = table[0..].ptr,
        .table_size = table.len,
        .table_adjacent = true,
        .stack_pad = &stack_pad,
    });
    try std.testing.expectEqual(@as(u8, 7), code.stackPadUnit(function).?);

    const location = try code.relocate(function);
    const relocated_stack_pad_address = code.stackPadAddress(function).?;
    try std.testing.expectEqualSlices(u8, &image, location.contents[0..image.len]);
    try std.testing.expectEqual(@as(usize, 0x1111), std.mem.readInt(
        usize,
        location.contents[image.len..][0..@sizeOf(usize)],
        .little,
    ));
    try std.testing.expectEqual(relocated_stack_pad_address, std.mem.readInt(
        usize,
        location.contents[image.len + @sizeOf(usize) ..][0..@sizeOf(usize)],
        .little,
    ));
    try std.testing.expectEqual(relocated_stack_pad_address, std.mem.readInt(
        usize,
        location.contents[image.len + @sizeOf(usize) * 2 ..][0..@sizeOf(usize)],
        .little,
    ));
}

test "code randomizer rejects invalid function ranges" {
    var code = CodeRandomizer.init(std.testing.allocator, .{ .shuffle_slots = 4 }, 55);
    defer code.deinit();

    const image = [_]u8{0xaa};
    try std.testing.expectError(error.InvalidFunctionRange, code.registerFunctionRange(.{
        .code_base = image[0..].ptr,
        .code_limit = image[0..].ptr,
    }));
    try std.testing.expectError(error.InvalidFunctionTableRange, code.registerFunctionRange(.{
        .code_base = image[0..].ptr,
        .code_limit = image[0..].ptr + image.len,
        .table_size = @sizeOf(usize),
    }));
}
