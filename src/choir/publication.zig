const std = @import("std");
const choir = @import("choir");
const operation = choir.product.operation;
const revision = choir.product.revision;

pub const Stage = enum(u8) {
    semantic,
    contract,
    tensor,
    dispatch,
    memory,
    kernel,
    target,

    pub fn name(self: Stage) []const u8 {
        return switch (self) {
            .semantic => "accy.semantic",
            .contract => "accy.contract",
            .tensor => "accy.tensor_opt",
            .dispatch => "accy.dispatch",
            .memory => "accy.memory",
            .kernel => "accy.kernel/gpu",
            .target => "accy.target",
        };
    }

    pub fn schema(comptime self: Stage) revision.record.Version {
        return .{ .name = "accy-" ++ @tagName(self) ++ "-record", .version = 1 };
    }
};

/// An opaque handle holds one reference to one stage record of the chosen
/// stage, together with the allocator that made the handle, so a caller can
/// pass it on or reopen it with the stage checked at compile time.
/// `fromRevision` returns `error.WrongStage` when the record belongs to another
/// stage, checks the record's schema gates, and then takes a reference. The
/// handle holds no compiler state and no cache, and those live in the job that
/// runs the stage. `deinit` drops the reference and frees the handle, and
/// `retain` makes a second handle over the same record. `plan` decodes the
/// stage's typed plan for the dispatch, memory, kernel and target stages, and
/// asking for it on another stage is a compile error.
pub fn Module(comptime stage: Stage) type {
    return opaque {
        const Self = @This();
        const Data = struct { allocator: std.mem.Allocator, product: operation.Product };

        pub fn fromRevision(
            allocator: std.mem.Allocator,
            published: *const revision.Revision,
        ) !*Self {
            if (!std.mem.eql(u8, published.address().stage, stage.name())) {
                return error.WrongStage;
            }
            try published.requireGates(&.{ operation.schema_identity, stage.schema() });
            const retained = try published.retain();
            errdefer retained.release();
            const data = try allocator.create(Data);
            data.* = .{ .allocator = allocator, .product = .{ .revision = retained } };
            return @ptrCast(data);
        }

        pub fn deinit(self: *Self) void {
            const data: *Data = @ptrCast(@alignCast(self));
            data.product.release();
            data.allocator.destroy(data);
        }

        pub fn retain(self: *const Self, allocator: std.mem.Allocator) !*Self {
            return fromRevision(allocator, self.record());
        }

        pub fn record(self: *const Self) *const revision.Revision {
            const data: *const Data = @ptrCast(@alignCast(self));
            return data.product.revision;
        }

        pub fn plan(
            self: *const Self,
            allocator: std.mem.Allocator,
            limits: choir.bytecode.image.Limits,
        ) !@import("root.zig").record.codec.Decoded(Plan(stage)) {
            if (Plan(stage) == void) @compileError("this stage has no separate plan record");
            const image = try self.open(allocator, limits);
            defer image.destroy();
            return @import("root.zig").record.codec.decode(
                allocator,
                Plan(stage),
                stage,
                image.stage(),
            );
        }

        pub fn eql(self: *const Self, other: *const Self) bool {
            return self.record().eql(other.record());
        }

        pub fn open(
            self: *const Self,
            allocator: std.mem.Allocator,
            limits: choir.bytecode.image.Limits,
        ) !*choir.product.entity.Image {
            const data: *const Data = @ptrCast(@alignCast(self));
            return data.product.open(allocator, limits);
        }
    };
}

/// Returns five fixed bytes, a version of 1 and the stage's number, for the
/// semantic, contract and tensor stages, and any other stage is a compile
/// error. The compiler writes these bytes as the stage payload of the first
/// three stages, and the checker compares against them. The first three stages
/// keep only their compiler image and store no plan and no cached analysis, so
/// these five bytes are their whole payload. The checker refuses a stage record
/// of one of those stages with `error.InvalidStageRecord` when its payload
/// differs from these bytes.
pub fn irRecord(comptime stage: Stage) [5]u8 {
    comptime requireIrStage(stage);
    return .{ 1, 0, 0, 0, @backingInt(stage) };
}

fn requireIrStage(comptime stage: Stage) void {
    switch (stage) {
        .semantic, .contract, .tensor => {},
        else => @compileError("this stage requires its complete typed plan schema"),
    }
}

pub fn Plan(comptime stage: Stage) type {
    const records = @import("root.zig").record;
    return switch (stage) {
        .dispatch => records.dispatch.Record,
        .memory => records.memory.Record,
        .kernel => records.kernel.Record,
        .target => records.target.Record,
        else => void,
    };
}
