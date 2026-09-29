//! The binding report a compiler writes beside a payload, and the launch check that reads it.
//!
//! A module's entries each read a push-constant block and a list of storage bindings at set 0.
//! Whoever launches one must bind what the module declares, so the writer that emitted the
//! payload states it in `<name>.bindings` and never leaves the launcher to restate it. This file
//! defines that format for every reader, and a writer outside the package names it as the
//! definition.
//!
//! THE FORMAT. Lines of fields separated by one space, each ending in a newline. Numbers are
//! decimal with no leading zero, and with no sign except where a `range` bound says so. Version
//! 2, in this order:
//!
//!     bindings 2
//!     target <name>
//!     requires <control>                 zero or more, each once
//!     entry <vertex|fragment|kernel> <name>
//!     workgroup <x> <y> <z>              a kernel's shape: once on a kernel, never on a stage
//!     grid <x> <y> <z>                   a kernel's grid bound: once on a kernel, never on a stage
//!     float <exact|bounded> <control>*   a kernel's float mark and modes: once on a kernel
//!     push <bytes>
//!     member <offset> <f32|i32|u32> <width>
//!     range <offset> <low> <high>        a kernel's stated range of one integer member
//!     binding <number> <lent|shared|parameters> <bytes>
//!     output <number> <exact|any>        a `bounded` kernel's mark on each lent binding
//!     descriptors <storage> <sampled> <resources>
//!
//! with the lines from `entry` to `descriptors` repeated for each entry. `requires` names a float
//! control the device must report before a pipeline is made: `denorm_preserve_f32`,
//! `signed_zero_inf_nan_preserve_f32` or `rounding_mode_rte_f32`. `member` lines are the push
//! block's leaves in offset order, each placed by the stage dialect's member rule. `binding`
//! lines number the storage bindings from 0 upward: a lent binding is written by exactly one
//! invocation per element, a shared one is only read, and the `parameters` binding holds a
//! by-value block past the push budget and comes last. `descriptors` counts what the entry uses
//! against the device's per-stage limits, and version 2 has no image binding, so `sampled` is 0
//! and `resources` equals `storage`.
//!
//! A KERNEL STATES WHAT A HOST NEEDS TO LAUNCH IT USEFULLY. `grid` is the most workgroups a
//! launch may count in each dimension, 1 in every dimension past the shape. A kernel built for a
//! foreign host returns at once from a launch past it, so such a launch writes nothing. `range`
//! states the half-open range `[low, high)` of one scalar `i32` or `u32` member, in member order,
//! and a launch that passes a value outside it writes nothing either. `float` marks the kernel
//! `exact`, or `bounded` when a float division is in its reach, and names the float controls the
//! kernel declares in the order above, each also a `requires` line. A `bounded` kernel marks each
//! of its lent bindings `exact`, compared byte for byte up to NaN, or `any`, where a quotient may
//! have reached any value of its element type. An `exact` kernel's bindings are all exact.
//!
//! A LATER LINE KIND RAISES THE VERSION. The reader refuses an unknown kind, an unknown value, a
//! line out of order, another version's report and a report that contradicts itself, each by
//! name, and never reads a missing field as zero.

const std = @import("std");
const contract = @import("contract.zig");

pub const Error = error{
    /// No `<name>.bindings` file stands beside the payload.
    MissingBindings,
    /// The text is not version 2 of the format, or it contradicts itself.
    MalformedBindings,
    /// The report holds more entries, bindings, members or bytes than the capacities below.
    BindingsCapacityExceeded,
};

pub const LaunchError = error{
    /// The launch binds a different number of buffers than the entry declares.
    LaunchBindingMismatch,
    /// A lent binding and another binding of the same launch name one buffer. The module assumes
    /// their bytes are disjoint, so the dispatch could race or read what another invocation wrote.
    LentBindingAliased,
};

/// The version this reader reads and a writer writes.
pub const version = 2;
/// Entries one report holds.
pub const max_entries = 16;
/// Storage bindings one entry holds: lib/gpu's Vulkan launch binds at most 64 buffers per set
/// (`runtime/vulkan/runtime.zig`, `max_buffers_per_set`).
pub const max_bindings = 64;
/// Push-constant bytes a block holds: Vulkan's guaranteed `maxPushConstantsSize`.
pub const max_push_bytes = 128;
/// Leaves one push block holds, since each is at least one 4-byte component.
pub const max_members = max_push_bytes / 4;
/// Workgroups a kernel's grid bound counts in one dimension at most: the default bound, and the
/// most Vulkan guarantees a device takes (`maxComputeWorkGroupCount`).
pub const max_grid = 65535;
/// Bytes an entry or target name holds.
pub const max_name_bytes = 63;
/// Bytes the longest line of the format holds. A `float` line naming every control is the
/// longest, and a `binding` line with a 20-digit size comes next.
pub const max_line_bytes = 96;
/// Lines one report holds at most: the header, the target, each float control once, and every
/// line of every entry at capacity. An entry has six lines of its own, from `entry` through
/// `descriptors`, a `range` line at most per member and an `output` line at most per binding.
pub const max_lines = 2 + std.enums.values(Control).len +
    max_entries * (6 + 2 * max_members + 2 * max_bindings);
/// Bytes the longest well-formed report holds.
pub const max_text_bytes = max_lines * max_line_bytes;

comptime {
    std.debug.assert(std.fmt.count("binding {d} parameters {d}\n", .{
        max_bindings - 1,
        std.math.maxInt(u64),
    }) <= max_line_bytes);
    std.debug.assert(std.fmt.count("entry fragment \n", .{}) + max_name_bytes <= max_line_bytes);
    var float_bytes = std.fmt.count("float bounded\n", .{});
    for (std.enums.values(Control)) |control| float_bytes += 1 + @tagName(control).len;
    std.debug.assert(float_bytes <= max_line_bytes);
    std.debug.assert(std.fmt.count("range {d} {d} {d}\n", .{
        max_push_bytes - 4,
        std.math.minInt(i32),
        @as(u64, std.math.maxInt(u32)) + 1,
    }) <= max_line_bytes);
}

