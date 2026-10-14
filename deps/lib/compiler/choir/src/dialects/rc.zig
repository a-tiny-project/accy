const std = @import("std");
const ir = @import("../core/root.zig");
const effects = ir.interfaces.effects;

pub const attr_names = struct {
    pub const ownership = "rc.ownership";
};

pub const RcDialect = struct {
    pub const name = "rc";
    const op_templates = ir.dialects.operationTemplate.dialect(@This());
    pub const spec = ir.dialects.dialectSpec(@This(), .{});

    pub const RetainOp: type = op_templates.unarySameType(
        "retain",
        ownershipOptions(.retain, .owned),
    );

    pub const ReleaseOp: type = op_templates.unaryNoResult(
        "release",
        ownershipOptions(.release, .none),
    );

    pub const BorrowOp: type = op_templates.unarySameTypeStringAttr(
        "borrow",
        attr_names.ownership,
        "borrowed",
        ownershipOptions(.borrow, .borrowed),
    );

    pub const MoveOp: type = op_templates.unarySameTypeStringAttr(
        "move",
        attr_names.ownership,
        "owned",
        ownershipOptions(.move, .transferred),
    );
};

fn ownershipOptions(
    comptime kind: effects.EventKind,
    comptime ownership: effects.Ownership,
) ir.dialects.opSpec.Options {
    const Declaration = struct {
        fn enumerate(subject: effects.EffectSubject, collector: *effects.Collector) void {
            if (subject.operandCount() != 1) return;
            collector.append(.{ .requirement = .{ .kind = .live, .subject = .{ .operand = 0 } } });
            collector.append(.{ .event = .{ .kind = kind, .resource = .{
                .subject = .{ .operand = 0 },
            } } });
            if (kind == .release) {
                collector.append(.{ .requirement = .{
                    .kind = .callee_contract,
                    .subject = .{ .operand = 0 },
                } });
                collector.append(.{ .event = .{ .kind = .free, .resource = .{
                    .subject = .{ .operand = 0 },
                } } });
            }
            for (0..subject.resultCount()) |index| collector.append(.{ .result = .{
                .index = index,
                .alias = .{ .operand = 0 },
                .ownership = ownership,
            } });
        }
    };
    return .{ .interfaces = &.{effects.EffectOpInterface.entryFor(.{
        .capacity = .{ .entries = 4, .per_result = 1 },
        .enumerate = Declaration.enumerate,
    })} };
}
