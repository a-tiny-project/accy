//! One sink channel per event type: a single sink installed by
//! compare-and-swap, an in-flight delivery count that uninstall drains, and a
//! per-thread callback depth that keeps a sink from observing its own work.
//! `alloc_observe` builds its allocation protocol on a channel, and `sys`
//! instantiates one for memory-mapping events.

pub const Channel = @import("channel.zig").Channel;
