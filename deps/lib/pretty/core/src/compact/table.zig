const std = @import("std");
const alloc_phase = @import("alloc_phase");
const format = @import("format.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
pub const Align = types.Align;
pub const Column = types.Column;

pub const Limits = struct {
    columns: usize,
    rows: usize,
    maximum_line_bytes: usize,
    footer_bytes: usize,
    output_bytes: usize,

    pub fn inspect(
        columns: []const Column,
        rows: []const []const []const u8,
        total: ?usize,
    ) error{CapacityOverflow}!Limits {
        const maximum_line_bytes = try format.maximumLineBytes(columns, rows);
        const body_lines = std.math.add(usize, rows.len, 2) catch
            return error.CapacityOverflow;
        const body_bytes = std.math.mul(
            usize,
            maximum_line_bytes,
            body_lines,
        ) catch return error.CapacityOverflow;
        const footer_bytes = try format.footerLength(rows.len, total);
        const output_bytes = std.math.add(usize, body_bytes, footer_bytes) catch
            return error.CapacityOverflow;
        std.debug.assert(maximum_line_bytes > 0);
        std.debug.assert(output_bytes >= body_bytes);
        return .{
            .columns = columns.len,
            .rows = rows.len,
            .maximum_line_bytes = maximum_line_bytes,
            .footer_bytes = footer_bytes,
            .output_bytes = output_bytes,
        };
    }
};

pub const Capacity = struct {
    limits: Limits,
    width_bytes: usize,
    output_bytes: usize,
    working_bytes: usize,

    pub fn derive(limits: Limits) error{CapacityOverflow}!Capacity {
        const width_bytes = std.math.mul(
            usize,
            limits.columns,
            @sizeOf(usize),
        ) catch return error.CapacityOverflow;
        const working_bytes = std.math.add(
            usize,
            width_bytes,
            limits.output_bytes,
        ) catch return error.CapacityOverflow;
        std.debug.assert(working_bytes >= width_bytes);
        std.debug.assert(working_bytes >= limits.output_bytes);
        return .{
            .limits = limits,
            .width_bytes = width_bytes,
            .output_bytes = limits.output_bytes,
            .working_bytes = working_bytes,
        };
    }
};

pub const RenderError = error{
    CapacityModelViolation,
    InputChanged,
};

const TableLimits = Limits;
const TableCapacity = Capacity;

/// Renders a compact table into storage derived from an exact input inspection.
/// The returned slice is borrowed until the next render or `deinit`.
pub const Table = struct {
    pub const claim: alloc_phase.capacity.Declaration = .{
        .source = .{
            .id = "pretty.compact_table",
            .kind = .phase_static,
            .limit_source = .caller,
            .storage = .{
                .covered = &.{
                    .{
                        .id = "exact_per_column_width_slice",
                        .lifetime = .steady,
                        .detail = "exact per-column width slice",
                    },
                    .{
                        .id = "derived_fixed_worst_case_rendered_output_byte_slice",
                        .lifetime = .steady,
                        .detail = "derived fixed worst-case rendered-output byte slice",
                    },
                },
                .excluded = &.{
                    "caller-owned column, row, header, and cell storage",
                    "the convenience compact.table wrapper result duplicate and its caller-owned lifetime",
                    "destination writes performed after Table.render returns its borrowed output",
                    "glom-owned result preparation, references, snippets, and non-table presentation modes",
                },
            },
            .capacity = .{
                .inputs = &.{
                    alloc_phase.capacity.bindInput(TableLimits, "columns", "columns"),
                    alloc_phase.capacity.bindInput(TableLimits, "maximum_line_bytes", "maximum_line_bytes"),
                    alloc_phase.capacity.bindInput(TableLimits, "rows", "rows"),
                    alloc_phase.capacity.bindInput(TableLimits, "footer_bytes", "footer_bytes"),
                },
                .type_selectors = &.{
                    alloc_phase.capacity.bindType(usize, "usize"),
                },
                .nodes = &.{
                    .{ .input = 0 },
                    .{ .scale = .{ .node = 0, .coefficient = .{ .size_of_concrete_type = 0 } } },
                    .{ .input = 1 },
                    .{ .input = 2 },
                    .{ .constant = 2 },
                    .{ .add = .{ .left = 3, .right = 4 } },
                    .{ .product = .{ .left = 2, .right = 5 } },
                    .{ .input = 3 },
                    .{ .add = .{ .left = 6, .right = 7 } },
                    .{ .add = .{ .left = 1, .right = 8 } },
                },
                .assertions = &.{.{
                    .scope = .closure_total,
                    .measure = .retained,
                    .relation = .exact,
                    .expression = 9,
                }},
            },
            .overload = .{
                .kind = .reject_before_seal,
                .detail = "capacity arithmetic overflow and initialization OOM fail before activation; render rejects changed derived capacity facts before measuring widths or writing output; content changes that preserve admitted capacity facts remain supported",
            },
            .risks = .{
                .transitive = .{
                    .status = .open,
                    .detail = "the source-reviewed fixed-writer helper chain carries no allocator capability, but no machine-checked call-graph certificate excludes future policy allocator reacquisition",
                },
                .foreign = .{
                    .status = .excluded,
                    .detail = "the owner uses process-local caller-allocated slices and a fixed in-memory writer; destination and operating-system writes are outside the owner",
                },
            },
            .obligations = &.{
                .{ .key = "pretty_compact_table_capacity_capacity_model", .role = .capacity_model },
                .{ .key = "pretty_compact_table_capacity_overload", .role = .overload },
                .{ .key = "pretty_compact_table_oom_retry", .role = .overload },
                .{ .key = "pretty_compact_table_sealed_transitive_risk", .role = .transitive_risk },
                .{ .key = "pretty_compact_table_sealed_foreign_risk", .role = .foreign_risk },
                .{ .key = "pretty_compact_table_limit_drift", .role = .custom },
                .{ .key = "pretty_compact_table_semantics", .role = .transitive_risk },
                .{ .key = "pretty_compact_table_overflow", .role = .overload },
            },
        },
        .bindings = .{
            .owner = @This(),
            .seal = .{
                .family = alloc_phase.capacity.selector(@This().activate),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
            .teardown = .{
                .family = alloc_phase.capacity.selector(@This().deinit),
                .premise = .{
                    .class = .checked_semantic_fact,
                    .authority = .checker,
                },
            },
        },
    };
    pub const Limits = TableLimits;
    pub const Capacity = TableCapacity;

    phase: alloc_phase.capacity.Phase,
    capacity: TableCapacity,
    widths: []usize,
    output: []u8,
    high_water: usize,

    pub fn init(allocator: Allocator, limits: TableLimits) !Table {
        const capacity = try TableCapacity.derive(limits);
        const widths = try allocator.alloc(usize, capacity.limits.columns);
        errdefer allocator.free(widths);
        const output = try allocator.alloc(u8, capacity.output_bytes);
        return .{
            .phase = .initialization,
            .capacity = capacity,
            .widths = widths,
            .output = output,
            .high_water = 0,
        };
    }

    pub fn activate(self: *Table) void {
        std.debug.assert(self.phase == .initialization);
        std.debug.assert(self.widths.len == self.capacity.limits.columns);
        std.debug.assert(self.output.len == self.capacity.output_bytes);
        self.phase = .steady;
    }

    pub fn render(
        self: *Table,
        columns: []const Column,
        rows: []const []const []const u8,
        total: ?usize,
    ) RenderError![]const u8 {
        std.debug.assert(self.phase == .steady);
        const inspected = TableLimits.inspect(columns, rows, total) catch
            return error.CapacityModelViolation;
        if (!std.meta.eql(inspected, self.capacity.limits)) return error.InputChanged;
        format.measureWidths(self.widths, columns, rows);
        var writer = std.Io.Writer.fixed(self.output);
        format.renderInto(&writer, self.widths, columns, rows, total) catch
            return error.CapacityModelViolation;
        const rendered = writer.buffered();
        self.high_water = @max(self.high_water, rendered.len);
        std.debug.assert(self.high_water <= self.capacity.output_bytes);
        return rendered;
    }

    pub fn highWater(self: *const Table) usize {
        std.debug.assert(self.phase == .steady);
        std.debug.assert(self.high_water <= self.capacity.output_bytes);
        return self.high_water;
    }

    pub fn deinit(self: *Table, allocator: Allocator) void {
        std.debug.assert(self.phase != .teardown);
        self.phase = .teardown;
        allocator.free(self.output);
        allocator.free(self.widths);
        self.output = &.{};
        self.widths = &.{};
    }
};

comptime {
    alloc_phase.capacity.requireAllocatorExactOwnerShape(Table);
}

/// Renders one compact table into a caller-owned allocation.
pub fn table(
    allocator: Allocator,
    columns: []const Column,
    rows: []const []const []const u8,
    total: ?usize,
) ![]u8 {
    const limits = try Limits.inspect(columns, rows, total);
    var owner = try Table.init(allocator, limits);
    owner.activate();
    defer owner.deinit(allocator);
    return try allocator.dupe(u8, try owner.render(columns, rows, total));
}

const fixture_columns = [_]Column{
    .{ .header = "name" },
    .{ .header = "count", .alignment = .right, .max_width = 10 },
};
const fixture_row_1 = [_][]const u8{ "alpha", "42" };
const fixture_row_2 = [_][]const u8{ "beta", "7" };
const fixture_row_3 = [_][]const u8{ "longer", "3" };
const fixture_rows = [_][]const []const u8{
    &fixture_row_1,
    &fixture_row_2,
    &fixture_row_3,
};

test "compact table capacity matches an independent typed-byte model" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Table, "pretty_compact_table_capacity_capacity_model"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Table, "pretty_compact_table_capacity_overload"),
        );
    }

    const limits = try Limits.inspect(&fixture_columns, &fixture_rows, 5);
    const capacity = try Capacity.derive(limits);
    const maximum_line_bytes = "longer".len + format.gutter.len + "count".len + 1;
    const footer_bytes = "(showing 3 of 5".len + format.footer_tail.len;
    const output_bytes = maximum_line_bytes * (fixture_rows.len + 2) + footer_bytes;
    try std.testing.expectEqual(@as(usize, 2), limits.columns);
    try std.testing.expectEqual(maximum_line_bytes, limits.maximum_line_bytes);
    try std.testing.expectEqual(footer_bytes, limits.footer_bytes);
    try std.testing.expectEqual(output_bytes, capacity.output_bytes);
    try std.testing.expectEqual(2 * @sizeOf(usize), capacity.width_bytes);
    try std.testing.expectEqual(
        capacity.width_bytes + capacity.output_bytes,
        capacity.working_bytes,
    );
}

