const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const schema = "tiny.build.test-run-receipt/v1";

pub fn digest(rows: anytype) [Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    hasher.update(schema);
    for (rows) |row| {
        hasher.update(&.{0});
        hasher.update(row.name);
        hasher.update(&.{0});
        hasher.update(@tagName(row.status));
        hasher.update(&.{@intFromBool(row.leaked)});
    }
    var result: [Sha256.digest_length]u8 = undefined;
    hasher.final(&result);
    return result;
}
