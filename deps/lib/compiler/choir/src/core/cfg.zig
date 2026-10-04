pub fn contains(source: anytype, target: anytype) bool {
    return containsExcluding(source, target, null);
}

pub fn containsOther(source: anytype, target: anytype, excluded: anytype) bool {
    return containsExcluding(source, target, @ptrCast(excluded));
}

pub fn containsBounded(
    source: anytype,
    target: anytype,
    operation_limit: usize,
) error{OperationListCorrupted}!bool {
    var operations = source.getOperations();
    var count: usize = 0;
    while (operations.next()) |operation| {
        count += 1;
        if (count > operation_limit) return error.OperationListCorrupted;
        for (operation.successors.items) |successor| {
            if (successor == target) return true;
        }
    }
    return false;
}

fn containsExcluding(
    source: anytype,
    target: anytype,
    excluded: ?*const anyopaque,
) bool {
    var operations = source.getOperations();
    while (operations.next()) |operation| {
        const operation_ptr: *const anyopaque = @ptrCast(operation);
        if (excluded != null and excluded.? == operation_ptr) continue;
        for (operation.successors.items) |successor| {
            if (successor == target) return true;
        }
    }
    return false;
}

pub fn prepare(source: anytype, successors: anytype) !void {
    for (successors, 0..) |successor, index| {
        if (appearedBefore(successors, index, successor)) continue;
        if (successor.hasPredecessor(source)) continue;
        try successor.predecessors.ensureUnusedCapacity(successor.allocator, 1);
    }
}

pub fn attachAssumeCapacity(source: anytype, successors: anytype) void {
    for (successors) |successor| {
        if (successor.hasPredecessor(source)) continue;
        successor.predecessors.appendAssumeCapacity(source);
    }
}

pub fn attach(source: anytype, operation: anytype) !void {
    try prepare(source, operation.successors.items);
    attachAssumeCapacity(source, operation.successors.items);
}

pub fn detach(source: anytype, operation: anytype) void {
    for (operation.successors.items) |successor| {
        if (containsOther(source, successor, operation)) continue;
        removePredecessor(successor, source);
    }
}

pub fn detachReplaced(source: anytype, operation: anytype, successors: anytype) void {
    for (operation.successors.items) |successor| {
        if (containsTarget(successors, successor)) continue;
        if (containsOther(source, successor, operation)) continue;
        removePredecessor(successor, source);
    }
}

fn appearedBefore(successors: anytype, index: usize, expected: anytype) bool {
    for (successors[0..index]) |successor| {
        if (successor == expected) return true;
    }
    return false;
}

fn containsTarget(successors: anytype, expected: anytype) bool {
    for (successors) |successor| {
        if (successor == expected) return true;
    }
    return false;
}

fn removePredecessor(target: anytype, source: anytype) void {
    var index: usize = 0;
    while (index < target.predecessors.items.len) {
        if (target.predecessors.items[index] != source) {
            index += 1;
            continue;
        }
        _ = target.predecessors.swapRemove(index);
    }
}
