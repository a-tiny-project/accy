const std = @import("std");
const pretty_json = @import("pretty").json;
const capture_mod = @import("capture.zig");
const report = @import("report.zig");
const event = @import("event.zig");
const record_mod = @import("record.zig");
const transport = @import("transport.zig");

pub const schema = "tracy.context/v0";
pub const CaptureIntegrity = capture_mod.Integrity;

pub const Group = enum {
    thread,
    cpu,
    reason,
    state,
    transition,
    none,

    pub fn fromName(text: []const u8) ?Group {
        if (std.mem.eql(u8, text, "thread")) return .thread;
        if (std.mem.eql(u8, text, "cpu")) return .cpu;
        if (std.mem.eql(u8, text, "reason")) return .reason;
        if (std.mem.eql(u8, text, "state")) return .state;
        if (std.mem.eql(u8, text, "transition")) return .transition;
        if (std.mem.eql(u8, text, "none")) return .none;
        return null;
    }

    fn tag(self: Group) []const u8 {
        return switch (self) {
            .thread => "thread",
            .cpu => "cpu",
            .reason => "reason",
            .state => "state",
            .transition => "transition",
            .none => "none",
        };
    }
};

pub const Sort = enum {
    running,
    blocked,
    ready,
    latency,
    switches,
    wakeups,
    migrations,
    last,
    thread,
    cpu,
    label,

    pub fn fromName(text: []const u8) ?Sort {
        if (std.mem.eql(u8, text, "running")) return .running;
        if (std.mem.eql(u8, text, "blocked")) return .blocked;
        if (std.mem.eql(u8, text, "ready")) return .ready;
        if (std.mem.eql(u8, text, "latency")) return .latency;
        if (std.mem.eql(u8, text, "switches")) return .switches;
        if (std.mem.eql(u8, text, "wakeups")) return .wakeups;
        if (std.mem.eql(u8, text, "migrations")) return .migrations;
        if (std.mem.eql(u8, text, "last")) return .last;
        if (std.mem.eql(u8, text, "thread")) return .thread;
        if (std.mem.eql(u8, text, "cpu")) return .cpu;
        if (std.mem.eql(u8, text, "label")) return .label;
        return null;
    }

    fn tag(self: Sort) []const u8 {
        return switch (self) {
            .running => "running",
            .blocked => "blocked",
            .ready => "ready",
            .latency => "latency",
            .switches => "switches",
            .wakeups => "wakeups",
            .migrations => "migrations",
            .last => "last",
            .thread => "thread",
            .cpu => "cpu",
            .label => "label",
        };
    }
};

pub const Options = struct {
    top: usize = 20,
    occurrences: usize = 80,
    group: Group = .thread,
    sort: Sort = .running,
    thread: ?u64 = null,
    cpu: ?u32 = null,
    since_ns: ?u64 = null,
    until_ns: ?u64 = null,
    match: ?[]const u8 = null,
    ignore_case: bool = false,
};

pub const Counters = struct {
    events: u64 = 0,
    switches: u64 = 0,
    wakeups: u64 = 0,
    thread_names: u64 = 0,
    ready_latency_samples: u64 = 0,
    redundant_wakeups: u64 = 0,
    ready_time_regressions: u64 = 0,
    filtered: u64 = 0,
    groups: u64 = 0,
    duration_ns: u64 = 0,
};

const ReasonState = struct {
    label: []const u8,
    threads: std.AutoHashMapUnmanaged(u64, void) = .{},
    cpus: std.AutoHashMapUnmanaged(u32, void) = .{},
    count: u64 = 0,
    blocked_ns: u64 = 0,
    ready_ns: u64 = 0,
    unknown_off_cpu_ns: u64 = 0,
    first_ns: u64 = 0,
    last_ns: u64 = 0,

    fn deinit(self: *ReasonState, allocator: std.mem.Allocator) void {
        self.threads.deinit(allocator);
        self.cpus.deinit(allocator);
        self.* = undefined;
    }
};

const TransitionState = struct {
    label: []const u8,
    prev_thread: u64 = 0,
    next_thread: u64 = 0,
    count: u64 = 0,
    first_ns: u64 = 0,
    last_ns: u64 = 0,

    fn deinit(self: *TransitionState, _: std.mem.Allocator) void {
        self.* = undefined;
    }
};

const CpuState = struct {
    id: u32,
    switches: u64 = 0,
    running_ns: u64 = 0,
    idle_ns: u64 = 0,
    current_thread: u64 = 0,
    current_since_ns: ?u64 = null,
    first_ns: u64 = 0,
    last_ns: u64 = 0,
};

const ThreadState = struct {
    id: u64,
    name: ?[]u8 = null,
    switch_ins: u64 = 0,
    switch_outs: u64 = 0,
    wakeups: u64 = 0,
    running_ns: u64 = 0,
    blocked_ns: u64 = 0,
    ready_ns: u64 = 0,
    ready_latencies: std.ArrayListUnmanaged(u64) = .empty,
    unknown_off_cpu_ns: u64 = 0,
    migrations: u64 = 0,
    running_since_ns: ?u64 = null,
    off_cpu_since_ns: ?u64 = null,
    ready_since_ns: ?u64 = null,
    last_cpu: ?u32 = null,
    off_cpu_reason: ?[]u8 = null,
    off_cpu_state: ?[]u8 = null,
    first_ns: u64 = 0,
    last_ns: u64 = 0,

    fn deinit(self: *ThreadState, allocator: std.mem.Allocator) void {
        if (self.name) |name| allocator.free(name);
        if (self.off_cpu_reason) |reason| allocator.free(reason);
        if (self.off_cpu_state) |state| allocator.free(state);
        self.ready_latencies.deinit(allocator);
        self.* = undefined;
    }

    fn displayName(self: ThreadState) []const u8 {
        return self.name orelse "";
    }
};

const OccurrenceKind = enum {
    context_switch,
    wakeup,

    fn tag(self: OccurrenceKind) []const u8 {
        return switch (self) {
            .context_switch => "switch",
            .wakeup => "wakeup",
        };
    }
};

const Occurrence = struct {
    kind: OccurrenceKind,
    seq: u64 = 0,
    time_ns: u64 = 0,
    source_thread: u64 = 0,
    cpu: ?u32 = null,
    prev_thread: u64 = 0,
    next_thread: u64 = 0,
    target_thread: u64 = 0,
    reason: ?[]u8 = null,
    state: ?[]u8 = null,
    previous_cstate: ?u32 = null,
    prev_priority: ?i64 = null,
    next_priority: ?i64 = null,
    priority_increment: ?i64 = null,
    ready_latency_ns: ?u64 = null,

    fn deinit(self: *Occurrence, allocator: std.mem.Allocator) void {
        if (self.reason) |reason| allocator.free(reason);
        if (self.state) |state| allocator.free(state);
        self.* = undefined;
    }
};

pub const Summary = struct {
    group: Group,
    label: []u8,
    count: u64 = 0,
    thread: ?u64 = null,
    cpu: ?u32 = null,
    prev_thread: u64 = 0,
    next_thread: u64 = 0,
    switch_ins: u64 = 0,
    switch_outs: u64 = 0,
    wakeups: u64 = 0,
    running_ns: u64 = 0,
    blocked_ns: u64 = 0,
    ready_ns: u64 = 0,
    ready_latency_samples: u64 = 0,
    ready_latency_mean_ns: u64 = 0,
    ready_latency_min_ns: u64 = 0,
    ready_latency_p50_ns: u64 = 0,
    ready_latency_p90_ns: u64 = 0,
    ready_latency_p99_ns: u64 = 0,
    ready_latency_max_ns: u64 = 0,
    unknown_off_cpu_ns: u64 = 0,
    idle_ns: u64 = 0,
    migrations: u64 = 0,
    first_ns: u64 = 0,
    last_ns: u64 = 0,

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        self.* = undefined;
    }
};

