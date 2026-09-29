//! The package instruments a running program, writes what it observes as a
//! trace, and analyzes those traces afterwards. A caller wants timing from
//! inside a running program, including from a program that must keep running
//! long past the point where a full trace would be too large to keep.
//!
//! A call opens a named region of a thread's execution, closed by the returned
//! value's `end`, as a *zone*. Another call ends one frame of a repeating
//! workload as a *frame mark*. A call samples a named numeric series over time
//! as a *plot*, with further calls reporting locks, GPU spans, fibers, context
//! switches, memory operations, and messages. With `build_options.enabled` set
//! to false, each of those calls answers immediately with an empty value, so a
//! build that leaves the call sites in place carries no tracing work.
//!
//! An active runtime writes its events to a `std.Io.Writer` the caller passes
//! to `start`, and this sequence of events is the *trace stream*. A ring buffer
//! standing in for that writer is a *flight recorder*: it takes fixed caller
//! buffers, keeps the most recent events, and writes the retained ones out on
//! demand when asked for a snapshot. The *overflow policy* decides what a full
//! recorder does with a new event, either overwrite the oldest event or stop
//! accepting. A snapshot answers with a report counting the events observed,
//! stored, retained, overwritten, dropped, and oversized. A caller halts the
//! runtime with `stop` before taking a snapshot or resetting a recorder, which
//! leaves the ring holding whole events.
//!
//! The analyzer reads a captured stream and reports summaries, frames against a
//! budget, flame graphs, and comparisons between two captures.

const build_options = @import("build_options");
const allocator_mod = @import("allocator.zig");
const capture_mod = @import("capture.zig");
const event_mod = @import("event.zig");
const flight_mod = @import("flight.zig");
const frame_mod = @import("frame.zig");
const instrumentation = @import("instrumentation.zig");
const runtime = @import("runtime.zig");
const transport_mod = @import("transport.zig");

pub const TracedAllocator = allocator_mod.TracedAllocator;
pub const cli = @import("cli/root.zig");
pub const compare = @import("compare.zig");
pub const capture = capture_mod;
pub const context = @import("context.zig");
pub const csv = @import("csv.zig");
pub const event = event_mod;
pub const File = @import("file.zig").File;
pub const flight = flight_mod;
pub const fibers = @import("fiber.zig");
pub const find = @import("find.zig");
pub const flame = @import("flame.zig");
pub const frame = frame_mod;
pub const gpu = @import("gpu.zig");
pub const locks = @import("lock.zig");
pub const memory = @import("memory.zig");
pub const messages = @import("message.zig");
pub const plots = @import("plot.zig");
pub const record = @import("record.zig");
pub const report = @import("report.zig");
pub const samples = @import("sample.zig");
pub const source = @import("source.zig");
pub const stats = @import("stats.zig");
pub const summary = @import("summary.zig");
pub const system = @import("system.zig");
pub const timeline = @import("timeline.zig");
pub const tree = @import("tree.zig");
pub const transport = transport_mod;

pub const enabled = build_options.enabled;
pub const FlightOverflowPolicy = transport_mod.OverflowPolicy;
pub const FlightRecorder = flight_mod.FlightRecorder;
pub const FlightReport = transport_mod.Report;
pub const ContextSwitchOptions = runtime.ContextSwitchOptions;
pub const Fiber = runtime.Fiber;
pub const GpuContext = runtime.GpuContext;
pub const GpuContextOptions = runtime.GpuContextOptions;
pub const GpuContextType = runtime.GpuContextType;
pub const GpuZone = runtime.GpuZone;
pub const CpuTopology = runtime.CpuTopology;
pub const HardwareSampleKind = runtime.HardwareSampleKind;
pub const Lock = runtime.Lock;
pub const PlotConfig = runtime.PlotConfig;
pub const PlotUnit = runtime.PlotUnit;
pub const SampleFrame = runtime.SampleFrame;
pub const SampleKind = runtime.SampleKind;
pub const StartOptions = runtime.StartOptions;
pub const ThreadWakeupOptions = runtime.ThreadWakeupOptions;
pub const Zone = runtime.Zone;

pub const start = instrumentation.start;
pub const stop = instrumentation.stop;
pub const tracedAllocator = instrumentation.tracedAllocator;
pub const namedAllocator = instrumentation.namedAllocator;
pub const zone = instrumentation.zone;
pub const zoneAt = instrumentation.zoneAt;
pub const zoneColor = instrumentation.zoneColor;
pub const zoneColorAt = instrumentation.zoneColorAt;
pub const lockable = instrumentation.lockable;
pub const lockableAt = instrumentation.lockableAt;
pub const sharedLockable = instrumentation.sharedLockable;
pub const sharedLockableAt = instrumentation.sharedLockableAt;
pub const frameMark = instrumentation.frameMark;
pub const frameMarkNamed = instrumentation.frameMarkNamed;
pub const sample = instrumentation.sample;
pub const sampleKind = instrumentation.sampleKind;
pub const sampleWeighted = instrumentation.sampleWeighted;
pub const sampleStack = instrumentation.sampleStack;
pub const sampleStackWeighted = instrumentation.sampleStackWeighted;
pub const newFiber = instrumentation.newFiber;
pub const newFiberHint = instrumentation.newFiberHint;
pub const newFiberNamed = instrumentation.newFiberNamed;
pub const newFiberNamedHint = instrumentation.newFiberNamedHint;
pub const gpuContext = instrumentation.gpuContext;
pub const contextSwitch = instrumentation.contextSwitch;
pub const threadWakeup = instrumentation.threadWakeup;
pub const threadContext = instrumentation.threadContext;
pub const threadPid = instrumentation.threadPid;
pub const cpuTopology = instrumentation.cpuTopology;
pub const systemTime = instrumentation.systemTime;
pub const systemPower = instrumentation.systemPower;
pub const hardwareSample = instrumentation.hardwareSample;
pub const message = instrumentation.message;
pub const appInfo = instrumentation.appInfo;
pub const plotConfig = instrumentation.plotConfig;
pub const plot = instrumentation.plot;
pub const plotFloat = instrumentation.plotFloat;
pub const plotInt = instrumentation.plotInt;
pub const alloc = instrumentation.alloc;
pub const allocNamed = instrumentation.allocNamed;
pub const free = instrumentation.free;
pub const freeNamed = instrumentation.freeNamed;
pub const freeSized = instrumentation.freeSized;
pub const freeSizedNamed = instrumentation.freeSizedNamed;
pub const setThreadName = instrumentation.setThreadName;
pub const isConnected = instrumentation.isConnected;
