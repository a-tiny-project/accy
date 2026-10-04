const builtin = @import("builtin");
const sys = @import("../root.zig");

const impl = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    else => @import("none.zig"),
};

pub const required_capabilities = sys.capabilities.noLibc(&.{ .libc_interop, .threads });

pub const supported = impl.supported;
pub const alignment = impl.alignment;
pub const signature = impl.signature;
pub const cpu_id_uninitialized = impl.cpu_id_uninitialized;
pub const cpu_id_registration_failed = impl.cpu_id_registration_failed;
pub const Flags = impl.Flags;
pub const CriticalSectionFlags = impl.CriticalSectionFlags;
pub const CriticalSection = impl.CriticalSection;
pub const Area = impl.Area;
pub const RegistrationState = impl.RegistrationState;
pub const RegistrationPolicy = impl.RegistrationPolicy;
pub const RegisterError = impl.RegisterError;

pub const registrationPolicy = impl.registrationPolicy;
pub const currentState = impl.currentState;
pub const registered = impl.registered;
pub const ensureRegistered = impl.ensureRegistered;
pub const currentArea = impl.currentArea;
pub const currentCpu = impl.currentCpu;
pub const currentNode = impl.currentNode;
pub const currentMemoryMapConcurrencyId = impl.currentMemoryMapConcurrencyId;
pub const setCriticalSection = impl.setCriticalSection;
pub const clearCriticalSection = impl.clearCriticalSection;
pub const validCpuId = impl.validCpuId;
