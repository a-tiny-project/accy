const std = @import("std");

pub const Location = union(enum) {
    unknown: void,

    file: FileLocation,

    file_range: FileRangeLocation,

    name: NameLocation,

    fused: FusedLocation,

    call_site: CallSiteLocation,

    pub const FileLocation = struct {
        filename: []const u8,
        line: u32,
        column: u32,
    };

    pub const FilePosition = struct {
        byte: u64,
        line: u32,
        column: u32,
    };

    pub const FileRangeLocation = struct {
        filename: []const u8,
        start: FilePosition,
        end: FilePosition,
    };

    pub const NameLocation = struct {
        name: []const u8,
        child: ?*const Location,
    };

    pub const FusedLocation = struct {
        locations: []const Location,
        metadata: ?*const anyopaque,
    };

    pub const CallSiteLocation = struct {
        callee: *const Location,
        caller: *const Location,
    };

    pub fn getUnknown() Location {
        return .{ .unknown = {} };
    }

    pub fn getFile(filename: []const u8, line: u32, column: u32) Location {
        return .{ .file = .{
            .filename = filename,
            .line = line,
            .column = column,
        } };
    }

    pub fn getFileRange(
        filename: []const u8,
        start: FilePosition,
        end: FilePosition,
    ) Location {
        std.debug.assert(start.byte <= end.byte);
        return .{ .file_range = .{
            .filename = filename,
            .start = start,
            .end = end,
        } };
    }

    pub fn getName(n: []const u8, child: ?*const Location) Location {
        return .{ .name = .{
            .name = n,
            .child = child,
        } };
    }

    pub fn eql(self: Location, other: Location) bool {
        const Tag = std.meta.Tag(Location);
        if (@as(Tag, self) != @as(Tag, other)) return false;

        return switch (self) {
            .unknown => true,
            .file => |f| {
                const o = other.file;
                return f.line == o.line and f.column == o.column and std.mem.eql(u8, f.filename, o.filename);
            },
            .file_range => |range| {
                const o = other.file_range;
                return range.start.byte == o.start.byte and
                    range.start.line == o.start.line and
                    range.start.column == o.start.column and
                    range.end.byte == o.end.byte and
                    range.end.line == o.end.line and
                    range.end.column == o.end.column and
                    std.mem.eql(u8, range.filename, o.filename);
            },
            .name => |n| {
                const o = other.name;
                if (!std.mem.eql(u8, n.name, o.name)) return false;
                if (n.child == null and o.child == null) return true;
                if (n.child == null or o.child == null) return false;
                return n.child.?.eql(o.child.?.*);
            },
            .fused => |f| {
                const o = other.fused;
                if (f.locations.len != o.locations.len) return false;
                for (f.locations, o.locations) |a, b| {
                    if (!a.eql(b)) return false;
                }
                return f.metadata == o.metadata;
            },
            .call_site => |c| {
                const o = other.call_site;
                return c.callee.eql(o.callee.*) and c.caller.eql(o.caller.*);
            },
        };
    }

    pub fn format(self: Location, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .unknown => try writer.writeAll("loc(unknown)"),
            .file => |f| try writer.print("loc(\"{s}\":{d}:{d})", .{ f.filename, f.line, f.column }),
            .file_range => |range| try writer.print(
                "loc(\"{s}\":{d}:{d}-{d}:{d}@{d}..{d})",
                .{
                    range.filename,
                    range.start.line,
                    range.start.column,
                    range.end.line,
                    range.end.column,
                    range.start.byte,
                    range.end.byte,
                },
            ),
            .name => |n| try writer.print("loc(\"{s}\")", .{n.name}),
            .fused => try writer.writeAll("loc(fused)"),
            .call_site => try writer.writeAll("loc(callsite)"),
        }
    }
};
