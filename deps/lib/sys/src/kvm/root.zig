const sys = @import("../root.zig");
const linux = @import("linux.zig");
const run_exit = @import("exit.zig");
const system = @import("system.zig");
const types = @import("types.zig");
const vcpu = @import("vcpu.zig");
const vm = @import("vm.zig");

pub const abi = @import("abi.zig");
pub const state = @import("state.zig");

pub const required_capabilities = sys.capabilities.noLibc(&.{
    .descriptors,
    .memory_mapping,
    .virtualization,
});

pub const supported = linux.supported;
pub const Availability = types.Availability;
pub const CapabilityReceipt = types.CapabilityReceipt;
pub const CapabilityStage = types.CapabilityStage;
pub const Extensions = types.Extensions;
pub const MemoryRegion = types.MemoryRegion;
pub const MapResult = types.MapResult;
pub const OpenAttempt = system.OpenAttempt;
pub const Operations = types.Operations;
pub const System = system.System;
pub const Vm = vm.Vm;
pub const Vcpu = vcpu.Vcpu;
pub const RunControls = vcpu.RunControls;
pub const RunStatus = vcpu.RunStatus;
pub const RawResult = types.RawResult;
pub const CreateError = types.CreateError;
pub const MemoryError = types.MemoryError;
pub const RunError = types.RunError;
pub const StateError = types.StateError;

pub const DecodeError = run_exit.DecodeError;
pub const Direction = run_exit.Direction;
pub const Exit = run_exit.Exit;
pub const ExitReason = run_exit.Reason;
pub const SystemEventKind = run_exit.SystemEventKind;

pub const decode = run_exit.decode;
pub const acquire = system.acquire;
pub const open = system.open;
pub const operationsFor = types.operationsFor;
pub const probe = system.probe;
pub const supported_cpuid_entries_max = system.supported_cpuid_entries_max;
