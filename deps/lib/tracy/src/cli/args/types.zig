const tracy = @import("../../root.zig");
const compare = tracy.compare;
const context = tracy.context;
const csv = tracy.csv;
const fiber = tracy.fibers;
const find = tracy.find;
const flame = tracy.flame;
const frame = tracy.frame;
const gpu = tracy.gpu;
const lock = tracy.locks;
const memory = tracy.memory;
const message = tracy.messages;
const plot = tracy.plots;
const sample = tracy.samples;
const source = tracy.source;
const stats = tracy.stats;
const summary = tracy.summary;
const system = tracy.system;
const timeline = tracy.timeline;
const tree = tracy.tree;

pub const Format = enum {
    text,
    jsonl,
};

pub const FlameFormat = enum {
    text,
    jsonl,
    folded,
};

pub const SummaryArgs = struct {
    path: []const u8,
    format: Format = .text,
    options: summary.Options = .{},
};

pub const ContextArgs = struct {
    path: []const u8,
    format: Format = .text,
    options: context.Options = .{},
};

pub const ExportArgs = struct {
    path: []const u8,
    mode: csv.Export,
    output: ?[]const u8 = null,
};

pub const TreeArgs = struct {
    path: []const u8,
    format: Format = .text,
    options: tree.Options = .{},
};

pub const StatsArgs = struct {
    path: []const u8,
    format: Format = .text,
    options: stats.Options = .{},
};

pub const FrameArgs = struct {
    path: []const u8,
    format: Format = .text,
    options: frame.Options = .{},
};

pub const MemoryArgs = struct {
    path: []const u8,
    format: Format = .text,
    options: memory.Options = .{},
};

pub const LockArgs = struct {
    path: []const u8,
    format: Format = .text,
    options: lock.Options = .{},
};

pub const MessageArgs = struct {
    path: []const u8,
    format: Format = .text,
    options: message.Options = .{},
};

pub const SampleArgs = struct {
    path: []const u8,
    format: Format = .text,
    options: sample.Options = .{},
};

pub const FiberArgs = struct {
    path: []const u8,
    format: Format = .text,
    options: fiber.Options = .{},
};

pub const GpuArgs = struct {
    path: []const u8,
    format: Format = .text,
    options: gpu.Options = .{},
};

pub const SystemArgs = struct {
    path: []const u8,
    format: Format = .text,
    options: system.Options = .{},
};

pub const PlotArgs = struct {
    path: []const u8,
    format: Format = .text,
    options: plot.Options = .{},
};

pub const FindArgs = struct {
    path: []const u8,
    format: Format = .text,
    options: find.Options,
};

pub const SourceArgs = struct {
    path: []const u8,
    format: Format = .text,
    options: source.Options = .{},
};

pub const FlameArgs = struct {
    path: []const u8,
    format: FlameFormat = .text,
    options: flame.Options = .{},
};

pub const TimelineArgs = struct {
    path: []const u8,
    format: Format = .text,
    options: timeline.Options = .{},
};

pub const CompareArgs = struct {
    baseline_path: []const u8,
    run_path: []const u8,
    format: Format = .text,
    options: compare.Options = .{},
};