pub const Stage = enum { vertex, fragment, kernel };

/// A float control the device must report before a pipeline of the module is made.
pub const Control = enum {
    denorm_preserve_f32,
    signed_zero_inf_nan_preserve_f32,
    rounding_mode_rte_f32,
};

pub const Scalar = enum { f32, i32, u32 };

/// One leaf of a push block: `width` components of one 4-byte scalar at `offset`.
pub const Member = struct {
    offset: u32,
    scalar: Scalar,
    width: u32,

    /// The stage dialect's rule: a scalar on 4 bytes, two lanes on 8, three or four on 16.
    fn alignment(self: Member) u32 {
        return switch (self.width) {
            1 => 4,
            2 => 8,
            else => 16,
        };
    }

    pub fn end(self: Member) u32 {
        return self.offset + 4 * self.width;
    }
};

pub const Class = enum {
    /// Each invocation writes the one element it takes, and no other binding shares its bytes.
    lent,
    /// Every invocation reads it and none writes it.
    shared,
    /// The by-value block past the push budget, read only.
    parameters,
};

pub const Binding = struct {
    number: u32,
    class: Class,
    /// The bytes the buffer holds at least.
    bytes: u64,
};

/// A kernel's float mark: `exact` when no float division is in its reach, `bounded` otherwise.
pub const Mark = enum { exact, bounded };

/// A kernel's float mark and the float controls it declares.
pub const Float = struct {
    mark: Mark,
    controls: std.EnumSet(Control),
};

/// The stated range `[low, high)` of one scalar integer member of a kernel's push block.
pub const Range = struct {
    /// The member's offset in the push block.
    offset: u32,
    low: i64,
    high: i64,

    pub fn contains(self: Range, value: i64) bool {
        return self.low <= value and value < self.high;
    }
};

/// What a `bounded` kernel promises about one lent binding's bytes.
pub const Answer = enum {
    /// No quotient reaches it, so it compares byte for byte up to NaN.
    exact,
    /// A quotient may reach it, so it may hold any value of its element type.
    any,
};

pub const Output = struct {
    number: u32,
    answer: Answer,
};

pub const Descriptors = struct {
    storage: u32,
    sampled: u32,
    resources: u32,
};

pub const Entry = struct {
    /// A slice of the text the report was parsed from.
    name: []const u8,
    stage: Stage,
    /// The workgroup shape, present exactly on a kernel.
    workgroup: ?[3]u32,
    /// The grid bound, present exactly on a kernel.
    grid: ?[3]u32,
    /// The float mark and controls, present exactly on a kernel.
    float: ?Float,
    push: u32,
    member_count: u32,
    held_members: [max_members]Member,
    range_count: u32,
    held_ranges: [max_members]Range,
    binding_count: u32,
    held_bindings: [max_bindings]Binding,
    output_count: u32,
    held_outputs: [max_bindings]Output,
    descriptors: Descriptors,

    pub fn members(self: *const Entry) []const Member {
        return self.held_members[0..self.member_count];
    }

    /// The stated ranges in member order. A member with no range takes any value.
    pub fn ranges(self: *const Entry) []const Range {
        return self.held_ranges[0..self.range_count];
    }

    pub fn bindings(self: *const Entry) []const Binding {
        return self.held_bindings[0..self.binding_count];
    }

    /// One mark per lent binding in number order for a `bounded` kernel, and none otherwise.
    pub fn outputs(self: *const Entry) []const Output {
        return self.held_outputs[0..self.output_count];
    }

    /// Refuses a launch of this entry that binds a lent binding's buffer to any other binding.
    ///
    /// `buffers[i]` is bound at binding `i`, as every lib/gpu launch binds them. Two bindings name
    /// one buffer when they carry one backend and one object id, since lib/gpu binds whole
    /// buffers. Two shared bindings may name one buffer. This is the one fact of the module's
    /// premise a host can break and this package can see: a host that binds its own buffers
    /// keeps it on trust.
    pub fn admitLaunch(
        self: *const Entry,
        buffers: []const contract.BufferBinding,
    ) LaunchError!void {
        if (buffers.len != self.binding_count) return error.LaunchBindingMismatch;
        for (self.bindings(), buffers, 0..) |declared, lent, index| {
            if (declared.class != .lent) continue;
            for (buffers, 0..) |other, other_index| {
                if (other_index == index) continue;
                if (other.handle.backend != lent.handle.backend) continue;
                if (other.handle.id == lent.handle.id) return error.LentBindingAliased;
            }
        }
    }
};

/// One module's binding report, parsed into storage its caller declares.
pub const Report = struct {
    version: u32,
    /// A slice of the text the report was parsed from.
    target: []const u8,
    requires: std.EnumSet(Control),
    entry_count: u32,
    held_entries: [max_entries]Entry,

    pub fn entries(self: *const Report) []const Entry {
        return self.held_entries[0..self.entry_count];
    }

    /// The entry named `name`, or null when the report lists none.
    pub fn find(self: *const Report, name: []const u8) ?*const Entry {
        for (self.entries()) |*listed| {
            if (std.mem.eql(u8, listed.name, name)) return listed;
        }
        return null;
    }
};