fn checkTableInitFailures(allocator: Allocator, limits: Limits) !void {
    var owner = try Table.init(allocator, limits);
    defer owner.deinit(allocator);
    try std.testing.expectEqual(alloc_phase.capacity.Phase.initialization, owner.phase);
}

test "compact table initialization cleans every allocation failure and retries" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Table, "pretty_compact_table_oom_retry"),
        );
    }

    const limits = try Limits.inspect(&fixture_columns, &fixture_rows, 5);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkTableInitFailures,
        .{limits},
    );
    var owner = try Table.init(std.testing.allocator, limits);
    defer owner.deinit(std.testing.allocator);
    owner.activate();
    try std.testing.expect((try owner.render(&fixture_columns, &fixture_rows, 5)).len > 0);
}

test "compact table is sealed before its first maximum render" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Table, "pretty_compact_table_sealed_transitive_risk"),
        );
    }
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Table, "pretty_compact_table_sealed_foreign_risk"),
        );
    }

    const limits = try Limits.inspect(&fixture_columns, &fixture_rows, 5);
    var phase_allocator = try alloc_phase.SealedPhaseAllocator.init(std.testing.allocator);
    var owner = try Table.init(phase_allocator.initializationAllocator(), limits);
    const widths_pointer = owner.widths.ptr;
    const output_pointer = owner.output.ptr;
    phase_allocator.seal();
    owner.activate();
    const first = try owner.render(&fixture_columns, &fixture_rows, 5);
    const second = try owner.render(&fixture_columns, &fixture_rows, 5);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expectEqual(widths_pointer, owner.widths.ptr);
    try std.testing.expectEqual(output_pointer, owner.output.ptr);
    try std.testing.expect(owner.highWater() <= owner.capacity.output_bytes);
    phase_allocator.beginTeardown();
    owner.deinit(phase_allocator.teardownAllocator());
    phase_allocator.deinit();
}

