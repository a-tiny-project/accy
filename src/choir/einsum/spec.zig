const std = @import("std");
const testing = std.testing;

pub const IndexSet = struct {
    words: [4]u64 = .{ 0, 0, 0, 0 },

    pub fn add(self: *IndexSet, index: u8) void {
        self.words[wordIndex(index)] |= bitMask(index);
    }

    pub fn contains(self: IndexSet, index: u8) bool {
        return (self.words[wordIndex(index)] & bitMask(index)) != 0;
    }

    pub fn unioned(self: IndexSet, other: IndexSet) IndexSet {
        return .{ .words = .{
            self.words[0] | other.words[0],
            self.words[1] | other.words[1],
            self.words[2] | other.words[2],
            self.words[3] | other.words[3],
        } };
    }

    pub fn intersected(self: IndexSet, other: IndexSet) IndexSet {
        return .{ .words = .{
            self.words[0] & other.words[0],
            self.words[1] & other.words[1],
            self.words[2] & other.words[2],
            self.words[3] & other.words[3],
        } };
    }

    pub fn without(self: IndexSet, other: IndexSet) IndexSet {
        return .{ .words = .{
            self.words[0] & ~other.words[0],
            self.words[1] & ~other.words[1],
            self.words[2] & ~other.words[2],
            self.words[3] & ~other.words[3],
        } };
    }

    pub fn eql(self: IndexSet, other: IndexSet) bool {
        return std.mem.eql(u64, &self.words, &other.words);
    }

    pub fn isEmpty(self: IndexSet) bool {
        return self.words[0] == 0 and self.words[1] == 0 and
            self.words[2] == 0 and self.words[3] == 0;
    }

    pub fn count(self: IndexSet) u32 {
        return @popCount(self.words[0]) +
            @popCount(self.words[1]) + @popCount(self.words[2]) + @popCount(self.words[3]);
    }

    fn wordIndex(index: u8) usize {
        return @intCast(index >> 6);
    }

    fn bitMask(index: u8) u64 {
        const shift: u6 = @intCast(index & 63);
        return @as(u64, 1) << shift;
    }
};

pub const Input = struct {
    indices: []const u8,
    index_set: IndexSet,
    dims: []const u64,
};

pub const Equation = struct {
    allocator: std.mem.Allocator,
    inputs: []Input,
    output: []const u8,
    output_set: IndexSet,
    index_set: IndexSet,
    dimensions: [256]u64,

    pub fn deinit(self: *Equation) void {
        for (self.inputs) |input| {
            self.allocator.free(input.indices);
            self.allocator.free(input.dims);
        }
        self.allocator.free(self.inputs);
        self.allocator.free(self.output);
        self.* = undefined;
    }

    pub fn dimension(self: *const Equation, index: u8) u64 {
        std.debug.assert(self.index_set.contains(index));
        return self.dimensions[index];
    }

    pub fn elementCount(self: *const Equation, indices: IndexSet) u128 {
        var product: u128 = 1;
        for (indices.words, 0..) |initial_word, word_index| {
            var word = initial_word;
            while (word != 0) {
                const bit: usize = @intCast(@ctz(word));
                const index: u8 = @intCast(word_index * 64 + bit);
                product = saturatingMul(product, self.dimension(index));
                word &= word - 1;
            }
        }
        return product;
    }

    pub fn inputSet(self: *const Equation, input_mask: u64) IndexSet {
        var set: IndexSet = .{};
        for (self.inputs, 0..) |input, index| {
            if ((input_mask & (@as(u64, 1) << @intCast(index))) == 0) continue;
            set = set.unioned(input.index_set);
        }
        return set;
    }
};

pub const ParseError = error{
    MissingArrow,
    MultipleArrows,
    EmptyInputList,
    InvalidIndex,
    RepeatedInputIndex,
    RepeatedOutputIndex,
    OutputIndexMissing,
    ArityMismatch,
    RankMismatch,
    DimensionMismatch,
    TooManyInputs,
} || std.mem.Allocator.Error;

