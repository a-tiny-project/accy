//! The C runtime that an artifact built without libc must not reach, as
//! plain data. A name matches after its symbol version, from the first `@`
//! on, is cut away.

/// Libraries a needed entry must not name, by prefix: libc, libm and the
/// vector math library it loads, and the dynamic loader.
pub const libraries = [_][]const u8{ "libc.so", "libm.so", "libmvec.so", "ld-linux" };

/// Names of the C runtime's own entry points: errno, allocation, dynamic
/// loading, time, randomness, memory mapping, descriptors, sockets,
/// processes, signals, timers and the math a compiler may call.
pub const runtime_symbols = [_][]const u8{
    "__errno_location", "__errno",       "___errno",      "__error",        "_errno",
    "_errnop",          "errno",         "getauxval",     "malloc",         "free",
    "calloc",           "realloc",       "aligned_alloc", "posix_memalign", "dlopen",
    "dlsym",            "dlclose",       "dlerror",       "clock_gettime",  "nanosleep",
    "getrandom",        "mmap",          "munmap",        "mprotect",       "madvise",
    "close",            "read",          "write",         "pipe",           "pipe2",
    "fcntl",            "socket",        "socketpair",    "connect",        "bind",
    "listen",           "accept",        "accept4",       "send",           "sendto",
    "sendmsg",          "recv",          "recvfrom",      "recvmsg",        "setsockopt",
    "getsockname",      "shutdown",      "poll",          "getpid",         "getppid",
    "gettid",           "getuid",        "getgid",        "geteuid",        "getegid",
    "kill",             "raise",         "sigaction",     "sigaltstack",    "sigprocmask",
    "timer_create",     "timer_settime", "timer_delete",  "exp",            "log",
    "pow",              "sin",           "cos",
};

/// Prefixes that mark the rest of the C runtime: its internals and threads.
pub const runtime_prefixes = [_][]const u8{ "__libc_", "pthread_" };
