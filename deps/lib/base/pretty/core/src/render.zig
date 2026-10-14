const std = @import("std");
const position = @import("position.zig");
const types = @import("types.zig");

const ColorMode = types.ColorMode;
const Doc = types.Doc;
const LayoutOptions = types.LayoutOptions;
const Style = types.Style;
const WriteState = types.WriteState;

pub const Error = error{
    IndentationOverflow,
    RenderDepthExceeded,
    RenderWorkspaceDepthZero,
    RenderWorkspaceSizeOverflow,
    RenderWorkspaceTooSmall,
    RenderWorkspaceMisaligned,
    RenderWorkspaceInUse,
    RenderFailureRequiresBuiltin,
};

const WriteError = Error || std.Io.Writer.Error;

pub const FlatFitWriter = struct {
    writer: std.Io.Writer,
    limit: usize,
    count: usize = 0,

    pub fn init(limit: usize) FlatFitWriter {
        return .{
            .writer = .{
                .vtable = &.{ .drain = drain },
                .buffer = &.{},
            },
            .limit = limit,
        };
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *FlatFitWriter = @alignCast(@fieldParentPtr("writer", writer));
        try self.accept(writer.buffered());
        writer.end = 0;

        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.accept(bytes);
            consumed += bytes.len;
        }

        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            try self.accept(pattern);
            consumed += pattern.len;
        }
        return consumed;
    }

    fn accept(self: *FlatFitWriter, bytes: []const u8) std.Io.Writer.Error!void {
        var budget = self.limit -| self.count;
        if (!position.consumeFlatBytes(bytes, &budget)) return error.WriteFailed;
        self.count = self.limit - budget;
    }
};

/// Active Doc nodes, root included. Sampled production constructors reach14;
/// 64 gives more than four times that observed depth in a small built-in preset.
/// Flagship callers still need to select their own limits and storage explicitly.
pub const default_render_depth: u32 = 64;

const Mode = enum { flat, broken };
const Phase = enum { enter, children, waiting, restore_style };
const RenderFrame = struct {
    doc: *const Doc,
    child_cursor: usize = 0,
    indent: usize = 0,
    mode: Mode = .broken,
    phase: Phase = .enter,
    previous_style: ?Style = null,
};
const FitFrame = struct {
    doc: *const Doc,
    child_cursor: usize = 0,
    mode: Mode,
};
const Frames = struct { render: []RenderFrame, fit: []FitFrame };
const LineFit = enum { continued, broke, overflowed };
const Workspace = types.Workspace;
const RenderFailure = types.RenderFailure;

pub const workspace_alignment = @max(@alignOf(RenderFrame), @alignOf(FitFrame));
pub const default_workspace_bytes = workspaceBytes(default_render_depth) catch
    @compileError("the built-in renderer workspace must be representable");

pub const WorkspaceLayout = struct {
    render_frame_bytes: u64,
    fit_frame_bytes: u64,
    render_bytes: u64,
    fit_offset: u64,
    fit_bytes: u64,
    total_bytes: u64,
    alignment: u32,
};

pub fn workspaceLayout(depth: u32) Error!WorkspaceLayout {
    if (depth == 0) return error.RenderWorkspaceDepthZero;
    const render_bytes = std.math.mul(u64, depth, @sizeOf(RenderFrame)) catch
        return error.RenderWorkspaceSizeOverflow;
    const padded = std.math.add(u64, render_bytes, @alignOf(FitFrame) - 1) catch
        return error.RenderWorkspaceSizeOverflow;
    const fit_offset = padded & ~@as(u64, @alignOf(FitFrame) - 1);
    const fit_bytes = std.math.mul(u64, depth, @sizeOf(FitFrame)) catch
        return error.RenderWorkspaceSizeOverflow;
    const total_bytes = std.math.add(u64, fit_offset, fit_bytes) catch
        return error.RenderWorkspaceSizeOverflow;
    return .{
        .render_frame_bytes = @sizeOf(RenderFrame),
        .fit_frame_bytes = @sizeOf(FitFrame),
        .render_bytes = render_bytes,
        .fit_offset = fit_offset,
        .fit_bytes = fit_bytes,
        .total_bytes = total_bytes,
        .alignment = workspace_alignment,
    };
}

