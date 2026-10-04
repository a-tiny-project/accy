const std = @import("std");
const lifecycle = @import("lifecycle.zig");
const memory = @import("memory.zig");
const core = @import("../root.zig");
const resources = @import("resources.zig");

pub const DialectLoaderFn = core.dialects.DialectLoaderFn;
pub const DialectExtensionFn = core.dialects.DialectExtensionFn;
pub const DialectRegistryEntry = core.dialects.DialectRegistryEntry;
pub const DialectRegistrySpec = core.dialects.DialectRegistrySpec;
pub const DialectLoadState = core.dialects.DialectLoadState;
pub const OpInterfaceFallbackFn = core.dialects.OpInterfaceFallbackFn;
pub const OpInterfaceFallbackEntry = core.dialects.OpInterfaceFallbackEntry;
pub const TypeInterfaceFallbackFn = core.dialects.TypeInterfaceFallbackFn;
pub const TypeInterfaceFallbackEntry = core.dialects.TypeInterfaceFallbackEntry;
pub const Dialect = core.dialects.Dialect;
pub const TypeStorage = core.types.TypeStorage;
pub const AttrStorage = core.attrs.AttrStorage;
pub const DialectAttrKey = core.attrs.DialectAttrKey;
pub const IntegerAttrKey = core.attrs.IntegerAttrKey;
pub const FloatAttrKey = core.attrs.FloatAttrKey;
pub const StringAttrKey = core.attrs.StringAttrKey;
pub const SymbolRefAttrKey = core.attrs.SymbolRefAttrKey;
pub const StringListAttrKey = core.attrs.StringListAttrKey;
pub const TypeInterner = core.types.TypeInterner;
pub const AttributeInterner = core.attrs.AttributeInterner;
pub const DialectRegistry = core.dialects.DialectRegistry;
pub const ResourceTracker = resources.Tracker;
pub const ThreadingExecutionGuard = core.ThreadingExecutionGuard;
pub const Context = lifecycle.Context;

pub fn configurationTableAllocator(context: *Context) std.mem.Allocator {
    return memory.configurationTableAllocator(context.memory);
}

pub fn configurationNameAllocator(context: *Context) std.mem.Allocator {
    return memory.configurationNameAllocator(context.memory);
}

pub fn configurationInterfaceAllocator(context: *Context) std.mem.Allocator {
    return memory.configurationInterfaceAllocator(context.memory);
}

pub fn configurationTransactionAllocator(context: *Context) std.mem.Allocator {
    return memory.configurationTransactionAllocator(context.memory);
}

pub fn initRegion(context: *Context) core.Region {
    return core.Region.init(memory.operationNestedAllocator(context.memory));
}

pub fn transientAllocator(context: *Context) std.mem.Allocator {
    return memory.transientAllocator(context.memory);
}

pub fn operationAllocator(context: *Context) std.mem.Allocator {
    return memory.operationNestedAllocator(context.memory);
}

pub fn fixedOperationAllocator(context: *Context) std.mem.Allocator {
    return lifecycle.operationStorageAllocator(context).allocator();
}

pub fn typeTableAllocator(context: *Context) std.mem.Allocator {
    return memory.typeTableAllocator(context.memory);
}

pub fn typeKeyAllocator(context: *Context) std.mem.Allocator {
    return memory.typeKeyAllocator(context.memory);
}

pub fn typePayloadAllocator(context: *Context) std.mem.Allocator {
    return memory.typePayloadAllocator(context.memory);
}

pub fn attributeTableAllocator(context: *Context) std.mem.Allocator {
    return memory.attributeTableAllocator(context.memory);
}

pub fn attributePayloadAllocator(context: *Context) std.mem.Allocator {
    return memory.attributePayloadAllocator(context.memory);
}

pub fn diagnosticHandlerAllocator(context: *Context) std.mem.Allocator {
    return memory.diagnosticHandlerAllocator(context.memory);
}

pub fn diagnosticPayloadAllocator(context: *Context) std.mem.Allocator {
    return memory.diagnosticPayloadAllocator(context.memory);
}