pub const Analyzer = struct {
    allocator: std.mem.Allocator,
    capture: capture_mod.Tracker = .{},
    threads: std.AutoHashMapUnmanaged(u64, ThreadState) = .{},
    cpus: std.AutoHashMapUnmanaged(u32, CpuState) = .{},
    reasons: std.StringHashMapUnmanaged(ReasonState) = .{},
    states: std.StringHashMapUnmanaged(ReasonState) = .{},
    transitions: std.StringHashMapUnmanaged(TransitionState) = .{},
    occurrences: std.ArrayListUnmanaged(Occurrence) = .empty,
    counters: Counters = .{},
    start_ns: ?u64 = null,
    end_ns: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) Analyzer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Analyzer) void {
        var thread_iter = self.threads.valueIterator();
        while (thread_iter.next()) |thread_state| thread_state.deinit(self.allocator);
        self.threads.deinit(self.allocator);
        self.cpus.deinit(self.allocator);
        var reason_iter = self.reasons.iterator();
        while (reason_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.reasons.deinit(self.allocator);
        var state_iter = self.states.iterator();
        while (state_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.states.deinit(self.allocator);
        var transition_iter = self.transitions.iterator();
        while (transition_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.transitions.deinit(self.allocator);
        for (self.occurrences.items) |*occurrence| occurrence.deinit(self.allocator);
        self.occurrences.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ingestJsonlBytes(self: *Analyzer, bytes: []const u8) !void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| try self.ingestJsonLine(line);
    }

    pub fn ingestJsonLine(self: *Analyzer, line: []const u8) !void {
        const text = std.mem.trim(u8, line, " \t\r\n");
        if (text.len == 0) return;
        var parsed = try record_mod.parseLine(self.allocator, text);
        defer parsed.deinit();
        switch (parsed) {
            .event => |value| try self.ingest(value),
            .flight => |report_value| self.recordFlightReport(report_value),
        }
    }

    pub fn ingest(self: *Analyzer, parsed: event.Parsed) !void {
        self.capture.record(parsed);
        self.counters.events += 1;
        if (self.start_ns == null and parsed.time_ns != 0) self.start_ns = parsed.time_ns;
        if (parsed.time_ns != 0) self.end_ns = parsed.time_ns;
        switch (parsed.kind) {
            .start => {
                if (parsed.time_ns != 0) self.start_ns = parsed.time_ns;
            },
            .stop => {
                if (parsed.time_ns != 0) self.end_ns = parsed.time_ns;
            },
            .thread_name => try self.recordThreadName(parsed),
            .context_switch => try self.recordSwitch(parsed),
            .thread_wakeup => try self.recordWakeup(parsed),
            else => {},
        }
    }

    pub fn collectSummaries(self: *Analyzer, allocator: std.mem.Allocator, options: Options) !std.ArrayListUnmanaged(Summary) {
        var summaries: std.ArrayListUnmanaged(Summary) = .empty;
        errdefer deinitSummaries(allocator, &summaries);
        self.counters.filtered = 0;
        switch (options.group) {
            .thread => {
                var iter = self.threads.valueIterator();
                while (iter.next()) |thread_state| {
                    if (!self.threadMatches(thread_state.*, options)) {
                        self.counters.filtered += 1;
                        continue;
                    }
                    try appendSummary(
                        allocator,
                        &summaries,
                        try threadSummary(allocator, thread_state.*),
                    );
                }
            },
            .cpu => {
                var iter = self.cpus.valueIterator();
                while (iter.next()) |cpu| {
                    if (options.cpu) |filter_cpu| if (cpu.id != filter_cpu) {
                        self.counters.filtered += 1;
                        continue;
                    };
                    try appendSummary(allocator, &summaries, try cpuSummary(allocator, cpu.*));
                }
            },
            .reason => try self.collectReasonState(allocator, &summaries, self.reasons, .reason, options),
            .state => try self.collectReasonState(allocator, &summaries, self.states, .state, options),
            .transition => {
                var iter = self.transitions.valueIterator();
                while (iter.next()) |transition| {
                    if (!transitionMatches(transition.*, options)) {
                        self.counters.filtered += 1;
                        continue;
                    }
                    try appendSummary(
                        allocator,
                        &summaries,
                        try transitionSummary(allocator, transition.*),
                    );
                }
            },
            .none => {
                for (self.occurrences.items) |occurrence| {
                    if (!occurrenceMatches(occurrence, options)) {
                        self.counters.filtered += 1;
                        continue;
                    }
                    try appendSummary(
                        allocator,
                        &summaries,
                        try occurrenceSummary(allocator, occurrence),
                    );
                }
            },
        }
        self.counters.groups = @intCast(summaries.items.len);
        self.counters.duration_ns = self.durationNs();
        sortSummaries(summaries.items, options.sort);
        return summaries;
    }

    pub fn collectOccurrences(self: *Analyzer, allocator: std.mem.Allocator, options: Options) !std.ArrayListUnmanaged(Occurrence) {
        var occurrences: std.ArrayListUnmanaged(Occurrence) = .empty;
        for (self.occurrences.items) |occurrence| {
            if (!occurrenceMatches(occurrence, options)) continue;
            try occurrences.append(allocator, occurrence);
        }
        sortOccurrences(occurrences.items, options.sort);
        return occurrences;
    }

    pub fn durationNs(self: Analyzer) u64 {
        const start_ns = self.start_ns orelse return 0;
        const end_ns = self.end_ns orelse return 0;
        if (end_ns <= start_ns) return 0;
        return end_ns - start_ns;
    }

    pub fn runningNs(self: Analyzer) u64 {
        var total: u64 = 0;
        var iter = self.threads.valueIterator();
        while (iter.next()) |thread_state| total +|= thread_state.running_ns;
        return total;
    }

    pub fn blockedNs(self: Analyzer) u64 {
        var total: u64 = 0;
        var iter = self.threads.valueIterator();
        while (iter.next()) |thread_state| total +|= thread_state.blocked_ns;
        return total;
    }

    pub fn readyNs(self: Analyzer) u64 {
        var total: u64 = 0;
        var iter = self.threads.valueIterator();
        while (iter.next()) |thread_state| total +|= thread_state.ready_ns;
        return total;
    }

    pub fn unknownOffCpuNs(self: Analyzer) u64 {
        var total: u64 = 0;
        var iter = self.threads.valueIterator();
        while (iter.next()) |thread_state| total +|= thread_state.unknown_off_cpu_ns;
        return total;
    }

    pub fn pendingReadyIntervals(self: Analyzer) u64 {
        var total: u64 = 0;
        var iter = self.threads.valueIterator();
        while (iter.next()) |thread_state| {
            if (thread_state.ready_since_ns != null) total +|= 1;
        }
        return total;
    }

    pub fn captureIntegrity(self: Analyzer) CaptureIntegrity {
        return self.capture.integrity(0);
    }

    pub fn readyLatencyEvidence(self: Analyzer) []const u8 {
        if (!std.mem.eql(u8, self.captureIntegrity().status, "complete")) return "partial";
        if (self.counters.ready_time_regressions != 0) return "partial";
        if (self.pendingReadyIntervals() != 0) return "partial";
        return "complete";
    }

    pub fn recordFlightReport(self: *Analyzer, report_value: transport.Report) void {
        self.capture.recordFlightReport(report_value);
    }

    fn recordThreadName(self: *Analyzer, parsed: event.Parsed) !void {
        const name = parsed.name orelse return;
        const thread_state = try self.threadState(parsed.thread);
        if (thread_state.name) |old| self.allocator.free(old);
        thread_state.name = try self.allocator.dupe(u8, name);
        self.counters.thread_names += 1;
    }

    fn recordSwitch(self: *Analyzer, parsed: event.Parsed) !void {
        self.counters.switches += 1;
        const occurrence_index = self.occurrences.items.len;
        var occurrence: Occurrence = .{
            .kind = .context_switch,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .source_thread = parsed.thread,
            .cpu = parsed.cpu,
            .prev_thread = parsed.prev_thread,
            .next_thread = parsed.next_thread,
            .previous_cstate = parsed.previous_cstate,
            .prev_priority = parsed.prev_priority,
            .next_priority = parsed.next_priority,
        };
        errdefer occurrence.deinit(self.allocator);
        occurrence.reason = try dupeOptional(self.allocator, parsed.context_reason);
        occurrence.state = try dupeOptional(self.allocator, parsed.context_state);
        try self.recordOccurrence(&occurrence);
        try self.recordTransition(parsed);
        if (parsed.cpu) |cpu_id| try self.recordCpuSwitch(cpu_id, parsed);
        if (parsed.prev_thread != 0) try self.recordSwitchOut(parsed);
        if (parsed.next_thread != 0) {
            self.occurrences.items[occurrence_index].ready_latency_ns =
                try self.recordSwitchIn(parsed);
        }
    }

    fn recordWakeup(self: *Analyzer, parsed: event.Parsed) !void {
        self.counters.wakeups += 1;
        const target_thread = if (parsed.target_thread != 0) parsed.target_thread else parsed.thread;
        var occurrence: Occurrence = .{
            .kind = .wakeup,
            .seq = parsed.seq,
            .time_ns = parsed.time_ns,
            .source_thread = parsed.thread,
            .cpu = parsed.cpu,
            .target_thread = target_thread,
            .priority_increment = parsed.value_i64,
        };
        errdefer occurrence.deinit(self.allocator);
        occurrence.reason = try dupeOptional(self.allocator, parsed.context_reason);
        try self.recordOccurrence(&occurrence);
        const target = try self.threadState(target_thread);
        noteTime(target, parsed.time_ns);
        target.wakeups += 1;
        if (parsed.cpu) |cpu| target.last_cpu = cpu;
        if (target.running_since_ns != null or target.ready_since_ns != null) {
            self.counters.redundant_wakeups +|= 1;
            return;
        }
        if (target.off_cpu_since_ns) |off_cpu_since| {
            if (parsed.time_ns >= off_cpu_since) {
                const duration = parsed.time_ns - off_cpu_since;
                target.blocked_ns +|= duration;
                try self.addReasonDuration(&self.reasons, target.off_cpu_reason orelse parsed.context_reason, duration, 0, 0, target_thread, parsed.cpu, parsed.time_ns);
                try self.addReasonDuration(&self.states, target.off_cpu_state, duration, 0, 0, target_thread, parsed.cpu, parsed.time_ns);
            }
            target.off_cpu_since_ns = null;
        }
        target.ready_since_ns = parsed.time_ns;
    }

    fn recordSwitchOut(self: *Analyzer, parsed: event.Parsed) !void {
        const thread_state = try self.threadState(parsed.prev_thread);
        noteTime(thread_state, parsed.time_ns);
        thread_state.switch_outs += 1;
        if (parsed.cpu) |cpu| thread_state.last_cpu = cpu;
        if (thread_state.running_since_ns) |running_since| {
            if (parsed.time_ns >= running_since) thread_state.running_ns +|= parsed.time_ns - running_since;
        }
        thread_state.running_since_ns = null;
        if (contextStateReady(parsed.context_state)) {
            thread_state.off_cpu_since_ns = null;
            thread_state.ready_since_ns = parsed.time_ns;
        } else {
            thread_state.off_cpu_since_ns = parsed.time_ns;
            thread_state.ready_since_ns = null;
        }
        try replaceOptional(self.allocator, &thread_state.off_cpu_reason, parsed.context_reason);
        try replaceOptional(self.allocator, &thread_state.off_cpu_state, parsed.context_state);
        try self.addReasonDuration(&self.reasons, parsed.context_reason, 0, 0, 1, parsed.prev_thread, parsed.cpu, parsed.time_ns);
        try self.addReasonDuration(&self.states, parsed.context_state, 0, 0, 1, parsed.prev_thread, parsed.cpu, parsed.time_ns);
    }

    fn recordSwitchIn(self: *Analyzer, parsed: event.Parsed) !?u64 {
        const thread_state = try self.threadState(parsed.next_thread);
        var ready_latency_ns: ?u64 = null;
        noteTime(thread_state, parsed.time_ns);
        thread_state.switch_ins += 1;
        if (parsed.cpu) |cpu| {
            if (thread_state.last_cpu) |last_cpu| {
                if (last_cpu != cpu) thread_state.migrations += 1;
            }
            thread_state.last_cpu = cpu;
        }
        if (thread_state.ready_since_ns) |ready_since| {
            if (parsed.time_ns >= ready_since) {
                const duration = parsed.time_ns - ready_since;
                try thread_state.ready_latencies.append(self.allocator, duration);
                thread_state.ready_ns +|= duration;
                self.counters.ready_latency_samples +|= 1;
                ready_latency_ns = duration;
                try self.addReasonDuration(&self.reasons, thread_state.off_cpu_reason, 0, duration, 0, parsed.next_thread, parsed.cpu, parsed.time_ns);
                try self.addReasonDuration(&self.states, thread_state.off_cpu_state, 0, duration, 0, parsed.next_thread, parsed.cpu, parsed.time_ns);
            } else {
                self.counters.ready_time_regressions +|= 1;
            }
        } else if (thread_state.off_cpu_since_ns) |off_cpu_since| {
            if (parsed.time_ns >= off_cpu_since) {
                const duration = parsed.time_ns - off_cpu_since;
                thread_state.unknown_off_cpu_ns +|= duration;
                try self.addUnknownDuration(&self.reasons, thread_state.off_cpu_reason, duration, parsed.next_thread, parsed.cpu, parsed.time_ns);
                try self.addUnknownDuration(&self.states, thread_state.off_cpu_state, duration, parsed.next_thread, parsed.cpu, parsed.time_ns);
            }
        }
        thread_state.running_since_ns = parsed.time_ns;
        thread_state.off_cpu_since_ns = null;
        thread_state.ready_since_ns = null;
        clearOptional(self.allocator, &thread_state.off_cpu_reason);
        clearOptional(self.allocator, &thread_state.off_cpu_state);
        return ready_latency_ns;
    }

    fn recordCpuSwitch(self: *Analyzer, cpu_id: u32, parsed: event.Parsed) !void {
        const entry = try self.cpus.getOrPut(self.allocator, cpu_id);
        if (!entry.found_existing) entry.value_ptr.* = .{ .id = cpu_id };
        const cpu_state = entry.value_ptr;
        noteCpuTime(cpu_state, parsed.time_ns);
        if (cpu_state.current_since_ns) |current_since| {
            if (parsed.time_ns >= current_since) {
                const duration = parsed.time_ns - current_since;
                if (cpu_state.current_thread == 0) {
                    cpu_state.idle_ns +|= duration;
                } else {
                    cpu_state.running_ns +|= duration;
                }
            }
        }
        cpu_state.switches += 1;
        cpu_state.current_thread = parsed.next_thread;
        cpu_state.current_since_ns = parsed.time_ns;
    }

    fn recordTransition(self: *Analyzer, parsed: event.Parsed) !void {
        var label_buffer: [48]u8 = undefined;
        const label = std.fmt.bufPrint(
            &label_buffer,
            "{d}->{d}",
            .{ parsed.prev_thread, parsed.next_thread },
        ) catch unreachable;
        if (self.transitions.getPtr(label)) |transition| {
            transition.count += 1;
            noteRange(&transition.first_ns, &transition.last_ns, parsed.time_ns);
            return;
        }
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        const entry = try self.transitions.getOrPut(self.allocator, owned_label);
        std.debug.assert(!entry.found_existing);
        entry.key_ptr.* = owned_label;
        entry.value_ptr.* = .{
            .label = owned_label,
            .prev_thread = parsed.prev_thread,
            .next_thread = parsed.next_thread,
            .count = 1,
        };
        noteRange(&entry.value_ptr.first_ns, &entry.value_ptr.last_ns, parsed.time_ns);
    }

    fn recordOccurrence(self: *Analyzer, occurrence: *Occurrence) !void {
        try self.occurrences.append(self.allocator, occurrence.*);
        occurrence.reason = null;
        occurrence.state = null;
    }

    fn addReasonDuration(
        self: *Analyzer,
        map: *std.StringHashMapUnmanaged(ReasonState),
        label_text: ?[]const u8,
        blocked_ns: u64,
        ready_ns: u64,
        count: u64,
        thread_id: u64,
        cpu_id: ?u32,
        time_ns: u64,
    ) !void {
        const row = try self.reasonState(map, label_text);
        row.count += count;
        row.blocked_ns +|= blocked_ns;
        row.ready_ns +|= ready_ns;
        try noteReasonThreadCpu(self.allocator, row, thread_id, cpu_id);
        noteRange(&row.first_ns, &row.last_ns, time_ns);
    }

    fn addUnknownDuration(
        self: *Analyzer,
        map: *std.StringHashMapUnmanaged(ReasonState),
        label_text: ?[]const u8,
        duration: u64,
        thread_id: u64,
        cpu_id: ?u32,
        time_ns: u64,
    ) !void {
        const row = try self.reasonState(map, label_text);
        row.unknown_off_cpu_ns +|= duration;
        try noteReasonThreadCpu(self.allocator, row, thread_id, cpu_id);
        noteRange(&row.first_ns, &row.last_ns, time_ns);
    }

    fn reasonState(
        self: *Analyzer,
        map: *std.StringHashMapUnmanaged(ReasonState),
        label_text: ?[]const u8,
    ) !*ReasonState {
        const label = label_text orelse "<unknown>";
        if (map.getPtr(label)) |row| return row;
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);
        const entry = try map.getOrPut(self.allocator, owned_label);
        std.debug.assert(!entry.found_existing);
        entry.key_ptr.* = owned_label;
        entry.value_ptr.* = .{ .label = owned_label };
        return entry.value_ptr;
    }

    fn threadState(self: *Analyzer, id: u64) !*ThreadState {
        const entry = try self.threads.getOrPut(self.allocator, id);
        if (!entry.found_existing) entry.value_ptr.* = .{ .id = id };
        return entry.value_ptr;
    }

    fn collectReasonState(
        self: *Analyzer,
        allocator: std.mem.Allocator,
        summaries: *std.ArrayListUnmanaged(Summary),
        map: std.StringHashMapUnmanaged(ReasonState),
        group: Group,
        options: Options,
    ) !void {
        var iter = map.valueIterator();
        while (iter.next()) |row| {
            if (!reasonStateMatches(row.*, options)) {
                self.counters.filtered += 1;
                continue;
            }
            try appendSummary(
                allocator,
                summaries,
                try reasonStateSummary(allocator, row.*, group),
            );
        }
    }

    fn threadMatches(self: Analyzer, thread_state: ThreadState, options: Options) bool {
        if (options.thread) |thread_filter| if (thread_state.id != thread_filter) return false;
        if (options.cpu) |cpu_filter| {
            const last_cpu = thread_state.last_cpu orelse return false;
            if (last_cpu != cpu_filter) return false;
        }
        if (options.match) |needle| {
            if (contains(thread_state.displayName(), needle, options.ignore_case)) return true;
            var buffer: [32]u8 = undefined;
            const thread_text = std.fmt.bufPrint(&buffer, "{d}", .{thread_state.id}) catch "";
            if (contains(thread_text, needle, options.ignore_case)) return true;
            return false;
        }
        _ = self;
        return true;
    }
};

pub fn deinitSummaries(allocator: std.mem.Allocator, summaries: *std.ArrayListUnmanaged(Summary)) void {
    for (summaries.items) |*summary| summary.deinit(allocator);
    summaries.deinit(allocator);
}

fn appendSummary(
    allocator: std.mem.Allocator,
    summaries: *std.ArrayListUnmanaged(Summary),
    summary_value: Summary,
) !void {
    var summary = summary_value;
    errdefer summary.deinit(allocator);
    try summaries.append(allocator, summary);
}

pub fn writeTextFromJsonlPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    return report.writeFromJsonlPath(Analyzer, writeText, allocator, path, writer, options);
}

pub fn writeJsonlFromJsonlPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    return report.writeFromJsonlPath(Analyzer, writeJsonl, allocator, path, writer, options);
}

pub fn ingestPath(analyzer: *Analyzer, path: []const u8) !void {
    return report.ingestJsonlPath(analyzer, path);
}

fn writeText(
    allocator: std.mem.Allocator,
    analyzer: *Analyzer,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var summaries = try analyzer.collectSummaries(allocator, options);
    defer deinitSummaries(allocator, &summaries);
    var occurrences = try analyzer.collectOccurrences(allocator, options);
    defer occurrences.deinit(allocator);

    try writer.print(
        "tracy context groups={d} switches={d} wakeups={d} threads={d} cpus={d} " ++
            "running_ns={d} blocked_ns={d} ready_ns={d} unknown_off_cpu_ns={d} " ++
            "ready_latency_samples={d} redundant_wakeups={d} " ++
            "ready_time_regressions={d} pending_ready_intervals={d} " ++
            "ready_latency_evidence={s} filtered={d} duration_ns={d} group={s} sort={s}\n",
        .{
            summaries.items.len,
            analyzer.counters.switches,
            analyzer.counters.wakeups,
            analyzer.threads.count(),
            analyzer.cpus.count(),
            analyzer.runningNs(),
            analyzer.blockedNs(),
            analyzer.readyNs(),
            analyzer.unknownOffCpuNs(),
            analyzer.counters.ready_latency_samples,
            analyzer.counters.redundant_wakeups,
            analyzer.counters.ready_time_regressions,
            analyzer.pendingReadyIntervals(),
            analyzer.readyLatencyEvidence(),
            analyzer.counters.filtered,
            analyzer.durationNs(),
            options.group.tag(),
            options.sort.tag(),
        },
    );
    try capture_mod.writeText(writer, analyzer.captureIntegrity());
    const summary_limit = @min(options.top, summaries.items.len);
    for (summaries.items[0..summary_limit]) |summary| {
        try writer.print("context group={s} label=", .{summary.group.tag()});
        try pretty_json.writeString(writer, summary.label);
        try writer.print(" count={d}", .{summary.count});
        try writeSummaryFieldsText(writer, summary);
        try writer.writeByte('\n');
    }

    const occurrence_limit = @min(options.occurrences, occurrences.items.len);
    for (occurrences.items[0..occurrence_limit]) |occurrence| {
        try writer.print("context-occurrence kind={s} time_ns={d} source_thread={d}", .{ occurrence.kind.tag(), occurrence.time_ns, occurrence.source_thread });
        try writeOccurrenceFieldsText(writer, occurrence);
        try writer.writeByte('\n');
    }
}

