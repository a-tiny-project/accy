const std = @import("std");
const x86 = @import("root.zig");

pub const Error = error{
    AmbiguousPrefix,
    InstructionTooLong,
    InvalidEncoding,
    TruncatedInstruction,
    UnsupportedAddressSize,
    UnsupportedOpcode,
    UnsupportedPrefix,
};

const Selector = enum {
    none,
    extension,
};

const Encoding = struct {
    modrm: bool = false,
    selector: Selector = .none,
};

const Bank = enum {
    none,
    gpr,
    vector,
    selector,
};

const Embedded = enum {
    none,
    accumulator,
    opcode,
};

const Shape = struct {
    register_bank: Bank = .none,
    register_access: x86.Access = .none,
    register_high8: bool = false,
    operand_bank: Bank = .none,
    operand_access: x86.Access = .none,
    operand_high8: bool = false,
    operand_width: ?x86.Width = null,
    embedded: Embedded = .none,
    embedded_access: x86.Access = .none,
};

const PrefixState = struct {
    form: x86.Prefix,
    rex: u8,
    segment: x86.Segment,

    fn wide(self: PrefixState) bool {
        return self.rex & 0x08 != 0;
    }

    fn rexR(self: PrefixState) u4 {
        return if (self.rex & 0x04 != 0) 8 else 0;
    }

    fn rexX(self: PrefixState) u4 {
        return if (self.rex & 0x02 != 0) 8 else 0;
    }

    fn rexB(self: PrefixState) u4 {
        return if (self.rex & 0x01 != 0) 8 else 0;
    }
};

const ModRm = struct {
    mode: x86.Mode,
    mode_raw: u2,
    extension: u3,
    register: u4,
    operand: u4,
    base: ?u4,
    index: ?u4,
    scale: x86.Scale,
    displacement: i32,
    displacement_bytes: u3,
    address: x86.AddressKind,
    segment: x86.Segment,
};

const Payload = struct {
    immediate: ?x86.Immediate = null,
    relative: ?i32 = null,
};

pub fn decode(code: []const u8) Error!x86.Instruction {
    var diagnostic: x86.Diagnostic = .{};
    return decodeWithDiagnostic(code, &diagnostic);
}

pub fn decodeWithDiagnostic(
    code: []const u8,
    diagnostic: *x86.Diagnostic,
) Error!x86.Instruction {
    diagnostic.* = .{};
    var cursor: usize = 0;
    const prefix = try parsePrefix(code, &cursor, diagnostic);
    const first = try takeByte(code, &cursor);
    const map: x86.Map = if (first == 0x0f) .two else .one;
    const opcode = if (map == .two) try takeByte(code, &cursor) else first;
    const instruction_encoding = encoding(map, opcode) orelse {
        const candidate = x86.Form{ .prefix = prefix.form, .map = map, .opcode = opcode };
        diagnostic.captureForm(candidate);
        return error.UnsupportedOpcode;
    };
    var modrm = if (instruction_encoding.modrm)
        try parseModRm(code, &cursor, prefix)
    else
        null;
    var form = createForm(prefix, map, opcode, instruction_encoding, modrm);
    const operation = operationFor(prefix, map, opcode, modrm) orelse {
        diagnostic.captureForm(form);
        return error.UnsupportedOpcode;
    };
    if (modrm) |*value| {
        parseDisplacement(code, &cursor, value) catch |failure| {
            diagnostic.captureForm(form);
            return failure;
        };
    }
    const payload = parsePayload(code, &cursor, prefix, map, opcode, modrm) catch |failure| {
        if (!(map == .one and opcode == 0xcd)) diagnostic.captureForm(form);
        return failure;
    };
    if (map == .one and opcode == 0xcd) {
        form.immediate = @truncate(payload.immediate.?.value);
    }
    if (cursor > 15) return error.InstructionTooLong;
    var result = createInstruction(form, operation, cursor, prefix, modrm, payload);
    addImplicitOperands(&result, prefix);
    return result;
}

fn parsePrefix(
    code: []const u8,
    cursor: *usize,
    diagnostic: *x86.Diagnostic,
) Error!PrefixState {
    while (cursor.* < code.len and cursor.* < 15) {
        const byte = code[cursor.*];
        if (byte == 0x67) {
            diagnostic.capturePrefix(code[0 .. cursor.* + 1]);
            return error.UnsupportedAddressSize;
        }
        if (!prefixByte(byte)) break;
        cursor.* += 1;
    }
    if (cursor.* == 15) return error.TruncatedInstruction;
    const bytes = code[0..cursor.*];
    const form = x86.Prefix.fromBytes(bytes) orelse {
        diagnostic.capturePrefix(bytes);
        return prefixError(bytes);
    };
    return .{
        .form = form,
        .rex = form.rexByte(),
        .segment = segmentFor(bytes),
    };
}

fn prefixByte(byte: u8) bool {
    return switch (byte) {
        0x26,
        0x2e,
        0x36,
        0x3e,
        0x64,
        0x65,
        0x66,
        0xf0,
        0xf2,
        0xf3,
        0x40...0x4f,
        => true,
        else => false,
    };
}

