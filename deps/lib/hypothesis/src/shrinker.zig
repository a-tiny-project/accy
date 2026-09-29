const std = @import("std");
const Allocator = std.mem.Allocator;
const conjecture = @import("conjecture.zig");
const ChoiceNode = conjecture.ChoiceNode;
const Span = conjecture.Span;
const Status = conjecture.Status;

pub const ReplayFn = *const fn (
    choices: []const ChoiceNode,
    byte_blocks: ?[]const u8,
    context: *anyopaque,
) Status;

pub fn shrink(
    allocator: Allocator,
    initial_choices: []const ChoiceNode,
    initial_spans: []const Span,
    initial_byte_blocks: ?[]const u8,
    replay_fn: ReplayFn,
    replay_context: *anyopaque,
    max_shrinks: usize,
) !ShrinkResult {
    var choices = try allocator.alloc(ChoiceNode, initial_choices.len);
    @memcpy(choices, initial_choices);

    var spans = try allocator.alloc(Span, initial_spans.len);
    @memcpy(spans, initial_spans);

    var byte_blocks: ?[]u8 = if (initial_byte_blocks) |bb| blk: {
        const buf = try allocator.alloc(u8, bb.len);
        @memcpy(buf, bb);
        break :blk buf;
    } else null;

    var shrinks_remaining: usize = max_shrinks;
    var improved = true;

    while (improved and shrinks_remaining > 0) {
        improved = false;

        const r1 = try deleteSpans(
            allocator,
            choices,
            spans,
            byte_blocks,
            replay_fn,
            replay_context,
            &shrinks_remaining,
        );
        if (r1.improved) {
            allocator.free(choices);
            choices = r1.choices;
            allocator.free(spans);
            spans = r1.spans;
            updateByteBlocks(allocator, &byte_blocks, r1.byte_blocks);
            improved = true;
        }

        const r2 = try tryTrivialSpans(
            allocator,
            choices,
            spans,
            byte_blocks,
            replay_fn,
            replay_context,
            &shrinks_remaining,
        );
        if (r2.improved) {
            allocator.free(choices);
            choices = r2.choices;
            updateByteBlocks(allocator, &byte_blocks, r2.byte_blocks);
            improved = true;
        }

        const r3 = try minimizeIndividual(
            allocator,
            choices,
            byte_blocks,
            replay_fn,
            replay_context,
            &shrinks_remaining,
        );
        if (r3.improved) {
            allocator.free(choices);
            choices = r3.choices;
            updateByteBlocks(allocator, &byte_blocks, r3.byte_blocks);
            improved = true;
        }

        const r4 = try minimizeDuplicated(
            allocator,
            choices,
            byte_blocks,
            replay_fn,
            replay_context,
            &shrinks_remaining,
        );
        if (r4.improved) {
            allocator.free(choices);
            choices = r4.choices;
            updateByteBlocks(allocator, &byte_blocks, r4.byte_blocks);
            improved = true;
        }

        const r5 = try redistributePairs(
            allocator,
            choices,
            byte_blocks,
            replay_fn,
            replay_context,
            &shrinks_remaining,
        );
        if (r5.improved) {
            allocator.free(choices);
            choices = r5.choices;
            updateByteBlocks(allocator, &byte_blocks, r5.byte_blocks);
            improved = true;
        }

        const r6 = try reorderSpans(
            allocator,
            choices,
            spans,
            byte_blocks,
            replay_fn,
            replay_context,
            &shrinks_remaining,
        );
        if (r6.improved) {
            allocator.free(choices);
            choices = r6.choices;
            allocator.free(spans);
            spans = r6.spans;
            updateByteBlocks(allocator, &byte_blocks, r6.byte_blocks);
            improved = true;
        }

        const r7 = try lowerTogether(
            allocator,
            choices,
            byte_blocks,
            replay_fn,
            replay_context,
            &shrinks_remaining,
        );
        if (r7.improved) {
            allocator.free(choices);
            choices = r7.choices;
            updateByteBlocks(allocator, &byte_blocks, r7.byte_blocks);
            improved = true;
        }

        const r8 = try minimizeFloats(
            allocator,
            choices,
            byte_blocks,
            replay_fn,
            replay_context,
            &shrinks_remaining,
        );
        if (r8.improved) {
            allocator.free(choices);
            choices = r8.choices;
            updateByteBlocks(allocator, &byte_blocks, r8.byte_blocks);
            improved = true;
        }
    }

    return .{
        .choices = choices,
        .spans = spans,
        .byte_blocks = byte_blocks,
    };
}

