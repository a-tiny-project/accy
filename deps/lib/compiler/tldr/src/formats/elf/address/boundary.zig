const std = @import("std");

pub const Boundary = struct {
    section_name: []const u8,
    stop: bool,
    optional: bool = false,
    match_prefix: bool = false,
    output_section: bool = false,

    pub const Context = struct {
        pub fn hash(_: Context, boundary: Boundary) u64 {
            var value = hashU64(0xd297a1b0a6e8d5f3, @intFromBool(boundary.stop));
            value = hashU64(value, @intFromBool(boundary.optional));
            value = hashU64(value, @intFromBool(boundary.match_prefix));
            value = hashU64(value, @intFromBool(boundary.output_section));
            return std.hash.Wyhash.hash(value, boundary.section_name);
        }

        pub fn eql(_: Context, left: Boundary, right: Boundary) bool {
            return left.stop == right.stop and
                left.optional == right.optional and
                left.match_prefix == right.match_prefix and
                left.output_section == right.output_section and
                std.mem.eql(u8, left.section_name, right.section_name);
        }
    };
};

pub fn forSymbol(symbol_name: []const u8) ?Boundary {
    if (std.mem.eql(u8, symbol_name, "__ehdr_start")) return .{ .section_name = "", .stop = false, .optional = true };
    if (std.mem.eql(u8, symbol_name, "__rela_iplt_start")) return .{ .section_name = ".rela.iplt", .stop = false, .optional = true, .output_section = true };
    if (std.mem.eql(u8, symbol_name, "__rela_iplt_end")) return .{ .section_name = ".rela.iplt", .stop = true, .optional = true, .output_section = true };
    if (arrayForSymbol(symbol_name, "__preinit_array_start", "__preinit_array_end", ".preinit_array")) |boundary| return boundary;
    if (arrayForSymbol(symbol_name, "__init_array_start", "__init_array_end", ".init_array")) |boundary| return boundary;
    if (arrayForSymbol(symbol_name, "__fini_array_start", "__fini_array_end", ".fini_array")) |boundary| return boundary;

    const start_prefix = "__start_";
    const stop_prefix = "__stop_";
    if (std.mem.startsWith(u8, symbol_name, start_prefix)) {
        const section_name = symbol_name[start_prefix.len..];
        if (isCIdentifier(section_name)) return .{ .section_name = section_name, .stop = false };
    }
    if (std.mem.startsWith(u8, symbol_name, stop_prefix)) {
        const section_name = symbol_name[stop_prefix.len..];
        if (isCIdentifier(section_name)) return .{ .section_name = section_name, .stop = true };
    }
    return null;
}

pub fn sectionNameMatches(boundary: Boundary, section_name: []const u8) bool {
    if (std.mem.eql(u8, section_name, boundary.section_name)) return true;
    return boundary.match_prefix and
        section_name.len > boundary.section_name.len and
        std.mem.startsWith(u8, section_name, boundary.section_name) and
        section_name[boundary.section_name.len] == '.';
}

fn arrayForSymbol(symbol_name: []const u8, start_name: []const u8, end_name: []const u8, section_name: []const u8) ?Boundary {
    if (std.mem.eql(u8, symbol_name, start_name)) {
        return .{ .section_name = section_name, .stop = false, .optional = true, .match_prefix = true };
    }
    if (std.mem.eql(u8, symbol_name, end_name)) {
        return .{ .section_name = section_name, .stop = true, .optional = true, .match_prefix = true };
    }
    return null;
}

fn isCIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!isCIdentifierStart(name[0])) return false;
    for (name[1..]) |byte| {
        if (!isCIdentifierContinue(byte)) return false;
    }
    return true;
}

fn isCIdentifierStart(byte: u8) bool {
    return byte == '_' or (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
}

fn isCIdentifierContinue(byte: u8) bool {
    return isCIdentifierStart(byte) or (byte >= '0' and byte <= '9');
}

fn hashU64(seed: u64, value: u64) u64 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    return std.hash.Wyhash.hash(seed, &bytes);
}
