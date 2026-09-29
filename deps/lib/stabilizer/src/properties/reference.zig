const std = @import("std");
const hypothesis = @import("hypothesis");
const stabilizer = @import("stabilizer");

const Allocator = std.mem.Allocator;

const code_alignment = stabilizer.code_alignment;
const stack_alignment = stabilizer.stack_alignment;
const max_stack_pad_unit = stabilizer.max_stack_pad_unit;

const FunctionId = stabilizer.FunctionId;
const LocationId = stabilizer.LocationId;
const FunctionOptions = stabilizer.FunctionOptions;
const FunctionEntryState = stabilizer.FunctionEntryState;
const FunctionLocation = stabilizer.FunctionLocation;
const CodeRandomizer = stabilizer.CodeRandomizer;

fn settings() hypothesis.Settings {
    return hypothesis.Settings.quick()
        .withSeed(0x57ab_11e5)
        .withDatabase("zig-out/hypothesis-failures/stabilizer");
}

fn drawUsize(data: *hypothesis.ConjectureData, min: usize, max: usize, shrink_towards: usize) !usize {
    return @intCast(try data.drawInteger(
        @intCast(min),
        @intCast(max),
        @intCast(shrink_towards),
    ));
}

const ReferenceFunction = struct {
    id: FunctionId,
    options: FunctionOptions,
    entry: FunctionEntryState = .trap,
    stack_pad_unit: ?u8 = null,
    current: ?LocationId = null,
    original_base: usize,
};