fn updateByteBlocks(
    allocator: Allocator,
    current: *?[]u8,
    next: ?[]u8,
) void {
    if (current.*) |old| {
        if (next) |new| {
            if (old.ptr != new.ptr) {
                allocator.free(old);
            }
        } else {
            allocator.free(old);
        }
    }
    current.* = next;
}

pub const ShrinkResult = struct {
    choices: []ChoiceNode,
    spans: []Span,
    byte_blocks: ?[]u8,

    pub fn deinit(self: *ShrinkResult, allocator: Allocator) void {
        allocator.free(self.choices);
        allocator.free(self.spans);
        if (self.byte_blocks) |bb| allocator.free(bb);
    }
};

const PassResult = struct {
    choices: []ChoiceNode,
    spans: []Span,
    byte_blocks: ?[]u8,
    improved: bool,
};

const PassResultNoSpans = struct {
    choices: []ChoiceNode,
    byte_blocks: ?[]u8,
    improved: bool,
};

fn tryCandidate(
    candidate: []const ChoiceNode,
    byte_blocks: ?[]const u8,
    replay_fn: ReplayFn,
    replay_context: *anyopaque,
    shrinks_remaining: *usize,
) bool {
    if (shrinks_remaining.* == 0) return false;
    shrinks_remaining.* -= 1;
    return replay_fn(candidate, byte_blocks, replay_context) == .interesting;
}

fn deleteSpans(
    allocator: Allocator,
    choices: []ChoiceNode,
    spans: []Span,
    byte_blocks: ?[]u8,
    replay_fn: ReplayFn,
    replay_context: *anyopaque,
    shrinks_remaining: *usize,
) !PassResult {
    if (spans.len == 0 or shrinks_remaining.* == 0) return .{
        .choices = choices,
        .spans = spans,
        .byte_blocks = byte_blocks,
        .improved = false,
    };

    var current_choices = try allocator.alloc(ChoiceNode, choices.len);
    @memcpy(current_choices, choices);
    var current_spans = try allocator.alloc(Span, spans.len);
    @memcpy(current_spans, spans);
    var improved = false;

    var group_size: usize = current_spans.len;
    while (group_size >= 1 and shrinks_remaining.* != 0) {
        var i: usize = 0;
        while (i + group_size <= current_spans.len and shrinks_remaining.* != 0) {
            const span_group = current_spans[i..][0..group_size];
            const first = span_group[0].start;
            const last = span_group[group_size - 1].end;

            if (first >= current_choices.len or last > current_choices.len or first >= last) {
                i += 1;
                continue;
            }

            const new_len = current_choices.len - (last - first);
            const candidate = try allocator.alloc(ChoiceNode, new_len);
            @memcpy(candidate[0..first], current_choices[0..first]);
            if (last < current_choices.len) {
                @memcpy(candidate[first..], current_choices[last..]);
            }

            if (tryCandidate(candidate, byte_blocks, replay_fn, replay_context, shrinks_remaining)) {
                allocator.free(current_choices);
                current_choices = candidate;
                const new_spans_len = current_spans.len - group_size;
                const new_spans = try allocator.alloc(Span, new_spans_len);
                var si: usize = 0;
                for (current_spans, 0..) |s, idx| {
                    if (idx >= i and idx < i + group_size) continue;
                    var adjusted = s;
                    if (adjusted.start >= last) {
                        adjusted.start -= (last - first);
                        adjusted.end -= (last - first);
                    } else if (adjusted.start >= first) {
                        continue;
                    } else if (adjusted.end > last) {
                        adjusted.end -= (last - first);
                    } else if (adjusted.end > first) {
                        adjusted.end = first;
                    }
                    new_spans[si] = adjusted;
                    si += 1;
                }
                allocator.free(current_spans);
                current_spans = try allocator.realloc(new_spans, si);
                improved = true;
            } else {
                allocator.free(candidate);
                i += 1;
            }
        }
        group_size /= 2;
    }

    if (!improved) {
        allocator.free(current_choices);
        allocator.free(current_spans);
    }

    return .{
        .choices = if (improved) current_choices else choices,
        .spans = if (improved) current_spans else spans,
        .byte_blocks = byte_blocks,
        .improved = improved,
    };
}