/// Reads `<name>.bindings` from `dir` into `text` and parses it into `report`, whose names then
/// point into `text`. A missing file is refused by name. `text` holds at least one byte more than
/// the longest well-formed report, so a file that fills it is longer than any report and is
/// refused rather than parsed as a prefix.
pub fn readBindings(
    io: std.Io,
    dir: std.Io.Dir,
    name: []const u8,
    text: []u8,
    report: *Report,
) !void {
    std.debug.assert(name.len != 0);
    std.debug.assert(text.len > max_text_bytes);
    var name_buffer: [max_name_bytes + ".bindings".len + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(&name_buffer, "{s}.bindings", .{name});
    const read = dir.readFile(io, path, text) catch |err| switch (err) {
        error.FileNotFound => return error.MissingBindings,
        else => |other| return other,
    };
    if (read.len == text.len) return error.BindingsCapacityExceeded;
    return parseBindings(read, report);
}

/// Parses one report's text into `report`, whose names point into `text`.
pub fn parseBindings(text: []const u8, report: *Report) Error!void {
    if (text.len > max_text_bytes) return error.BindingsCapacityExceeded;
    var lines: Lines = .{ .text = text };
    report.* = .{
        .version = version,
        .target = "",
        .requires = .init(.{}),
        .entry_count = 0,
        .held_entries = undefined,
    };

    var header = try lines.expect("bindings");
    if (try header.number(u32) != version) return error.MalformedBindings;
    try header.finish();
    var target = try lines.expect("target");
    report.target = try target.name();
    try target.finish();

    while (lines.peekKind()) |kind| {
        if (!std.mem.eql(u8, kind, "requires")) break;
        var line = try lines.expect("requires");
        const control = try line.value(Control);
        if (report.requires.contains(control)) return error.MalformedBindings;
        report.requires.insert(control);
        try line.finish();
    }

    while (!lines.done()) {
        if (report.entry_count == max_entries) return error.BindingsCapacityExceeded;
        const entry = &report.held_entries[report.entry_count];
        try parseEntry(&lines, entry, report.requires);
        if (report.find(entry.name) != null) return error.MalformedBindings;
        report.entry_count += 1;
    }
    if (report.entry_count == 0) return error.MalformedBindings;
}

fn parseEntry(lines: *Lines, entry: *Entry, requires: std.EnumSet(Control)) Error!void {
    var opened = try lines.expect("entry");
    const stage = try opened.value(Stage);
    entry.* = .{
        .name = try opened.name(),
        .stage = stage,
        .workgroup = null,
        .grid = null,
        .float = null,
        .push = 0,
        .member_count = 0,
        .held_members = undefined,
        .range_count = 0,
        .held_ranges = undefined,
        .binding_count = 0,
        .held_bindings = undefined,
        .output_count = 0,
        .held_outputs = undefined,
        .descriptors = undefined,
    };
    try opened.finish();

    if (stage == .kernel) {
        var shape = try lines.expect("workgroup");
        entry.workgroup = try shape.extents(std.math.maxInt(u32));
        try shape.finish();
        var bound = try lines.expect("grid");
        entry.grid = try bound.extents(max_grid);
        try bound.finish();
        entry.float = try parseFloat(lines, requires);
    }

    var push = try lines.expect("push");
    entry.push = try push.number(u32);
    if (entry.push % 4 != 0 or entry.push > max_push_bytes) return error.MalformedBindings;
    try push.finish();

    try parseMembers(lines, entry);
    try parseRanges(lines, entry);
    try parseStorage(lines, entry);
    try parseOutputs(lines, entry);

    var counted = try lines.expect("descriptors");
    entry.descriptors = .{
        .storage = try counted.number(u32),
        .sampled = try counted.number(u32),
        .resources = try counted.number(u32),
    };
    try counted.finish();
    if (entry.descriptors.storage != entry.binding_count) return error.MalformedBindings;
    if (entry.descriptors.sampled != 0) return error.MalformedBindings;
    if (entry.descriptors.resources != entry.descriptors.storage) return error.MalformedBindings;
}

/// A kernel's `float` line: its mark, then the controls it declares in `Control`'s order, each
/// once and each one the report `requires`.
fn parseFloat(lines: *Lines, requires: std.EnumSet(Control)) Error!Float {
    var line = try lines.expect("float");
    var float: Float = .{ .mark = try line.value(Mark), .controls = .init(.{}) };
    var next: usize = 0;
    while (!line.ended()) {
        const control = try line.value(Control);
        if (@backingInt(control) < next) return error.MalformedBindings;
        if (!requires.contains(control)) return error.MalformedBindings;
        next = @backingInt(control) + 1;
        float.controls.insert(control);
    }
    try line.finish();
    return float;
}

/// The push block's `member` lines, in offset order and inside the push extent.
fn parseMembers(lines: *Lines, entry: *Entry) Error!void {
    var cursor: u32 = 0;
    while (lines.peekIs("member")) {
        if (entry.member_count == max_members) return error.BindingsCapacityExceeded;
        var line = try lines.expect("member");
        const member: Member = .{
            .offset = try line.number(u32),
            .scalar = try line.value(Scalar),
            .width = try line.number(u32),
        };
        try line.finish();
        if (member.width < 1 or member.width > 4) return error.MalformedBindings;
        if (member.offset % member.alignment() != 0 or member.offset < cursor) {
            return error.MalformedBindings;
        }
        if (member.end() > entry.push) return error.MalformedBindings;
        cursor = member.end();
        entry.held_members[entry.member_count] = member;
        entry.member_count += 1;
    }
}

/// A kernel's `range` lines, each on a scalar integer member, in member order and inside the
/// member's type.
fn parseRanges(lines: *Lines, entry: *Entry) Error!void {
    var ranged: usize = 0;
    while (lines.peekIs("range")) {
        if (entry.stage != .kernel) return error.MalformedBindings;
        var line = try lines.expect("range");
        const offset = try line.number(u32);
        const members = entry.members();
        while (ranged < members.len and members[ranged].offset < offset) ranged += 1;
        if (ranged == members.len) return error.MalformedBindings;
        const member = members[ranged];
        if (member.offset != offset or member.width != 1) return error.MalformedBindings;
        const lowest: i64, const highest: i64 = switch (member.scalar) {
            .f32 => return error.MalformedBindings,
            .i32 => .{ std.math.minInt(i32), @as(i64, std.math.maxInt(i32)) + 1 },
            .u32 => .{ 0, @as(i64, std.math.maxInt(u32)) + 1 },
        };
        const range: Range = .{
            .offset = offset,
            .low = try line.signed(member.scalar == .i32),
            .high = try line.signed(member.scalar == .i32),
        };
        try line.finish();
        if (range.low < lowest or range.low >= range.high or range.high > highest) {
            return error.MalformedBindings;
        }
        ranged += 1;
        entry.held_ranges[entry.range_count] = range;
        entry.range_count += 1;
    }
}

/// The `binding` lines, numbered from 0, with the `parameters` binding last.
fn parseStorage(lines: *Lines, entry: *Entry) Error!void {
    while (lines.peekIs("binding")) {
        if (entry.binding_count == max_bindings) return error.BindingsCapacityExceeded;
        var line = try lines.expect("binding");
        const binding: Binding = .{
            .number = try line.number(u32),
            .class = try line.value(Class),
            .bytes = try line.number(u64),
        };
        try line.finish();
        if (binding.number != entry.binding_count) return error.MalformedBindings;
        if (binding.bytes == 0) return error.MalformedBindings;
        if (entry.binding_count != 0) {
            const last = entry.held_bindings[entry.binding_count - 1];
            if (last.class == .parameters) return error.MalformedBindings;
        }
        entry.held_bindings[entry.binding_count] = binding;
        entry.binding_count += 1;
    }
}

/// A `bounded` kernel's `output` lines, one per lent binding in number order.
fn parseOutputs(lines: *Lines, entry: *Entry) Error!void {
    const float = entry.float orelse return;
    if (float.mark != .bounded) return;
    for (entry.bindings()) |binding| {
        if (binding.class != .lent) continue;
        var line = try lines.expect("output");
        const output: Output = .{
            .number = try line.number(u32),
            .answer = try line.value(Answer),
        };
        try line.finish();
        if (output.number != binding.number) return error.MalformedBindings;
        entry.held_outputs[entry.output_count] = output;
        entry.output_count += 1;
    }
}

/// The report's lines, one at a time, each split into fields as it is read.
const Lines = struct {
    text: []const u8,
    at: usize = 0,

    fn done(self: *const Lines) bool {
        return self.at == self.text.len;
    }

    /// The kind of the next line, or null at the end.
    fn peekKind(self: *const Lines) ?[]const u8 {
        if (self.done()) return null;
        const rest = self.text[self.at..];
        const end = std.mem.indexOfAny(u8, rest, " \n") orelse rest.len;
        return rest[0..end];
    }

    fn peekIs(self: *const Lines, kind: []const u8) bool {
        const next = self.peekKind() orelse return false;
        return std.mem.eql(u8, next, kind);
    }

    /// The next line, which must be of `kind` and end in a newline.
    fn expect(self: *Lines, kind: []const u8) Error!Line {
        const rest = self.text[self.at..];
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.MalformedBindings;
        if (end > max_line_bytes) return error.MalformedBindings;
        self.at += end + 1;
        var line: Line = .{ .text = rest[0..end] };
        if (!std.mem.eql(u8, try line.field(), kind)) return error.MalformedBindings;
        return line;
    }
};

/// One line's fields, read left to right.
const Line = struct {
    text: []const u8,
    at: usize = 0,

    /// The next field: one or more bytes up to a single space or the line's end.
    fn field(self: *Line) Error![]const u8 {
        if (self.at > self.text.len) return error.MalformedBindings;
        const rest = self.text[self.at..];
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        if (end == 0) return error.MalformedBindings;
        self.at += end + 1;
        return rest[0..end];
    }

    fn finish(self: *const Line) Error!void {
        if (self.at != self.text.len + 1) return error.MalformedBindings;
    }

    /// Whether every field has been read.
    fn ended(self: *const Line) bool {
        return self.at > self.text.len;
    }

    /// Three extents, each from 1 through `most`.
    fn extents(self: *Line, most: u32) Error![3]u32 {
        var read: [3]u32 = undefined;
        for (&read) |*extent| {
            extent.* = try self.number(u32);
            if (extent.* == 0 or extent.* > most) return error.MalformedBindings;
        }
        return read;
    }

    /// A number that may take a leading `-` when `negative` allows it, and never spells `-0`.
    fn signed(self: *Line, negative: bool) Error!i64 {
        if (!negative or self.at >= self.text.len or self.text[self.at] != '-') {
            return try self.number(u33);
        }
        self.at += 1;
        const magnitude = try self.number(u32);
        if (magnitude == 0) return error.MalformedBindings;
        return -@as(i64, magnitude);
    }

    /// A decimal number with no sign and no leading zero.
    fn number(self: *Line, comptime T: type) Error!T {
        const digits = try self.field();
        for (digits) |byte| {
            if (!std.ascii.isDigit(byte)) return error.MalformedBindings;
        }
        if (digits.len > 1 and digits[0] == '0') return error.MalformedBindings;
        return std.fmt.parseInt(T, digits, 10) catch error.MalformedBindings;
    }

    fn value(self: *Line, comptime E: type) Error!E {
        return std.meta.stringToEnum(E, try self.field()) orelse error.MalformedBindings;
    }

    /// A name of letters, digits, `_` and `-`, at most `max_name_bytes` long.
    fn name(self: *Line) Error![]const u8 {
        const spelled = try self.field();
        if (spelled.len > max_name_bytes) return error.MalformedBindings;
        for (spelled) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') {
                return error.MalformedBindings;
            }
        }
        return spelled;
    }
};