const ReferenceCodeModel = struct {
    allocator: Allocator,
    functions: std.ArrayListUnmanaged(ReferenceFunction) = .empty,
    locations: std.ArrayListUnmanaged(FunctionLocation) = .empty,
    live: std.ArrayListUnmanaged(FunctionId) = .empty,
    next_function_id: FunctionId = 1,
    next_location_id: LocationId = 1,
    next_original_base: usize = 0x0800_0000,
    next_base: usize = 0x2000_0000,
    next_stack_pad_unit: u8 = 0,
    rerandomizing: bool = false,

    fn init(allocator: Allocator) ReferenceCodeModel {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ReferenceCodeModel) void {
        self.functions.deinit(self.allocator);
        self.locations.deinit(self.allocator);
        self.live.deinit(self.allocator);
        self.* = undefined;
    }

    fn registerFunction(self: *ReferenceCodeModel, options: FunctionOptions) !FunctionId {
        const normalized = normalizeReferenceFunctionOptions(options);
        const id = self.next_function_id;
        self.next_function_id += 1;
        errdefer self.next_function_id -= 1;
        const previous_original_base = self.next_original_base;
        const original_base = self.allocateOriginalBase(normalized.code_size);
        errdefer self.next_original_base = previous_original_base;
        try self.functions.append(self.allocator, .{
            .id = id,
            .options = normalized,
            .stack_pad_unit = options.stack_pad_unit,
            .original_base = original_base,
        });
        return id;
    }

    fn relocate(self: *ReferenceCodeModel, id: FunctionId) !void {
        const function = self.findFunction(id) orelse return error.UnknownFunction;
        if (function.current) |current_id| {
            if (self.findLocation(current_id)) |location| location.defunct = true;
        }
        const allocation_size = referenceFunctionAllocationSize(function.options);
        const location_id = self.next_location_id;
        self.next_location_id += 1;
        try self.locations.append(self.allocator, .{
            .id = location_id,
            .function = id,
            .base = self.next_base,
            .size = allocation_size,
        });
        self.next_base += allocation_size + code_alignment;
        function.current = location_id;
        function.entry = .forwarding;
        if (function.stack_pad_unit != null) {
            function.stack_pad_unit = self.nextStackPadUnit();
        }
        try self.markLive(id);
    }

    fn beginRerandomizationAt(self: *ReferenceCodeModel, instruction_pointer: usize) usize {
        var forwarded_instruction_pointer = instruction_pointer;
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

    fn enterFunction(self: *ReferenceCodeModel, id: FunctionId, roots: []const usize) !?*FunctionLocation {
        const function = self.findFunction(id) orelse return error.UnknownFunction;
        return switch (function.entry) {
            .trap => {
                try self.trap(id, roots);
                return self.currentLocation(id);
            },
            .forwarding => self.currentLocation(id),
        };
    }

    fn trap(self: *ReferenceCodeModel, id: FunctionId, roots: []const usize) !void {
        if (self.rerandomizing) {
            for (roots) |root| self.markAddress(root);
            self.sweep();
            self.rerandomizing = false;
        }
        try self.relocate(id);
    }

    fn markAddress(self: *ReferenceCodeModel, address: usize) void {
        for (self.locations.items) |*location| {
            if (address >= location.base and address < location.base + location.size) {
                location.marked = true;
            }
        }
    }

    fn sweep(self: *ReferenceCodeModel) void {
        var index: usize = 0;
        while (index < self.locations.items.len) {
            const location = &self.locations.items[index];
            if (location.defunct and !location.marked) {
                _ = self.locations.swapRemove(index);
            } else {
                location.marked = false;
                index += 1;
            }
        }
    }

    fn adjustAddress(self: *ReferenceCodeModel, address: usize) usize {
        for (self.locations.items) |location| {
            if (address >= location.base and address < location.base + location.size) {
                const function = self.findFunction(location.function) orelse return address;
                return function.original_base + (address - location.base);
            }
        }
        return address;
    }

    fn currentLocation(self: *ReferenceCodeModel, id: FunctionId) ?*FunctionLocation {
        const function = self.findFunction(id) orelse return null;
        const current = function.current orelse return null;
        return self.findLocation(current);
    }

    fn markLive(self: *ReferenceCodeModel, id: FunctionId) !void {
        for (self.live.items) |live_id| if (live_id == id) return;
        try self.live.append(self.allocator, id);
    }

    fn nextStackPadUnit(self: *ReferenceCodeModel) u8 {
        const out = self.next_stack_pad_unit;
        self.next_stack_pad_unit +%= 1;
        return out;
    }

    fn allocateOriginalBase(self: *ReferenceCodeModel, size: usize) usize {
        const base = std.mem.alignForward(usize, self.next_original_base, code_alignment);
        self.next_original_base = base + std.mem.alignForward(usize, size, code_alignment) + code_alignment;
        return base;
    }

    fn findFunction(self: *ReferenceCodeModel, id: FunctionId) ?*ReferenceFunction {
        for (self.functions.items) |*function| if (function.id == id) return function;
        return null;
    }

    fn findLocation(self: *ReferenceCodeModel, id: LocationId) ?*FunctionLocation {
        for (self.locations.items) |*location| if (location.id == id) return location;
        return null;
    }
};

const CodeReferenceProperty = struct {
    pub fn property(data: *hypothesis.ConjectureData, allocator: Allocator) !void {
        var code = CodeRandomizer.init(allocator, .{
            .shuffle_slots = 16,
            .alignment = code_alignment,
        }, 0x5245_4643);
        defer code.deinit();
        var reference = ReferenceCodeModel.init(allocator);
        defer reference.deinit();

        const functions = try drawUsize(data, 1, 8, 2);
        var ids: [8]FunctionId = undefined;
        var index: usize = 0;
        while (index < functions) : (index += 1) {
            const options: FunctionOptions = .{
                .code_size = try drawUsize(data, 1, 512, 64),
                .table_size = try drawUsize(data, 0, 128, 0),
                .table_adjacent = try data.drawBoolean(),
                .stack_pad_unit = if (try data.drawBoolean())
                    @truncate(try drawUsize(data, 0, max_stack_pad_unit, 0))
                else
                    null,
            };
            ids[index] = try code.registerFunction(options);
            try std.testing.expectEqual(ids[index], try reference.registerFunction(options));
        }
        try expectCodeMatchesReference(&code, &reference, ids[0..functions]);

        const steps = try drawUsize(data, 1, 96, 8);
        index = 0;
        while (index < steps) : (index += 1) {
            const operation = try drawUsize(data, 0, 2, 1);
            if (operation == 0) {
                const mode = try drawUsize(data, 0, 2, 0);
                if (mode == 0 and reference.live.items.len > 0) {
                    const live_index = try drawUsize(data, 0, reference.live.items.len - 1, 0);
                    const id = reference.live.items[live_index];
                    const code_ip = code.originalBase(id).?;
                    const reference_ip = reference.findFunction(id).?.original_base;
                    const code_forwarded = code.beginRerandomizationAt(code_ip);
                    const reference_forwarded = reference.beginRerandomizationAt(reference_ip);
                    try std.testing.expectEqual(code.currentLocation(id).?.base, code_forwarded);
                    try std.testing.expectEqual(reference.currentLocation(id).?.base, reference_forwarded);
                    try std.testing.expectEqual(code_ip, code.adjustAddress(code_forwarded));
                    try std.testing.expectEqual(reference_ip, reference.adjustAddress(reference_forwarded));
                } else {
                    const id = ids[try drawUsize(data, 0, functions - 1, 0)];
                    const ip = if (mode == 1) code.originalBase(id).? + 1 else 0x7000_0000 + index;
                    try std.testing.expectEqual(ip, code.beginRerandomizationAt(ip));
                    try std.testing.expectEqual(ip, reference.beginRerandomizationAt(ip));
                }
            } else {
                const id = ids[try drawUsize(data, 0, functions - 1, 0)];
                if (operation == 1) {
                    _ = try code.relocate(id);
                    try reference.relocate(id);
                } else {
                    var code_roots_buf: [3]usize = undefined;
                    var reference_roots_buf: [3]usize = undefined;
                    const roots_len = try drawLocationRoots(
                        data,
                        &code,
                        &reference,
                        &code_roots_buf,
                        &reference_roots_buf,
                    );
                    _ = try code.enterFunction(id, code_roots_buf[0..roots_len]);
                    _ = try reference.enterFunction(id, reference_roots_buf[0..roots_len]);
                }
            }
            try expectCodeMatchesReference(&code, &reference, ids[0..functions]);
        }
    }
};

fn normalizeReferenceFunctionOptions(options: FunctionOptions) FunctionOptions {
    var out = options;
    if (out.code_size == 0) out.code_size = 1;
    return out;
}

fn referenceFunctionAllocationSize(options: FunctionOptions) usize {
    return if (options.table_adjacent) options.code_size + options.table_size else options.code_size;
}

fn drawLocationRoots(
    data: *hypothesis.ConjectureData,
    code: *CodeRandomizer,
    reference: *ReferenceCodeModel,
    code_roots: []usize,
    reference_roots: []usize,
) !usize {
    if (code.next_location_id <= 1) return 0;

    const limit = try drawUsize(data, 0, code_roots.len, 0);
    var count: usize = 0;
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        const location_id: LocationId = @intCast(try drawUsize(data, 1, code.next_location_id - 1, 1));
        const code_location = codeLocation(code, location_id) orelse continue;
        const reference_location = reference.findLocation(location_id) orelse return error.ReferenceMismatch;
        const offset = try drawUsize(data, 0, @min(code_location.size, reference_location.size) - 1, 0);
        code_roots[count] = code_location.base + offset;
        reference_roots[count] = reference_location.base + offset;
        count += 1;
    }
    return count;
}

