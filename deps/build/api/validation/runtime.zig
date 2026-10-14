const std = @import("std");
const validation = @import("root.zig");
const source = @import("source.zig");

pub const patch_list_bytes_max = 64 * 1024;
pub const runtime_commands_max = 16;

/// Shared tool source inputs. A Lean pin uses source.nix's package path
/// shapes, including paths deleted from the new tree.
pub const Kind = enum { zig, lean, gates, lean_pin };

pub const Input = struct {
    path: []const u8,
    kind: Kind,

    pub fn matches(input: Input, changed: []const u8) bool {
        if (input.kind != .lean_pin) return std.mem.eql(u8, input.path, changed);
        if (!validation.plan.within(input.path, changed) or changed.len <= input.path.len) {
            return false;
        }
        var components = std.mem.splitScalar(u8, changed[input.path.len + 1 ..], '/');
        _ = components.next() orelse return false; // family
        _ = components.next() orelse return false; // package
        const tail = components.rest();
        return std.mem.eql(u8, tail, "lean-toolchain") or
            std.mem.eql(u8, tail, "proof/lean-toolchain") or
            std.mem.eql(u8, tail, "proof/lean/lean-toolchain");
    }
};

/// Independent of each owner's source-input budget.
pub const inputs_max = 64;
pub const Mask = u8;

pub fn bit(kind: Kind) Mask {
    return @as(Mask, 1) << @intCast(@backingInt(kind));
}

/// Classify one immutable recipe once per selection. Unreadable declarations
/// conservatively read every group, including standard routes.
pub fn classify(recipe: validation.Recipe) Mask {
    if (!readable(recipe.runtime)) return bit(.zig) | bit(.lean) | bit(.gates) | bit(.lean_pin);
    var mask = bit(.zig);
    if (recipe.runtime.len > 2) mask |= bit(.gates);
    for (recipe.runtime[2..]) |command| {
        if (lean(command)) {
            mask |= bit(.lean) | bit(.lean_pin);
            break;
        }
    }
    return mask;
}

pub const fixed_inputs = [_]Input{
    .{ .path = "nix/zig.nix", .kind = .zig },
    .{ .path = "nix/zig-patches.list", .kind = .zig },
    .{ .path = "nix/zig-consumer-patches.list", .kind = .zig },
    .{ .path = "flake.nix", .kind = .zig },
    .{ .path = "flake.lock", .kind = .zig },
    .{ .path = "nix/lean.nix", .kind = .lean },
    .{ .path = "lib", .kind = .lean_pin },
    .{ .path = "nix/gates.nix", .kind = .gates },
    .{ .path = "nix/gates-source.nix", .kind = .gates },
    .{ .path = "nix/overlay.nix", .kind = .gates },
    .{ .path = "nix/formatters.nix", .kind = .gates },
    .{ .path = "nix/source.nix", .kind = .gates },
};

pub const patch_lists = [_][]const u8{
    "nix/zig-patches.list", "nix/zig-consumer-patches.list",
};

/// Package-only projections and fixture trees may have no pinned compiler.
/// A tree with nix/zig.nix must supply both lists. Observe reads so cached
/// configure graphs regenerate the owner inventory when a list changes.
pub fn load(arena: std.mem.Allocator, tree: source.Tree) ![]const Input {
    const compiler = try tree.readOptional(arena, "nix/zig.nix", source.source_bytes_max);
    var inputs: std.ArrayList(Input) = .empty;
    try inputs.appendSlice(arena, &fixed_inputs);
    for (patch_lists) |path| {
        const bytes = (try tree.readOptional(arena, path, patch_list_bytes_max)) orelse {
            if (compiler != null) return error.MissingValidationCompilerPatchList;
            continue;
        };
        try patches(arena, &inputs, bytes);
    }
    return inputs.toOwnedSlice(arena);
}

fn patches(arena: std.mem.Allocator, inputs: *std.ArrayList(Input), bytes: []const u8) !void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |path| {
        if (path.len == 0) continue;
        if (!validation.plan.validPath(path)) return error.InvalidValidationCompilerPatch;
        var present = false;
        for (inputs.items) |input| {
            if (input.kind == .zig and std.mem.eql(u8, input.path, path)) {
                present = true;
                break;
            }
        }
        if (present) continue;
        if (inputs.items.len == inputs_max) {
            return error.ValidationPlanCapacityExceeded;
        }
        try inputs.append(arena, .{ .path = try arena.dupe(u8, path), .kind = .zig });
    }
}

fn readable(commands: []const []const u8) bool {
    if (commands.len < 2 or commands.len > runtime_commands_max or
        !std.mem.eql(u8, commands[0], "zig") or !std.mem.eql(u8, commands[1], "git"))
        return false;
    for (commands, 0..) |command, index| {
        if (command.len == 0 or !std.ascii.isAlphabetic(command[0])) return false;
        for (command) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
        }
        for (commands[0..index]) |prior| {
            if (std.mem.eql(u8, prior, command)) return false;
        }
    }
    return true;
}

fn lean(command: []const u8) bool {
    for ([_][]const u8{
        "lean",
        "lake",
        "lake-patchelf",
        "leanc",
        "leanchecker",
        "leanir",
    }) |name| {
        if (std.mem.eql(u8, command, name)) return true;
    }
    return false;
}