fn writeJsonl(
    allocator: std.mem.Allocator,
    analyzer: *Analyzer,
    writer: *std.Io.Writer,
    options: Options,
) !void {
    var summaries = try analyzer.collectSummaries(allocator, options);
    defer deinitSummaries(allocator, &summaries);
    var occurrences = try analyzer.collectOccurrences(allocator, options);
    defer occurrences.deinit(allocator);

    var summary_stream = pretty_json.Writer.init(writer, .minified);
    const summary_record = try summary_stream.object();
    try summary_record.field("schema", schema);
    try summary_record.field("kind", "summary");
    try summary_record.field("groups", summaries.items.len);
    try summary_record.field("switches", analyzer.counters.switches);
    try summary_record.field("wakeups", analyzer.counters.wakeups);
    try summary_record.field("threads", analyzer.threads.count());
    try summary_record.field("cpus", analyzer.cpus.count());
    try summary_record.field("running_ns", analyzer.runningNs());
    try summary_record.field("blocked_ns", analyzer.blockedNs());
    try summary_record.field("ready_ns", analyzer.readyNs());
    try summary_record.field("unknown_off_cpu_ns", analyzer.unknownOffCpuNs());
    try summary_record.field("ready_latency_samples", analyzer.counters.ready_latency_samples);
    try summary_record.field("redundant_wakeups", analyzer.counters.redundant_wakeups);
    try summary_record.field("ready_time_regressions", analyzer.counters.ready_time_regressions);
    try summary_record.field("pending_ready_intervals", analyzer.pendingReadyIntervals());
    try summary_record.field("filtered", analyzer.counters.filtered);
    try summary_record.field("duration_ns", analyzer.durationNs());
    try summary_record.field("group", options.group.tag());
    try summary_record.field("sort", options.sort.tag());
    try summary_record.field("ready_latency_evidence", analyzer.readyLatencyEvidence());
    try capture_mod.writeFields(summary_record, analyzer.captureIntegrity());
    try summary_record.endLine();

    const summary_limit = @min(options.top, summaries.items.len);
    for (summaries.items[0..summary_limit]) |summary| {
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("schema", schema);
        try object.field("kind", "group");
        try object.field("group", summary.group.tag());
        try object.field("label", summary.label);
        try object.field("count", summary.count);
        try writeSummaryFields(object, summary);
        try object.endLine();
    }

    const occurrence_limit = @min(options.occurrences, occurrences.items.len);
    for (occurrences.items[0..occurrence_limit]) |occurrence| {
        var stream = pretty_json.Writer.init(writer, .minified);
        const object = try stream.object();
        try object.field("schema", schema);
        try object.field("kind", occurrence.kind.tag());
        try object.field("time_ns", occurrence.time_ns);
        try object.field("source_thread", occurrence.source_thread);
        try writeOccurrenceFields(object, occurrence);
        try object.endLine();
    }
}