/// Bytes for depth render frames plus depth simultaneously live fit frames.
/// The caller aligns the region to workspace_alignment and borrows it exclusively.
pub fn workspaceBytes(depth: u32) Error!usize {
    return std.math.cast(
        usize,
        (try workspaceLayout(depth)).total_bytes,
    ) orelse error.RenderWorkspaceSizeOverflow;
}

/// Reconstructs built-in numeric evidence and root context after depth rejection.
/// A supplied workspace has its own last_failure and is rejected by this helper.
pub fn builtinDepthFailure(doc: Doc, workspace: ?*Workspace) Error!RenderFailure {
    if (workspace != null) return error.RenderFailureRequiresBuiltin;
    return .{
        .limit = .render_depth,
        .value = default_render_depth,
        .use = default_render_depth,
        .request = 1,
        .reached_depth = @as(u64, default_render_depth) + 1,
        .doc = doc,
        .context = .reconstructed_root,
        .supplied_workspace = false,
    };
}

/// Keeps the allocating entrypoint's error contract. Depth alone grows caller-
/// allocated traversal storage before output; it is never a policy refusal here.
/// OutOfMemory includes an unrepresentable workspace or exhausted u32 depth domain,
/// as well as physical allocation failure. Bounded callers receive typed limits.
pub const AllocError = error{ OutOfMemory, IndentationOverflow, WriteFailed };

pub fn renderAlloc(
    allocator: std.mem.Allocator,
    doc: Doc,
    options: LayoutOptions,
) AllocError![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const fits_builtin = if (executeBuiltin(
        true,
        &out.writer,
        doc,
        options,
        .{},
        null,
    )) |_| true else |err| switch (err) {
        error.RenderDepthExceeded => false,
        else => return allocatingError(err),
    };
    if (!fits_builtin) try renderGrowing(allocator, &out.writer, doc, options);
    return try out.toOwnedSlice();
}

// Exactly26 heap capacities follow D64: 128 through2^31, then maxInt(u32).
// A freeing allocator retains at most one workspace at a time. An arena may
// retain the sum of all26 allocations even though every attempted region is freed.
fn renderGrowing(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    doc: Doc,
    options: LayoutOptions,
) AllocError!void {
    var depth = nextAllocDepth(default_render_depth).?;
    while (true) {
        std.debug.assert(depth > default_render_depth);
        const size = workspaceBytes(depth) catch return error.OutOfMemory;
        const bytes = try allocator.alignedAlloc(u8, .fromByteUnits(workspace_alignment), size);
        defer allocator.free(bytes);
        var workspace: Workspace = .{ .bytes = bytes, .max_depth = depth };
        _ = executeWorkspace(
            true,
            writer,
            doc,
            options,
            .{},
            &workspace,
            null,
            true,
        ) catch |err| switch (err) {
            error.RenderDepthExceeded => {
                depth = nextAllocDepth(depth) orelse return error.OutOfMemory;
                continue;
            },
            else => return allocatingError(err),
        };
        return;
    }
}

fn nextAllocDepth(depth: u32) ?u32 {
    std.debug.assert(depth >= default_render_depth);
    if (depth == std.math.maxInt(u32)) return null;
    const next = std.math.mul(u32, depth, 2) catch std.math.maxInt(u32);
    std.debug.assert(next > depth);
    return next;
}

fn allocatingError(err: WriteError) AllocError {
    return switch (err) {
        error.IndentationOverflow => error.IndentationOverflow,
        // Preserve the writer's error even when its drain failed to allocate.
        error.WriteFailed => error.WriteFailed,
        else => unreachable, // Internally owned regions satisfy every shape invariant.
    };
}