const scene_text =
    \\bindings 2
    \\target spirv-vulkan
    \\requires denorm_preserve_f32
    \\requires signed_zero_inf_nan_preserve_f32
    \\entry vertex lift
    \\push 0
    \\descriptors 0 0 0
    \\entry fragment paint
    \\push 0
    \\descriptors 0 0 0
    \\
;

/// First pixels' fill kernel as its version-1 interface states it: `fb` lent, three shared
/// tables, and six `u32` push members, five of them with a stated range. Beside it `swap` and
/// `blend` shape aliasing, and `divide` is a `bounded` kernel with one output a quotient
/// reaches.
const fill_text =
    \\bindings 2
    \\target spirv-vulkan
    \\requires denorm_preserve_f32
    \\requires signed_zero_inf_nan_preserve_f32
    \\requires rounding_mode_rte_f32
    \\entry kernel fill
    \\workgroup 8 8 1
    \\grid 32 16 1
    \\float exact
    \\push 24
    \\member 0 u32 1
    \\member 4 u32 1
    \\member 8 u32 1
    \\member 12 u32 1
    \\member 16 u32 1
    \\member 20 u32 1
    \\range 0 1 513
    \\range 4 1 257
    \\range 8 0 513
    \\range 12 0 4194305
    \\range 20 1 2
    \\binding 0 lent 524288
    \\binding 1 shared 526336
    \\binding 2 shared 65536
    \\binding 3 shared 4194304
    \\descriptors 4 0 4
    \\entry kernel swap
    \\workgroup 64 1 1
    \\grid 65535 1 1
    \\float exact
    \\push 0
    \\binding 0 lent 8
    \\binding 1 shared 8
    \\descriptors 2 0 2
    \\entry kernel blend
    \\workgroup 64 1 1
    \\grid 65535 1 1
    \\float exact
    \\push 0
    \\binding 0 shared 64
    \\binding 1 shared 64
    \\binding 2 lent 64
    \\descriptors 3 0 3
    \\entry kernel divide
    \\workgroup 64 1 1
    \\grid 4 1 1
    \\float bounded denorm_preserve_f32 signed_zero_inf_nan_preserve_f32 rounding_mode_rte_f32
    \\push 8
    \\member 0 f32 1
    \\member 4 i32 1
    \\range 4 -8 -1
    \\binding 0 lent 1024
    \\binding 1 shared 1024
    \\binding 2 lent 1024
    \\output 0 any
    \\output 2 exact
    \\descriptors 3 0 3
    \\