/// Two figures for one parse: the bytes the parser asks its allocator for,
/// counting list growth it cannot give back, and the structural visits. The
/// einsum pass reads these two figures to charge a parse before it runs it. The
/// figures leave out stack storage, the internals of the allocator or arena,
/// and the borrowed equation text and shapes. The parser reads an input's
/// dimensions only after that input's rank matches its labels, which are unique
/// letters and digits.
pub const ParseBounds = struct {
    allocation_capacity: u64 = 0,
    structural_visits: u64 = 0,

    const Error = error{WorkOverflow};

    fn add(a: u64, b: u64) Error!u64 {
        return std.math.add(u64, a, b) catch return error.WorkOverflow;
    }

    fn multiply(a: u64, b: u64) Error!u64 {
        return std.math.mul(u64, a, b) catch return error.WorkOverflow;
    }

    fn slice(comptime T: type, count: usize) Error!u64 {
        if (count == 0) return 0;
        return add(try multiply(@sizeOf(T), count), @alignOf(T) - 1);
    }

    /// Charges the bytes for one growing list of `count` items of `T` for the
    /// parse bound: every capacity the list grows through, then one more slice
    /// for the final `toOwnedSlice` copy that happens when shrinking cannot
    /// resize or remap in place.
    fn list(comptime T: type, count: usize) Error!u64 {
        std.debug.assert(count <= 63);
        var capacity: usize = 0;
        var bytes: u64 = 0;
        while (capacity < count) {
            capacity = std.ArrayList(T).growCapacity(capacity + 1);
            bytes = try add(bytes, try slice(T, capacity));
        }
        return add(bytes, try slice(T, count));
    }
};

/// Returns the figures for an equation of `equation_bytes` bytes and
/// `input_count` inputs, computed from those two numbers alone with no parsing
/// and no allocation, so the einsum pass can call this with the equation length
/// and operand count before parsing. The figures cover a successful parse and
/// every error the parse can stop at. The parser looks for the arrow and for a
/// second arrow before it checks the input limit, so above 63 inputs the
/// figures charge only the text scan and no storage. Label lists stop at 62
/// distinct letters and digits, so extra whitespace lengthens the scan but adds
/// no storage. Structural visits cover copies, checks of dimensions and label
/// sets, transfers, and cleanup after a failed prefix. A test parses inside a
/// fixed buffer of the charged size that never frees.
pub fn parseBounds(equation_bytes: usize, input_count: usize) ParseBounds.Error!ParseBounds {
    var bounds: ParseBounds = .{
        .structural_visits = try ParseBounds.add(1, try ParseBounds.multiply(16, equation_bytes)),
    };
    if (input_count > 63) return bounds;
    const labels = @min(equation_bytes, 62);
    const label_storage = try ParseBounds.list(u8, labels);
    const input_storage = try ParseBounds.add(label_storage, try ParseBounds.slice(u64, labels));
    bounds.allocation_capacity = try ParseBounds.add(
        try ParseBounds.list(Input, input_count),
        try ParseBounds.add(try ParseBounds.multiply(input_count, input_storage), label_storage),
    );
    bounds.structural_visits = try ParseBounds.add(bounds.structural_visits, try ParseBounds.add(
        try ParseBounds.multiply(4, bounds.allocation_capacity),
        16 * (input_count + 1),
    ));
    return bounds;
}

pub fn parse(
    allocator: std.mem.Allocator,
    equation: []const u8,
    input_shapes: []const []const u64,
) ParseError!Equation {
    const arrow = findArrow(equation) orelse return error.MissingArrow;
    if (findArrow(equation[arrow + 2 ..]) != null) return error.MultipleArrows;
    if (input_shapes.len > 63) return error.TooManyInputs;

    const lhs = equation[0..arrow];
    const rhs = equation[arrow + 2 ..];
    var dimensions: [256]u64 = undefined;
    var global_indices: IndexSet = .{};
    var inputs = std.ArrayListUnmanaged(Input).empty;
    errdefer inputs.deinit(allocator);
    errdefer freeInputs(allocator, inputs.items);

    var input_index: usize = 0;
    var term_iter = std.mem.splitScalar(u8, lhs, ',');
    while (term_iter.next()) |term| {
        if (input_index >= input_shapes.len) return error.ArityMismatch;
        const input = try parseInput(
            allocator,
            term,
            input_shapes[input_index],
            &dimensions,
            &global_indices,
        );
        var input_owned = true;
        errdefer if (input_owned) freeInput(allocator, input);
        try inputs.append(allocator, input);
        input_owned = false;
        input_index += 1;
    }
    if (input_index == 0) return error.EmptyInputList;
    if (input_index != input_shapes.len) return error.ArityMismatch;

    const output = try parseOutput(allocator, rhs, global_indices);
    errdefer allocator.free(output.indices);

    return .{
        .allocator = allocator,
        .inputs = try inputs.toOwnedSlice(allocator),
        .output = output.indices,
        .output_set = output.index_set,
        .index_set = global_indices,
        .dimensions = dimensions,
    };
}