fn prefixError(bytes: []const u8) Error {
    if (operand16CsSequence(bytes)) return error.UnsupportedPrefix;
    var operand16 = false;
    var lock = false;
    var repeat = false;
    var segment = false;
    var rex = false;
    for (bytes) |byte| {
        if (byte >= 0x40 and byte <= 0x4f) {
            if (rex) return error.AmbiguousPrefix;
            rex = true;
            continue;
        }
        if (rex) return error.AmbiguousPrefix;
        switch (byte) {
            0x66 => {
                if (operand16) return error.AmbiguousPrefix;
                operand16 = true;
            },
            0xf0 => {
                if (lock) return error.AmbiguousPrefix;
                lock = true;
            },
            0xf2, 0xf3 => {
                if (repeat) return error.AmbiguousPrefix;
                repeat = true;
            },
            0x26, 0x2e, 0x36, 0x3e, 0x64, 0x65 => {
                if (segment) return error.AmbiguousPrefix;
                segment = true;
            },
            else => {},
        }
    }
    return error.UnsupportedPrefix;
}

fn operand16CsSequence(bytes: []const u8) bool {
    if (bytes.len < 2 or bytes[bytes.len - 1] != 0x2e) return false;
    for (bytes[0 .. bytes.len - 1]) |byte| {
        if (byte != 0x66) return false;
    }
    return true;
}

fn segmentFor(bytes: []const u8) x86.Segment {
    for (bytes) |byte| {
        return switch (byte) {
            0x26 => .es,
            0x2e => .cs,
            0x36 => .ss,
            0x3e => .ds,
            0x64 => .fs,
            0x65 => .gs,
            else => continue,
        };
    }
    return .none;
}

fn encoding(map: x86.Map, opcode: u8) ?Encoding {
    return switch (map) {
        .one => encodingOne(opcode),
        .two => encodingTwo(opcode),
    };
}

fn encodingOne(opcode: u8) ?Encoding {
    if (groupOpcode(opcode)) return .{ .modrm = true, .selector = .extension };
    if (plainModRmOpcode(opcode)) return .{ .modrm = true };
    if (x86.formModeled(.{ .opcode = opcode })) return .{};
    return null;
}

fn groupOpcode(opcode: u8) bool {
    return switch (opcode) {
        0x80,
        0x81,
        0x83,
        0xc0,
        0xc1,
        0xc6,
        0xc7,
        0xd0,
        0xd1,
        0xd2,
        0xd3,
        0xf6,
        0xf7,
        0xfe,
        0xff,
        => true,
        else => false,
    };
}

fn plainModRmOpcode(opcode: u8) bool {
    if (opcode <= 0x03) return true;
    if (opcode >= 0x08 and opcode <= 0x0b) return true;
    if (opcode >= 0x18 and opcode <= 0x1b) return true;
    if (opcode >= 0x20 and opcode <= 0x23) return true;
    if (opcode >= 0x28 and opcode <= 0x2b) return true;
    if (opcode >= 0x30 and opcode <= 0x33) return true;
    return switch (opcode) {
        0x38,
        0x39,
        0x3b,
        0x69,
        0x6b,
        0x84,
        0x85,
        0x88,
        0x89,
        0x8a,
        0x8b,
        0x8d,
        => true,
        else => false,
    };
}

fn encodingTwo(opcode: u8) ?Encoding {
    if (opcode == 0x1f or opcode == 0x90 or
        ((opcode >= 0x92 and opcode <= 0x97) or
            (opcode >= 0x9c and opcode <= 0x9f)))
    {
        return .{ .modrm = true, .selector = .extension };
    }
    if (switch (opcode) {
        0x10,
        0x11,
        0x42,
        0x43,
        0x44,
        0x45,
        0x47,
        0x6f,
        0x70,
        0x7f,
        0xaf,
        0xb0,
        0xb6,
        0xb7,
        0xbe,
        0xbf,
        => true,
        else => false,
    }) return .{ .modrm = true };
    if (x86.formModeled(.{ .map = .two, .opcode = opcode })) return .{};
    return null;
}

fn parseModRm(
    code: []const u8,
    cursor: *usize,
    prefix: PrefixState,
) Error!ModRm {
    const byte = try takeByte(code, cursor);
    const mode_raw: u2 = @intCast(byte >> 6);
    const extension: u3 = @intCast((byte >> 3) & 7);
    const operand_raw: u3 = @intCast(byte & 7);
    var result = ModRm{
        .mode = modeFromRaw(mode_raw),
        .mode_raw = mode_raw,
        .extension = extension,
        .register = @as(u4, extension) | prefix.rexR(),
        .operand = @as(u4, operand_raw) | prefix.rexB(),
        .base = null,
        .index = null,
        .scale = .one,
        .displacement = 0,
        .displacement_bytes = 0,
        .address = .none,
        .segment = prefix.segment,
    };
    if (mode_raw == 3) return result;
    if (operand_raw == 4) {
        try parseSib(code, cursor, prefix, &result);
    } else if (mode_raw == 0 and operand_raw == 5) {
        result.address = .rip_relative;
        result.displacement_bytes = 4;
    } else {
        result.base = result.operand;
        result.address = .base;
    }
    if (mode_raw == 1) result.displacement_bytes = 1;
    if (mode_raw == 2) result.displacement_bytes = 4;
    return result;
}

