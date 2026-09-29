const analyze_mod = @import("analyze.zig");
const budget_mod = @import("budget.zig");
const capture_mod = @import("capture.zig");
const identity_mod = @import("identity.zig");
const report_mod = @import("report.zig");
const roots_mod = @import("roots.zig");
const symbolize_mod = @import("symbolize.zig");

pub const analyze = analyze_mod;
pub const budget = budget_mod;
pub const capture = capture_mod;
pub const identity = identity_mod;
pub const report = report_mod;
pub const roots = roots_mod;
pub const symbolize = symbolize_mod;

pub const Attribution = capture_mod.Attribution;
pub const Capture = capture_mod.Capture;
pub const Interner = capture_mod.Interner;
pub const max_frames_limit = capture_mod.max_frames_limit;

pub const Digest = identity_mod.Digest;

pub fn isMetadataLine(line: []const u8) bool {
    return capture_mod.isMetadataLine(line) or
        identity_mod.isMetadataLine(line);
}