fn parseInput(
    allocator: std.mem.Allocator,
    term: []const u8,
    shape: []const u64,
    dimensions: *[256]u64,
    global_indices: *IndexSet,
) ParseError!Input {
    var local_indices = std.ArrayListUnmanaged(u8).empty;
    errdefer local_indices.deinit(allocator);
    var local_set: IndexSet = .{};
    for (term) |index| {
        if (isSpace(index)) continue;
        if (!validIndex(index)) return error.InvalidIndex;
        if (local_set.contains(index)) return error.RepeatedInputIndex;
        local_set.add(index);
        try local_indices.append(allocator, index);
    }
    if (local_indices.items.len != shape.len) return error.RankMismatch;
    for (local_indices.items, shape) |index, dim| {
        if (global_indices.contains(index)) {
            if (dimensions[index] != dim) return error.DimensionMismatch;
        } else {
            global_indices.add(index);
            dimensions[index] = dim;
        }
    }
    const owned_indices = try local_indices.toOwnedSlice(allocator);
    errdefer allocator.free(owned_indices);
    const owned_dims = try allocator.dupe(u64, shape);
    return .{
        .indices = owned_indices,
        .index_set = local_set,
        .dims = owned_dims,
    };
}

const OutputParse = struct {
    indices: []const u8,
    index_set: IndexSet,
};

fn parseOutput(
    allocator: std.mem.Allocator,
    term: []const u8,
    global_indices: IndexSet,
) ParseError!OutputParse {
    var indices = std.ArrayListUnmanaged(u8).empty;
    errdefer indices.deinit(allocator);
    var output_set: IndexSet = .{};
    for (term) |index| {
        if (isSpace(index)) continue;
        if (!validIndex(index)) return error.InvalidIndex;
        if (output_set.contains(index)) return error.RepeatedOutputIndex;
        if (!global_indices.contains(index)) return error.OutputIndexMissing;
        output_set.add(index);
        try indices.append(allocator, index);
    }
    return .{
        .indices = try indices.toOwnedSlice(allocator),
        .index_set = output_set,
    };
}

fn freeInputs(allocator: std.mem.Allocator, inputs: []const Input) void {
    for (inputs) |input| freeInput(allocator, input);
}

fn freeInput(allocator: std.mem.Allocator, input: Input) void {
    allocator.free(input.indices);
    allocator.free(input.dims);
}

fn findArrow(equation: []const u8) ?usize {
    return std.mem.indexOf(u8, equation, "->");
}

fn validIndex(index: u8) bool {
    return std.ascii.isAlphanumeric(index);
}

fn isSpace(index: u8) bool {
    return switch (index) {
        ' ', '\n', '\r', '\t' => true,
        else => false,
    };
}

fn saturatingMul(lhs: u128, rhs: u64) u128 {
    if (lhs == 0 or rhs == 0) return 0;
    const rhs_wide: u128 = rhs;
    const max = std.math.maxInt(u128);
    if (lhs > max / rhs_wide) return max;
    return lhs * rhs_wide;
}

fn expectSetContains(set: IndexSet, indices: []const u8) !void {
    for (indices) |index| try testing.expect(set.contains(index));
    try testing.expectEqual(@as(u32, @intCast(indices.len)), set.count());
}

