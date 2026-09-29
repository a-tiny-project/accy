const std = @import("std");
const root = @import("../../../root.zig");
const elf = @import("../root.zig");
const checked = @import("value.zig");

const model = root.model;
const Rela = elf.format.Rela;
const copyInto = elf.format.copyInto;
const writeU32 = elf.format.writeU32;

fn checkedRelocationPatchOffset(
    contribution_size: u64,
    base_file_offset: u64,
    patch_offset: u64,
    patch_size: u64,
) model.Error!usize {
    if (patch_offset > contribution_size or
        patch_size > contribution_size - patch_offset) return error.InvalidRange;
    return @intCast(base_file_offset + patch_offset);
}

pub fn tlsGdToLocalExec(
    image: []u8,
    contribution_size: u64,
    base_file_offset: u64,
    relocation: Rela,
    value: i128,
) model.Error!void {
    if (relocation.offset < 4) return error.InvalidRange;
    const patch_offset = try checkedRelocationPatchOffset(contribution_size, base_file_offset, relocation.offset - 4, 16);
    const replacement = [_]u8{
        0x64, 0x48, 0x8b, 0x04, 0x25, 0x00, 0x00, 0x00,
        0x00, 0x48, 0x8d, 0x80, 0x00, 0x00, 0x00, 0x00,
    };
    copyInto(image, patch_offset, &replacement);
    writeU32(image, patch_offset + 12, @bitCast(try checked.checkedI32(value)));
}

pub fn tlsLdToLocalExec(
    image: []u8,
    contribution_size: u64,
    base_file_offset: u64,
    relocation: Rela,
) model.Error!void {
    if (relocation.offset < 3) return error.InvalidRange;
    const probe_offset = try checkedRelocationPatchOffset(contribution_size, base_file_offset, relocation.offset - 3, 9);
    const direct_call_opcode_offset = probe_offset + 7;
    const replacement = [_]u8{
        0x66, 0x66, 0x66, 0x64, 0x48, 0x8b, 0x04, 0x25,
        0x00, 0x00, 0x00, 0x00,
    };
    if (image[direct_call_opcode_offset] == 0xe8) {
        const patch_offset = try checkedRelocationPatchOffset(contribution_size, base_file_offset, relocation.offset - 3, replacement.len);
        copyInto(image, patch_offset, &replacement);
        return;
    }
    if (image[direct_call_opcode_offset] == 0xff and image[direct_call_opcode_offset + 1] == 0x15) {
        const patch_offset = try checkedRelocationPatchOffset(contribution_size, base_file_offset, relocation.offset - 3, replacement.len + 1);
        image[patch_offset] = 0x66;
        copyInto(image, patch_offset + 1, &replacement);
        return;
    }
    return error.UnsupportedRelocation;
}

pub const Gotpcrelx = enum {
    pc_relative,
    absolute_signed_32,
};

pub fn gotpcrelxInstruction(image: []u8, place_offset: usize, relocation_type: u32) ?Gotpcrelx {
    if (relaxGotpcrelxMov(image, place_offset, relocation_type)) return .pc_relative;
    if (relaxGotpcrelxIndirectBranch(image, place_offset, relocation_type)) return .pc_relative;
    if (relaxGotpcrelxBinaryImmediate(image, place_offset, relocation_type)) return .absolute_signed_32;
    return null;
}

fn relaxGotpcrelxMov(image: []u8, place_offset: usize, relocation_type: u32) bool {
    if (place_offset < 2) return false;
    if (relocation_type == @backingInt(std.elf.R_X86_64.REX_GOTPCRELX)) {
        if (place_offset < 3 or !isRexPrefix(image[place_offset - 3])) return false;
    }
    const opcode_offset = place_offset - 2;
    if (image[opcode_offset] != 0x8b) return false;
    if (!isRipRelativeMemoryOperand(image[place_offset - 1])) return false;
    image[opcode_offset] = 0x8d;
    return true;
}