fn parseSib(
    code: []const u8,
    cursor: *usize,
    prefix: PrefixState,
    result: *ModRm,
) Error!void {
    const sib = try takeByte(code, cursor);
    result.scale = @fromBackingInt(@intCast(@as(u2, @intCast(sib >> 6))));
    const index_raw: u3 = @intCast((sib >> 3) & 7);
    const base_raw: u3 = @intCast(sib & 7);
    if (index_raw != 4 or prefix.rexX() != 0) {
        result.index = @as(u4, index_raw) | prefix.rexX();
    }
    if (result.mode_raw == 0 and base_raw == 5) {
        result.displacement_bytes = 4;
    } else {
        result.base = @as(u4, base_raw) | prefix.rexB();
    }
    result.address = if (result.base == null)
        if (result.index == null) .absolute else .absolute_indexed
    else if (result.index == null)
        .base
    else
        .base_indexed;
}

fn parseDisplacement(
    code: []const u8,
    cursor: *usize,
    modrm: *ModRm,
) Error!void {
    modrm.displacement = switch (modrm.displacement_bytes) {
        0 => 0,
        1 => try readI8(code, cursor),
        4 => try readI32(code, cursor),
        else => return error.InvalidEncoding,
    };
}

fn createForm(
    prefix: PrefixState,
    map: x86.Map,
    opcode: u8,
    instruction_encoding: Encoding,
    modrm: ?ModRm,
) x86.Form {
    var result = x86.Form{
        .prefix = prefix.form,
        .map = map,
        .opcode = opcode,
        .width = effectiveWidth(prefix.form, map, opcode),
    };
    const shape_value = shape(map, opcode, if (modrm) |value| value.extension else null);
    if (modrm) |value| {
        result.mode = value.mode;
        result.address = value.address;
        result.base_role = addressRole(value.base);
        result.index_role = addressRole(value.index);
        if (instruction_encoding.selector == .extension) {
            result.extension = .fromRaw(value.extension);
        }
        applyOperands(&result, prefix, shape_value, value);
    }
    applyEmbedded(&result, prefix, shape_value, opcode);
    return result;
}

fn effectiveWidth(prefix: x86.Prefix, map: x86.Map, opcode: u8) x86.Width {
    return switch (map) {
        .one => oneByteWidth(prefix, opcode),
        .two => twoByteWidth(prefix, opcode),
    };
}

fn oneByteWidth(prefix: x86.Prefix, opcode: u8) x86.Width {
    if (switch (opcode) {
        0x90, 0x9c, 0xcd, 0xf4, 0xf5, 0xfa, 0xfb => true,
        else => false,
    }) return .none;
    if ((opcode >= 0x50 and opcode <= 0x5f) or
        ((opcode >= 0x72 and opcode <= 0x77) or
            (opcode >= 0x7c and opcode <= 0x7f)) or
        switch (opcode) {
            0x6a, 0xc3, 0xe8, 0xe9, 0xeb => true,
            else => false,
        }) return controlWidth(prefix);
    if (byteOpcode(opcode)) return .byte;
    return operandWidth(prefix);
}

fn byteOpcode(opcode: u8) bool {
    if (opcode >= 0xb0 and opcode <= 0xb7) return true;
    return switch (opcode) {
        0x00,
        0x02,
        0x04,
        0x08,
        0x0a,
        0x18,
        0x1a,
        0x1c,
        0x20,
        0x22,
        0x24,
        0x28,
        0x2a,
        0x2c,
        0x30,
        0x32,
        0x34,
        0x38,
        0x3c,
        0x80,
        0x84,
        0x88,
        0x8a,
        0xa4,
        0xa8,
        0xaa,
        0xc0,
        0xc6,
        0xd0,
        0xd2,
        0xee,
        0xf6,
        0xfe,
        => true,
        else => false,
    };
}

fn twoByteWidth(prefix: x86.Prefix, opcode: u8) x86.Width {
    if (switch (opcode) {
        0x0b, 0x1f, 0x30, 0x32, 0xa2 => true,
        else => false,
    }) return .none;
    if (switch (opcode) {
        0x10, 0x11, 0x6f, 0x70, 0x7f => true,
        else => false,
    }) return .vector128;
    if ((opcode >= 0x82 and opcode <= 0x87) or
        (opcode >= 0x8c and opcode <= 0x8f)) return controlWidth(prefix);
    if (opcode == 0x90 or ((opcode >= 0x92 and opcode <= 0x97) or
        (opcode >= 0x9c and opcode <= 0x9f)) or opcode == 0xb0)
    {
        return .byte;
    }
    if (opcode == 0xb6 or opcode == 0xb7 or opcode == 0xbe or opcode == 0xbf) {
        return if (prefix.wide())
            .qword
        else if (prefix.hasOperand16())
            .word
        else
            .dword;
    }
    return operandWidth(prefix);
}

fn operandWidth(prefix: x86.Prefix) x86.Width {
    if (prefix.wide()) return .qword;
    if (prefix.hasOperand16()) return .word;
    return .dword;
}

fn controlWidth(prefix: x86.Prefix) x86.Width {
    return if (prefix.hasOperand16()) .word else .qword;
}

fn shape(map: x86.Map, opcode: u8, extension: ?u3) Shape {
    return switch (map) {
        .one => shapeOne(opcode, extension),
        .two => shapeTwo(opcode),
    };
}

fn shapeOne(opcode: u8, extension: ?u3) Shape {
    if (opcode < 0x80) return shapeOneLow(opcode);
    return shapeOneHigh(opcode, extension);
}

