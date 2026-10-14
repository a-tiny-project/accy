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