;

test "a stage build's report reads back entry by entry" {
    var report: Report = undefined;
    try parseBindings(scene_text, &report);
    try std.testing.expectEqual(@as(u32, 2), report.version);
    try std.testing.expectEqualStrings("spirv-vulkan", report.target);
    try std.testing.expect(report.requires.contains(.denorm_preserve_f32));
    try std.testing.expect(report.requires.contains(.signed_zero_inf_nan_preserve_f32));
    try std.testing.expect(!report.requires.contains(.rounding_mode_rte_f32));
    try std.testing.expectEqual(@as(usize, 2), report.entries().len);
    const lift = report.find("lift").?;
    try std.testing.expectEqual(Stage.vertex, lift.stage);
    try std.testing.expectEqual(@as(?[3]u32, null), lift.workgroup);
    try std.testing.expectEqual(@as(?[3]u32, null), lift.grid);
    try std.testing.expectEqual(@as(?Float, null), lift.float);
    try std.testing.expectEqual(@as(u32, 0), lift.push);
    try std.testing.expectEqual(@as(usize, 0), lift.bindings().len);
    try std.testing.expectEqual(@as(usize, 0), lift.ranges().len);
    try std.testing.expectEqual(@as(usize, 0), lift.outputs().len);
    try std.testing.expectEqual(Stage.fragment, report.find("paint").?.stage);
    try std.testing.expectEqual(@as(?*const Entry, null), report.find("shade"));
}

test "fill's report states its shape, grid bound, float mark, ranges and bindings" {
    var report: Report = undefined;
    try parseBindings(fill_text, &report);
    const fill = report.find("fill").?;
    try std.testing.expectEqual([3]u32{ 8, 8, 1 }, fill.workgroup.?);
    try std.testing.expectEqual([3]u32{ 32, 16, 1 }, fill.grid.?);
    try std.testing.expectEqual(Mark.exact, fill.float.?.mark);
    try std.testing.expectEqual(@as(usize, 0), fill.float.?.controls.count());
    try std.testing.expectEqual(@as(u32, 24), fill.push);
    try std.testing.expectEqual(@as(usize, 6), fill.members().len);
    for (fill.members(), 0..) |member, ordinal| {
        try std.testing.expectEqual(@as(u32, @intCast(4 * ordinal)), member.offset);
        try std.testing.expectEqual(Scalar.u32, member.scalar);
        try std.testing.expectEqual(@as(u32, 1), member.width);
    }
    const ranges = [_]Range{
        .{ .offset = 0, .low = 1, .high = 513 },
        .{ .offset = 4, .low = 1, .high = 257 },
        .{ .offset = 8, .low = 0, .high = 513 },
        .{ .offset = 12, .low = 0, .high = 4194305 },
        .{ .offset = 20, .low = 1, .high = 2 },
    };
    try std.testing.expectEqualSlices(Range, &ranges, fill.ranges());
    try std.testing.expect(fill.ranges()[0].contains(512));
    try std.testing.expect(!fill.ranges()[0].contains(513));
    try std.testing.expect(!fill.ranges()[4].contains(2));
    const bytes = [_]u64{ 524288, 526336, 65536, 4194304 };
    for (fill.bindings(), bytes, 0..) |binding, extent, number| {
        try std.testing.expectEqual(@as(u32, @intCast(number)), binding.number);
        try std.testing.expectEqual(if (number == 0) Class.lent else Class.shared, binding.class);
        try std.testing.expectEqual(extent, binding.bytes);
    }
    try std.testing.expectEqual(@as(usize, 0), fill.outputs().len);
    const descriptors: Descriptors = .{ .storage = 4, .sampled = 0, .resources = 4 };
    try std.testing.expectEqual(descriptors, fill.descriptors);
    try std.testing.expectEqual([3]u32{ 65535, 1, 1 }, report.find("swap").?.grid.?);
}

