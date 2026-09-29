const std = @import("std");
const x86 = @import("root.zig");

test "x86 signed conditions retain displacement widths and byte destinations" {
    const branches = [_]x86.Operation{ .jl, .jge, .jle, .jg };
    const sets = [_]x86.Operation{ .setl, .setge, .setle, .setg };
    for (branches, sets, 0..) |operation, set, index| {
        const condition: u8 = @intCast(0xc + index);
        const short = try x86.decode(&.{ 0x70 + condition, 0xf8 });
        const near = try x86.decode(&.{ 0x0f, 0x80 + condition, 0xf8, 0xff, 0xff, 0xff });
        try std.testing.expectEqual(operation, short.operation);
        try std.testing.expectEqual(operation, near.operation);
        try std.testing.expectEqual(@as(i32, -8), short.relative.?);
        try std.testing.expectEqual(@as(i32, -8), near.relative.?);
        try std.testing.expectEqual(@as(u4, 2), short.bytes);
        try std.testing.expectEqual(@as(u4, 6), near.bytes);
        const byte = try x86.decode(&.{ 0x40, 0x0f, 0x90 + condition, 0xc4 });
        try std.testing.expectEqual(set, byte.operation);
        try std.testing.expectEqual(x86.Access.write, byte.operand_access);
        try std.testing.expectEqual(
            x86.Register{ .number = 4, .lane = .low8 },
            byte.operand.register,
        );
    }
}

test "x86 two operand multiplication retains its read and write destination" {
    const decoded = try x86.decode(&.{ 0x48, 0x0f, 0xaf, 0xe1 });
    try std.testing.expectEqual(x86.Operation.imul, decoded.operation);
    try std.testing.expectEqual(x86.Access.read_write, decoded.register_access);
    try std.testing.expectEqual(x86.Access.read, decoded.operand_access);
    try std.testing.expectEqual(x86.Role.rsp, decoded.register.?.role());
    try std.testing.expectEqual(@as(u3, 0), decoded.implicit_count);
}

test "x86 form key has a canonical little-endian encoding" {
    const form = x86.Form{
        .prefix = .rex_w,
        .opcode = 0x89,
        .width = .qword,
        .mode = .register,
        .register_role = .ordinary,
        .register_access = .read,
        .operand_role = .ordinary,
        .operand_access = .write,
    };
    const encoded = form.encodedKey();
    try std.testing.expectEqual(form.key(), std.mem.readInt(u64, &encoded, .little));
}

test "x86 byte registers retain high and REX low lanes" {
    const ah = try x86.decode(&.{ 0xb4, 0x7f });
    try std.testing.expectEqual(
        x86.Register{ .number = 0, .lane = .high8 },
        ah.embedded.?,
    );
    const spl = try x86.decode(&.{ 0x40, 0xb4, 0x7f });
    try std.testing.expectEqual(
        x86.Register{ .number = 4, .lane = .low8 },
        spl.embedded.?,
    );
}

test "x86 memory operands retain SIB and RIP-relative topology" {
    const indexed = try x86.decode(&.{ 0x48, 0x8b, 0x44, 0x8d, 0xf8 });
    try std.testing.expectEqual(x86.Operation.mov, indexed.operation);
    try std.testing.expectEqualDeep(
        x86.Memory{
            .kind = .base_indexed,
            .width = .qword,
            .base = .{ .number = 5, .lane = .qword },
            .index = .{ .number = 1, .lane = .qword },
            .scale = .four,
            .displacement = -8,
        },
        indexed.operand.memory,
    );
    const relative = try x86.decode(&.{ 0x48, 0x8b, 0x05, 0x34, 0x12, 0x00, 0x00 });
    try std.testing.expectEqual(x86.AddressKind.rip_relative, relative.operand.memory.kind);
    try std.testing.expectEqual(@as(i32, 0x1234), relative.operand.memory.displacement);
}

test "x86 immediates retain encoding and extension" {
    const instruction = try x86.decode(&.{ 0x48, 0x83, 0xc0, 0xff });
    try std.testing.expectEqual(x86.Operation.add, instruction.operation);
    try std.testing.expectEqual(x86.RegisterLane.qword, instruction.operand.register.lane);
    try std.testing.expectEqual(
        x86.Immediate{ .value = 0xff, .encoded_bytes = 1, .extension = .sign },
        instruction.immediate.?,
    );
    try std.testing.expectEqual(@as(i64, -1), instruction.immediate.?.signed());
}