fn shapeOneLow(opcode: u8) Shape {
    return switch (opcode) {
        0x00, 0x08, 0x18, 0x20, 0x28, 0x30 => gpr(.read, .read_write, true),
        0x01, 0x09, 0x19, 0x21, 0x29, 0x31 => gpr(.read, .read_write, false),
        0x02, 0x0a, 0x1a, 0x22, 0x2a, 0x32 => gpr(.read_write, .read, true),
        0x03, 0x0b, 0x1b, 0x23, 0x2b, 0x33 => gpr(.read_write, .read, false),
        0x38 => gpr(.read, .read, true),
        0x39, 0x3b => gpr(.read, .read, false),
        0x04,
        0x05,
        0x0d,
        0x1c,
        0x1d,
        0x24,
        0x25,
        0x2c,
        0x2d,
        0x34,
        0x35,
        => embedded(.accumulator, .read_write),
        0x3c, 0x3d => embedded(.accumulator, .read),
        0x50...0x57 => embedded(.opcode, .read),
        0x58...0x5f => embedded(.opcode, .write),
        0x69, 0x6b => gpr(.write, .read, false),
        else => .{},
    };
}

fn shapeOneHigh(opcode: u8, extension: ?u3) Shape {
    const byte_group = opcode == 0xc0 or opcode == 0xfe;
    return switch (opcode) {
        0x80 => group(groupAccess(extension), true),
        0x81, 0x83 => group(groupAccess(extension), false),
        0x84 => gpr(.read, .read, true),
        0x85 => gpr(.read, .read, false),
        0x88 => gpr(.read, .write, true),
        0x89 => gpr(.read, .write, false),
        0x8a => gpr(.write, .read, true),
        0x8b => gpr(.write, .read, false),
        0x8d => gpr(.write, .none, false),
        0xa8, 0xa9 => embedded(.accumulator, .read),
        0xb0...0xbf => embedded(.opcode, .write),
        0xc0, 0xc1, 0xd0, 0xd1, 0xd2, 0xd3, 0xfe => group(.read_write, byte_group),
        0xc6, 0xc7 => group(.write, opcode == 0xc6),
        0xf6, 0xf7 => group(groupThreeAccess(extension), opcode == 0xf6),
        0xff => groupFiveShape(extension),
        else => .{},
    };
}

fn shapeTwo(opcode: u8) Shape {
    return switch (opcode) {
        0x10, 0x6f, 0x70 => vector(.read),
        0x11, 0x7f => vector(.write),
        0x42...0x45, 0x47 => gpr(.read_write, .read, false),
        0x90, 0x92...0x97, 0x9c...0x9f => group(.write, true),
        0xaf => gpr(.read_write, .read, false),
        0xb0 => gpr(.read, .read_write, true),
        0xb6, 0xbe => gprMixed(.write, .read, .byte),
        0xb7, 0xbf => gprMixed(.write, .read, .word),
        0xc8...0xcf => embedded(.opcode, .write),
        else => .{},
    };
}

fn gpr(register_access: x86.Access, operand_access: x86.Access, byte: bool) Shape {
    return .{
        .register_bank = .gpr,
        .register_access = register_access,
        .register_high8 = byte,
        .operand_bank = .gpr,
        .operand_access = operand_access,
        .operand_high8 = byte,
    };
}

fn gprMixed(
    register_access: x86.Access,
    operand_access: x86.Access,
    operand_width: x86.Width,
) Shape {
    return .{
        .register_bank = .gpr,
        .register_access = register_access,
        .operand_bank = .gpr,
        .operand_access = operand_access,
        .operand_high8 = operand_width == .byte,
        .operand_width = operand_width,
    };
}

fn group(access: x86.Access, byte: bool) Shape {
    return .{
        .register_bank = .selector,
        .operand_bank = .gpr,
        .operand_access = access,
        .operand_high8 = byte,
    };
}

fn groupFiveShape(extension: ?u3) Shape {
    var result = group(groupFiveAccess(extension), false);
    if (extension == 2 or extension == 4) result.operand_width = .qword;
    return result;
}

fn vector(access: x86.Access) Shape {
    return .{
        .register_bank = .vector,
        .register_access = if (access == .read) .write else .read,
        .operand_bank = .vector,
        .operand_access = access,
    };
}

fn embedded(kind: Embedded, access: x86.Access) Shape {
    return .{ .embedded = kind, .embedded_access = access };
}

fn groupAccess(extension: ?u3) x86.Access {
    return if (extension == 7) .read else .read_write;
}

fn groupThreeAccess(extension: ?u3) x86.Access {
    return switch (extension orelse 0) {
        2, 3 => .read_write,
        else => .read,
    };
}

fn groupFiveAccess(extension: ?u3) x86.Access {
    return switch (extension orelse 0) {
        0, 1 => .read_write,
        else => .read,
    };
}

fn applyOperands(
    result: *x86.Form,
    prefix: PrefixState,
    shape_value: Shape,
    modrm: ModRm,
) void {
    if (shape_value.register_bank == .gpr) {
        const register = gprRegister(
            modrm.register,
            result.width,
            prefix,
            shape_value.register_high8,
        );
        result.register_role = register.role();
        result.register_access = shape_value.register_access;
    }
    if (modrm.mode == .register and shape_value.operand_bank == .gpr) {
        const width = operandWidthFor(result.*, shape_value);
        const operand = gprRegister(modrm.operand, width, prefix, shape_value.operand_high8);
        result.operand_role = operand.role();
    }
    result.operand_access = if (shape_value.operand_bank == .vector and
        modrm.mode == .register)
        .none
    else
        shape_value.operand_access;
}

