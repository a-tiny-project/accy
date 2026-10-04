const std = @import("std");
const record = @import("root.zig").record;

pub const accounting_version: u32 = 1;

pub const WorkVector = struct {
    input_bytes: u64 = 0,
    output_bytes: u64 = 0,
    structural_visits: u64 = 0,
    analysis_computations: u64 = 0,
    rewrite_attempts: u64 = 0,
    allocation_capacity: u64 = 0,

    pub const Component: type = std.meta.FieldEnum(WorkVector);

    pub fn add(self: WorkVector, other: WorkVector) error{WorkOverflow}!WorkVector {
        var result: WorkVector = .{};
        inline for (@typeInfo(WorkVector).@"struct".field_names) |field| {
            @field(result, field) = std.math.add(
                u64,
                @field(self, field),
                @field(other, field),
            ) catch return error.WorkOverflow;
        }
        return result;
    }

    pub fn exceeded(self: WorkVector, allowance: WorkVector) ?Component {
        inline for (@typeInfo(WorkVector).@"struct".field_names) |field| {
            if (@field(self, field) > @field(allowance, field)) {
                return @field(Component, field);
            }
        }
        return null;
    }

    pub fn uniform(value: u64) WorkVector {
        var result: WorkVector = .{};
        inline for (@typeInfo(WorkVector).@"struct".field_names) |field| {
            @field(result, field) = value;
        }
        return result;
    }
};

/// Physical observations are informational and never determine admission.
pub const Counters = struct {
    pass_runs: u64 = 0,
    passes_modified: u64 = 0,
    analysis_misses: u64 = 0,
    analysis_hits: u64 = 0,
    successful_rewrites: u64 = 0,
    rewrite_iterations: u64 = 0,

    fn add(self: Counters, other: Counters) !Counters {
        var result: Counters = .{};
        inline for (@typeInfo(Counters).@"struct".field_names) |field| {
            @field(result, field) = std.math.add(
                u64,
                @field(self, field),
                @field(other, field),
            ) catch return error.WorkOverflow;
        }
        return result;
    }
};

pub const Outcome = enum(u8) { running, success, rejected, exhausted, cancelled };
fn failureOutcome(err: anyerror) Outcome {
    return switch (err) {
        error.WorkExhausted, error.WorkOverflow, error.WorkTraceLimit => .exhausted,
        else => .rejected,
    };
}

pub const Phase = enum(u8) {
    transport,
    reservation,
    input,
    decode,
    verification,
    pass,
    analysis,
    capture,
    gate,
    output,
};

pub const Limits = struct {
    allowance: WorkVector,
    workspace: u64,
    events: u32,
};

pub const Contract = struct {
    identity: record.Version,
    work: WorkVector,
    workspace: u64 = 0,
    retained_storage: u64 = 0,
};

pub const Executed = struct {
    work: WorkVector = .{},
    counters: Counters = .{},
};

pub const Event = struct {
    name: [96]u8 = @splat(0),
    name_length: u8,
    version: u32,
    phase: Phase,
    occurrence: u32,
    parent: ?u32,
    charged: WorkVector,
    executed: Executed = .{},
    workspace: u64,
    retained_storage: u64,
    outcome: Outcome = .running,
    admitted: bool = false,

    pub fn identity(self: *const Event) record.Version {
        return .{ .name = self.name[0..self.name_length], .version = self.version };
    }
};

pub const WorkReceiptV1 = struct {
    version: u32 = accounting_version,
    limits: Limits,
    charged: WorkVector,
    executed: Executed,
    events: []const Event,
    /// Conservative normative ceiling, not an observed allocator or RSS peak.
    maximum_live_storage: u64,
    outcome: Outcome,
    missing_work_contract: bool,
    exceeded: ?WorkVector.Component,
};

