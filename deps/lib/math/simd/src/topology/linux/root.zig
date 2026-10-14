const owner = @import("owner.zig");

pub const totalLogicalProcessors = owner.totalLogicalProcessors;
pub const fillRecords = owner.fillRecords;
pub const fillClusterCacheSizes = owner.fillClusterCacheSizes;
pub const getThreadAffinity = owner.getThreadAffinity;
pub const setThreadAffinity = owner.setThreadAffinity;
pub const dataCaches = owner.dataCaches;