test "compact table detects changed admitted input" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Table, "pretty_compact_table_limit_drift"),
        );
    }

    const limits = try Limits.inspect(&fixture_columns, &fixture_rows, 5);
    var owner = try Table.init(std.testing.allocator, limits);
    defer owner.deinit(std.testing.allocator);
    owner.activate();
    try std.testing.expectError(
        error.InputChanged,
        owner.render(&fixture_columns, fixture_rows[0..2], 5),
    );
    const above_capacity_rows = fixture_rows ++ [_][]const []const u8{&fixture_row_1};
    try std.testing.expectError(
        error.InputChanged,
        owner.render(&fixture_columns, &above_capacity_rows, 5),
    );
    const changed_row = [_][]const u8{ "zeta", "8" };
    const changed_rows = [_][]const []const u8{
        &fixture_row_1,
        &changed_row,
        &fixture_row_3,
    };
    const rendered = try owner.render(&fixture_columns, &changed_rows, 5);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "zeta") != null);
}

test "compact table has no trailing whitespace and preserves footer" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Table, "pretty_compact_table_semantics"),
        );
    }

    const out = try table(
        std.testing.allocator,
        &fixture_columns,
        &fixture_rows,
        5,
    );
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "showing 3 of 5") != null);
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(line[line.len - 1] != ' ');
    }
}

test "compact table capacity rejects arithmetic overflow" {
    comptime {
        alloc_phase.capacity.record(
            alloc_phase.capacity.witness(Table, "pretty_compact_table_overflow"),
        );
    }

    const limits = Limits{
        .columns = std.math.maxInt(usize) / @sizeOf(usize) + 1,
        .rows = 0,
        .maximum_line_bytes = 1,
        .footer_bytes = 0,
        .output_bytes = 1,
    };
    try std.testing.expectError(error.CapacityOverflow, Capacity.derive(limits));
}
