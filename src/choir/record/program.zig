const std = @import("std");
const choir = @import("choir");
const model = @import("../../kernel/model/root.zig");
const records = @import("root.zig");
const schedule = model.core.schedule;
const Configuration = choir.product.operation.Configuration;

/// The stored form of one generated kernel program: its own compiler bytecode,
/// the number of its function within that bytecode, its parameters, its loop
/// and thread structure, its launch shape and its arithmetic policy. A kernel
/// stage record carries one of these for each kernel it generated. The function
/// number counts operations in this program's own bytecode, which is separate
/// from the bytecode of the whole stage.
pub const Record = struct {
    image: []const u8,
    function: u32,
    params: []const model.Param,
    schedule: schedule.Record,
    launch: schedule.Launch,
    arithmetic: choir.product.recipe.ArithmeticPolicy,
};

/// Copies each generated program into its record for the kernel stage: verifies
/// the program, encodes its bytecode, and fails with `error.RecordLimit` when
/// that bytecode exceeds the configured image size. The call numbers the
/// program's operations, snapshots its schedule, encodes the whole record,
/// decodes it again and compares the result with the live program. The caller
/// receives the decoded copy, which owns its own memory apart from `source`.
pub fn capture(
    allocator: std.mem.Allocator,
    source: *const model.Program,
    comptime configuration: Configuration,
) !records.codec.Decoded(Record) {
    comptime coverage();
    const root = source.kernelModule();
    var context = try choir.ir.Context.init(allocator, configuration.context);
    defer context.deinit(allocator);
    context.arithmetic_policy = root.context.arithmetic_policy;
    try configuration.register(&context);
    try choir.ir.verifyOperation(root, configuration.verify);
    const image = try choir.bytecode.qualification.encode(
        allocator,
        root,
        &.{},
        &context,
        configuration.codec,
    );
    defer allocator.free(image);
    if (image.len > configuration.image.bytes) return error.RecordLimit;
    const entity_limit = configuration.image.entities;
    var references = try records.reference.Index.init(allocator, root, entity_limit);
    defer references.deinit();
    var snapshot = try source.scheduleSnapshot(allocator);
    defer snapshot.deinit(allocator);
    const projected = Record{
        .image = image,
        .function = (try references.operation(source.storage.kernel.func().op)).ordinal,
        .params = source.params(),
        .schedule = try snapshot.record(),
        .launch = try source.launch(),
        .arithmetic = root.context.arithmetic_policy,
    };
    const bytes = try records.codec.encode(allocator, Record, .kernel, projected, &references);
    defer allocator.free(bytes);
    var decoded = try records.codec.decode(allocator, Record, .kernel, bytes);
    errdefer decoded.deinit();
    try records.codec.compare(decoded.value, projected, &references);
    return decoded;
}

/// Validates each stored program for the checker before a record is accepted:
/// decodes the bytecode into a scratch context, verifies it, and checks that
/// the function number is in range (`error.UnboundProductInput`). The function
/// must be a kernel with a body, named `entry_name`, whose arguments match the
/// stored parameters in count and type. The stored launch shape must match the
/// result of replaying the schedule, and any mismatch is
/// `error.InvalidStageRecord`.
pub fn validate(
    allocator: std.mem.Allocator,
    value: Record,
    entry_name: []const u8,
    comptime configuration: Configuration,
) !void {
    const image = try choir.bytecode.image.Index.create(
        allocator,
        value.image,
        configuration.image,
    );
    defer image.destroy();
    if (value.function >= image.view().operations.len) return error.UnboundProductInput;
    var context = try choir.ir.Context.init(allocator, configuration.context);
    defer context.deinit(allocator);
    context.arithmetic_policy = value.arithmetic;
    try configuration.register(&context);
    var decoded = try choir.bytecode.decodeModule(allocator, &context, value.image);
    defer decoded.deinit();
    try choir.ir.verifyOperation(decoded.module, configuration.verify);
    var references = try records.reference.Index.init(
        allocator,
        decoded.module,
        configuration.image.entities,
    );
    defer references.deinit();
    const function = try selectedFunction(&references, value.function);
    const name = function.getName() orelse return error.InvalidStageRecord;
    if (!std.mem.eql(u8, name, entry_name)) return error.InvalidStageRecord;
    if (!function.isKernel() or !function.hasBody()) return error.InvalidStageRecord;
    if (function.getNumArguments() != value.params.len) return error.InvalidStageRecord;
    for (value.params, function.getArguments()) |param, argument| {
        if (!argument.type.eql(try param.getType(&context))) return error.InvalidStageRecord;
    }
    var replayed = try schedule.Schedule.init(allocator, value.schedule.replay_limits);
    defer replayed.deinit(allocator);
    try replayed.replay(value.schedule);
    if (!std.meta.eql(try replayed.launch(), value.launch)) return error.InvalidStageRecord;
}