fn relaxGotpcrelxIndirectBranch(image: []u8, place_offset: usize, relocation_type: u32) bool {
    if (relocation_type == @backingInt(std.elf.R_X86_64.REX_GOTPCRELX)) return false;
    if (place_offset < 2) return false;
    const opcode_offset = place_offset - 2;
    if (image[opcode_offset] != 0xff) return false;
    const modrm = image[place_offset - 1];
    if (!isRipRelativeMemoryOperand(modrm)) return false;
    const reg = (modrm >> 3) & 0x7;
    const opcode: u8 = switch (reg) {
        2 => 0xe8,
        4 => 0xe9,
        else => return false,
    };
    image[opcode_offset] = 0x67;
    image[opcode_offset + 1] = opcode;
    return true;
}

pub fn gotpcrelWeakUndefinedNullCheck(image: []u8, place_offset: usize) bool {
    if (place_offset < 3 or place_offset + 4 >= image.len) return false;
    const rex_offset = place_offset - 3;
    const rex = image[rex_offset];
    if (!isRexPrefix(rex) or (rex & 0x08) == 0) return false;
    if (image[place_offset - 2] != 0x83) return false;
    const modrm = image[place_offset - 1];
    if (!isRipRelativeMemoryOperand(modrm) or ((modrm >> 3) & 0x7) != 7) return false;
    if (image[place_offset + 4] != 0) return false;
    const replacement = [_]u8{ 0x48, 0x39, 0xe4, 0x0f, 0x1f, 0x44, 0x00, 0x00 };
    @memcpy(image[rex_offset..][0..replacement.len], &replacement);
    return true;
}

pub fn gottpoffToLocalExec(image: []u8, place_offset: usize, value: i128) model.Error!void {
    if (place_offset < 3 or place_offset > image.len or 4 > image.len - place_offset) return error.InvalidRange;
    const rex_offset = place_offset - 3;
    const rex = image[rex_offset];
    if (!isRexPrefix(rex) or (rex & 0x08) == 0) return error.UnsupportedRelocation;
    if (image[place_offset - 2] != 0x8b) return error.UnsupportedRelocation;
    const modrm = image[place_offset - 1];
    if (!isRipRelativeMemoryOperand(modrm)) return error.UnsupportedRelocation;
    const reg = (modrm >> 3) & 0x7;
    const high_reg = (rex >> 2) & 0x1;
    image[rex_offset] = 0x48 | high_reg;
    image[place_offset - 2] = 0xc7;
    image[place_offset - 1] = 0xc0 | reg;
    writeU32(image, place_offset, @bitCast(try checked.checkedI32(value)));
}

fn relaxGotpcrelxBinaryImmediate(image: []u8, place_offset: usize, relocation_type: u32) bool {
    if (relocation_type != @backingInt(std.elf.R_X86_64.REX_GOTPCRELX)) return false;
    if (place_offset < 3) return false;
    const rex_offset = place_offset - 3;
    const rex = image[rex_offset];
    if (!isRexPrefix(rex) or (rex & 0x08) == 0) return false;
    const opcode_offset = place_offset - 2;
    const group_operation: u8 = switch (image[opcode_offset]) {
        0x03 => 0,
        0x0b => 1,
        0x13 => 2,
        0x1b => 3,
        0x23 => 4,
        0x2b => 5,
        0x33 => 6,
        0x3b => 7,
        else => return false,
    };
    const modrm_offset = place_offset - 1;
    const modrm = image[modrm_offset];
    if (!isRipRelativeMemoryOperand(modrm)) return false;
    const reg = (modrm >> 3) & 0x7;
    const high_reg = (rex >> 2) & 0x1;
    image[rex_offset] = 0x48 | high_reg;
    image[opcode_offset] = 0x81;
    image[modrm_offset] = 0xc0 | (group_operation << 3) | reg;
    return true;
}

fn isRexPrefix(byte: u8) bool {
    return byte >= 0x40 and byte <= 0x4f;
}

fn isRipRelativeMemoryOperand(modrm: u8) bool {
    return (modrm & 0xc7) == 0x05;
}