fn applyEmbedded(
    result: *x86.Form,
    prefix: PrefixState,
    shape_value: Shape,
    opcode: u8,
) void {
    result.embedded_access = shape_value.embedded_access;
    const register = switch (shape_value.embedded) {
        .none => return,
        .accumulator => gprRegister(0, result.width, prefix, result.width == .byte),
        .opcode => gprRegister(
            @as(u4, @intCast(opcode & 7)) | prefix.rexB(),
            result.width,
            prefix,
            result.width == .byte,
        ),
    };
    result.embedded_role = register.role();
}

fn operandWidthFor(form: x86.Form, shape_value: Shape) x86.Width {
    return shape_value.operand_width orelse form.width;
}

fn addressRole(value: ?u4) x86.Role {
    const number = value orelse return .none;
    return (x86.Register{ .number = number, .lane = .qword }).role();
}

fn operationFor(
    prefix: PrefixState,
    map: x86.Map,
    opcode: u8,
    modrm: ?ModRm,
) ?x86.Operation {
    return switch (map) {
        .one => operationOne(
            prefix,
            opcode,
            if (modrm) |value| value.extension else null,
        ),
        .two => operationTwo(
            prefix,
            opcode,
            if (modrm) |value| value.extension else null,
        ),
    };
}

fn operationOne(
    prefix: PrefixState,
    opcode: u8,
    extension: ?u3,
) ?x86.Operation {
    if (arithmeticOperation(opcode)) |operation| return operation;
    if (opcode >= 0x50 and opcode <= 0x57) return .push;
    if (opcode >= 0x58 and opcode <= 0x5f) return .pop;
    if ((opcode >= 0x72 and opcode <= 0x77) or
        (opcode >= 0x7c and opcode <= 0x7f)) return conditionOperation(opcode & 0x0f);
    if (opcode >= 0xb0 and opcode <= 0xbf) return .mov;
    return switch (opcode) {
        0x69, 0x6b => .imul,
        0x6a => .push,
        0x80, 0x81, 0x83 => groupOneOperation(extension),
        0x84, 0x85, 0xa8, 0xa9 => .test_,
        0x88...0x8b => .mov,
        0xc6, 0xc7 => if (extension == 0) .mov else null,
        0x8d => .lea,
        0x90 => if (prefix.form.hasOperand16() or prefix.rexB() != 0)
            .xchg
        else
            .nop,
        0x9c => .pushf,
        0xa4, 0xa5 => .movs,
        0xaa, 0xab => .stos,
        0xc0, 0xc1, 0xd0, 0xd1, 0xd2, 0xd3 => shiftOperation(extension),
        0xc3 => .ret,
        0xcd => .int_,
        0xe8 => .call,
        0xe9, 0xeb => .jmp,
        0xee => .out,
        0xf4 => .hlt,
        0xf5 => .cmc,
        0xf6 => groupThreeByteOperation(extension),
        0xf7 => groupThreeOperation(extension),
        0xfa => .cli,
        0xfb => .sti,
        0xfe => groupFourOperation(extension),
        0xff => groupFiveOperation(extension),
        else => null,
    };
}

fn arithmeticOperation(opcode: u8) ?x86.Operation {
    return switch (opcode & 0xf8) {
        0x00 => if (opcode <= 0x05) .add else null,
        0x08 => if (opcode <= 0x0d) .or_ else null,
        0x18 => if (opcode <= 0x1d) .sbb else null,
        0x20 => if (opcode <= 0x25) .and_ else null,
        0x28 => if (opcode <= 0x2d) .sub else null,
        0x30 => if (opcode <= 0x35) .xor_ else null,
        0x38 => if (opcode == 0x38 or opcode == 0x39 or
            (opcode >= 0x3b and opcode <= 0x3d)) .cmp else null,
        else => null,
    };
}

fn groupOneOperation(extension: ?u3) ?x86.Operation {
    return switch (extension orelse return null) {
        0 => .add,
        1 => .or_,
        2 => .adc,
        3 => .sbb,
        4 => .and_,
        5 => .sub,
        6 => .xor_,
        7 => .cmp,
    };
}

fn shiftOperation(extension: ?u3) ?x86.Operation {
    return switch (extension orelse return null) {
        0 => .rol,
        1 => .ror,
        4, 6 => .shl,
        5 => .shr,
        7 => .sar,
        else => null,
    };
}

fn groupThreeOperation(extension: ?u3) ?x86.Operation {
    return switch (extension orelse return null) {
        0 => .test_,
        2 => .not_,
        3 => .neg,
        4 => .mul,
        5 => .imul,
        6 => .div,
        7 => .idiv,
        else => null,
    };
}

fn groupThreeByteOperation(extension: ?u3) ?x86.Operation {
    return switch (extension orelse return null) {
        0 => .test_,
        2 => .not_,
        3 => .neg,
        else => null,
    };
}

fn groupFiveOperation(extension: ?u3) ?x86.Operation {
    return switch (extension orelse return null) {
        0 => .inc,
        1 => .dec,
        2 => .call,
        4 => .jmp,
        else => null,
    };
}

fn groupFourOperation(extension: ?u3) ?x86.Operation {
    return switch (extension orelse return null) {
        0 => .inc,
        1 => .dec,
        else => null,
    };
}