/// Restores a working kernel program from a stored record for a later compile:
/// rebuilds the whole program in new storage sized from the record, then
/// verifies it, checks its name, and replays its schedule. Storage that runs
/// out gives `error.WorkExhausted`. The returned program copies the bytecode,
/// the parameters and the schedule, and keeps no pointer into `value`.
pub fn restore(
    allocator: std.mem.Allocator,
    value: Record,
    entry_name: []const u8,
    comptime configuration: Configuration,
) !model.Program {
    const limits = try restorationLimits(value, entry_name, configuration);
    const capacity = model.program.Capacity.derive(limits) catch return error.WorkOverflow;
    var storage = try model.core.builder.Storage.init(allocator, limits.raw());
    var transferred = false;
    defer if (!transferred) storage.deinit(allocator);
    const program = restoreIn(
        allocator,
        value,
        entry_name,
        &storage,
        capacity,
        configuration,
    ) catch |err| {
        return if (storage.context.exhaustedSegment() != null) error.WorkExhausted else err;
    };
    transferred = true;
    return program;
}

fn restorationLimits(
    value: Record,
    entry_name: []const u8,
    comptime configuration: Configuration,
) !model.program.Limits {
    var names: usize = 0;
    for (value.schedule.axes) |axis| {
        names = std.math.add(usize, names, axis.name.len) catch return error.WorkOverflow;
    }
    for (value.schedule.steps) |step| {
        if (step == .axis) {
            names = std.math.add(usize, names, step.axis.name.len) catch return error.WorkOverflow;
        }
    }
    return .{
        .context = configuration.context,
        .parameters = value.params.len,
        .kernel_name_bytes = entry_name.len,
        .temporary_values = 0,
        .temporary_types = 0,
        .schedule = value.schedule.replay_limits,
        .snapshot = .{
            .axes = value.schedule.axes.len,
            .steps = value.schedule.steps.len,
            .name_bytes = names,
        },
    };
}

fn restoreIn(
    allocator: std.mem.Allocator,
    value: Record,
    entry_name: []const u8,
    storage: *model.core.builder.Storage,
    capacity: model.program.Capacity,
    comptime configuration: Configuration,
) !model.Program {
    const image = try choir.bytecode.image.Index.create(
        allocator,
        value.image,
        configuration.image,
    );
    defer image.destroy();
    if (value.function >= image.view().operations.len) return error.UnboundProductInput;
    storage.context.arithmetic_policy = value.arithmetic;
    try configuration.register(storage.context);
    var decoded = try choir.bytecode.decodeModule(
        choir.ir.context.operationAllocator(storage.context),
        storage.context,
        value.image,
    );
    errdefer decoded.deinit();
    errdefer decoded.module.erase();
    try choir.ir.verifyOperation(decoded.module, configuration.verify);
    var references = try records.reference.Index.init(
        allocator,
        decoded.module,
        configuration.image.entities,
    );
    defer references.deinit();
    const function = try selectedFunction(&references, value.function);
    const name = function.getName() orelse return error.InvalidStageRecord;
    if (!std.mem.eql(u8, name, entry_name)) return error.InvalidStageRecord;
    var replayed = try schedule.Schedule.init(allocator, value.schedule.replay_limits);
    errdefer replayed.deinit(allocator);
    try replayed.replay(value.schedule);
    if (!std.meta.eql(try replayed.launch(), value.launch)) return error.InvalidStageRecord;
    const kernel = try model.Kernel.fromDecoded(
        allocator,
        storage.*,
        decoded,
        function,
        value.params,
    );
    return model.Program.init(kernel, replayed, capacity);
}

fn selectedFunction(
    references: *const records.reference.Index,
    ordinal: u32,
) !choir.dialects.FuncDialect.FuncOp {
    var selected: ?*choir.ir.Operation = null;
    var entries = references.operations.iterator();
    for (0..references.operations.count()) |_| {
        const entry = entries.next().?;
        if (entry.value_ptr.ordinal == ordinal) selected = entry.key_ptr.*;
    }
    const operation = selected orelse return error.UnboundProductInput;
    const FuncOp = choir.dialects.FuncDialect.FuncOp;
    if (!std.mem.eql(u8, operation.name.name, FuncOp.operation_name)) {
        return error.InvalidStageRecord;
    }
    return .{ .op = operation };
}

fn coverage() void {
    const require = choir.product.revision.record.requireFields;
    require(model.Program, &.{ "capacity", "storage" });
    require(@FieldType(model.Program, "storage"), &.{ "kernel", "schedule" });
    require(model.Kernel, &.{ "allocator", "capacity", "storage", "state" });
    const State = @typeInfo(@FieldType(model.Kernel, "state")).pointer.child;
    require(State, &.{ "ctx", "module", "func", "params", "decoded" });
    require(schedule.Snapshot, &.{
        "phase",
        "capacity",
        "storage",
        "version",
        "axes_storage",
        "axes_len",
        "steps_storage",
        "steps_len",
        "names_storage",
        "names_len",
        "replay_limits",
        "captured",
    });
}