test "einsum parser validates matrix product equation" {
    const shapes = [_][]const u64{ &.{ 2, 3 }, &.{ 3, 5 } };
    var equation = try parse(testing.allocator, "ik, kj -> ij", &shapes);
    defer equation.deinit();

    try testing.expectEqual(@as(usize, 2), equation.inputs.len);
    try testing.expectEqualSlices(u8, "ik", equation.inputs[0].indices);
    try testing.expectEqualSlices(u8, "kj", equation.inputs[1].indices);
    try testing.expectEqualSlices(u8, "ij", equation.output);
    try expectSetContains(equation.index_set, "ijk");
    try testing.expectEqual(@as(u64, 2), equation.dimension('i'));
    try testing.expectEqual(@as(u64, 3), equation.dimension('k'));
    try testing.expectEqual(@as(u64, 5), equation.dimension('j'));
}

test "einsum parser accepts scalar operands and scalar outputs" {
    const dot_shapes = [_][]const u64{ &.{4}, &.{4} };
    var dot = try parse(testing.allocator, "i,i->", &dot_shapes);
    defer dot.deinit();

    try testing.expectEqual(@as(usize, 0), dot.output.len);
    try testing.expect(dot.output_set.isEmpty());

    const scalar_shapes = [_][]const u64{&.{}};
    var scalar = try parse(testing.allocator, "->", &scalar_shapes);
    defer scalar.deinit();

    try testing.expectEqual(@as(usize, 1), scalar.inputs.len);
    try testing.expectEqual(@as(usize, 0), scalar.inputs[0].indices.len);
    try testing.expectEqual(@as(usize, 0), scalar.output.len);
}

test "einsum parser rejects inconsistent dimensions and missing output indices" {
    const bad_shapes = [_][]const u64{ &.{ 2, 3 }, &.{ 4, 5 } };
    try testing.expectError(
        error.DimensionMismatch,
        parse(testing.allocator, "ik,kj->ij", &bad_shapes),
    );

    const shapes = [_][]const u64{ &.{ 2, 3 }, &.{ 3, 5 } };
    try testing.expectError(
        error.OutputIndexMissing,
        parse(testing.allocator, "ik,kj->ix", &shapes),
    );
}

test "einsum parser rejects repeated indices in one input" {
    const shapes = [_][]const u64{&.{ 4, 4 }};
    try testing.expectError(error.RepeatedInputIndex, parse(testing.allocator, "ii->i", &shapes));
}

fn parseStorageWitness(text: []const u8, shapes: []const []const u64) !void {
    const bound = try parseBounds(text.len, shapes.len);
    const bytes = try testing.allocator.alloc(u8, @intCast(bound.allocation_capacity));
    defer testing.allocator.free(bytes);
    var buffer = std.heap.FixedBufferAllocator.init(bytes);
    const base = buffer.allocator();
    const vtable: std.mem.Allocator.VTable = .{
        .alloc = base.vtable.alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = std.mem.Allocator.noFree,
    };
    const allocator: std.mem.Allocator = .{ .ptr = base.ptr, .vtable = &vtable };
    var expected = parse(testing.allocator, text, shapes) catch |err| {
        try testing.expectError(err, parse(allocator, text, shapes));
        try testing.expect(buffer.end_index <= bound.allocation_capacity);
        return;
    };
    defer expected.deinit();
    var actual = try parse(allocator, text, shapes);
    defer actual.deinit();
    try testing.expectEqualDeep(expected.inputs, actual.inputs);
    try testing.expectEqualSlices(u8, expected.output, actual.output);
    try testing.expectEqual(expected.index_set, actual.index_set);
    try testing.expectEqual(expected.output_set, actual.output_set);
    for (0..256) |label| {
        if (actual.index_set.contains(@intCast(label))) {
            try testing.expectEqual(expected.dimensions[label], actual.dimensions[label]);
        }
    }
    try testing.expect(buffer.end_index <= bound.allocation_capacity);
}

