const std = @import("std");
const root = @import("../../root.zig");

/// Apple CS_CodeDirectory v0x20400, pinned in xnu/osfmk/kern/cs_blobs.h.
/// The 4KiB hash page is independent of the arm64 16KiB VM page.
pub const hash_page_bytes = 4096;
pub const directory_header_bytes = 88;
pub const superblob_header_bytes = 20;
pub const hash_bytes = 32;

pub const Plan = struct {
    identifier: []const u8,
    code_limit: u32,
    code_slots: u32,
    hash_offset: u32,
    directory_bytes: u32,
    signature_bytes: u32,
    executable_bytes: u64,

    pub fn init(identifier: []const u8, code_limit: u64, executable_bytes: u64) root.Error!Plan {
        if (identifier.len == 0 or identifier.len > std.math.maxInt(u32) - directory_header_bytes - 8 or
            std.mem.indexOfScalar(u8, identifier, 0) != null)
        {
            return error.UnsupportedMachOExecutablePolicy;
        }
        const limit = std.math.cast(u32, code_limit) orelse return error.SectionLayoutOverflow;
        const ident_end = std.math.add(usize, directory_header_bytes, identifier.len + 1) catch
            return error.SectionLayoutOverflow;
        const hash_offset = std.math.cast(u32, std.mem.alignForward(usize, ident_end, 8)) orelse
            return error.SectionLayoutOverflow;
        const slots: u32 = @intCast((code_limit + hash_page_bytes - 1) / hash_page_bytes);
        const hashes = std.math.mul(u32, slots, hash_bytes) catch return error.SectionLayoutOverflow;
        const directory = std.math.add(u32, hash_offset, hashes) catch return error.SectionLayoutOverflow;
        const signature_bytes = std.math.add(u32, superblob_header_bytes, directory) catch
            return error.SectionLayoutOverflow;
        return .{
            .identifier = identifier,
            .code_limit = limit,
            .code_slots = slots,
            .hash_offset = hash_offset,
            .directory_bytes = directory,
            .signature_bytes = signature_bytes,
            .executable_bytes = executable_bytes,
        };
    }

    /// Covered bytes are already frozen. This writes only their reserved signature
    /// suffix; callers must never mutate covered bytes after this operation.
    pub fn write(self: Plan, image: []u8) void {
        std.debug.assert(image.len == @as(usize, self.code_limit) + self.signature_bytes);
        const out = image[self.code_limit..];
        @memset(out, 0);
        put32(out, 0, 0xfade0cc0);
        put32(out, 4, self.signature_bytes);
        put32(out, 8, 1);
        put32(out, 12, 0); // CSSLOT_CODEDIRECTORY.
        put32(out, 16, superblob_header_bytes);
        const directory = out[superblob_header_bytes..];
        put32(directory, 0, 0xfade0c02);
        put32(directory, 4, self.directory_bytes);
        put32(directory, 8, 0x20400);
        put32(directory, 12, 2); // CS_ADHOC; no entitlements, CMS or hardened grant.
        put32(directory, 16, self.hash_offset);
        put32(directory, 20, directory_header_bytes);
        put32(directory, 24, 0);
        put32(directory, 28, self.code_slots);
        put32(directory, 32, self.code_limit);
        directory[36] = hash_bytes;
        directory[37] = 2; // SHA256.
        directory[38] = 0; // Not an Apple platform binary.
        directory[39] = 12;
        put64(directory, 56, self.code_limit);
        put64(directory, 64, 0); // Executable segment starts at file offset zero.
        put64(directory, 72, self.executable_bytes);
        put64(directory, 80, 1); // CS_EXECSEG_MAIN_BINARY.
        @memcpy(directory[directory_header_bytes..][0..self.identifier.len], self.identifier);
        for (0..self.code_slots) |slot| {
            const start = slot * hash_page_bytes;
            const end = @min(start + hash_page_bytes, self.code_limit);
            var digest: [hash_bytes]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(image[start..end], &digest, .{});
            @memcpy(directory[self.hash_offset + slot * hash_bytes ..][0..hash_bytes], &digest);
        }
    }
};

fn put32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .big);
}

fn put64(bytes: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[offset..][0..8], value, .big);
}