fn tryTrivialSpans(
    allocator: Allocator,
    choices: []ChoiceNode,
    spans: []Span,
    byte_blocks: ?[]u8,
    replay_fn: ReplayFn,
    replay_context: *anyopaque,
    shrinks_remaining: *usize,
) !PassResultNoSpans {
    if (shrinks_remaining.* == 0) return .{
        .choices = choices,
        .byte_blocks = byte_blocks,
        .improved = false,
    };

    var current_choices = try allocator.alloc(ChoiceNode, choices.len);
    @memcpy(current_choices, choices);
    const saved = try allocator.alloc(u64, choices.len);
    defer allocator.free(saved);
    var improved = false;

    for (spans) |span| {
        if (shrinks_remaining.* == 0) break;
        if (span.start >= current_choices.len or span.end > current_choices.len) continue;

        var changed = false;
        for (current_choices[span.start..span.end]) |node| {
            if (!node.was_forced and node.value != node.shrink_towards) {
                changed = true;
                break;
            }
        }
        if (!changed) continue;

        const window = current_choices[span.start..span.end];
        for (window, 0..) |node, offset| saved[offset] = node.value;
        for (window) |*node| {
            if (!node.was_forced) {
                node.value = node.shrink_towards;
            }
        }

        if (tryCandidate(current_choices, byte_blocks, replay_fn, replay_context, shrinks_remaining)) {
            improved = true;
        } else {
            for (window, 0..) |*node, offset| node.value = saved[offset];
        }
    }

    if (!improved) {
        allocator.free(current_choices);
    }

    return .{
        .choices = if (improved) current_choices else choices,
        .byte_blocks = byte_blocks,
        .improved = improved,
    };
}

