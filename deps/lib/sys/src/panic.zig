const capabilities = @import("capabilities.zig");

pub const required_capabilities = capabilities.pure();

pub const no_libc = struct {
    pub fn call(msg: []const u8, ra: ?usize) noreturn {
        _ = msg;
        _ = ra;
        @trap();
    }

    pub fn sentinelMismatch(expected: anytype, found: @TypeOf(expected)) noreturn {
        _ = found;
        call("", null);
    }

    pub fn unwrapError(err: anyerror) noreturn {
        _ = @errorName(err);
        call("", null);
    }

    pub fn outOfBounds(index: usize, len: usize) noreturn {
        _ = index;
        _ = len;
        call("", null);
    }

    pub fn startGreaterThanEnd(start: usize, end: usize) noreturn {
        _ = start;
        _ = end;
        call("", null);
    }

    pub fn inactiveUnionField(active: anytype, accessed: @TypeOf(active)) noreturn {
        _ = accessed;
        call("", null);
    }

    pub fn sliceCastLenRemainder(src_len: usize) noreturn {
        _ = src_len;
        call("", null);
    }

    pub fn reachedUnreachable() noreturn {
        call("", null);
    }

    pub fn unwrapNull() noreturn {
        call("", null);
    }

    pub fn castToNull() noreturn {
        call("", null);
    }

    pub fn incorrectAlignment() noreturn {
        call("", null);
    }

    pub fn invalidErrorCode() noreturn {
        call("", null);
    }

    pub fn integerOutOfBounds() noreturn {
        call("", null);
    }

    pub fn integerOverflow() noreturn {
        call("", null);
    }

    pub fn shlOverflow() noreturn {
        call("", null);
    }

    pub fn shrOverflow() noreturn {
        call("", null);
    }

    pub fn divideByZero() noreturn {
        call("", null);
    }

    pub fn exactDivisionRemainder() noreturn {
        call("", null);
    }

    pub fn integerPartOutOfBounds() noreturn {
        call("", null);
    }

    pub fn corruptSwitch() noreturn {
        call("", null);
    }

    pub fn shiftRhsTooBig() noreturn {
        call("", null);
    }

    pub fn invalidEnumValue() noreturn {
        call("", null);
    }

    pub fn forLenMismatch() noreturn {
        call("", null);
    }

    pub fn copyLenMismatch() noreturn {
        call("", null);
    }

    pub fn memcpyAlias() noreturn {
        call("", null);
    }

    pub fn noreturnReturned() noreturn {
        call("", null);
    }
};