pub fn write(writer: *std.Io.Writer, doc: Doc, options: LayoutOptions) WriteError!void {
    try writeWithState(writer, doc, options, .{});
}

pub fn writeWithState(
    writer: *std.Io.Writer,
    doc: Doc,
    options: LayoutOptions,
    state: WriteState,
) WriteError!void {
    _ = try executeBuiltin(true, writer, doc, options, state, null);
}

pub fn writeWithFailure(
    writer: *std.Io.Writer,
    doc: Doc,
    options: LayoutOptions,
    sink: ?*?RenderFailure,
) WriteError!void {
    _ = try executeBuiltin(true, writer, doc, options, .{}, sink);
}

pub fn writeBounded(
    writer: *std.Io.Writer,
    doc: Doc,
    options: LayoutOptions,
    workspace: *Workspace,
    sink: ?*?RenderFailure,
) WriteError!void {
    try writeBoundedWithState(writer, doc, options, .{}, workspace, sink);
}

pub fn writeBoundedWithState(
    writer: *std.Io.Writer,
    doc: Doc,
    options: LayoutOptions,
    state: WriteState,
    workspace: *Workspace,
    sink: ?*?RenderFailure,
) WriteError!void {
    _ = try executeWorkspace(true, writer, doc, options, state, workspace, sink, true);
}

/// Checks every occurrence before writer mutation and returns maximum active depth.
/// Cycles are rejected by the depth ceiling, not diagnosed as cycles.
pub fn preflight(doc: Doc, options: LayoutOptions) Error!u32 {
    return executeBuiltin(false, null, doc, options, .{}, null);
}

pub fn preflightBounded(doc: Doc, workspace: *Workspace, sink: ?*?RenderFailure) Error!u32 {
    return executeWorkspace(false, null, doc, .{}, .{}, workspace, sink, true);
}

fn ExecutionError(comptime output: bool) type {
    return if (output) WriteError else Error;
}

// Only this out-of-line branch owns the built-in arrays. Supplied and grown
// storage call executeWorkspace directly, without reserving the built-in region.
noinline fn executeBuiltin(
    comptime output: bool,
    writer: ?*std.Io.Writer,
    doc: Doc,
    options: LayoutOptions,
    state: WriteState,
    sink: ?*?RenderFailure,
) ExecutionError(output)!u32 {
    var bytes: [default_workspace_bytes]u8 align(workspace_alignment) = undefined;
    var workspace: Workspace = .{ .bytes = &bytes, .max_depth = default_render_depth };
    return executeWorkspace(output, writer, doc, options, state, &workspace, sink, false);
}

fn executeWorkspace(
    comptime output: bool,
    writer: ?*std.Io.Writer,
    doc: Doc,
    options: LayoutOptions,
    state: WriteState,
    workspace: *Workspace,
    sink: ?*?RenderFailure,
    supplied: bool,
) ExecutionError(output)!u32 {
    if (workspace.in_use) {
        if (sink) |target| {
            if (target != &workspace.last_failure) target.* = failure(
                .workspace_use,
                1,
                1,
                1,
                doc,
                supplied,
            );
        }
        return error.RenderWorkspaceInUse;
    }
    workspace.in_use = true;
    defer workspace.in_use = false;
    workspace.last_failure = null;
    if (sink) |target| target.* = null;
    const frames = try placeFrames(workspace, doc, sink, supplied);
    const depth = try checkDepth(&doc, frames.render, workspace, sink, supplied);
    if (output) {
        std.debug.assert(writer != null);
        var renderer = Renderer{
            .writer = writer.?,
            .width = options.width,
            .color = options.color,
            .col = state.column,
            .frames = frames,
        };
        try renderer.writeDoc(&doc, state.indent);
    }
    workspace.last_failure = null;
    if (sink) |target| target.* = null;
    return depth;
}

fn failure(
    limit: types.RenderLimit,
    value: u64,
    use: u64,
    request: u64,
    doc: Doc,
    supplied: bool,
) RenderFailure {
    return .{
        .limit = limit,
        .value = value,
        .use = use,
        .request = request,
        .doc = doc,
        .supplied_workspace = supplied,
    };
}