test "x86 mixed-width operands retain their source lane" {
    const register = try x86.decode(&.{ 0x48, 0x0f, 0xb7, 0xc1 });
    try std.testing.expectEqual(x86.Operation.movzx, register.operation);
    try std.testing.expectEqual(x86.RegisterLane.qword, register.register.?.lane);
    try std.testing.expectEqual(x86.RegisterLane.word, register.operand.register.lane);

    const memory = try x86.decode(&.{ 0x48, 0x0f, 0xb6, 0x01 });
    try std.testing.expectEqual(x86.Width.byte, memory.operand.memory.width);
    try std.testing.expectEqual(@as(u4, 1), memory.operand.memory.base.?.number);

    const word = try x86.decode(&.{ 0x66, 0x0f, 0xb7, 0xc1 });
    try std.testing.expectEqual(x86.RegisterLane.word, word.register.?.lane);
    try std.testing.expectEqual(x86.RegisterLane.word, word.operand.register.lane);
}

test "x86 ModRM byte registers retain high lanes" {
    const source = try x86.decode(&.{ 0x88, 0xe0 });
    try std.testing.expectEqual(
        x86.Register{ .number = 0, .lane = .high8 },
        source.register.?,
    );
    const destination = try x86.decode(&.{ 0x8a, 0xe0 });
    try std.testing.expectEqual(
        x86.Register{ .number = 0, .lane = .high8 },
        destination.register.?,
    );
}

test "x86 operation identity distinguishes legacy aliases" {
    const xchg = try x86.decode(&.{ 0x66, 0x90 });
    try std.testing.expectEqual(x86.Operation.xchg, xchg.operation);
    try std.testing.expectEqual(x86.Access.read_write, xchg.register_access);
    try std.testing.expectEqual(x86.RegisterLane.word, xchg.register.?.lane);
    try std.testing.expectEqual(x86.Access.read_write, xchg.embedded_access);
    try std.testing.expectEqual(
        x86.Operation.seto,
        (try x86.decode(&.{ 0x40, 0x0f, 0x90, 0xc0 })).operation,
    );
}

test "x86 retains compiler string stores" {
    const store = try x86.decode(&.{ 0xf3, 0xab });
    try std.testing.expectEqual(x86.Operation.stos, store.operation);
    try std.testing.expectEqual(x86.Width.dword, store.form.width);
    try std.testing.expectEqual(x86.Prefix.repeat, store.form.prefix);
    try std.testing.expectEqual(@as(u3, 3), store.implicit_count);
}

test "x86 retains compiler maximum-length padding" {
    const aligned = try x86.decode(&.{
        0x66, 0x66, 0x66, 0x2e, 0x0f, 0x1f,
        0x84, 0x00, 0x00, 0x00, 0x00, 0x00,
    });
    try std.testing.expectEqual(x86.Operation.nop, aligned.operation);
    try std.testing.expectEqual(x86.Prefix.operand16_3_cs, aligned.form.prefix);
    const padding = try x86.decode(&.{
        0x66, 0x66, 0x66, 0x66, 0x66, 0x2e, 0x0f,
        0x1f, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00,
    });
    try std.testing.expectEqual(x86.Operation.nop, padding.operation);
    try std.testing.expectEqual(x86.Prefix.operand16_5_cs, padding.form.prefix);
    try std.testing.expectEqual(@as(u8, 14), padding.bytes);
}

test "x86 explicit access is independent of the policy form" {
    const swap = try x86.decode(&.{ 0x0f, 0xc8 });
    try std.testing.expectEqual(x86.Access.write, swap.form.embedded_access);
    try std.testing.expectEqual(x86.Access.read_write, swap.embedded_access);

    const vector = try x86.decode(&.{ 0x0f, 0x10, 0xc1 });
    try std.testing.expectEqual(x86.Access.none, vector.form.register_access);
    try std.testing.expectEqual(x86.Access.write, vector.register_access);
    try std.testing.expectEqual(x86.Access.read, vector.operand_access);

    const shuffle = try x86.decode(&.{ 0x66, 0x0f, 0x70, 0xc1, 1 });
    try std.testing.expectEqual(x86.Operation.pshufd, shuffle.operation);
    try std.testing.expectEqual(x86.Access.write, shuffle.register_access);
    try std.testing.expectEqual(x86.Access.read, shuffle.operand_access);
}