fn minimizeIndividual(
    allocator: Allocator,
    choices: []ChoiceNode,
    byte_blocks: ?[]u8,
    replay_fn: ReplayFn,
    replay_context: *anyopaque,
    shrinks_remaining: *usize,
) !PassResultNoSpans {
    if (shrinks_remaining.* == 0) return .{
        .choices = choices,
        .byte_blocks = byte_blocks,
        .improved = false,
    };

    var current_choices = try allocator.alloc(ChoiceNode, choices.len);
    @memcpy(current_choices, choices);
    var improved = false;

    var i: usize = 0;
    while (i < current_choices.len) : (i += 1) {
        if (shrinks_remaining.* == 0) break;
        const node = current_choices[i];
        if (node.was_forced or node.kind != .integer) continue;
        if (node.value == node.shrink_towards) continue;

        var lo = node.shrink_towards;
        var hi = node.value;
        const shrinks_down = node.shrink_towards <= node.value;
        if (lo > hi) {
            const tmp = lo;
            lo = hi;
            hi = tmp;
        }

        var kept = node.value;
        while (lo < hi) {
            if (shrinks_remaining.* == 0) break;
            const mid = lo + (hi - lo) / 2;
            const try_val = if (shrinks_down) mid else hi - (mid - lo);

            current_choices[i].value = try_val;

            if (tryCandidate(current_choices, byte_blocks, replay_fn, replay_context, shrinks_remaining)) {
                kept = try_val;
                hi = try_val;
                improved = true;
            } else {
                current_choices[i].value = kept;
                if (shrinks_down) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
        }
    }

    if (!improved) {
        allocator.free(current_choices);
    }

    return .{
        .choices = if (improved) current_choices else choices,
        .byte_blocks = byte_blocks,
        .improved = improved,
    };
}

fn minimizeDuplicated(
    allocator: Allocator,
    choices: []ChoiceNode,
    byte_blocks: ?[]u8,
    replay_fn: ReplayFn,
    replay_context: *anyopaque,
    shrinks_remaining: *usize,
) !PassResultNoSpans {
    if (shrinks_remaining.* == 0) return .{
        .choices = choices,
        .byte_blocks = byte_blocks,
        .improved = false,
    };

    var current_choices = try allocator.alloc(ChoiceNode, choices.len);
    @memcpy(current_choices, choices);
    const touched = try allocator.alloc(usize, choices.len);
    defer allocator.free(touched);
    var improved = false;

    var i: usize = 0;
    while (i < current_choices.len) : (i += 1) {
        if (shrinks_remaining.* == 0) break;
        const node = current_choices[i];
        if (node.was_forced or node.kind != .integer) continue;
        if (node.value == node.shrink_towards) continue;

        var touched_count: usize = 0;
        for (current_choices[i + 1 ..], i + 1..) |other, other_index| {
            if (other.kind == .integer and !other.was_forced and other.value == node.value) {
                touched[touched_count] = other_index;
                touched_count += 1;
            }
        }

        if (touched_count == 0) continue;

        const target = node.shrink_towards;
        current_choices[i].value = target;
        for (touched[0..touched_count]) |other_index| {
            current_choices[other_index].value = target;
        }

        if (tryCandidate(current_choices, byte_blocks, replay_fn, replay_context, shrinks_remaining)) {
            improved = true;
        } else {
            current_choices[i].value = node.value;
            for (touched[0..touched_count]) |other_index| {
                current_choices[other_index].value = node.value;
            }
        }
    }

    if (!improved) {
        allocator.free(current_choices);
    }

    return .{
        .choices = if (improved) current_choices else choices,
        .byte_blocks = byte_blocks,
        .improved = improved,
    };
}

fn redistributePairs(
    allocator: Allocator,
    choices: []ChoiceNode,
    byte_blocks: ?[]u8,
    replay_fn: ReplayFn,
    replay_context: *anyopaque,
    shrinks_remaining: *usize,
) !PassResultNoSpans {
    if (choices.len < 2 or shrinks_remaining.* == 0) return .{
        .choices = choices,
        .byte_blocks = byte_blocks,
        .improved = false,
    };

    var current_choices = try allocator.alloc(ChoiceNode, choices.len);
    @memcpy(current_choices, choices);
    var improved = false;

    var i: usize = 0;
    while (i + 1 < current_choices.len) : (i += 1) {
        if (shrinks_remaining.* == 0) break;
        const a = &current_choices[i];
        const b = &current_choices[i + 1];

        if (a.kind != .integer or b.kind != .integer) continue;
        if (a.was_forced or b.was_forced) continue;

        const sum = a.value +% b.value;
        const new_a = a.shrink_towards;
        if (sum < new_a) continue;
        if (new_a == a.value) continue;
        const new_b = sum -% new_a;

        if (new_b > b.max or new_a < a.min) continue;

        const old_a = a.value;
        const old_b = b.value;
        a.value = new_a;
        b.value = new_b;

        if (tryCandidate(current_choices, byte_blocks, replay_fn, replay_context, shrinks_remaining)) {
            improved = true;
        } else {
            a.value = old_a;
            b.value = old_b;
        }
    }

    if (!improved) {
        allocator.free(current_choices);
    }

    return .{
        .choices = if (improved) current_choices else choices,
        .byte_blocks = byte_blocks,
        .improved = improved,
    };
}

fn reorderSpans(
    allocator: Allocator,
    choices: []ChoiceNode,
    spans: []Span,
    byte_blocks: ?[]u8,
    replay_fn: ReplayFn,
    replay_context: *anyopaque,
    shrinks_remaining: *usize,
) !PassResult {
    if (spans.len < 2 or shrinks_remaining.* == 0) return .{
        .choices = choices,
        .spans = spans,
        .byte_blocks = byte_blocks,
        .improved = false,
    };

    var current_choices = try allocator.alloc(ChoiceNode, choices.len);
    @memcpy(current_choices, choices);
    var current_spans = try allocator.alloc(Span, spans.len);
    @memcpy(current_spans, spans);
    var improved = false;

    var i: usize = 0;
    while (i + 1 < current_spans.len) : (i += 1) {
        if (shrinks_remaining.* == 0) break;
        const a = current_spans[i];
        const b = current_spans[i + 1];

        if (a.depth != b.depth) continue;
        if (a.end != b.start) continue;
        if (a.end > current_choices.len or b.end > current_choices.len) continue;

        const a_slice = current_choices[a.start..a.end];
        const b_slice = current_choices[b.start..b.end];

        if (!lexLess(b_slice, a_slice)) continue;

        const candidate = try allocator.alloc(ChoiceNode, current_choices.len);
        @memcpy(candidate[0..a.start], current_choices[0..a.start]);
        const b_len = b.end - b.start;
        const a_len = a.end - a.start;
        @memcpy(candidate[a.start..][0..b_len], b_slice);
        @memcpy(candidate[a.start + b_len ..][0..a_len], a_slice);
        if (b.end < current_choices.len) {
            @memcpy(candidate[a.start + b_len + a_len ..], current_choices[b.end..]);
        }

        if (tryCandidate(candidate, byte_blocks, replay_fn, replay_context, shrinks_remaining)) {
            allocator.free(current_choices);
            current_choices = candidate;
            current_spans[i] = .{
                .label = b.label,
                .start = a.start,
                .end = a.start + b_len,
                .depth = a.depth,
            };
            current_spans[i + 1] = .{
                .label = a.label,
                .start = a.start + b_len,
                .end = a.start + b_len + a_len,
                .depth = a.depth,
            };
            improved = true;
        } else {
            allocator.free(candidate);
        }
    }

    if (!improved) {
        allocator.free(current_choices);
        allocator.free(current_spans);
    }

    return .{
        .choices = if (improved) current_choices else choices,
        .spans = if (improved) current_spans else spans,
        .byte_blocks = byte_blocks,
        .improved = improved,
    };
}

fn lowerTogether(
    allocator: Allocator,
    choices: []ChoiceNode,
    byte_blocks: ?[]u8,
    replay_fn: ReplayFn,
    replay_context: *anyopaque,
    shrinks_remaining: *usize,
) !PassResultNoSpans {
    if (shrinks_remaining.* == 0) return .{
        .choices = choices,
        .byte_blocks = byte_blocks,
        .improved = false,
    };

    var current_choices = try allocator.alloc(ChoiceNode, choices.len);
    @memcpy(current_choices, choices);
    var improved = false;

    const window: usize = 3;
    var saved: [window]u64 = undefined;
    var start: usize = 0;
    while (start + 1 < current_choices.len) : (start += 1) {
        if (shrinks_remaining.* == 0) break;
        const end = @min(start + window, current_choices.len);

        var can_lower = false;
        for (current_choices[start..end]) |node| {
            if (node.kind == .integer and !node.was_forced and node.value > node.shrink_towards) {
                can_lower = true;
                break;
            }
        }
        if (!can_lower) continue;

        const slice = current_choices[start..end];
        for (slice, 0..) |node, offset| saved[offset] = node.value;
        for (slice) |*node| {
            if (node.kind == .integer and !node.was_forced and node.value > node.shrink_towards) {
                node.value -= 1;
            }
        }

        if (tryCandidate(current_choices, byte_blocks, replay_fn, replay_context, shrinks_remaining)) {
            improved = true;
        } else {
            for (slice, 0..) |*node, offset| node.value = saved[offset];
        }
    }

    if (!improved) {
        allocator.free(current_choices);
    }

    return .{
        .choices = if (improved) current_choices else choices,
        .byte_blocks = byte_blocks,
        .improved = improved,
    };
}

fn minimizeFloats(
    allocator: Allocator,
    choices: []ChoiceNode,
    byte_blocks: ?[]u8,
    replay_fn: ReplayFn,
    replay_context: *anyopaque,
    shrinks_remaining: *usize,
) !PassResultNoSpans {
    if (shrinks_remaining.* == 0) return .{
        .choices = choices,
        .byte_blocks = byte_blocks,
        .improved = false,
    };

    var current_choices = try allocator.alloc(ChoiceNode, choices.len);
    @memcpy(current_choices, choices);
    var improved = false;

    for (0..current_choices.len) |i| {
        if (shrinks_remaining.* == 0) break;
        const node_snapshot = current_choices[i];
        if (node_snapshot.was_forced or node_snapshot.kind != .float) continue;

        const min_f: f64 = @bitCast(node_snapshot.min);
        const max_f: f64 = @bitCast(node_snapshot.max);
        const target_f: f64 = @bitCast(node_snapshot.shrink_towards);
        const cur_f: f64 = @bitCast(node_snapshot.value);

        if (bitsEqual(cur_f, target_f)) continue;

        var candidates_buf: [8]f64 = undefined;
        var n_candidates: usize = 0;
        addFloatCandidate(&candidates_buf, &n_candidates, target_f, min_f, max_f);
        addFloatCandidate(&candidates_buf, &n_candidates, 0.0, min_f, max_f);
        addFloatCandidate(&candidates_buf, &n_candidates, 1.0, min_f, max_f);
        addFloatCandidate(&candidates_buf, &n_candidates, -1.0, min_f, max_f);
        if (std.math.isFinite(cur_f) and std.math.signbit(cur_f) and cur_f != 0.0) {
            addFloatCandidate(&candidates_buf, &n_candidates, -cur_f, min_f, max_f);
        }
        if (std.math.isFinite(cur_f)) {
            addFloatCandidate(&candidates_buf, &n_candidates, @trunc(cur_f), min_f, max_f);
            addFloatCandidate(&candidates_buf, &n_candidates, @floor(cur_f), min_f, max_f);
        }

        for (candidates_buf[0..n_candidates]) |cand| {
            if (shrinks_remaining.* == 0) break;
            const cur_now: f64 = @bitCast(current_choices[i].value);
            if (bitsEqual(cand, cur_now)) continue;

            const old_bits = current_choices[i].value;
            current_choices[i].value = @bitCast(cand);

            if (tryCandidate(current_choices, byte_blocks, replay_fn, replay_context, shrinks_remaining)) {
                improved = true;
                break;
            } else {
                current_choices[i].value = old_bits;
            }
        }

        var phase_b_steps: usize = 0;
        const max_bisect_steps: usize = 32;
        while (phase_b_steps < max_bisect_steps) : (phase_b_steps += 1) {
            if (shrinks_remaining.* == 0) break;
            const cur_now: f64 = @bitCast(current_choices[i].value);
            if (!std.math.isFinite(cur_now) or !std.math.isFinite(target_f)) break;
            if (cur_now == target_f) break;

            const mid = cur_now * 0.5 + target_f * 0.5;
            if (mid == cur_now or mid == target_f) break;
            if (mid < min_f or mid > max_f) break;

            const old_bits = current_choices[i].value;
            current_choices[i].value = @bitCast(mid);

            if (tryCandidate(current_choices, byte_blocks, replay_fn, replay_context, shrinks_remaining)) {
                improved = true;
            } else {
                current_choices[i].value = old_bits;
                break;
            }
        }
    }

    if (!improved) {
        allocator.free(current_choices);
    }

    return .{
        .choices = if (improved) current_choices else choices,
        .byte_blocks = byte_blocks,
        .improved = improved,
    };
}

fn addFloatCandidate(buf: *[8]f64, n: *usize, v: f64, lo: f64, hi: f64) void {
    if (n.* >= buf.len) return;
    if (std.math.isNan(v)) return;
    if (v < lo or v > hi) return;
    for (buf[0..n.*]) |existing| {
        if (bitsEqual(existing, v)) return;
    }
    buf[n.*] = v;
    n.* += 1;
}

fn bitsEqual(a: f64, b: f64) bool {
    const ai: u64 = @bitCast(a);
    const bi: u64 = @bitCast(b);
    return ai == bi;
}

fn lexLess(a: []const ChoiceNode, b: []const ChoiceNode) bool {
    const len = @min(a.len, b.len);
    for (a[0..len], b[0..len]) |x, y| {
        if (x.value < y.value) return true;
        if (x.value > y.value) return false;
    }
    return a.len < b.len;
}

const AlwaysInterestingReplay = struct {
    fn replay(_: []const ChoiceNode, _: ?[]const u8, _: *anyopaque) Status {
        return .interesting;
    }
};

const TwoChoiceReplay = struct {
    fn replay(choices: []const ChoiceNode, _: ?[]const u8, _: *anyopaque) Status {
        return if (choices.len == 2) .interesting else .valid;
    }
};

const IndividualThresholdReplay = struct {
    fn replay(choices: []const ChoiceNode, _: ?[]const u8, _: *anyopaque) Status {
        if (choices.len > 0 and choices[0].value > 10) return .interesting;
        return .valid;
    }
};

const DuplicatedZeroReplay = struct {
    fn replay(choices: []const ChoiceNode, _: ?[]const u8, _: *anyopaque) Status {
        if (choices[0].value == 0 and choices[2].value == 0 and choices[3].value == 0) {
            return .interesting;
        }
        return .valid;
    }
};

const FiniteFloatReplay = struct {
    fn replay(choices: []const ChoiceNode, _: ?[]const u8, _: *anyopaque) Status {
        if (choices.len == 0) return .valid;
        const value: f64 = @bitCast(choices[0].value);
        return if (std.math.isFinite(value)) .interesting else .valid;
    }
};

const PositiveFloatThresholdReplay = struct {
    fn replay(choices: []const ChoiceNode, _: ?[]const u8, _: *anyopaque) Status {
        if (choices.len == 0) return .valid;
        const value: f64 = @bitCast(choices[0].value);
        return if (std.math.isFinite(value) and value > 5.0) .interesting else .valid;
    }
};

const AbsoluteFloatThresholdReplay = struct {
    fn replay(choices: []const ChoiceNode, _: ?[]const u8, _: *anyopaque) Status {
        if (choices.len == 0) return .valid;
        const value: f64 = @bitCast(choices[0].value);
        return if (std.math.isFinite(value) and @abs(value) > 10.0) .interesting else .valid;
    }
};

test "shrink survives consecutive improving span passes" {
    const allocator = std.testing.allocator;
    const choices = [_]ChoiceNode{
        .{ .kind = .integer, .value = 5, .min = 0, .max = 100, .shrink_towards = 0 },
        .{ .kind = .integer, .value = 7, .min = 0, .max = 100, .shrink_towards = 0 },
        .{ .kind = .integer, .value = 9, .min = 0, .max = 100, .shrink_towards = 0 },
    };
    const spans = [_]Span{
        .{ .label = "outer", .start = 0, .end = 3, .depth = 0 },
        .{ .label = "inner", .start = 1, .end = 3, .depth = 1 },
    };
    var ctx: usize = 0;
    var result = try shrink(
        allocator,
        &choices,
        &spans,
        null,
        &AlwaysInterestingReplay.replay,
        @ptrCast(&ctx),
        200,
    );
    defer result.deinit(allocator);
    try std.testing.expect(result.choices.len <= choices.len);
}

test "shrink frees exact span allocation when nested spans drop" {
    const allocator = std.testing.allocator;
    const choices = [_]ChoiceNode{
        .{ .kind = .integer, .value = 3, .min = 0, .max = 100, .shrink_towards = 0 },
        .{ .kind = .integer, .value = 5, .min = 0, .max = 100, .shrink_towards = 0 },
        .{ .kind = .integer, .value = 7, .min = 0, .max = 100, .shrink_towards = 0 },
        .{ .kind = .integer, .value = 9, .min = 0, .max = 100, .shrink_towards = 0 },
    };
    const spans = [_]Span{
        .{ .label = "outer", .start = 0, .end = 4, .depth = 0 },
        .{ .label = "mid", .start = 1, .end = 3, .depth = 1 },
        .{ .label = "inner", .start = 1, .end = 2, .depth = 2 },
        .{ .label = "tail", .start = 3, .end = 4, .depth = 1 },
    };
    var ctx: usize = 0;
    var result = try shrink(
        allocator,
        &choices,
        &spans,
        null,
        &TwoChoiceReplay.replay,
        @ptrCast(&ctx),
        50,
    );
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.choices.len);
}