test "a bounded kernel states its controls, a signed range and each lent output's answer" {
    var report: Report = undefined;
    try parseBindings(fill_text, &report);
    const divide = report.find("divide").?;
    const float = divide.float.?;
    try std.testing.expectEqual(Mark.bounded, float.mark);
    try std.testing.expectEqual(report.requires, float.controls);
    const range: Range = .{ .offset = 4, .low = -8, .high = -1 };
    try std.testing.expectEqualSlices(Range, &.{range}, divide.ranges());
    const outputs = [_]Output{
        .{ .number = 0, .answer = .any },
        .{ .number = 2, .answer = .exact },
    };
    try std.testing.expectEqualSlices(Output, &outputs, divide.outputs());
}

fn bufferOf(id: contract.BackendObjectId) contract.BufferBinding {
    const handle: contract.BufferHandle = .{
        .id = id,
        .backend = .vulkan,
        .byte_size = 4194304,
        .ownership = .backend,
    };
    return .{
        .handle = handle,
        .access = .read_write,
        .ownership = .backend,
        .byte_size = handle.byte_size,
    };
}

test "a launch that binds a lent binding's buffer again refuses by name" {
    var report: Report = undefined;
    try parseBindings(fill_text, &report);
    const fill = report.find("fill").?;
    const one = bufferOf(1);
    const two = bufferOf(2);
    const three = bufferOf(3);
    const four = bufferOf(4);
    const aliased = error.LentBindingAliased;
    try std.testing.expectError(aliased, fill.admitLaunch(&.{ one, one, three, four }));
    try std.testing.expectError(aliased, fill.admitLaunch(&.{ one, two, three, one }));
    try fill.admitLaunch(&.{ one, two, three, four });
    try fill.admitLaunch(&.{ one, two, two, two });
    const mismatch = error.LaunchBindingMismatch;
    try std.testing.expectError(mismatch, fill.admitLaunch(&.{ one, two, three }));

    const swap = report.find("swap").?;
    try std.testing.expectError(aliased, swap.admitLaunch(&.{ two, two }));

    const blend = report.find("blend").?;
    try blend.admitLaunch(&.{ one, one, three });
    try std.testing.expectError(aliased, blend.admitLaunch(&.{ one, three, one }));

    var other_backend = one;
    other_backend.handle.backend = .cpu;
    try swap.admitLaunch(&.{ one, other_backend });
}

fn expectMalformed(text: []const u8) !void {
    var report: Report = undefined;
    try std.testing.expectError(error.MalformedBindings, parseBindings(text, &report));
}

test "a report that breaks the grammar or contradicts itself refuses by name" {
    const head = "bindings 2\ntarget spirv-vulkan\n";
    const stage_tail = "push 0\ndescriptors 0 0 0\n";
    const lift = head ++ "entry vertex lift\n";
    const kernel = "entry kernel fill\nworkgroup 8 8 1\ngrid 32 16 1\n";
    const fill = head ++ kernel ++ "float exact\npush 0\n";
    const denorm = "requires denorm_preserve_f32\n";
    try expectMalformed("");
    try expectMalformed("bindings 1\ntarget spirv-vulkan\nentry vertex lift\n" ++ stage_tail);
    try expectMalformed("bindings 3\ntarget spirv-vulkan\nentry vertex lift\n" ++ stage_tail);
    try expectMalformed(head);
    try expectMalformed(head ++ "entry vertex lift\n" ++ "push 0\ndescriptors 0 0 0");
    try expectMalformed(head ++ "entry vertex lift\n" ++ "push 0\ndescriptors 0 0 0\n\n");
    try expectMalformed(head ++ "entry vertex lift\n" ++ "push 0\ndescriptors  0 0 0\n");
    try expectMalformed(head ++ "entry vertex lift\n" ++ "push 0\ndescriptors 0 0 0 \n");
    try expectMalformed(head ++ "entry vertex lift\n" ++ "push 00\ndescriptors 0 0 0\n");
    try expectMalformed(head ++ "entry vertex lift\n" ++ "push 6\ndescriptors 0 0 0\n");
    try expectMalformed(head ++ "entry vertex lift\n" ++ "push 132\ndescriptors 0 0 0\n");
    try expectMalformed(head ++ "entry vertex lift\n" ++ "push +4\ndescriptors 0 0 0\n");
    try expectMalformed(head ++ "entry vertex lift\n" ++ "descriptors 0 0 0\n");
    try expectMalformed(head ++ "entry geometry lift\n" ++ stage_tail);
    try expectMalformed(head ++ "entry vertex li/ft\n" ++ stage_tail);
    try expectMalformed(lift ++ stage_tail ++ "entry fragment lift\n" ++ stage_tail);
    try expectMalformed(head ++ "requires denorm_preserve_f64\nentry vertex lift\n" ++ stage_tail);
    try expectMalformed(head ++ denorm ++ denorm ++ "entry vertex lift\n" ++ stage_tail);
    try expectMalformed(lift ++ stage_tail ++ denorm);
    try expectMalformed(head ++ "entry vertex lift\nworkgroup 8 8 1\n" ++ stage_tail);
    try expectMalformed(head ++ "entry kernel fill\n" ++ stage_tail);
    try expectMalformed(head ++ "entry kernel fill\nworkgroup 8 0 1\n" ++ stage_tail);
    try expectMalformed(head ++ "entry kernel fill\nworkgroup 8 8\n" ++ stage_tail);
    try expectMalformed(head ++ "entry vertex lift\npush 16\nmember 4 f32 2\ndescriptors 0 0 0\n");
    try expectMalformed(head ++ "entry vertex lift\npush 16\nmember 4 f32 3\ndescriptors 0 0 0\n");
    try expectMalformed(head ++ "entry vertex lift\npush 16\nmember 0 f32 5\ndescriptors 0 0 0\n");
    try expectMalformed(head ++ "entry vertex lift\npush 16\nmember 16 f32 1\ndescriptors 0 0 0\n");
    try expectMalformed(lift ++ "push 16\nmember 4 u32 1\nmember 0 u32 1\ndescriptors 0 0 0\n");
    try expectMalformed(head ++ "entry vertex lift\npush 16\nmember 0 u64 1\ndescriptors 0 0 0\n");
    try expectMalformed(fill ++ "binding 1 lent 4\ndescriptors 1 0 1\n");
    try expectMalformed(fill ++ "binding 0 lent 0\ndescriptors 1 0 1\n");
    try expectMalformed(fill ++ "binding 0 parameters 256\nbinding 1 lent 4\ndescriptors 2 0 2\n");
    try expectMalformed(fill ++ "binding 0 lent 4\ndescriptors 2 0 2\n");
    try expectMalformed(fill ++ "binding 0 lent 4\ndescriptors 1 1 2\n");
    try expectMalformed(fill ++ "binding 0 lent 4\ndescriptors 1 0 2\n");
    try expectMalformed(fill ++ "binding 0 texture 4\ndescriptors 1 0 1\n");
    try expectMalformed(fill ++ "descriptors 0 0 0\nsampler 0\n");
}

