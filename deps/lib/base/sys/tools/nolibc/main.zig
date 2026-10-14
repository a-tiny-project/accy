//! `nolibc-inspect <label> <checks> <path>`: inspects one ELF artifact for
//! the C runtime. `checks` is `u` to check undefined symbols too, or `-` for
//! the needed libraries alone. Each finding is printed to stderr. The exit
//! status is 1 for a finding, and 2 for a file that cannot be opened or
//! inspected or for arguments that do not match the usage line.

const std = @import("std");
const nolibc = @import("root.zig");

const Printer = struct {
    stderr: *std.Io.Writer,
    label: []const u8,
    path: []const u8,

    fn found(context: *anyopaque, kind: nolibc.Kind, name: []const u8) void {
        const printer: *Printer = @ptrCast(@alignCast(context));
        const what = switch (kind) {
            .needed_library => "links forbidden C runtime library",
            .undefined_symbol => "exposes forbidden unresolved C runtime symbol",
        };
        printer.stderr.print(
            "[{s}] {s} {s}: {s}\n",
            .{ printer.label, printer.path, what, name },
        ) catch {};
    }
};

const usage = "usage: nolibc-inspect <label> <-|u> <path>\n";

pub fn main(init: std.process.Init) u8 {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    defer stderr.interface.flush() catch {};

    const arguments = init.minimal.args.toSlice(init.arena.allocator()) catch |err| {
        stderr.interface.print("nolibc-inspect: cannot read arguments: {t}\n", .{err}) catch {};
        return 2;
    };
    if (arguments.len != 4) {
        stderr.interface.writeAll(usage) catch {};
        return 2;
    }
    const label = arguments[1];
    const path = arguments[3];
    const checks = parseChecks(arguments[2]) orelse {
        stderr.interface.writeAll(usage) catch {};
        return 2;
    };
    var printer: Printer = .{ .stderr = &stderr.interface, .label = label, .path = path };

    const file = std.Io.Dir.cwd().openFile(init.io, path, .{}) catch |err|
        return refuse(&stderr.interface, label, path, err);
    defer file.close(init.io);
    const report: nolibc.Report = .{ .context = &printer, .found = Printer.found };
    nolibc.inspect(init.io, file, checks, report) catch |err| switch (err) {
        error.LinksRuntimeLibrary, error.ExposesRuntimeSymbol => return 1,
        else => |failure| return refuse(&stderr.interface, label, path, failure),
    };
    return 0;
}

fn refuse(stderr: *std.Io.Writer, label: []const u8, path: []const u8, failure: anyerror) u8 {
    stderr.print("[{s}] {s} cannot be inspected: {t}\n", .{ label, path, failure }) catch {};
    return 2;
}

fn parseChecks(text: []const u8) ?nolibc.Checks {
    if (std.mem.eql(u8, text, "-")) return .{};
    if (std.mem.eql(u8, text, "u")) return .{ .undefined_symbols = true };
    return null;
}
