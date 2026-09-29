const std = @import("std");

const Dir = std.Io.Dir;

/// Sets the `depth_max` value the tree is laid out for, at two, so a test walks
/// the fixture tree at this depth to get the counts the layout promises. A walk
/// at this bound reaches `nested/deep` and reads it, and stops short of
/// `nested/deep/deeper`.
pub const visible_depth: u8 = 2;

/// Records what went into one tree, handed back by the call that made it. A
/// test compares the walk's results against it, because the counts depend on
/// the host that built the tree.
pub const Layout = struct {
    /// Counts how many font files a walk bounded at `visible_depth` accepts
    /// from the tree, which a test compares against the catalog's entry count.
    fonts: u32,
    /// Holds those files' sizes added together, which a test compares against
    /// the summed sizes of the admitted entries.
    bytes: u64,
    /// Reports whether the directory created with mode zero could still be
    /// opened, as it can for a privileged test process. A test reads this to
    /// know whether the directory was unreadable on this host, and the font
    /// count and the byte total follow this flag because a privileged process
    /// also admits the font inside that directory.
    locked_readable: bool,
};

const locked_mode: Dir.Permissions = @fromBackingInt(@intCast(0o000));
const open_mode: Dir.Permissions = @fromBackingInt(@intCast(0o755));

/// Lays the tree out inside `dir` and reports what went in, which a test calls
/// once to get a tree that exercises every case the walk has to survive. Inside
/// the tree are two levels of subdirectory, one directory below the depth
/// bound, a symbolic link pointing back at its own parent, a symbolic link to a
/// font file, a `.txt` file, a font named with an uppercase extension, and a
/// directory created with mode zero.
pub fn create(io: std.Io, dir: Dir) !Layout {
    try write(io, dir, "Regular.ttf", 64);
    try write(io, dir, "Italic.OTF", 32);
    try write(io, dir, "Notes.txt", 8);
    try dir.symLink(io, "Regular.ttf", "link.ttf", .{});
    try dir.createDir(io, "nested", open_mode);
    try write(io, dir, "nested/Bold.otf", 16);
    try dir.createDir(io, "nested/deep", open_mode);
    try write(io, dir, "nested/deep/Deep.ttc", 24);
    try dir.createDir(io, "nested/deep/deeper", open_mode);
    try write(io, dir, "nested/deep/deeper/TooDeep.ttf", 128);
    try dir.createDir(io, "loop", open_mode);
    try write(io, dir, "loop/Loop.pfb", 48);
    try dir.symLink(io, "../loop", "loop/back", .{ .is_directory = true });
    try dir.createDir(io, "locked", open_mode);
    try write(io, dir, "locked/Hidden.ttf", 12);
    try dir.setFilePermissions(io, "locked", locked_mode, .{});
    const readable = probe(io, dir);
    const layout: Layout = .{
        .fonts = if (readable) 7 else 6,
        .bytes = if (readable) 260 else 248,
        .locked_readable = readable,
    };
    std.debug.assert(layout.fonts >= 6);
    std.debug.assert(layout.bytes >= 248);
    return layout;
}

/// Puts mode 0o755 back on the locked directory, so a test can delete its
/// temporary tree afterwards. A failure to restore it is ignored, because the
/// caller is already tearing the tree down.
pub fn release(io: std.Io, dir: Dir) void {
    dir.setFilePermissions(io, "locked", open_mode, .{}) catch {};
}

fn probe(io: std.Io, dir: Dir) bool {
    var opened = dir.openDir(io, "locked", .{ .iterate = true }) catch return false;
    opened.close(io);
    return true;
}

fn write(io: std.Io, dir: Dir, sub_path: []const u8, bytes: usize) !void {
    var content: [128]u8 = @splat('f');
    std.debug.assert(sub_path.len != 0);
    std.debug.assert(bytes != 0);
    std.debug.assert(bytes <= content.len);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = content[0..bytes] });
}

/// Creates `directories` subdirectories holding `files` font files apiece, at
/// the width a real machine's font directory was measured at, so a benchmark
/// can walk a tree the size of a real host font directory. The call returns the
/// count of files created, the product of the two arguments.
pub fn createCorpus(io: std.Io, dir: Dir, directories: u16, files: u16) !u32 {
    std.debug.assert(directories != 0);
    std.debug.assert(files != 0);
    var directory_name: [32]u8 = undefined;
    var leaf_name: [64]u8 = undefined;
    var created: u32 = 0;
    for (0..directories) |directory| {
        const sub = try std.fmt.bufPrint(&directory_name, "d{d}", .{directory});
        try dir.createDir(io, sub, open_mode);
        for (0..files) |file| {
            const leaf = try std.fmt.bufPrint(&leaf_name, "{s}/f{d}.ttf", .{ sub, file });
            try dir.writeFile(io, .{ .sub_path = leaf, .data = "font" });
            created += 1;
        }
    }
    std.debug.assert(created == @as(u32, directories) * @as(u32, files));
    return created;
}