test "a kernel's grid bound, float mark, ranges and outputs refuse where they contradict" {
    const head = "bindings 2\ntarget spirv-vulkan\n";
    const rte = "requires rounding_mode_rte_f32\n";
    const shaped = "entry kernel k\nworkgroup 8 8 1\n";
    const kernel = shaped ++ "grid 32 16 1\n";
    const exact = head ++ kernel ++ "float exact\n";
    const empty = "push 0\ndescriptors 0 0 0\n";
    const pushed = "push 8\nmember 0 u32 1\nmember 4 i32 1\n";
    const tail = "descriptors 0 0 0\n";
    const lent = "push 0\nbinding 0 shared 4\nbinding 1 lent 4\n";
    const bounded = head ++ kernel ++ "float bounded\n" ++ lent;
    // A kernel's grid bound and float mark are each one line, in their place, on a kernel only.
    try expectMalformed(head ++ shaped ++ "float exact\n" ++ empty);
    try expectMalformed(head ++ kernel ++ empty);
    try expectMalformed(head ++ shaped ++ "float exact\ngrid 32 16 1\n" ++ empty);
    try expectMalformed(head ++ "entry vertex lift\ngrid 1 1 1\n" ++ empty);
    try expectMalformed(head ++ "entry vertex lift\nfloat exact\n" ++ empty);
    try expectMalformed(head ++ shaped ++ "grid 32 16\nfloat exact\n" ++ empty);
    try expectMalformed(head ++ shaped ++ "grid 32 0 1\nfloat exact\n" ++ empty);
    try expectMalformed(head ++ shaped ++ "grid 65536 1 1\nfloat exact\n" ++ empty);
    try expectMalformed(head ++ shaped ++ "grid 32 16 1 1\nfloat exact\n" ++ empty);
    // A float line's mark is known, and its controls are distinct, in order and required.
    try expectMalformed(head ++ kernel ++ "float\n" ++ empty);
    try expectMalformed(head ++ kernel ++ "float approximate\n" ++ empty);
    try expectMalformed(head ++ kernel ++ "float exact rounding_mode_rte_f32\n" ++ empty);
    try expectMalformed(head ++ rte ++ kernel ++ "float exact rounding_mode_rte_f32 \n" ++ empty);
    const both = "requires denorm_preserve_f32\n" ++ rte;
    const reversed = "float exact rounding_mode_rte_f32 denorm_preserve_f32\n";
    try expectMalformed(head ++ both ++ kernel ++ reversed ++ empty);
    const twice = "float exact rounding_mode_rte_f32 rounding_mode_rte_f32\n";
    try expectMalformed(head ++ rte ++ kernel ++ twice ++ empty);
    // A range names one scalar integer member, in member order, with low below high and both
    // inside the member's type. Only an `i32` bound takes a sign.
    try expectMalformed(exact ++ pushed ++ "range 2 0 1\n" ++ tail);
    try expectMalformed(exact ++ pushed ++ "range 8 0 1\n" ++ tail);
    try expectMalformed(exact ++ pushed ++ "range 4 0 1\nrange 0 0 1\n" ++ tail);
    try expectMalformed(exact ++ pushed ++ "range 0 0 1\nrange 0 1 2\n" ++ tail);
    try expectMalformed(exact ++ pushed ++ "range 0 5 5\n" ++ tail);
    try expectMalformed(exact ++ pushed ++ "range 0 6 5\n" ++ tail);
    try expectMalformed(exact ++ pushed ++ "range 0 -1 5\n" ++ tail);
    try expectMalformed(exact ++ pushed ++ "range 0 0 4294967297\n" ++ tail);
    try expectMalformed(exact ++ pushed ++ "range 4 -2147483649 0\n" ++ tail);
    try expectMalformed(exact ++ pushed ++ "range 4 0 2147483649\n" ++ tail);
    try expectMalformed(exact ++ pushed ++ "range 4 -0 1\n" ++ tail);
    try expectMalformed(exact ++ pushed ++ "range 4 - 1\n" ++ tail);
    try expectMalformed(exact ++ pushed ++ "range 0 0 1 2\n" ++ tail);
    try expectMalformed(exact ++ "push 4\nmember 0 f32 1\nrange 0 0 1\n" ++ tail);
    try expectMalformed(exact ++ "push 8\nmember 0 u32 2\nrange 0 0 1\n" ++ tail);
    try expectMalformed(exact ++ pushed ++ "binding 0 lent 4\nrange 0 0 1\ndescriptors 1 0 1\n");
    try expectMalformed(head ++ "entry vertex lift\npush 4\nmember 0 u32 1\nrange 0 0 1\n" ++ tail);
    var report: Report = undefined;
    try parseBindings(exact ++ pushed ++ "range 0 0 4294967296\nrange 4 -2147483648 2147483648\n" ++
        tail, &report);
    const widest = report.find("k").?.ranges();
    try std.testing.expectEqual(@as(i64, 1) << 32, widest[0].high);
    try std.testing.expectEqual(-(@as(i64, 1) << 31), widest[1].low);
    // A bounded kernel marks each lent binding once, in number order, and an exact one marks none.
    try parseBindings(bounded ++ "output 1 any\ndescriptors 2 0 2\n", &report);
    try expectMalformed(bounded ++ "descriptors 2 0 2\n");
    try expectMalformed(bounded ++ "output 0 any\ndescriptors 2 0 2\n");
    try expectMalformed(bounded ++ "output 1 maybe\ndescriptors 2 0 2\n");
    try expectMalformed(bounded ++ "output 1 any\noutput 1 any\ndescriptors 2 0 2\n");
    try expectMalformed(exact ++ lent ++ "output 1 exact\ndescriptors 2 0 2\n");
    const stage = head ++ "entry vertex lift\n" ++ lent;
    try expectMalformed(stage ++ "output 1 exact\ndescriptors 2 0 2\n");
}