test "minimizeIndividual shrinks toward target" {
    const allocator = std.testing.allocator;

    var choices = [_]ChoiceNode{
        .{ .kind = .integer, .value = 50, .min = 0, .max = 100, .shrink_towards = 0 },
    };

    var ctx: usize = 0;
    var remaining: usize = 100;
    const result = try minimizeIndividual(
        allocator,
        &choices,
        null,
        &IndividualThresholdReplay.replay,
        @ptrCast(&ctx),
        &remaining,
    );

    if (result.improved) {
        defer allocator.free(result.choices);
        try std.testing.expectEqual(11, result.choices[0].value);
    }
}

test "minimizeDuplicated shrinks equal integers together" {
    const allocator = std.testing.allocator;

    var choices = [_]ChoiceNode{
        .{ .kind = .integer, .value = 7, .min = 0, .max = 10, .shrink_towards = 0 },
        .{ .kind = .integer, .value = 3, .min = 0, .max = 10, .shrink_towards = 0 },
        .{ .kind = .integer, .value = 7, .min = 0, .max = 10, .shrink_towards = 0 },
        .{ .kind = .integer, .value = 7, .min = 0, .max = 10, .shrink_towards = 0 },
    };

    var ctx: usize = 0;
    var remaining: usize = 10;
    const result = try minimizeDuplicated(
        allocator,
        &choices,
        null,
        &DuplicatedZeroReplay.replay,
        @ptrCast(&ctx),
        &remaining,
    );

    try std.testing.expect(result.improved);
    defer allocator.free(result.choices);
    try std.testing.expectEqual(@as(u64, 0), result.choices[0].value);
    try std.testing.expectEqual(@as(u64, 3), result.choices[1].value);
    try std.testing.expectEqual(@as(u64, 0), result.choices[2].value);
    try std.testing.expectEqual(@as(u64, 0), result.choices[3].value);
}