fn storageFailure(capacity: u64, required: u64, doc: Doc, supplied: bool) RenderFailure {
    std.debug.assert(required > capacity);
    var rejected = failure(.workspace_bytes, capacity, 0, required, doc, supplied);
    rejected.storage = .{
        .capacity = capacity,
        .required = required,
        .deficit = required - capacity,
    };
    return rejected;
}

fn saveFailure(workspace: *Workspace, sink: ?*?RenderFailure, rejected: RenderFailure) void {
    std.debug.assert(workspace.in_use);
    workspace.last_failure = rejected;
    if (sink) |target| target.* = rejected;
}

fn placeFrames(
    workspace: *Workspace,
    doc: Doc,
    sink: ?*?RenderFailure,
    supplied: bool,
) Error!Frames {
    const layout = workspaceLayout(workspace.max_depth) catch |err| {
        saveFailure(workspace, sink, failure(.workspace_depth, 0, 0, 1, doc, supplied));
        return err;
    };
    const needed = layout.total_bytes;
    const bytes = std.math.cast(usize, needed) orelse {
        saveFailure(workspace, sink, storageFailure(workspace.bytes.len, needed, doc, supplied));
        return error.RenderWorkspaceSizeOverflow;
    };
    if (workspace.bytes.len < bytes) {
        saveFailure(workspace, sink, storageFailure(workspace.bytes.len, needed, doc, supplied));
        return error.RenderWorkspaceTooSmall;
    }
    const misalignment = @intFromPtr(workspace.bytes.ptr) % workspace_alignment;
    if (misalignment != 0) {
        saveFailure(
            workspace,
            sink,
            failure(
                .workspace_alignment,
                workspace_alignment,
                misalignment,
                workspace_alignment - misalignment,
                doc,
                supplied,
            ),
        );
        return error.RenderWorkspaceMisaligned;
    }
    const depth: usize = @intCast(workspace.max_depth);
    const render_bytes = depth * @sizeOf(RenderFrame);
    const fit_offset = std.mem.alignForward(usize, render_bytes, @alignOf(FitFrame));
    const render_frames = std.mem.bytesAsSlice(
        RenderFrame,
        @as([]align(@alignOf(RenderFrame)) u8, @alignCast(workspace.bytes[0..render_bytes])),
    );
    const fit_frames = std.mem.bytesAsSlice(
        FitFrame,
        @as([]align(@alignOf(FitFrame)) u8, @alignCast(workspace.bytes[fit_offset..bytes])),
    );
    std.debug.assert(render_frames.len == depth);
    std.debug.assert(fit_frames.len == depth);
    std.debug.assert(fit_offset >= render_bytes);
    std.debug.assert(bytes <= workspace.bytes.len);
    return .{ .render = render_frames, .fit = fit_frames };
}

fn checkDepth(
    root: *const Doc,
    frames: []RenderFrame,
    workspace: *Workspace,
    sink: ?*?RenderFailure,
    supplied: bool,
) Error!u32 {
    std.debug.assert(frames.len > 0);
    frames[0] = .{ .doc = root };
    var used: usize = 1;
    var deepest: usize = 1;
    while (used != 0) {
        std.debug.assert(used <= frames.len);
        const frame = &frames[used - 1];
        const child = nextChild(frame.doc, &frame.child_cursor) orelse {
            used -= 1;
            continue;
        };
        if (used == frames.len) {
            var rejected = failure(.render_depth, workspace.max_depth, used, 1, child.*, supplied);
            rejected.reached_depth = @as(u64, workspace.max_depth) + 1;
            rejected.context = .offending_child;
            saveFailure(workspace, sink, rejected);
            return error.RenderDepthExceeded;
        }
        frames[used] = .{ .doc = child };
        used += 1;
        deepest = @max(deepest, used);
    }
    std.debug.assert(deepest <= workspace.max_depth);
    return @intCast(deepest);
}