/// A job owns this bounded ledger. Only admitted obligations may execute.
pub const AccountingV1 = opaque {
    pub fn create(
        allocator: std.mem.Allocator,
        limits: Limits,
        pipeline: []const record.Version,
    ) !*AccountingV1 {
        return Ledger.create(allocator, limits, pipeline);
    }

    pub fn destroy(self: *AccountingV1) void {
        ledger(self).destroy();
    }

    pub fn begin(self: *AccountingV1, phase: Phase, contract: Contract) !u32 {
        return ledger(self).begin(phase, contract);
    }

    pub fn finish(self: *AccountingV1, token: u32, outcome: Outcome, executed: Executed) !void {
        try ledger(self).finish(token, outcome, executed);
    }

    /// Record physical screening separately from the fixed transport reservation.
    pub fn observeTransport(self: *AccountingV1, bytes: u64) !void {
        const state = ledger(self);
        if (state.outcome != .running) return error.TerminalWorkOutcome;
        if (state.count != 4 or state.events[0].phase != .transport) {
            return error.CompilerWorkAlreadyStarted;
        }
        const executed = WorkVector{ .input_bytes = bytes };
        state.events[0].executed.work = try state.events[0].executed.work.add(executed);
        state.executed.work = try state.executed.work.add(executed);
    }

    /// Physical counters do not alter admission or the normative charge trace.
    /// Closing observations may follow failure; successful completion is immutable.
    pub fn observeCounters(self: *AccountingV1, counters: Counters) !void {
        const state = ledger(self);
        if (state.outcome == .success) return error.TerminalWorkOutcome;
        const total = state.executed.counters.add(counters) catch {
            return state.reject(error.WorkOverflow);
        };
        if (state.current) |token| {
            const event = &state.events[token];
            event.executed.counters = event.executed.counters.add(counters) catch {
                return state.reject(error.WorkOverflow);
            };
        }
        state.executed.counters = total;
    }

    pub fn missingContract(self: *AccountingV1) void {
        std.debug.assert(ledger(self).outcome == .running);
        ledger(self).missing_work_contract = true;
    }

    pub fn fail(self: *AccountingV1, outcome: Outcome) void {
        std.debug.assert(outcome != .running);
        std.debug.assert(outcome != .success);
        if (ledger(self).outcome == .running) ledger(self).outcome = outcome;
    }

    pub fn producersComplete(self: *AccountingV1) !void {
        try ledger(self).producersComplete();
    }

    pub fn complete(self: *AccountingV1) !void {
        const state = ledger(self);
        try state.producersComplete();
        const required = [_]Phase{ .transport, .reservation, .input, .capture, .gate, .output };
        for (required) |phase| {
            if (!state.completed.contains(phase)) {
                state.missing_work_contract = true;
                return error.MissingWorkContract;
            }
        }
        state.outcome = .success;
    }

    pub fn view(self: *const AccountingV1) WorkReceiptV1 {
        const state: *const Ledger = @ptrCast(@alignCast(self));
        return state.view();
    }

    /// Only a locally sealed store may treat a replay as reuse entitlement.
    pub fn replay(self: *AccountingV1, cold: WorkReceiptV1, skip: u32) !void {
        if (cold.version != accounting_version) return error.AccountingVersionMismatch;
        if (cold.outcome != .success or cold.missing_work_contract) {
            return error.MissingWorkContract;
        }
        if (skip > cold.events.len) return error.InvalidWorkTrace;
        const state = ledger(self);
        for (cold.events[skip..]) |*event| {
            if (!event.admitted or event.outcome != .success) return error.InvalidWorkTrace;
            while (state.current != event.parent) {
                const token = state.current orelse return error.InvalidWorkTrace;
                try self.finish(token, .success, .{});
            }
            if (event.occurrence != state.count) return error.InvalidWorkTrace;
            _ = try self.begin(event.phase, .{
                .identity = event.identity(),
                .work = event.charged,
                .workspace = event.workspace,
                .retained_storage = event.retained_storage,
            });
        }
        while (state.current) |token| try self.finish(token, .success, .{});
    }
};