test "x86 multiply implicit access distinguishes products and dividends" {
    const multiply = try x86.decode(&.{ 0x48, 0xf7, 0xe1 });
    try std.testing.expectEqual(x86.Operation.mul, multiply.operation);
    try std.testing.expectEqual(x86.Access.read_write, multiply.implicit[0].access);
    try std.testing.expectEqual(x86.Access.write, multiply.implicit[1].access);

    const divide = try x86.decode(&.{ 0x48, 0xf7, 0xf1 });
    try std.testing.expectEqual(x86.Operation.div, divide.operation);
    try std.testing.expectEqual(x86.Access.read_write, divide.implicit[0].access);
    try std.testing.expectEqual(x86.Access.read_write, divide.implicit[1].access);
}

test "x86 K0 operations collapse into exactly seventeen families" {
    const expected = [_]x86.Family{
        .arithmetic,
        .logic,
        .swap,
        .control,
        .carry,
        .condition,
        .condition,
        .condition,
        .arithmetic,
        .unary,
        .divide,
        .boundary,
        .multiply,
        .unary,
        .condition,
        .condition,
        .condition,
        .condition,
        .condition,
        .control,
        .condition,
        .address,
        .move,
        .string,
        .extend,
        .extend,
        .multiply,
        .nop,
        .unary,
        .logic,
        .boundary,
        .stack,
        .stack,
        .control,
        .shift,
        .arithmetic,
        .condition,
        .condition,
        .condition,
        .condition,
        .condition,
        .condition,
        .shift,
        .shift,
        .string,
        .arithmetic,
        .logic,
        .boundary,
        .logic,
    };
    var seen: [@typeInfo(x86.Family).@"enum".field_names.len]bool = @splat(false);
    for (expected, 0..) |family, index| {
        const operation: x86.Operation = @fromBackingInt(@intCast(index));
        try std.testing.expectEqual(family, operation.family());
        seen[@backingInt(family)] = true;
    }
    var family_count: u8 = 0;
    for (seen) |present| family_count += @intFromBool(present);
    try std.testing.expectEqual(@as(u8, 17), family_count);
}

test "x86 indirect control retains its complete memory operand" {
    const instruction = try x86.decode(&.{
        0xff, 0x24, 0xd5, 0x08, 0xe1, 0x00, 0x02,
    });
    try std.testing.expectEqual(x86.Operation.jmp, instruction.operation);
    try std.testing.expectEqualDeep(
        x86.Memory{
            .kind = .absolute_indexed,
            .width = .qword,
            .index = .{ .number = 2, .lane = .qword },
            .scale = .eight,
            .displacement = 0x0200_e108,
        },
        instruction.operand.memory,
    );
}

test "x86 faults before returning a truncated instruction" {
    try std.testing.expectError(
        error.TruncatedInstruction,
        x86.decode(&.{ 0x48, 0x8b, 0x05, 0x34 }),
    );
    try std.testing.expectError(
        error.UnsupportedAddressSize,
        x86.decode(&.{ 0x67, 0x90 }),
    );
}

test "x86 rejects unimplemented group and mandatory-prefix semantics" {
    const cases = [_][]const u8{
        &.{ 0xfe, 0xd0 },
        &.{ 0xf6, 0xe0 },
        &.{ 0xc6, 0xc8, 0 },
        &.{ 0x0f, 0x1f, 0xc8 },
        &.{ 0x0f, 0x90, 0xc8 },
        &.{ 0xf3, 0x0f, 0x10, 0xc0 },
        &.{ 0x66, 0x0f, 0x6f, 0xc0 },
        &.{ 0xf3, 0x0f, 0x70, 0xc0, 0 },
    };
    for (cases) |code| {
        try std.testing.expectError(error.UnsupportedOpcode, x86.decode(code));
    }
}