fn threadSummary(allocator: std.mem.Allocator, thread_state: ThreadState) !Summary {
    std.mem.sort(u64, thread_state.ready_latencies.items, {}, std.sort.asc(u64));
    const latency_samples: u64 = @intCast(thread_state.ready_latencies.items.len);
    var id_buffer: [20]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buffer, "{d}", .{thread_state.id}) catch unreachable;
    const name = thread_state.name orelse "";
    const separator = if (name.len == 0) "" else " ";
    const label = try std.mem.concat(allocator, u8, &.{ "thread ", id, separator, name });
    return .{
        .group = .thread,
        .label = label,
        .count = thread_state.switch_ins + thread_state.switch_outs + thread_state.wakeups,
        .thread = thread_state.id,
        .cpu = thread_state.last_cpu,
        .switch_ins = thread_state.switch_ins,
        .switch_outs = thread_state.switch_outs,
        .wakeups = thread_state.wakeups,
        .running_ns = thread_state.running_ns,
        .blocked_ns = thread_state.blocked_ns,
        .ready_ns = thread_state.ready_ns,
        .ready_latency_samples = latency_samples,
        .ready_latency_mean_ns = if (latency_samples == 0)
            0
        else
            thread_state.ready_ns / latency_samples,
        .ready_latency_min_ns = readyLatencyPercentile(thread_state.ready_latencies.items, 0),
        .ready_latency_p50_ns = readyLatencyPercentile(thread_state.ready_latencies.items, 50),
        .ready_latency_p90_ns = readyLatencyPercentile(thread_state.ready_latencies.items, 90),
        .ready_latency_p99_ns = readyLatencyPercentile(thread_state.ready_latencies.items, 99),
        .ready_latency_max_ns = readyLatencyPercentile(thread_state.ready_latencies.items, 100),
        .unknown_off_cpu_ns = thread_state.unknown_off_cpu_ns,
        .migrations = thread_state.migrations,
        .first_ns = thread_state.first_ns,
        .last_ns = thread_state.last_ns,
    };
}

fn cpuSummary(allocator: std.mem.Allocator, cpu_state: CpuState) !Summary {
    const label = try std.fmt.allocPrint(allocator, "cpu {d}", .{cpu_state.id});
    return .{
        .group = .cpu,
        .label = label,
        .count = cpu_state.switches,
        .cpu = cpu_state.id,
        .running_ns = cpu_state.running_ns,
        .idle_ns = cpu_state.idle_ns,
        .first_ns = cpu_state.first_ns,
        .last_ns = cpu_state.last_ns,
    };
}

fn reasonStateSummary(allocator: std.mem.Allocator, row: ReasonState, group: Group) !Summary {
    return .{
        .group = group,
        .label = try allocator.dupe(u8, row.label),
        .count = row.count,
        .blocked_ns = row.blocked_ns,
        .ready_ns = row.ready_ns,
        .unknown_off_cpu_ns = row.unknown_off_cpu_ns,
        .first_ns = row.first_ns,
        .last_ns = row.last_ns,
    };
}

fn transitionSummary(allocator: std.mem.Allocator, transition: TransitionState) !Summary {
    return .{
        .group = .transition,
        .label = try allocator.dupe(u8, transition.label),
        .count = transition.count,
        .prev_thread = transition.prev_thread,
        .next_thread = transition.next_thread,
        .first_ns = transition.first_ns,
        .last_ns = transition.last_ns,
    };
}

fn occurrenceSummary(allocator: std.mem.Allocator, occurrence: Occurrence) !Summary {
    var label = std.Io.Writer.Allocating.init(allocator);
    defer label.deinit();
    try label.writer.print("{s} {d}", .{ occurrence.kind.tag(), occurrence.time_ns });
    var summary: Summary = .{
        .group = .none,
        .label = try allocator.dupe(u8, label.written()),
        .count = 1,
        .thread = occurrence.target_thread,
        .cpu = occurrence.cpu,
        .prev_thread = occurrence.prev_thread,
        .next_thread = occurrence.next_thread,
        .first_ns = occurrence.time_ns,
        .last_ns = occurrence.time_ns,
    };
    if (occurrence.ready_latency_ns) |latency_ns| {
        summary.ready_ns = latency_ns;
        summary.ready_latency_samples = 1;
        summary.ready_latency_mean_ns = latency_ns;
        summary.ready_latency_min_ns = latency_ns;
        summary.ready_latency_p50_ns = latency_ns;
        summary.ready_latency_p90_ns = latency_ns;
        summary.ready_latency_p99_ns = latency_ns;
        summary.ready_latency_max_ns = latency_ns;
    }
    return summary;
}

fn transitionMatches(transition: TransitionState, options: Options) bool {
    if (options.thread) |thread| {
        if (transition.prev_thread != thread and transition.next_thread != thread) return false;
    }
    if (!labelMatches(transition.label, options)) return false;
    return true;
}

fn occurrenceMatches(occurrence: Occurrence, options: Options) bool {
    if (options.thread) |thread| {
        if (occurrence.source_thread != thread and occurrence.prev_thread != thread and occurrence.next_thread != thread and occurrence.target_thread != thread) return false;
    }
    if (options.cpu) |cpu_filter| {
        const cpu = occurrence.cpu orelse return false;
        if (cpu != cpu_filter) return false;
    }
    if (options.since_ns) |since_ns| if (occurrence.time_ns < since_ns) return false;
    if (options.until_ns) |until_ns| if (occurrence.time_ns > until_ns) return false;
    if (options.match) |needle| {
        if (contains(occurrence.kind.tag(), needle, options.ignore_case)) return true;
        if (occurrence.reason) |reason| if (contains(reason, needle, options.ignore_case)) return true;
        if (occurrence.state) |state| if (contains(state, needle, options.ignore_case)) return true;
        return false;
    }
    return true;
}

fn labelMatches(label: []const u8, options: Options) bool {
    if (options.match) |needle| return contains(label, needle, options.ignore_case);
    return true;
}

fn reasonStateMatches(row: ReasonState, options: Options) bool {
    if (options.thread) |thread| {
        if (!row.threads.contains(thread)) return false;
    }
    if (options.cpu) |cpu| {
        if (!row.cpus.contains(cpu)) return false;
    }
    return labelMatches(row.label, options);
}