test "einsum parser bounds cover unreclaimed growth and full label arity" {
    const labels = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const dims: [labels.len]u64 = @splat(2);
    for ([_]usize{ 1, 2, 8, 9, 20, 63 }) |count| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(testing.allocator);
        const shapes = try testing.allocator.alloc([]const u64, count);
        defer testing.allocator.free(shapes);
        for (shapes, 0..) |*shape, index| {
            if (index != 0) try text.append(testing.allocator, ',');
            try text.appendSlice(testing.allocator, labels);
            shape.* = &dims;
        }
        try text.appendSlice(testing.allocator, "->" ++ labels);
        try parseStorageWitness(text.items, shapes);
    }
    try parseStorageWitness("->", &.{&.{}});
    try parseStorageWitness(",,->", &.{ &.{}, &.{}, &.{} });
    try parseStorageWitness("i,i->", &.{ &.{4}, &.{4} });
    var spaced: [4100]u8 = @splat(' ');
    @memcpy(spaced[4096..], "a->a");
    try parseStorageWitness(&spaced, &.{&.{7}});
}

test "einsum parser bounds preserve errors after partial allocations" {
    const Case = struct { text: []const u8, shapes: []const []const u64, err: ParseError };
    const cases = [_]Case{
        .{ .text = "a", .shapes = &.{&.{2}}, .err = error.MissingArrow },
        .{ .text = "a->a->", .shapes = &.{&.{2}}, .err = error.MultipleArrows },
        .{ .text = "a,b?->", .shapes = &.{ &.{2}, &.{3} }, .err = error.InvalidIndex },
        .{ .text = "a,bb->", .shapes = &.{ &.{2}, &.{ 3, 3 } }, .err = error.RepeatedInputIndex },
        .{ .text = "a->aa", .shapes = &.{&.{2}}, .err = error.RepeatedOutputIndex },
        .{ .text = "a->ab", .shapes = &.{&.{2}}, .err = error.OutputIndexMissing },
        .{ .text = "a,b->", .shapes = &.{&.{2}}, .err = error.ArityMismatch },
        .{ .text = "a->", .shapes = &.{ &.{2}, &.{3} }, .err = error.ArityMismatch },
        .{ .text = "->", .shapes = &.{}, .err = error.ArityMismatch },
        .{ .text = "a,b->", .shapes = &.{ &.{2}, &.{ 3, 3 } }, .err = error.RankMismatch },
        .{ .text = "a,a->", .shapes = &.{ &.{2}, &.{3} }, .err = error.DimensionMismatch },
    };
    for (cases) |case| {
        try testing.expectError(case.err, parse(testing.allocator, case.text, case.shapes));
        try parseStorageWitness(case.text, case.shapes);
    }
    const too_many: [64][]const u64 = @splat(&.{});
    try testing.expectError(error.TooManyInputs, parse(testing.allocator, "->", &too_many));
    try parseStorageWitness("->", &too_many);
}

test "einsum parser bounds include rejected text scans and checked arithmetic" {
    const short = try parseBounds(2, 64);
    const long = try parseBounds(8192, 64);
    try testing.expectEqual(@as(u64, 0), long.allocation_capacity);
    try testing.expect(long.structural_visits >= 8192);
    try testing.expect(long.structural_visits > short.structural_visits);
    const labels = try parseBounds(62, 2);
    const spaced = try parseBounds(8192, 2);
    try testing.expectEqual(labels.allocation_capacity, spaced.allocation_capacity);
    try testing.expect(spaced.structural_visits > labels.structural_visits);
    try testing.expectError(error.WorkOverflow, parseBounds(std.math.maxInt(usize), 1));
    try testing.expectError(error.WorkOverflow, ParseBounds.add(std.math.maxInt(u64), 1));
}

fn parseAllocationWitness(allocator: std.mem.Allocator) !void {
    const labels = "abcdefghi";
    const dims: [labels.len]u64 = @splat(2);
    const shapes: [9][]const u64 = @splat(&dims);
    const text = "abcdefghi,abcdefghi,abcdefghi,abcdefghi,abcdefghi," ++
        "abcdefghi,abcdefghi,abcdefghi,abcdefghi->abcdefghi";
    var equation = try parse(allocator, text, &shapes);
    defer equation.deinit();
    try testing.expectEqualSlices(u8, labels, equation.output);
}

test "einsum parser releases every partially allocated equation" {
    try testing.checkAllAllocationFailures(testing.allocator, parseAllocationWitness, .{});
}