fn nextChild(doc: *const Doc, cursor: *usize) ?*const Doc {
    switch (doc.*) {
        .concat => |parts| {
            std.debug.assert(cursor.* <= parts.len);
            if (cursor.* == parts.len) return null;
            const child = &parts[cursor.*];
            cursor.* += 1;
            return child;
        },
        .nest, .group, .styled => {
            std.debug.assert(cursor.* <= 1);
            if (cursor.* == 1) return null;
            cursor.* = 1;
            return switch (doc.*) {
                .nest => |nested| nested.doc,
                .group => |grouped| grouped,
                .styled => |styled| styled.doc,
                else => unreachable,
            };
        },
        else => return null,
    }
}

const Renderer = struct {
    writer: *std.Io.Writer,
    width: usize,
    color: ColorMode,
    frames: Frames,
    col: usize = 0,
    active_style: ?Style = null,
    used: usize = 0,

    fn writeDoc(self: *Renderer, doc: *const Doc, indent: usize) WriteError!void {
        std.debug.assert(self.used == 0);
        self.push(doc, indent, .broken);
        while (self.used != 0) {
            std.debug.assert(self.used <= self.frames.render.len);
            const frame = &self.frames.render[self.used - 1];
            switch (frame.phase) {
                .enter => try self.enter(frame),
                .children => {
                    if (nextChild(frame.doc, &frame.child_cursor)) |child| {
                        self.push(child, frame.indent, frame.mode);
                    } else self.used -= 1;
                },
                .waiting => self.used -= 1,
                .restore_style => {
                    std.debug.assert(self.active_style == frame.doc.styled.style);
                    try self.writeStyleEnd(frame.previous_style);
                    self.active_style = frame.previous_style;
                    self.used -= 1;
                },
            }
        }
        std.debug.assert(self.active_style == null);
    }

    fn push(self: *Renderer, doc: *const Doc, indent: usize, mode: Mode) void {
        std.debug.assert(self.used < self.frames.render.len);
        self.frames.render[self.used] = .{ .doc = doc, .indent = indent, .mode = mode };
        self.used += 1;
    }

    fn enter(self: *Renderer, frame: *RenderFrame) WriteError!void {
        switch (frame.doc.*) {
            .concat => frame.phase = .children,
            .nest => |nested| {
                const indent = std.math.add(usize, frame.indent, nested.amount) catch
                    return error.IndentationOverflow;
                frame.phase = .waiting;
                self.push(nested.doc, indent, frame.mode);
            },
            .group => |grouped| {
                const mode: Mode = if (frame.mode == .flat or self.fits(grouped))
                    .flat
                else
                    .broken;
                frame.phase = .waiting;
                self.push(grouped, frame.indent, mode);
            },
            .styled => |styled| {
                frame.phase = .waiting;
                if (styled.style != .plain) {
                    frame.previous_style = self.active_style;
                    try self.writeStyleStart(styled.style);
                    self.active_style = styled.style;
                    frame.phase = .restore_style;
                }
                self.push(styled.doc, frame.indent, frame.mode);
            },
            else => {
                try self.writeLeaf(frame);
                self.used -= 1;
            },
        }
    }

    fn writeLeaf(self: *Renderer, frame: *const RenderFrame) std.Io.Writer.Error!void {
        switch (frame.doc.*) {
            .empty => {},
            .text => |bytes| try self.writeBytes(bytes),
            .line => |bytes| {
                if (frame.mode == .flat) return self.writeBytes(bytes);
                try self.writeBreak(frame.indent);
            },
            .hardline => try self.writeBreak(frame.indent),
            else => unreachable,
        }
    }

    fn writeBytes(self: *Renderer, bytes: []const u8) std.Io.Writer.Error!void {
        try self.writer.writeAll(bytes);
        self.col = position.Summary.fromBytes(bytes).advance(.{ .column = self.col }).column;
    }

    fn writeBreak(self: *Renderer, indent: usize) std.Io.Writer.Error!void {
        try self.writer.writeByte('\n');
        try self.writer.splatByteAll(' ', indent);
        self.col = indent;
    }

    fn fits(self: *const Renderer, doc: *const Doc) bool {
        var remaining = self.width -| self.col;
        if (fitWalk(doc, .flat, true, self.frames.fit, &remaining) != .continued) return false;
        var ancestor = self.used;
        while (ancestor != 0) {
            ancestor -= 1;
            const frame = &self.frames.render[ancestor];
            if (frame.doc.* != .concat) continue;
            const parts = frame.doc.concat;
            std.debug.assert(frame.child_cursor <= parts.len);
            for (parts[frame.child_cursor..]) |*pending| {
                switch (fitWalk(pending, frame.mode, false, self.frames.fit, &remaining)) {
                    .continued => {},
                    .broke => return true,
                    .overflowed => return false,
                }
            }
        }
        return true;
    }

    fn writeStyleStart(self: *Renderer, style: Style) std.Io.Writer.Error!void {
        if (self.color != .ansi or style == .plain) return;
        try self.writer.writeAll(ansiCodeFor(style));
    }

    fn writeStyleEnd(self: *Renderer, previous: ?Style) std.Io.Writer.Error!void {
        if (self.color != .ansi) return;
        try self.writer.writeAll(ansi_reset);
        if (previous) |style| {
            if (style != .plain) try self.writer.writeAll(ansiCodeFor(style));
        }
    }
};