fn writeSummaryFieldsText(writer: *std.Io.Writer, summary: Summary) !void {
    if (summary.thread) |thread| try writer.print(" thread={d}", .{thread});
    if (summary.cpu) |cpu| try writer.print(" cpu={d}", .{cpu});
    if (summary.prev_thread != 0 or summary.next_thread != 0) try writer.print(" prev_thread={d} next_thread={d}", .{ summary.prev_thread, summary.next_thread });
    if (summary.switch_ins != 0) try writer.print(" switches_in={d}", .{summary.switch_ins});
    if (summary.switch_outs != 0) try writer.print(" switches_out={d}", .{summary.switch_outs});
    if (summary.wakeups != 0) try writer.print(" wakeups={d}", .{summary.wakeups});
    if (summary.running_ns != 0) try writer.print(" running_ns={d}", .{summary.running_ns});
    if (summary.blocked_ns != 0) try writer.print(" blocked_ns={d}", .{summary.blocked_ns});
    if (summary.ready_ns != 0) try writer.print(" ready_ns={d}", .{summary.ready_ns});
    try writeReadyLatencyText(writer, summary);
    if (summary.unknown_off_cpu_ns != 0) try writer.print(" unknown_off_cpu_ns={d}", .{summary.unknown_off_cpu_ns});
    if (summary.idle_ns != 0) try writer.print(" idle_ns={d}", .{summary.idle_ns});
    if (summary.migrations != 0) try writer.print(" migrations={d}", .{summary.migrations});
    if (summary.first_ns != 0) try writer.print(" first_ns={d}", .{summary.first_ns});
    if (summary.last_ns != 0) try writer.print(" last_ns={d}", .{summary.last_ns});
}

fn writeSummaryFields(object: pretty_json.Object, summary: Summary) !void {
    if (summary.thread) |thread| try object.field("thread", thread);
    if (summary.cpu) |cpu| try object.field("cpu", cpu);
    if (summary.prev_thread != 0 or summary.next_thread != 0) {
        try object.field("prev_thread", summary.prev_thread);
        try object.field("next_thread", summary.next_thread);
    }
    if (summary.switch_ins != 0) try object.field("switches_in", summary.switch_ins);
    if (summary.switch_outs != 0) try object.field("switches_out", summary.switch_outs);
    if (summary.wakeups != 0) try object.field("wakeups", summary.wakeups);
    if (summary.running_ns != 0) try object.field("running_ns", summary.running_ns);
    if (summary.blocked_ns != 0) try object.field("blocked_ns", summary.blocked_ns);
    if (summary.ready_ns != 0) try object.field("ready_ns", summary.ready_ns);
    try writeReadyLatencyFields(object, summary);
    if (summary.unknown_off_cpu_ns != 0) try object.field("unknown_off_cpu_ns", summary.unknown_off_cpu_ns);
    if (summary.idle_ns != 0) try object.field("idle_ns", summary.idle_ns);
    if (summary.migrations != 0) try object.field("migrations", summary.migrations);
    if (summary.first_ns != 0) try object.field("first_ns", summary.first_ns);
    if (summary.last_ns != 0) try object.field("last_ns", summary.last_ns);
}

fn writeReadyLatencyText(writer: *std.Io.Writer, summary: Summary) !void {
    if (summary.ready_latency_samples == 0) return;
    try writer.print(
        " ready_latency_samples={d} ready_latency_mean_ns={d} " ++
            "ready_latency_min_ns={d} ready_latency_p50_ns={d} " ++
            "ready_latency_p90_ns={d} ready_latency_p99_ns={d} " ++
            "ready_latency_max_ns={d}",
        .{
            summary.ready_latency_samples,
            summary.ready_latency_mean_ns,
            summary.ready_latency_min_ns,
            summary.ready_latency_p50_ns,
            summary.ready_latency_p90_ns,
            summary.ready_latency_p99_ns,
            summary.ready_latency_max_ns,
        },
    );
}

fn writeReadyLatencyFields(object: pretty_json.Object, summary: Summary) !void {
    if (summary.ready_latency_samples == 0) return;
    try object.field("ready_latency_samples", summary.ready_latency_samples);
    try object.field("ready_latency_mean_ns", summary.ready_latency_mean_ns);
    try object.field("ready_latency_min_ns", summary.ready_latency_min_ns);
    try object.field("ready_latency_p50_ns", summary.ready_latency_p50_ns);
    try object.field("ready_latency_p90_ns", summary.ready_latency_p90_ns);
    try object.field("ready_latency_p99_ns", summary.ready_latency_p99_ns);
    try object.field("ready_latency_max_ns", summary.ready_latency_max_ns);
}

fn writeOccurrenceFieldsText(writer: *std.Io.Writer, occurrence: Occurrence) !void {
    if (occurrence.cpu) |cpu| try writer.print(" cpu={d}", .{cpu});
    if (occurrence.prev_thread != 0) try writer.print(" prev_thread={d}", .{occurrence.prev_thread});
    if (occurrence.next_thread != 0) try writer.print(" next_thread={d}", .{occurrence.next_thread});
    if (occurrence.target_thread != 0) try writer.print(" target_thread={d}", .{occurrence.target_thread});
    if (occurrence.reason) |reason| {
        try writer.writeAll(" reason=");
        try pretty_json.writeString(writer, reason);
    }
    if (occurrence.state) |state| {
        try writer.writeAll(" state=");
        try pretty_json.writeString(writer, state);
    }
    if (occurrence.previous_cstate) |previous_cstate| try writer.print(" previous_cstate={d}", .{previous_cstate});
    if (occurrence.prev_priority) |prev_priority| try writer.print(" prev_priority={d}", .{prev_priority});
    if (occurrence.next_priority) |next_priority| try writer.print(" next_priority={d}", .{next_priority});
    if (occurrence.priority_increment) |priority_increment| try writer.print(" priority_increment={d}", .{priority_increment});
    if (occurrence.ready_latency_ns) |latency_ns| {
        try writer.print(" ready_latency_ns={d}", .{latency_ns});
    }
}

fn writeOccurrenceFields(object: pretty_json.Object, occurrence: Occurrence) !void {
    if (occurrence.cpu) |cpu| try object.field("cpu", cpu);
    if (occurrence.prev_thread != 0) try object.field("prev_thread", occurrence.prev_thread);
    if (occurrence.next_thread != 0) try object.field("next_thread", occurrence.next_thread);
    if (occurrence.target_thread != 0) try object.field("target_thread", occurrence.target_thread);
    if (occurrence.reason) |reason| try object.field("context_reason", reason);
    if (occurrence.state) |state| try object.field("context_state", state);
    if (occurrence.previous_cstate) |previous_cstate| try object.field("previous_cstate", previous_cstate);
    if (occurrence.prev_priority) |prev_priority| try object.field("prev_priority", prev_priority);
    if (occurrence.next_priority) |next_priority| try object.field("next_priority", next_priority);
    if (occurrence.priority_increment) |priority_increment| try object.field("priority_increment", priority_increment);
    if (occurrence.ready_latency_ns) |latency_ns| try object.field("ready_latency_ns", latency_ns);
}

fn noteTime(thread: *ThreadState, time_ns: u64) void {
    noteRange(&thread.first_ns, &thread.last_ns, time_ns);
}

fn noteCpuTime(cpu: *CpuState, time_ns: u64) void {
    noteRange(&cpu.first_ns, &cpu.last_ns, time_ns);
}

fn noteRange(first_ns: *u64, last_ns: *u64, time_ns: u64) void {
    if (time_ns == 0) return;
    if (first_ns.* == 0 or time_ns < first_ns.*) first_ns.* = time_ns;
    last_ns.* = @max(last_ns.*, time_ns);
}

fn noteReasonThreadCpu(allocator: std.mem.Allocator, row: *ReasonState, thread_id: u64, cpu_id: ?u32) !void {
    if (thread_id != 0) try row.threads.put(allocator, thread_id, {});
    if (cpu_id) |cpu| try row.cpus.put(allocator, cpu, {});
}

fn dupeOptional(allocator: std.mem.Allocator, text: ?[]const u8) !?[]u8 {
    const actual = text orelse return null;
    return try allocator.dupe(u8, actual);
}

fn replaceOptional(allocator: std.mem.Allocator, slot: *?[]u8, text: ?[]const u8) !void {
    clearOptional(allocator, slot);
    slot.* = try dupeOptional(allocator, text);
}