fn operationTwo(
    prefix: PrefixState,
    opcode: u8,
    extension: ?u3,
) ?x86.Operation {
    if ((opcode >= 0x82 and opcode <= 0x87) or
        (opcode >= 0x8c and opcode <= 0x8f)) return conditionOperation(opcode & 0x0f);
    if (opcode >= 0xc8 and opcode <= 0xcf) {
        return if (bareOrRex(prefix.form)) .bswap else null;
    }
    return switch (opcode) {
        0x0b => .ud2,
        0x10, 0x11 => if (bareOrRex(prefix.form)) .movups else null,
        0x1f => if (extension == 0) .nop else null,
        0x30 => .wrmsr,
        0x32 => .rdmsr,
        0x42 => .cmovb,
        0x43 => .cmovae,
        0x44 => .cmove,
        0x45 => .cmovne,
        0x47 => .cmova,
        0x6f, 0x7f => if (prefix.form.repeated()) .movdqu else null,
        0x70 => if (operand16Encoding(prefix.form)) .pshufd else null,
        0x90 => if (extension == 0 and bareOrRex(prefix.form)) .seto else null,
        0x92 => if (extension == 0 and bareOrRex(prefix.form)) .setb else null,
        0x93 => if (extension == 0 and bareOrRex(prefix.form)) .setae else null,
        0x94 => if (extension == 0 and bareOrRex(prefix.form)) .sete else null,
        0x95 => if (extension == 0 and bareOrRex(prefix.form)) .setne else null,
        0x96 => if (extension == 0 and bareOrRex(prefix.form)) .setbe else null,
        0x97 => if (extension == 0 and bareOrRex(prefix.form)) .seta else null,
        0x9c => if (extension == 0 and bareOrRex(prefix.form)) .setl else null,
        0x9d => if (extension == 0 and bareOrRex(prefix.form)) .setge else null,
        0x9e => if (extension == 0 and bareOrRex(prefix.form)) .setle else null,
        0x9f => if (extension == 0 and bareOrRex(prefix.form)) .setg else null,
        0xa2 => .cpuid,
        0xaf => .imul,
        0xb0 => .cmpxchg,
        0xb6, 0xb7 => .movzx,
        0xbe, 0xbf => .movsx,
        else => null,
    };
}

fn bareOrRex(prefix: x86.Prefix) bool {
    return prefix == .none or
        (prefix.rexByte() != 0 and prefix.bytes().len == 1);
}

fn operand16Encoding(prefix: x86.Prefix) bool {
    return switch (prefix) {
        .operand16,
        .operand16_rex_b,
        .operand16_rex_r,
        .operand16_rex_rb,
        => true,
        else => false,
    };
}

fn conditionOperation(code: u8) ?x86.Operation {
    return switch (code) {
        0x2 => .jb,
        0x3 => .jae,
        0x4 => .je,
        0x5 => .jne,
        0x6 => .jbe,
        0x7 => .ja,
        0xc => .jl,
        0xd => .jge,
        0xe => .jle,
        0xf => .jg,
        else => null,
    };
}

fn parsePayload(
    code: []const u8,
    cursor: *usize,
    prefix: PrefixState,
    map: x86.Map,
    opcode: u8,
    modrm: ?ModRm,
) Error!Payload {
    return switch (map) {
        .one => parseOnePayload(code, cursor, prefix, opcode, modrm),
        .two => parseTwoPayload(code, cursor, opcode),
    };
}

fn parseOnePayload(
    code: []const u8,
    cursor: *usize,
    prefix: PrefixState,
    opcode: u8,
    modrm: ?ModRm,
) Error!Payload {
    if (arithmeticImmediateBytes(prefix, opcode)) |bytes| {
        return immediatePayload(code, cursor, bytes, prefix.wide());
    }
    if ((opcode >= 0x72 and opcode <= 0x77) or
        (opcode >= 0x7c and opcode <= 0x7f)) return relativePayload(code, cursor, 1);
    if (opcode >= 0xb0 and opcode <= 0xb7) return immediatePayload(code, cursor, 1, false);
    if (opcode >= 0xb8 and opcode <= 0xbf) {
        const bytes = if (prefix.wide()) 8 else operandBytes(prefix);
        return immediatePayload(code, cursor, bytes, false);
    }
    return switch (opcode) {
        0x69 => immediatePayload(code, cursor, operandBytes(prefix), prefix.wide()),
        0x6a, 0x6b, 0x80, 0x83 => immediatePayload(code, cursor, 1, opcode != 0x80),
        0x81 => immediatePayload(code, cursor, operandBytes(prefix), prefix.wide()),
        0xa8 => immediatePayload(code, cursor, 1, false),
        0xa9 => immediatePayload(code, cursor, operandBytes(prefix), prefix.wide()),
        0xc0, 0xc1 => immediatePayload(code, cursor, 1, false),
        0xc6 => immediatePayload(code, cursor, 1, false),
        0xc7 => immediatePayload(code, cursor, operandBytes(prefix), prefix.wide()),
        0xcd => immediatePayload(code, cursor, 1, false),
        0xe8, 0xe9 => relativePayload(code, cursor, 4),
        0xeb => relativePayload(code, cursor, 1),
        0xf6, 0xf7 => if (modrm.?.extension == 0)
            immediatePayload(
                code,
                cursor,
                if (opcode == 0xf6) 1 else operandBytes(prefix),
                opcode == 0xf7 and prefix.wide(),
            )
        else
            .{},
        else => .{},
    };
}

