const std = @import("std");
const report_mod = @import("report.zig");

pub const max_repair_entries: usize = 32;

pub const OverflowRepair = struct {
    allocation_return_address: usize = 0,
    padding_bytes: usize = 0,
};

pub const DangleRepair = struct {
    allocation_return_address: usize = 0,
    free_return_address: usize = 0,
    quarantine_epochs: u64 = 0,
};

pub const RepairTable = struct {
    overflow_count: usize = 0,
    dangle_count: usize = 0,
    overflow_entries: [max_repair_entries]OverflowRepair = @as([max_repair_entries]OverflowRepair, @splat(.{})),
    dangle_entries: [max_repair_entries]DangleRepair = @as([max_repair_entries]DangleRepair, @splat(.{})),

    pub fn fromReport(report: report_mod.Report, current: RepairTable) RepairTable {
        var next = current;
        for (report.issueSlice()) |issue| next.recordIssue(issue);
        return next;
    }

    pub fn overflowPadding(self: RepairTable, allocation_return_address: usize) usize {
        var index: usize = 0;
        while (index < self.overflow_count) : (index += 1) {
            const entry = self.overflow_entries[index];
            if (entry.allocation_return_address == allocation_return_address) return entry.padding_bytes;
        }
        return 0;
    }

    pub fn lifeExtension(self: RepairTable, allocation_return_address: usize, free_return_address: usize) u64 {
        var index: usize = 0;
        while (index < self.dangle_count) : (index += 1) {
            const entry = self.dangle_entries[index];
            if (entry.allocation_return_address == allocation_return_address and entry.free_return_address == free_return_address) {
                return entry.quarantine_epochs;
            }
        }
        return 0;
    }

    fn recordIssue(self: *RepairTable, issue: report_mod.Issue) void {
        switch (issue.kind) {
            .buffer_overflow => self.recordOverflow(issue),
            .use_after_free, .double_free => self.recordDangle(issue),
            .invalid_free, .leak, .size_mismatch => {},
        }
    }

    fn recordOverflow(self: *RepairTable, issue: report_mod.Issue) void {
        if (issue.allocation_return_address == 0) return;
        const needed = if (issue.offset >= issue.requested_len)
            issue.offset - issue.requested_len + 1
        else
            1;
        if (needed == 0) return;

        var index: usize = 0;
        while (index < self.overflow_count) : (index += 1) {
            if (self.overflow_entries[index].allocation_return_address == issue.allocation_return_address) {
                self.overflow_entries[index].padding_bytes = @max(self.overflow_entries[index].padding_bytes, needed);
                return;
            }
        }
        if (self.overflow_count == self.overflow_entries.len) return;
        self.overflow_entries[self.overflow_count] = .{
            .allocation_return_address = issue.allocation_return_address,
            .padding_bytes = needed,
        };
        self.overflow_count += 1;
    }

    fn recordDangle(self: *RepairTable, issue: report_mod.Issue) void {
        if (issue.allocation_return_address == 0) return;
        const free_return_address = if (issue.free_return_address != 0) issue.free_return_address else issue.return_address;
        if (free_return_address == 0) return;

        var index: usize = 0;
        while (index < self.dangle_count) : (index += 1) {
            if (self.dangle_entries[index].allocation_return_address == issue.allocation_return_address and self.dangle_entries[index].free_return_address == free_return_address) {
                self.dangle_entries[index].quarantine_epochs = growU64(self.dangle_entries[index].quarantine_epochs, 1, 4096);
                return;
            }
        }
        if (self.dangle_count == self.dangle_entries.len) return;
        self.dangle_entries[self.dangle_count] = .{
            .allocation_return_address = issue.allocation_return_address,
            .free_return_address = free_return_address,
            .quarantine_epochs = 1,
        };
        self.dangle_count += 1;
    }
};

pub const RepairPolicy = struct {
    red_zone_bytes: usize = 16,
    quarantine_epochs: u64 = 16,
    repairs: RepairTable = .{},

    pub fn fromReport(report: report_mod.Report, current: RepairPolicy) RepairPolicy {
        var next = current;
        if (report.counters.buffer_overflow > 0) {
            next.red_zone_bytes = growUsize(current.red_zone_bytes, 16, 1024);
        }
        if (report.counters.use_after_free > 0 or report.counters.double_free > 0) {
            next.quarantine_epochs = growU64(current.quarantine_epochs, 1, 4096);
        }
        next.repairs = RepairTable.fromReport(report, current.repairs);
        return next;
    }
};

fn growUsize(current: usize, initial: usize, cap: usize) usize {
    if (current == 0) return initial;
    if (current >= cap) return current;
    return @min(current * 2, cap);
}

fn growU64(current: u64, initial: u64, cap: u64) u64 {
    if (current == 0) return initial;
    if (current >= cap) return current;
    return @min(current * 2, cap);
}

test "repair policy grows padding and quarantine from diagnostics" {
    const report: report_mod.Report = .{
        .counters = .{
            .buffer_overflow = 1,
            .use_after_free = 1,
        },
    };
    const repaired = RepairPolicy.fromReport(report, .{ .red_zone_bytes = 8, .quarantine_epochs = 2 });
    try std.testing.expectEqual(@as(usize, 16), repaired.red_zone_bytes);
    try std.testing.expectEqual(@as(u64, 4), repaired.quarantine_epochs);
}

test "repair policy starts from zero without reducing hardened settings" {
    const report: report_mod.Report = .{
        .counters = .{
            .buffer_overflow = 1,
            .double_free = 1,
        },
    };

    const started = RepairPolicy.fromReport(report, .{ .red_zone_bytes = 0, .quarantine_epochs = 0 });
    try std.testing.expectEqual(@as(usize, 16), started.red_zone_bytes);
    try std.testing.expectEqual(@as(u64, 1), started.quarantine_epochs);

    const hardened = RepairPolicy.fromReport(report, .{ .red_zone_bytes = 2048, .quarantine_epochs = 8192 });
    try std.testing.expectEqual(@as(usize, 2048), hardened.red_zone_bytes);
    try std.testing.expectEqual(@as(u64, 8192), hardened.quarantine_epochs);
}

test "repair table records overflow padding by allocation site" {
    const report: report_mod.Report = .{
        .issues = .{
            .count = 1,
            .items = [_]report_mod.Issue{.{
                .kind = .buffer_overflow,
                .offset = 13,
                .requested_len = 8,
                .allocation_return_address = 0x1000,
            }} ++ @as([(report_mod.max_issues - 1)]report_mod.Issue, @splat(.{})),
        },
    };

    const table = RepairTable.fromReport(report, .{});
    try std.testing.expectEqual(@as(usize, 6), table.overflowPadding(0x1000));
    try std.testing.expectEqual(@as(usize, 0), table.overflowPadding(0x2000));
}

test "repair table records dangle extensions by allocation and free site" {
    const report: report_mod.Report = .{
        .issues = .{
            .count = 1,
            .items = [_]report_mod.Issue{.{
                .kind = .use_after_free,
                .allocation_return_address = 0x1000,
                .free_return_address = 0x2000,
            }} ++ @as([(report_mod.max_issues - 1)]report_mod.Issue, @splat(.{})),
        },
    };

    const first = RepairTable.fromReport(report, .{});
    const second = RepairTable.fromReport(report, first);
    try std.testing.expectEqual(@as(u64, 1), first.lifeExtension(0x1000, 0x2000));
    try std.testing.expectEqual(@as(u64, 2), second.lifeExtension(0x1000, 0x2000));
    try std.testing.expectEqual(@as(u64, 0), second.lifeExtension(0x1000, 0x3000));
}