fn clearOptional(allocator: std.mem.Allocator, slot: *?[]u8) void {
    if (slot.*) |text| allocator.free(text);
    slot.* = null;
}

fn sortSummaries(items: []Summary, sort: Sort) void {
    std.mem.sort(Summary, items, sort, summaryLessThan);
}

fn summaryLessThan(sort: Sort, left: Summary, right: Summary) bool {
    return switch (sort) {
        .running => summaryRunningGreaterThan({}, left, right),
        .blocked => summaryBlockedGreaterThan({}, left, right),
        .ready => summaryReadyGreaterThan({}, left, right),
        .latency => summaryLatencyGreaterThan({}, left, right),
        .switches => summarySwitchesGreaterThan({}, left, right),
        .wakeups => summaryWakeupsGreaterThan({}, left, right),
        .migrations => summaryMigrationsGreaterThan({}, left, right),
        .last => summaryLastGreaterThan({}, left, right),
        .thread => summaryThreadLessThan({}, left, right),
        .cpu => summaryCpuLessThan({}, left, right),
        .label => summaryLabelLessThan({}, left, right),
    };
}

fn summaryRunningGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.running_ns != right.running_ns) return left.running_ns > right.running_ns;
    return summarySwitchesGreaterThan({}, left, right);
}

fn summaryBlockedGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.blocked_ns != right.blocked_ns) return left.blocked_ns > right.blocked_ns;
    return summarySwitchesGreaterThan({}, left, right);
}

fn summaryReadyGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.ready_ns != right.ready_ns) return left.ready_ns > right.ready_ns;
    return summarySwitchesGreaterThan({}, left, right);
}

fn summaryLatencyGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.ready_latency_max_ns != right.ready_latency_max_ns) {
        return left.ready_latency_max_ns > right.ready_latency_max_ns;
    }
    if (left.ready_latency_p99_ns != right.ready_latency_p99_ns) {
        return left.ready_latency_p99_ns > right.ready_latency_p99_ns;
    }
    return summarySwitchesGreaterThan({}, left, right);
}

fn summarySwitchesGreaterThan(_: void, left: Summary, right: Summary) bool {
    const left_switches = left.switch_ins + left.switch_outs + left.count;
    const right_switches = right.switch_ins + right.switch_outs + right.count;
    if (left_switches != right_switches) return left_switches > right_switches;
    return std.mem.lessThan(u8, left.label, right.label);
}

fn summaryWakeupsGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.wakeups != right.wakeups) return left.wakeups > right.wakeups;
    return summarySwitchesGreaterThan({}, left, right);
}

fn summaryMigrationsGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.migrations != right.migrations) return left.migrations > right.migrations;
    return summarySwitchesGreaterThan({}, left, right);
}

fn summaryLastGreaterThan(_: void, left: Summary, right: Summary) bool {
    if (left.last_ns != right.last_ns) return left.last_ns > right.last_ns;
    return summarySwitchesGreaterThan({}, left, right);
}

fn summaryThreadLessThan(_: void, left: Summary, right: Summary) bool {
    const left_thread = left.thread orelse 0;
    const right_thread = right.thread orelse 0;
    if (left_thread != right_thread) return left_thread < right_thread;
    return summarySwitchesGreaterThan({}, left, right);
}

fn summaryCpuLessThan(_: void, left: Summary, right: Summary) bool {
    const left_cpu = left.cpu orelse 0;
    const right_cpu = right.cpu orelse 0;
    if (left_cpu != right_cpu) return left_cpu < right_cpu;
    return summarySwitchesGreaterThan({}, left, right);
}

fn summaryLabelLessThan(_: void, left: Summary, right: Summary) bool {
    return std.mem.lessThan(u8, left.label, right.label);
}

fn sortOccurrences(items: []Occurrence, sort: Sort) void {
    switch (sort) {
        .latency => std.mem.sort(Occurrence, items, {}, occurrenceLatencyGreaterThan),
        .last => std.mem.sort(Occurrence, items, {}, occurrenceTimeGreaterThan),
        else => std.mem.sort(Occurrence, items, {}, occurrenceTimeLessThan),
    }
}

fn occurrenceLatencyGreaterThan(_: void, left: Occurrence, right: Occurrence) bool {
    const left_latency = left.ready_latency_ns orelse 0;
    const right_latency = right.ready_latency_ns orelse 0;
    if (left_latency != right_latency) return left_latency > right_latency;
    return occurrenceTimeLessThan({}, left, right);
}

fn occurrenceTimeLessThan(_: void, left: Occurrence, right: Occurrence) bool {
    if (left.time_ns != right.time_ns) return left.time_ns < right.time_ns;
    return left.seq < right.seq;
}

fn occurrenceTimeGreaterThan(_: void, left: Occurrence, right: Occurrence) bool {
    if (left.time_ns != right.time_ns) return left.time_ns > right.time_ns;
    return left.seq > right.seq;
}

fn contextStateReady(state: ?[]const u8) bool {
    const text = state orelse return false;
    inline for (.{ "ready", "runnable", "r", "r+" }) |ready| {
        if (asciiEqlIgnoreCase(text, ready)) return true;
    }
    return false;
}

fn readyLatencyPercentile(sorted: []const u64, percent: u64) u64 {
    if (sorted.len == 0) return 0;
    const rank: usize = @intCast((@as(u128, @min(percent, 100)) * sorted.len + 99) / 100);
    const index = @min(@max(rank, 1) - 1, sorted.len - 1);
    return sorted[index];
}

fn contains(haystack: []const u8, needle: []const u8, ignore_case: bool) bool {
    if (!ignore_case) return std.mem.indexOf(u8, haystack, needle) != null;
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (asciiEqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn asciiEqlIgnoreCase(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

test "context analyzer preserves preempted ready latency" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 90, .thread = 1, .name = "test" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .thread_name, .time_ns = 95, .thread = 10, .name = "worker" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .context_switch, .time_ns = 100, .thread = 1, .cpu = 0, .next_thread = 10 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .context_switch, .time_ns = 150, .thread = 1, .cpu = 0, .prev_thread = 10, .next_thread = 11, .context_reason = "WrPreempted", .context_state = "Ready" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .thread_wakeup, .time_ns = 180, .thread = 1, .target_thread = 10, .cpu = 0, .context_reason = "Unwait" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 6, .kind = .context_switch, .time_ns = 220, .thread = 1, .cpu = 1, .prev_thread = 11, .next_thread = 10, .context_reason = "WrYieldExecution", .context_state = "Ready" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 7, .kind = .stop, .time_ns = 260, .thread = 1 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqual(@as(u64, 3), analyzer.counters.switches);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.wakeups);
    try std.testing.expectEqual(@as(u64, 50), analyzer.threads.get(10).?.running_ns);
    try std.testing.expectEqual(@as(u64, 0), analyzer.threads.get(10).?.blocked_ns);
    try std.testing.expectEqual(@as(u64, 70), analyzer.threads.get(10).?.ready_ns);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.ready_latency_samples);
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.redundant_wakeups);
    try std.testing.expectEqual(@as(u64, 1), analyzer.threads.get(10).?.migrations);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeText(std.testing.allocator, &analyzer, &out.writer, .{ .group = .thread, .sort = .running, .top = 4, .occurrences = 4 });
    const text = out.written();
    try expectContextContains(
        text,
        "ready_latency_samples=1 redundant_wakeups=1 ready_time_regressions=0 " ++
            "pending_ready_intervals=1 ready_latency_evidence=partial",
    );
    try expectContextContains(
        text,
        "context group=thread label=\"thread 10 worker\" count=4 thread=10 cpu=1 " ++
            "switches_in=2 switches_out=1 wakeups=1 running_ns=50 ready_ns=70 " ++
            "ready_latency_samples=1 ready_latency_mean_ns=70 ready_latency_min_ns=70 " ++
            "ready_latency_p50_ns=70 ready_latency_p90_ns=70 ready_latency_p99_ns=70 " ++
            "ready_latency_max_ns=70 migrations=1",
    );
    try expectContextContains(
        text,
        "context-occurrence kind=switch time_ns=220 source_thread=1 cpu=1 " ++
            "prev_thread=11 next_thread=10 reason=\"WrYieldExecution\" state=\"Ready\" " ++
            "ready_latency_ns=70",
    );
    try std.testing.expect(std.mem.indexOf(u8, text, "context-occurrence kind=switch time_ns=150 source_thread=1 cpu=0 prev_thread=10 next_thread=11 reason=\"WrPreempted\" state=\"Ready\"") != null);
}