fn parseTwoPayload(
    code: []const u8,
    cursor: *usize,
    opcode: u8,
) Error!Payload {
    if ((opcode >= 0x82 and opcode <= 0x87) or
        (opcode >= 0x8c and opcode <= 0x8f)) return relativePayload(code, cursor, 4);
    if (opcode == 0x70) return immediatePayload(code, cursor, 1, false);
    return .{};
}

fn arithmeticImmediateBytes(prefix: PrefixState, opcode: u8) ?usize {
    const form = opcode & 7;
    if (arithmeticOperation(opcode) == null) return null;
    if (form == 4) return 1;
    if (form == 5) return operandBytes(prefix);
    return null;
}

fn operandBytes(prefix: PrefixState) usize {
    return if (!prefix.wide() and prefix.form.hasOperand16()) 2 else 4;
}

fn immediatePayload(
    code: []const u8,
    cursor: *usize,
    bytes: usize,
    sign: bool,
) Error!Payload {
    return .{ .immediate = .{
        .value = try readUnsigned(code, cursor, bytes),
        .encoded_bytes = @intCast(bytes),
        .extension = if (sign) .sign else .none,
    } };
}

fn relativePayload(code: []const u8, cursor: *usize, bytes: usize) Error!Payload {
    return .{ .relative = switch (bytes) {
        1 => try readI8(code, cursor),
        4 => try readI32(code, cursor),
        else => unreachable,
    } };
}

fn createInstruction(
    form: x86.Form,
    operation: x86.Operation,
    bytes: usize,
    prefix: PrefixState,
    modrm: ?ModRm,
    payload: Payload,
) x86.Instruction {
    const shape_value = shape(form.map, form.opcode, if (modrm) |value| value.extension else null);
    var result = x86.Instruction{
        .form = form,
        .operation = operation,
        .family = operation.family(),
        .bytes = @intCast(bytes),
        .register_access = shape_value.register_access,
        .operand_access = shape_value.operand_access,
        .embedded_access = shape_value.embedded_access,
        .immediate = payload.immediate,
        .relative = payload.relative,
    };
    if (modrm) |value| applyDecodedOperands(&result, prefix, shape_value, value);
    if (modrm) |value| {
        result.modrm_mode = value.mode_raw;
        result.modrm_operand = value.operand;
    }
    result.embedded = decodedEmbedded(form, prefix, shape_value);
    applyExactEncoding(&result, prefix);
    return result;
}

fn applyExactEncoding(result: *x86.Instruction, prefix: PrefixState) void {
    switch (result.operation) {
        .bswap => result.embedded_access = .read_write,
        .xchg => if (result.form.map == .one and result.form.opcode == 0x90) {
            const width = if (prefix.form.hasOperand16())
                x86.Width.word
            else if (prefix.wide())
                x86.Width.qword
            else
                x86.Width.dword;
            result.register = gprRegister(0, width, prefix, false);
            result.register_access = .read_write;
            result.embedded = gprRegister(prefix.rexB(), width, prefix, false);
            result.embedded_access = .read_write;
        },
        else => {},
    }
}

fn applyDecodedOperands(
    result: *x86.Instruction,
    prefix: PrefixState,
    shape_value: Shape,
    modrm: ModRm,
) void {
    if (shape_value.register_bank == .gpr) {
        result.register = gprRegister(
            modrm.register,
            result.form.width,
            prefix,
            shape_value.register_high8,
        );
    } else if (shape_value.register_bank == .vector) {
        result.register = vectorRegister(modrm.register);
    }
    if (modrm.mode == .register) {
        result.operand = decodedRegisterOperand(result.form, prefix, shape_value, modrm);
    } else {
        result.operand = .{ .memory = decodedMemory(
            result.form,
            shape_value,
            modrm,
        ) };
    }
}

fn decodedRegisterOperand(
    form: x86.Form,
    prefix: PrefixState,
    shape_value: Shape,
    modrm: ModRm,
) x86.Operand {
    if (shape_value.operand_bank == .vector) {
        return .{ .register = vectorRegister(modrm.operand) };
    }
    const width = operandWidthFor(form, shape_value);
    return .{ .register = gprRegister(
        modrm.operand,
        width,
        prefix,
        shape_value.operand_high8,
    ) };
}

fn decodedMemory(
    form: x86.Form,
    shape_value: Shape,
    modrm: ModRm,
) x86.Memory {
    return .{
        .kind = modrm.address,
        .width = if (shape_value.operand_access == .none)
            .none
        else
            operandWidthFor(form, shape_value),
        .base = if (modrm.base) |number| addressRegister(number) else null,
        .index = if (modrm.index) |number| addressRegister(number) else null,
        .scale = modrm.scale,
        .displacement = modrm.displacement,
        .segment = modrm.segment,
    };
}

fn decodedEmbedded(
    form: x86.Form,
    prefix: PrefixState,
    shape_value: Shape,
) ?x86.Register {
    return switch (shape_value.embedded) {
        .none => null,
        .accumulator => gprRegister(0, form.width, prefix, form.width == .byte),
        .opcode => gprRegister(
            @as(u4, @intCast(form.opcode & 7)) | prefix.rexB(),
            form.width,
            prefix,
            form.width == .byte,
        ),
    };
}

