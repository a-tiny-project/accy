pub const IssueKind = enum {
    invalid_free,
    double_free,
    buffer_overflow,
    use_after_free,
    leak,
    size_mismatch,
};

pub const Issue = struct {
    kind: IssueKind = .invalid_free,
    address: usize = 0,
    offset: usize = 0,
    requested_len: usize = 0,
    block_size: usize = 0,
    allocation_id: u64 = 0,
    allocation_return_address: usize = 0,
    free_return_address: usize = 0,
    free_epoch: u64 = 0,
    return_address: usize = 0,
};

pub const max_issues: usize = 32;

pub const IssueLog = struct {
    count: usize = 0,
    dropped: usize = 0,
    items: [max_issues]Issue = @as([max_issues]Issue, @splat(.{})),

    pub fn append(self: *IssueLog, issue: Issue) void {
        if (self.count < self.items.len) {
            self.items[self.count] = issue;
            self.count += 1;
            return;
        }
        self.dropped += 1;
    }

    pub fn slice(self: *const IssueLog) []const Issue {
        return self.items[0..self.count];
    }
};

pub const Counters = struct {
    invalid_free: usize = 0,
    double_free: usize = 0,
    buffer_overflow: usize = 0,
    use_after_free: usize = 0,
    size_mismatch: usize = 0,

    pub fn issueCount(self: Counters) usize {
        return self.invalid_free +
            self.double_free +
            self.buffer_overflow +
            self.use_after_free +
            self.size_mismatch;
    }

    pub fn increment(self: *Counters, kind: IssueKind) void {
        switch (kind) {
            .invalid_free => self.invalid_free += 1,
            .double_free => self.double_free += 1,
            .buffer_overflow => self.buffer_overflow += 1,
            .use_after_free => self.use_after_free += 1,
            .size_mismatch => self.size_mismatch += 1,
            .leak => {},
        }
    }
};

pub const Report = struct {
    counters: Counters = .{},
    live_allocations: usize = 0,
    live_bytes: usize = 0,
    leak_count: usize = 0,
    leak_issue: ?Issue = null,
    last_issue: ?Issue = null,
    issues: IssueLog = .{},

    pub fn isClean(self: Report) bool {
        return self.counters.issueCount() == 0 and self.leak_count == 0;
    }

    pub fn issueSlice(self: *const Report) []const Issue {
        return self.issues.slice();
    }
};