test "lexLess comparison" {
    const a = [_]ChoiceNode{
        .{ .kind = .integer, .value = 1 },
        .{ .kind = .integer, .value = 2 },
    };
    const b = [_]ChoiceNode{
        .{ .kind = .integer, .value = 2 },
        .{ .kind = .integer, .value = 1 },
    };
    try std.testing.expect(lexLess(&a, &b));
    try std.testing.expect(!lexLess(&b, &a));
}

test "minimizeFloats reaches target via canonical 0.0" {
    const allocator = std.testing.allocator;

    var choices = [_]ChoiceNode{
        .{
            .kind = .float,
            .value = @bitCast(@as(f64, 7.5)),
            .min = @bitCast(@as(f64, -100.0)),
            .max = @bitCast(@as(f64, 100.0)),
            .shrink_towards = @bitCast(@as(f64, 0.0)),
        },
    };

    var ctx: usize = 0;
    var remaining: usize = 100;
    const result = try minimizeFloats(
        allocator,
        &choices,
        null,
        &FiniteFloatReplay.replay,
        @ptrCast(&ctx),
        &remaining,
    );

    try std.testing.expect(result.improved);
    defer allocator.free(result.choices);
    const final: f64 = @bitCast(result.choices[0].value);
    try std.testing.expectEqual(@as(f64, 0.0), final);
}

