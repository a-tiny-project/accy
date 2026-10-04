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