test "a report past a capacity refuses by name" {
    var report: Report = undefined;
    const text = try std.testing.allocator.alloc(u8, max_text_bytes);
    defer std.testing.allocator.free(text);
    var writer: std.Io.Writer = .fixed(text);
    try writer.writeAll("bindings 2\ntarget spirv-vulkan\n");
    for (0..max_entries + 1) |ordinal| {
        try writer.print("entry vertex e{d}\npush 0\ndescriptors 0 0 0\n", .{ordinal});
    }
    const exceeded = error.BindingsCapacityExceeded;
    try std.testing.expectError(exceeded, parseBindings(writer.buffered(), &report));

    writer = .fixed(text);
    try writer.writeAll("bindings 2\ntarget spirv-vulkan\n");
    try writer.writeAll("entry kernel wide\nworkgroup 1 1 1\ngrid 1 1 1\nfloat exact\npush 0\n");
    for (0..max_bindings + 1) |number| try writer.print("binding {d} shared 4\n", .{number});
    try writer.print("descriptors {d} 0 {d}\n", .{ max_bindings + 1, max_bindings + 1 });
    try std.testing.expectError(exceeded, parseBindings(writer.buffered(), &report));
}

test "the longest report the capacities admit fits the text bound and reads back" {
    var report: Report = undefined;
    const text = try std.testing.allocator.alloc(u8, max_text_bytes);
    defer std.testing.allocator.free(text);
    var writer: std.Io.Writer = .fixed(text);
    try writer.writeAll("bindings 2\ntarget spirv-vulkan\n");
    for (std.enums.values(Control)) |control| {
        try writer.print("requires {s}\n", .{@tagName(control)});
    }
    const name: [max_name_bytes - 2]u8 = @splat('k');
    for (0..max_entries) |ordinal| {
        try writer.print("entry kernel {s}{d:0>2}\n", .{ &name, ordinal });
        try writer.writeAll("workgroup 4294967295 4294967295 4294967295\ngrid 65535 65535 65535\n");
        try writer.writeAll("float bounded");
        for (std.enums.values(Control)) |control| try writer.print(" {s}", .{@tagName(control)});
        try writer.print("\npush {d}\n", .{max_push_bytes});
        for (0..max_members) |member| try writer.print("member {d} i32 1\n", .{4 * member});
        for (0..max_members) |member| {
            try writer.print("range {d} -2147483648 2147483648\n", .{4 * member});
        }
        for (0..max_bindings) |number| {
            try writer.print("binding {d} lent {d}\n", .{ number, std.math.maxInt(u64) });
        }
        for (0..max_bindings) |number| try writer.print("output {d} any\n", .{number});
        try writer.print("descriptors {d} 0 {d}\n", .{ max_bindings, max_bindings });
    }
    try parseBindings(writer.buffered(), &report);
    try std.testing.expectEqual(@as(usize, max_entries), report.entries().len);
    const last = report.entries()[max_entries - 1];
    try std.testing.expectEqual(@as(usize, max_members), last.ranges().len);
    try std.testing.expectEqual(@as(usize, max_bindings), last.outputs().len);
}

test "a missing or overlong bindings file is refused by name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text = try std.testing.allocator.alloc(u8, max_text_bytes + 1);
    defer std.testing.allocator.free(text);
    var report: Report = undefined;
    const absent = readBindings(io, tmp.dir, "absent", text, &report);
    try std.testing.expectError(error.MissingBindings, absent);
    try tmp.dir.writeFile(io, .{ .sub_path = "scene.bindings", .data = scene_text });
    try readBindings(io, tmp.dir, "scene", text, &report);
    try std.testing.expectEqual(Stage.fragment, report.find("paint").?.stage);
    const long = try std.testing.allocator.alloc(u8, max_text_bytes + 1);
    defer std.testing.allocator.free(long);
    @memset(long, '\n');
    try tmp.dir.writeFile(io, .{ .sub_path = "long.bindings", .data = long });
    const overlong = readBindings(io, tmp.dir, "long", text, &report);
    try std.testing.expectError(error.BindingsCapacityExceeded, overlong);
}