test "minimizeFloats reaches integer-valued canonical from large value" {
    const allocator = std.testing.allocator;

    var choices = [_]ChoiceNode{
        .{
            .kind = .float,
            .value = @bitCast(@as(f64, 17.3)),
            .min = @bitCast(@as(f64, -1000.0)),
            .max = @bitCast(@as(f64, 1000.0)),
            .shrink_towards = @bitCast(@as(f64, 0.0)),
        },
    };

    var ctx: usize = 0;
    var remaining: usize = 200;
    const result = try minimizeFloats(
        allocator,
        &choices,
        null,
        &PositiveFloatThresholdReplay.replay,
        @ptrCast(&ctx),
        &remaining,
    );

    try std.testing.expect(result.improved);
    defer allocator.free(result.choices);
    const final: f64 = @bitCast(result.choices[0].value);
    try std.testing.expect(final > 5.0);
    try std.testing.expect(final < 17.3);
}

test "minimizeFloats handles NaN by reaching 0.0" {
    const allocator = std.testing.allocator;

    const nan = std.math.nan(f64);
    var choices = [_]ChoiceNode{
        .{
            .kind = .float,
            .value = @bitCast(nan),
            .min = @bitCast(@as(f64, -1.0)),
            .max = @bitCast(@as(f64, 1.0)),
            .shrink_towards = @bitCast(@as(f64, 0.0)),
        },
    };

    var ctx: usize = 0;
    var remaining: usize = 50;
    const result = try minimizeFloats(
        allocator,
        &choices,
        null,
        &AlwaysInterestingReplay.replay,
        @ptrCast(&ctx),
        &remaining,
    );

    try std.testing.expect(result.improved);
    defer allocator.free(result.choices);
    const final: f64 = @bitCast(result.choices[0].value);
    try std.testing.expectEqual(@as(f64, 0.0), final);
}

test "minimizeFloats sign-strips negative finite values" {
    const allocator = std.testing.allocator;

    var choices = [_]ChoiceNode{
        .{
            .kind = .float,
            .value = @bitCast(@as(f64, -17.5)),
            .min = @bitCast(@as(f64, -1000.0)),
            .max = @bitCast(@as(f64, 1000.0)),
            .shrink_towards = @bitCast(@as(f64, 0.0)),
        },
    };

    var ctx: usize = 0;
    var remaining: usize = 200;
    const result = try minimizeFloats(
        allocator,
        &choices,
        null,
        &AbsoluteFloatThresholdReplay.replay,
        @ptrCast(&ctx),
        &remaining,
    );

    try std.testing.expect(result.improved);
    defer allocator.free(result.choices);
    const final: f64 = @bitCast(result.choices[0].value);
    try std.testing.expect(!std.math.signbit(final));
    try std.testing.expect(@abs(final) > 10.0);
}