fn fitWalk(
    root: *const Doc,
    mode: Mode,
    candidate: bool,
    frames: []FitFrame,
    budget: *usize,
) LineFit {
    std.debug.assert(frames.len > 0);
    frames[0] = .{ .doc = root, .mode = mode };
    var used: usize = 1;
    while (used != 0) {
        std.debug.assert(used <= frames.len);
        const frame = &frames[used - 1];
        if (nextChild(frame.doc, &frame.child_cursor)) |child| {
            std.debug.assert(used < frames.len);
            frames[used] = .{ .doc = child, .mode = frame.mode };
            used += 1;
            continue;
        }
        const result = fitLeaf(frame.doc.*, frame.mode, candidate, budget);
        if (result != .continued) return result;
        used -= 1;
    }
    return .continued;
}

fn fitLeaf(doc: Doc, mode: Mode, candidate: bool, budget: *usize) LineFit {
    const bytes = switch (doc) {
        .text => |bytes| bytes,
        .line => |bytes| if (mode == .flat) bytes else return .broke,
        .hardline => return if (candidate) .overflowed else .broke,
        else => return .continued,
    };
    if (candidate) {
        return if (position.consumeFlatBytes(bytes, budget)) .continued else .overflowed;
    }
    return consumeLineBytes(bytes, budget);
}

fn consumeLineBytes(bytes: []const u8, budget: *usize) LineFit {
    const prefix = bytes[0..@min(bytes.len, budget.* +| 1)];
    if (std.mem.findAny(u8, prefix, "\r\n")) |index| {
        budget.* -= index;
        return .broke;
    }
    if (bytes.len > budget.*) return .overflowed;
    budget.* -= bytes.len;
    return .continued;
}

const ansi_reset = "\x1b[0m";

fn ansiCodeFor(style_kind: Style) []const u8 {
    return switch (style_kind) {
        .plain => "",
        .title => "\x1b[1;96m",
        .keyword => "\x1b[1;94m",
        .name => "\x1b[96m",
        .value => "\x1b[32m",
        .string => "\x1b[32m",
        .number => "\x1b[35m",
        .type_name => "\x1b[33m",
        .attribute => "\x1b[36m",
        .block_label => "\x1b[1;35m",
        .source => "\x1b[37m",
        .punctuation => "\x1b[2m",
        .muted => "\x1b[2m",
        .accent => "\x1b[1m",
        .warning => "\x1b[1;33m",
        .danger => "\x1b[1;31m",
    };
}
