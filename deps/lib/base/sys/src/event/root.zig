const sys = @import("../root.zig");
const types = @import("types.zig");
const backend = @import("poll.zig");

pub const required_capabilities = sys.capabilities.host(&.{ .descriptors, .event_loop, .networking, .time });

pub const AcceptError = types.AcceptError;
pub const CallbackAction = types.CallbackAction;
pub const CloseError = types.CloseError;
pub const Datagram = types.Datagram;
pub const Options = types.Options;
pub const PollError = types.PollError;
pub const PollEvent = types.PollEvent;
pub const ReadBuffer = types.ReadBuffer;
pub const ReadError = types.ReadError;
pub const RecvError = types.RecvError;
pub const RunMode = types.RunMode;
pub const SendError = types.SendError;
pub const WriteBuffer = types.WriteBuffer;
pub const WriteError = types.WriteError;

pub const Async = backend.Async;
pub const Completion = backend.Completion;
pub const File = backend.File;
pub const Loop = backend.Loop;
pub const TCP = backend.TCP;
pub const Timer = backend.Timer;
pub const UDP = backend.UDP;
