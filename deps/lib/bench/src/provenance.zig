const std = @import("std");
const options = @import("profile_build_options");

test "generated profile build provenance is complete" {
    try std.testing.expect(options.git_sha.len == 12 or std.mem.eql(u8, options.git_sha, "unknown"));
    try std.testing.expect(@TypeOf(options.git_dirty) == bool);
    try std.testing.expect(options.optimize.len != 0);
    try std.testing.expect(options.target.len != 0);
    try std.testing.expect(options.host_os.len != 0);
    try std.testing.expect(options.host_arch.len != 0);
}