test "context jsonl filters by cpu reason and thread" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .context_switch, .time_ns = 100, .thread = 1, .cpu = 0, .next_thread = 10 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 2, .kind = .context_switch, .time_ns = 140, .thread = 1, .cpu = 0, .prev_thread = 10, .next_thread = 11, .context_reason = "WrMutex", .context_state = "Waiting" }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 3, .kind = .thread_wakeup, .time_ns = 160, .thread = 1, .target_thread = 10, .cpu = 0 }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 4, .kind = .context_switch, .time_ns = 180, .thread = 1, .cpu = 0, .prev_thread = 11, .next_thread = 10 }).writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, .{ .group = .reason, .cpu = 0, .thread = 10, .match = "wrmutex", .ignore_case = true });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "\"schema\":\"tracy.context/v0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"kind\":\"summary\",\"groups\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"label\":\"WrMutex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"blocked_ns\":20") != null);
}

test "context reports ready latency distributions and worst occurrences" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    var seq: u64 = 1;
    try (event.TraceEvent{ .seq = seq, .kind = .start, .time_ns = 1 }).writeJsonLine(&trace.writer);
    seq += 1;
    var time_ns: u64 = 100;
    for ([_]u64{ 10, 20, 30, 40, 100 }) |latency_ns| {
        try appendReadyLatencySample(&trace.writer, &seq, 10, time_ns, latency_ns);
        time_ns += latency_ns + 10;
    }
    try appendReadyLatencySample(&trace.writer, &seq, 20, time_ns, 200);
    try (event.TraceEvent{ .seq = seq, .kind = .stop, .time_ns = time_ns + 210 })
        .writeJsonLine(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqual(@as(u64, 6), analyzer.counters.ready_latency_samples);
    try std.testing.expectEqualStrings("complete", analyzer.readyLatencyEvidence());

    var rows = try analyzer.collectSummaries(std.testing.allocator, .{ .sort = .latency });
    defer deinitSummaries(std.testing.allocator, &rows);
    try std.testing.expectEqual(@as(?u64, 20), rows.items[0].thread);
    const worker = rows.items[1];
    try std.testing.expectEqual(@as(?u64, 10), worker.thread);
    try std.testing.expectEqual(@as(u64, 5), worker.ready_latency_samples);
    try std.testing.expectEqual(@as(u64, 40), worker.ready_latency_mean_ns);
    try std.testing.expectEqual(@as(u64, 10), worker.ready_latency_min_ns);
    try std.testing.expectEqual(@as(u64, 30), worker.ready_latency_p50_ns);
    try std.testing.expectEqual(@as(u64, 100), worker.ready_latency_p90_ns);
    try std.testing.expectEqual(@as(u64, 100), worker.ready_latency_p99_ns);
    try std.testing.expectEqual(@as(u64, 100), worker.ready_latency_max_ns);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(
        std.testing.allocator,
        &analyzer,
        &out.writer,
        .{ .sort = .latency, .top = 3, .occurrences = 1 },
    );
    try expectContextContains(out.written(), "\"ready_latency_evidence\":\"complete\"");
    try expectContextContains(out.written(), "\"ready_latency_p99_ns\":100");
    try expectContextContains(out.written(), "\"ready_latency_ns\":200");
}

test "context retains flight reports and invalid ready evidence" {
    var trace = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer trace.deinit();
    try (event.TraceEvent{ .seq = 1, .kind = .start, .time_ns = 10 })
        .writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 3,
        .kind = .thread_wakeup,
        .time_ns = 100,
        .target_thread = 10,
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{
        .seq = 4,
        .kind = .context_switch,
        .time_ns = 90,
        .next_thread = 10,
    }).writeJsonLine(&trace.writer);
    try (event.TraceEvent{ .seq = 5, .kind = .stop, .time_ns = 110 })
        .writeJsonLine(&trace.writer);
    const flight_report = contextTestFlightReport();
    try flight_report.writeJsonl(&trace.writer);

    var analyzer = Analyzer.init(std.testing.allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace.written());
    try std.testing.expectEqual(@as(u64, 1), analyzer.counters.ready_time_regressions);
    try std.testing.expectEqualStrings("partial", analyzer.readyLatencyEvidence());
    const integrity = analyzer.captureIntegrity();
    try std.testing.expectEqualStrings("sequence_gaps", integrity.status);
    try std.testing.expectEqualDeep(flight_report, integrity.flight_report.?);

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(std.testing.allocator, &analyzer, &out.writer, .{});
    try expectContextContains(out.written(), "\"ready_time_regressions\":1");
    try expectContextContains(out.written(), "\"flight_report\":{");
}

test "context releases ready latency evidence on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        analyzeReadyLatency,
        .{},
    );
}

fn analyzeReadyLatency(allocator: std.mem.Allocator) !void {
    const trace =
        "{\"v\":0,\"seq\":1,\"kind\":\"start\",\"time_ns\":10}\n" ++
        "{\"v\":0,\"seq\":2,\"kind\":\"context.switch\",\"time_ns\":20," ++
        "\"prev_thread\":7,\"next_thread\":8,\"context_reason\":\"preempted\"," ++
        "\"context_state\":\"Ready\"}\n" ++
        "{\"v\":0,\"seq\":3,\"kind\":\"context.switch\",\"time_ns\":40," ++
        "\"prev_thread\":8,\"next_thread\":7,\"context_reason\":\"waiting\"," ++
        "\"context_state\":\"Waiting\"}\n" ++
        "{\"v\":0,\"seq\":4,\"kind\":\"stop\",\"time_ns\":50}\n";
    var analyzer = Analyzer.init(allocator);
    defer analyzer.deinit();
    try analyzer.ingestJsonlBytes(trace);
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeJsonl(allocator, &analyzer, &out.writer, .{ .sort = .latency });
}

fn appendReadyLatencySample(
    writer: *std.Io.Writer,
    seq: *u64,
    thread: u64,
    start_ns: u64,
    latency_ns: u64,
) !void {
    try (event.TraceEvent{
        .seq = seq.*,
        .kind = .thread_wakeup,
        .time_ns = start_ns,
        .thread = 99,
        .target_thread = thread,
        .cpu = 0,
    }).writeJsonLine(writer);
    seq.* += 1;
    try (event.TraceEvent{
        .seq = seq.*,
        .kind = .context_switch,
        .time_ns = start_ns + latency_ns,
        .thread = 99,
        .cpu = 0,
        .prev_thread = 99,
        .next_thread = thread,
    }).writeJsonLine(writer);
    seq.* += 1;
    try (event.TraceEvent{
        .seq = seq.*,
        .kind = .context_switch,
        .time_ns = start_ns + latency_ns + 1,
        .thread = 99,
        .cpu = 0,
        .prev_thread = thread,
        .next_thread = 99,
        .context_state = "Waiting",
    }).writeJsonLine(writer);
    seq.* += 1;
}

fn contextTestFlightReport() transport.Report {
    return .{
        .policy = .overwrite_oldest,
        .state = .accepting,
        .capacity_bytes = 64,
        .retained_bytes = 32,
        .event_capacity_bytes = 16,
        .writer_capacity_bytes = 8,
        .observed_events = 5,
        .stored_events = 5,
        .retained_events = 4,
        .overwritten_events = 1,
        .dropped_events = 0,
        .oversized_events = 0,
        .partial_event_bytes = 0,
        .discarding_oversized_event = false,
    };
}

fn expectContextContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}