fn expectCodeMatchesReference(code: *CodeRandomizer, reference: *ReferenceCodeModel, ids: []const FunctionId) !void {
    try std.testing.expectEqual(reference.locations.items.len, code.locationCount());
    try std.testing.expectEqual(reference.rerandomizing, code.rerandomizing);
    try std.testing.expectEqual(reference.next_function_id, code.next_function_id);
    try std.testing.expectEqual(reference.next_location_id, code.next_location_id);
    try std.testing.expectEqual(reference.next_original_base, code.next_original_base);
    try std.testing.expectEqual(reference.live.items.len, code.live.items.len);
    for (reference.live.items, 0..) |id, index| {
        try std.testing.expectEqual(id, code.live.items[index]);
    }

    var reference_defunct: usize = 0;
    for (reference.locations.items) |location| {
        if (location.defunct) reference_defunct += 1;
    }
    var code_defunct: usize = 0;
    for (code.locations.items) |location| {
        if (location.defunct) code_defunct += 1;
    }
    try std.testing.expectEqual(reference_defunct, code_defunct);

    for (reference.locations.items) |expected| {
        const actual = codeLocation(code, expected.id) orelse return error.ReferenceMismatch;
        try std.testing.expectEqual(expected.function, actual.function);
        try std.testing.expectEqual(expected.size, actual.size);
        try std.testing.expectEqual(expected.defunct, actual.defunct);
        try std.testing.expectEqual(expected.marked, actual.marked);
        const offset = if (expected.size == 0) 0 else expected.size / 2;
        try std.testing.expectEqual(
            reference.adjustAddress(expected.base + offset),
            code.adjustAddress(actual.base + offset),
        );
    }

    for (ids) |id| {
        const reference_function = reference.findFunction(id).?;
        try std.testing.expectEqual(reference_function.entry, code.entryState(id).?);
        try std.testing.expectEqual(reference_function.original_base, code.originalBase(id).?);
        try std.testing.expectEqual(reference_function.stack_pad_unit != null, code.stackPadUnit(id) != null);
        if (code.stackPad(id)) |pad| {
            try std.testing.expectEqual(@as(usize, pad.unit) * stack_alignment, pad.bytes);
        }
        const reference_current = reference.currentLocation(id);
        const code_current = code.currentLocation(id);
        if (reference_current) |expected| {
            const actual = code_current orelse return error.ReferenceMismatch;
            try std.testing.expectEqual(expected.function, actual.function);
            try std.testing.expectEqual(expected.size, actual.size);
            try std.testing.expectEqual(expected.defunct, actual.defunct);
        } else {
            try std.testing.expect(code_current == null);
        }
    }
}

fn codeLocation(code: *CodeRandomizer, id: LocationId) ?*FunctionLocation {
    for (code.locations.items) |*location| if (location.id == id) return location;
    return null;
}

test "pbt: code relocation matches upstream trap sweep model" {
    try hypothesis.checkNamed(CodeReferenceProperty, "stabilizer-code-reference", settings());
}
