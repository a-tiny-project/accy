const std = @import("std");
const sys = @import("sys");

pub const WaitWord = std.atomic.Value(u32);

pub fn nanoSleep(nanoseconds: u64) bool {
    if (!sys.time.supportsAwakeClock()) return false;
    sys.time.sleepNanoseconds(nanoseconds);
    return true;
}

pub fn blockUntilDifferent(
    previous: u32,
    word: *const WaitWord,
) u32 {
    return sys.thread.blockUntilDifferent(previous, word);
}

pub fn wakeAll(word: *WaitWord) void {
    sys.thread.wakeAll(word);
}

const WakeContext = struct {
    word: *WaitWord,
    observed: *u32,

    fn wait(self: WakeContext) void {
        self.observed.* = blockUntilDifferent(7, self.word);
    }
};

test "Highway wait word blocks until storage changes and wakes" {
    if (!sys.thread.threadsSupported()) return error.SkipZigTest;
    var word = WaitWord.init(7);
    var observed: u32 = 0;
    const handle = try sys.thread.spawn(WakeContext.wait, .{
        WakeContext{ .word = &word, .observed = &observed },
    });
    _ = nanoSleep(std.time.ns_per_ms);
    word.store(11, .release);
    wakeAll(&word);
    handle.join();
    try std.testing.expectEqual(@as(u32, 11), observed);
    try std.testing.expectEqual(@as(u32, 11), blockUntilDifferent(7, &word));
}