fn gprRegister(
    number: u4,
    width: x86.Width,
    prefix: PrefixState,
    high8: bool,
) x86.Register {
    if (high8 and prefix.rex == 0 and number >= 4 and number <= 7) {
        return .{ .number = number - 4, .lane = .high8 };
    }
    return .{ .number = number, .lane = laneFor(width) };
}

fn vectorRegister(number: u4) x86.Register {
    return .{ .bank = .vector, .number = number, .lane = .vector128 };
}

fn addressRegister(number: u4) x86.Register {
    return .{ .number = number, .lane = .qword };
}

fn laneFor(width: x86.Width) x86.RegisterLane {
    return switch (width) {
        .byte => .low8,
        .word => .word,
        .dword => .dword,
        .qword, .none => .qword,
        .vector128 => .vector128,
    };
}

fn addImplicitOperands(result: *x86.Instruction, prefix: PrefixState) void {
    switch (result.operation) {
        .push, .pop, .pushf, .call, .ret => addImplicit(result, gprUse(4, .qword, .read_write)),
        .mul, .div, .idiv => addMultiplyImplicit(result),
        .imul => if (result.form.opcode == 0xf6 or result.form.opcode == 0xf7)
            addMultiplyImplicit(result),
        .out => {
            addImplicit(result, gprUse(2, .word, .read));
            addImplicit(result, gprUse(0, .low8, .read));
        },
        .movs => addStringImplicit(result, prefix, false),
        .stos => addStringImplicit(result, prefix, true),
        .cmpxchg => addImplicit(result, gprUse(0, .low8, .read_write)),
        .cpuid => addCpuidImplicit(result),
        .rdmsr => addRdmsrImplicit(result),
        .wrmsr => addWrmsrImplicit(result),
        .rol, .ror, .sar, .shl, .shr => if (result.form.opcode == 0xd2 or
            result.form.opcode == 0xd3) addImplicit(result, gprUse(1, .low8, .read)),
        else => {},
    }
}

fn addMultiplyImplicit(result: *x86.Instruction) void {
    const lane = laneFor(result.form.width);
    addImplicit(result, gprUse(0, lane, .read_write));
    addImplicit(result, gprUse(
        2,
        lane,
        if (result.operation == .mul or result.operation == .imul)
            .write
        else
            .read_write,
    ));
}

fn addStringImplicit(
    result: *x86.Instruction,
    prefix: PrefixState,
    accumulator: bool,
) void {
    if (!accumulator) addImplicit(result, gprUse(6, .qword, .read_write));
    if (accumulator) {
        addImplicit(result, gprUse(0, laneFor(result.form.width), .read));
    }
    addImplicit(result, gprUse(7, .qword, .read_write));
    if (prefix.form.repeated()) addImplicit(result, gprUse(1, .qword, .read_write));
}

fn addCpuidImplicit(result: *x86.Instruction) void {
    addImplicit(result, gprUse(0, .dword, .read_write));
    addImplicit(result, gprUse(1, .dword, .read_write));
    addImplicit(result, gprUse(2, .dword, .write));
    addImplicit(result, gprUse(3, .dword, .write));
}

fn addRdmsrImplicit(result: *x86.Instruction) void {
    addImplicit(result, gprUse(1, .dword, .read));
    addImplicit(result, gprUse(0, .dword, .write));
    addImplicit(result, gprUse(2, .dword, .write));
}

fn addWrmsrImplicit(result: *x86.Instruction) void {
    addImplicit(result, gprUse(1, .dword, .read));
    addImplicit(result, gprUse(0, .dword, .read));
    addImplicit(result, gprUse(2, .dword, .read));
}

fn gprUse(number: u4, lane: x86.RegisterLane, access: x86.Access) x86.RegisterAccess {
    return .{ .register = .{ .number = number, .lane = lane }, .access = access };
}

fn addImplicit(result: *x86.Instruction, value: x86.RegisterAccess) void {
    std.debug.assert(result.implicit_count < result.implicit.len);
    result.implicit[result.implicit_count] = value;
    result.implicit_count += 1;
}

fn modeFromRaw(value: u2) x86.Mode {
    return switch (value) {
        0 => .memory,
        1 => .displacement8,
        2 => .displacement32,
        3 => .register,
    };
}

fn readI8(code: []const u8, cursor: *usize) Error!i32 {
    return @as(i8, @bitCast(try takeByte(code, cursor)));
}

fn readI32(code: []const u8, cursor: *usize) Error!i32 {
    const value = try take(code, cursor, 4);
    return std.mem.readInt(i32, value[0..4], .little);
}

fn readUnsigned(code: []const u8, cursor: *usize, bytes: usize) Error!u64 {
    const value = try take(code, cursor, bytes);
    return switch (bytes) {
        1 => value[0],
        2 => std.mem.readInt(u16, value[0..2], .little),
        4 => std.mem.readInt(u32, value[0..4], .little),
        8 => std.mem.readInt(u64, value[0..8], .little),
        else => error.InvalidEncoding,
    };
}

fn takeByte(code: []const u8, cursor: *usize) Error!u8 {
    return (try take(code, cursor, 1))[0];
}

fn take(code: []const u8, cursor: *usize, count: usize) Error![]const u8 {
    if (cursor.* > code.len or count > code.len - cursor.*) {
        return error.TruncatedInstruction;
    }
    if (cursor.* + count > 15) return error.InstructionTooLong;
    const result = code[cursor.*..][0..count];
    cursor.* += count;
    return result;
}