const Ledger = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    events: []Event,
    count: u32 = 0,
    current: ?u32 = null,
    pipeline: []record.Version,
    next_pass: usize = 0,
    charged: WorkVector = .{},
    executed: Executed = .{},
    maximum_live_storage: u64 = 0,
    retained_storage: u64 = 0,
    outcome: Outcome = .running,
    missing_work_contract: bool = false,
    exceeded: ?WorkVector.Component = null,
    completed: std.EnumSet(Phase) = .{},

    fn create(
        allocator: std.mem.Allocator,
        limits: Limits,
        pipeline: []const record.Version,
    ) !*AccountingV1 {
        if (limits.events == 0) return error.WorkTraceLimit;
        const control_bytes = try storageCapacity(limits, pipeline);
        const self = try allocator.create(Ledger);
        errdefer allocator.destroy(self);
        const events = try allocator.alloc(Event, limits.events);
        errdefer allocator.free(events);
        const owned_pipeline = try clonePipeline(allocator, pipeline);
        self.* = .{
            .allocator = allocator,
            .limits = limits,
            .events = events,
            .pipeline = owned_pipeline,
            .retained_storage = control_bytes,
            .maximum_live_storage = control_bytes,
        };
        return @ptrCast(self);
    }

    fn destroy(self: *Ledger) void {
        const allocator = self.allocator;
        for (self.pipeline) |version| allocator.free(version.name);
        allocator.free(self.pipeline);
        allocator.free(self.events);
        allocator.destroy(self);
    }

    fn begin(self: *Ledger, phase: Phase, contract: Contract) !u32 {
        if (self.outcome != .running) return error.TerminalWorkOutcome;
        if (self.count == self.events.len) return self.reject(error.WorkTraceLimit);
        if (contract.identity.name.len > 96) return self.reject(error.ObligationNameTooLong);
        if (contract.identity.name.len == 0 or contract.identity.version == 0) {
            return self.reject(error.MissingWorkContract);
        }
        if (phase == .pass) try self.admitPass(contract.identity);
        const token = self.count;
        const event = &self.events[token];
        event.* = .{
            .name_length = @intCast(contract.identity.name.len),
            .version = contract.identity.version,
            .phase = phase,
            .occurrence = token,
            .parent = self.current,
            .charged = contract.work,
            .workspace = contract.workspace,
            .retained_storage = contract.retained_storage,
        };
        @memcpy(event.name[0..event.name_length], contract.identity.name);
        self.count += 1;
        self.charged = self.charged.add(contract.work) catch {
            event.outcome = .exhausted;
            self.outcome = .exhausted;
            return error.WorkOverflow;
        };
        try self.admitStorage(contract, event);
        event.admitted = true;
        self.current = token;
        return token;
    }

    fn admitStorage(self: *Ledger, contract: Contract, event: *Event) !void {
        const live = std.math.add(
            u64,
            self.retained_storage,
            @max(contract.workspace, contract.retained_storage),
        ) catch {
            event.outcome = .exhausted;
            return self.reject(error.WorkOverflow);
        };
        self.maximum_live_storage = @max(self.maximum_live_storage, live);
        self.exceeded = self.charged.exceeded(self.limits.allowance);
        if (self.exceeded != null or contract.workspace > self.limits.workspace) {
            event.outcome = .exhausted;
            self.outcome = .exhausted;
            return error.WorkExhausted;
        }
        self.retained_storage = std.math.add(
            u64,
            self.retained_storage,
            contract.retained_storage,
        ) catch {
            event.outcome = .exhausted;
            return self.reject(error.WorkOverflow);
        };
    }

    fn admitPass(self: *Ledger, identity: record.Version) !void {
        if (self.next_pass == self.pipeline.len) return self.reject(error.MissingWorkContract);
        if (!identity.eql(self.pipeline[self.next_pass])) {
            return self.reject(error.WorkContractMismatch);
        }
        self.next_pass += 1;
    }

    fn finish(self: *Ledger, token: u32, outcome: Outcome, executed: Executed) !void {
        std.debug.assert(token < self.count);
        std.debug.assert(self.current == token);
        std.debug.assert(outcome != .running);
        const event = &self.events[token];
        std.debug.assert(event.outcome == .running);
        const final_outcome = if (self.outcome == .running) outcome else self.outcome;
        event.outcome = final_outcome;
        self.current = event.parent;
        event.executed.work = executed.work;
        event.executed.counters = event.executed.counters.add(executed.counters) catch {
            event.outcome = .exhausted;
            return self.reject(error.WorkOverflow);
        };
        self.executed.work = self.executed.work.add(executed.work) catch {
            return self.reject(error.WorkOverflow);
        };
        self.executed.counters = self.executed.counters.add(executed.counters) catch {
            return self.reject(error.WorkOverflow);
        };
        if (final_outcome == .success) {
            self.completed.insert(event.phase);
        } else if (self.outcome == .running) {
            self.outcome = final_outcome;
        }
    }

    fn producersComplete(self: *Ledger) !void {
        if (self.outcome == .exhausted) return error.WorkExhausted;
        if (self.outcome != .running) return error.TerminalWorkOutcome;
        if (self.current != null or self.missing_work_contract or
            self.next_pass != self.pipeline.len)
        {
            self.missing_work_contract = true;
            return error.MissingWorkContract;
        }
    }

    fn reject(self: *Ledger, err: anyerror) anyerror {
        if (self.outcome == .running) self.outcome = failureOutcome(err);
        if (err == error.MissingWorkContract) self.missing_work_contract = true;
        return err;
    }

    fn view(self: *const Ledger) WorkReceiptV1 {
        return .{
            .limits = self.limits,
            .charged = self.charged,
            .executed = self.executed,
            .events = self.events[0..self.count],
            .maximum_live_storage = self.maximum_live_storage,
            .outcome = self.outcome,
            .missing_work_contract = self.missing_work_contract,
            .exceeded = self.exceeded,
        };
    }
};

fn ledger(handle: *AccountingV1) *Ledger {
    return @ptrCast(@alignCast(handle));
}

fn storageCapacity(limits: Limits, pipeline: []const record.Version) !u64 {
    var size = std.math.mul(u64, limits.events, @sizeOf(Event)) catch
        return error.WorkOverflow;
    size = std.math.add(u64, size, @sizeOf(Ledger)) catch return error.WorkOverflow;
    const entries = std.math.mul(u64, pipeline.len, @sizeOf(record.Version)) catch
        return error.WorkOverflow;
    size = std.math.add(u64, size, entries) catch return error.WorkOverflow;
    for (pipeline) |version| {
        size = std.math.add(u64, size, version.name.len) catch return error.WorkOverflow;
    }
    return size;
}

fn clonePipeline(allocator: std.mem.Allocator, pipeline: []const record.Version) ![]record.Version {
    const copy = try allocator.alloc(record.Version, pipeline.len);
    errdefer allocator.free(copy);
    var initialized: usize = 0;
    errdefer for (copy[0..initialized]) |version| allocator.free(version.name);
    for (pipeline, copy) |version, *target| {
        target.* = .{
            .name = try allocator.dupe(u8, version.name),
            .version = version.version,
        };
        initialized += 1;
    }
    return copy;
}
