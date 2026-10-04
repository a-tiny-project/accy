const std = @import("std");

pub const Operation = enum(u8) {
    map,
    unmap,
    protect,
    discard,
    decommit,
    advise,
};

pub const Source = enum(u8) {
    anonymous,
    reserve,
    anonymous_fixed,
    private_file,
    shared_file,
    private_file_fixed,
    unmap,
    protect,
    discard,
    decommit,
    huge_pages,
    small_pages,
};

pub const Event = struct {
    operation: Operation,
    source: Source,
    address: usize,
    len: usize,
    return_address: usize,
    succeeded: bool,
};

const Channel = @import("alloc_observe_channel").Channel(Event);

pub const Sink = Channel.Sink;
pub const Session = Channel.Session;
pub const Suppression = Channel.Suppression;
pub const install = Channel.install;
pub const suppress = Channel.suppress;
pub const record = Channel.record;

test "physical memory observer records owner operations" {
    const Recorder = struct {
        event: ?Event = null,

        fn sink(self: *@This()) Sink {
            return .{
                .context = self,
                .record = accept,
            };
        }

        fn accept(context: *anyopaque, event: Event) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.event = event;
            record(event);
        }
    };
    var recorder = Recorder{};
    var sink = recorder.sink();
    var session = try install(&sink);
    defer session.deinit();
    const expected = Event{
        .operation = .map,
        .source = .anonymous,
        .address = 0x1000,
        .len = 4096,
        .return_address = 0x2000,
        .succeeded = true,
    };
    record(expected);
    try std.testing.expectEqual(expected, recorder.event.?);
}
