import ctypes
import errno
import functools
import json
import os
import select
import signal
import subprocess
import sys
import time


def contract(text):
    if not text.isascii() or not text.isdecimal() or len(text) > 20:
        raise ValueError("missing-or-invalid-build-budget")
    ceiling = int(text)
    if not 0 < ceiling < 2**64:
        raise ValueError("invalid-build-budget")
    return ceiling


def receipt(phase, argv, ceiling, reason, **observed):
    print(
        json.dumps(
            dict(
                schema="tiny.loom.darwin-memory/v2",
                phase=phase,
                argv=argv,
                ceiling_bytes=ceiling,
                reason=reason,
                **observed,
            ),
            separators=(",", ":"),
        ),
        file=sys.stderr,
        flush=True,
    )


class BsdInfo(ctypes.Structure):
    _fields_ = [
        ("flags", ctypes.c_uint32),
        ("status", ctypes.c_uint32),
        ("exit_status", ctypes.c_uint32),
        ("pid", ctypes.c_uint32),
        ("parent_pid", ctypes.c_uint32),
        ("credentials", ctypes.c_uint32 * 7),
        ("command", ctypes.c_char * 16),
        ("name", ctypes.c_char * 32),
        ("file_count", ctypes.c_uint32),
        ("process_group", ctypes.c_uint32),
        ("terminal", ctypes.c_uint32 * 4),
        ("start", ctypes.c_uint64 * 2),
    ]


class TaskInfo(ctypes.Structure):
    _fields_ = [
        ("virtual_size", ctypes.c_uint64),
        ("resident_size", ctypes.c_uint64),
        ("times", ctypes.c_uint64 * 4),
        ("counts", ctypes.c_int32 * 12),
    ]


class Processes:
    capacity = 4096

    def __init__(self):
        self.library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        for name in ("proc_listchildpids", "proc_listpgrppids"):
            function = getattr(self.library, name)
            function.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
            function.restype = ctypes.c_int
        self.library.proc_pidinfo.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_uint64,
            ctypes.c_void_p,
            ctypes.c_int,
        ]
        self.library.proc_pidinfo.restype = ctypes.c_int

    def pids(self, function, pid):
        buffer = (ctypes.c_int * (self.capacity + 1))()
        ctypes.set_errno(0)
        count = function(pid, buffer, ctypes.sizeof(buffer))
        fault = ctypes.get_errno()
        if count < 0 or (count == 0 and fault):
            if fault == errno.ESRCH:
                return []
            raise OSError(fault, "resident-census-unavailable")
        if count >= len(buffer):
            raise RuntimeError("resident-census-capacity")
        return [value for value in buffer[:count] if value > 0]

    def info(self, pid, flavor, structure):
        value = structure()
        ctypes.set_errno(0)
        count = self.library.proc_pidinfo(
            pid, flavor, 0, ctypes.byref(value), ctypes.sizeof(value)
        )
        if count == 0 and ctypes.get_errno() == errno.ESRCH:
            return None
        if count != ctypes.sizeof(value):
            raise OSError(ctypes.get_errno(), "resident-process-unavailable")
        return value

    def group(self, group):
        return self.pids(self.library.proc_listpgrppids, group)

    def live(self, pid):
        value = self.info(pid, 3, BsdInfo)
        return value is not None and value.status != 5


@functools.cache
def processes():
    return Processes()


def resident(group):
    observer = processes()
    pending = [group, *observer.group(group)]
    seen = set()
    total = largest_bytes = 0
    largest = group
    owned = []
    while pending:
        pid = pending.pop()
        if pid in seen:
            continue
        if len(seen) >= observer.capacity:
            raise RuntimeError("resident-census-capacity")
        seen.add(pid)
        if not observer.live(pid):
            continue
        owned.append(pid)
        pending.extend(observer.pids(observer.library.proc_listchildpids, pid))
        task = observer.info(pid, 4, TaskInfo)
        if task is None:
            continue
        total += task.resident_size
        if task.resident_size > largest_bytes:
            largest, largest_bytes = pid, task.resident_size
    return total, largest, owned


def signal_group(group, requested):
    try:
        os.killpg(group, requested)
    except ProcessLookupError:
        pass
    except PermissionError:
        observer = processes()
        if any(observer.live(pid) for pid in observer.group(group)):
            raise


def interrupt(group, owned=()):
    if os.getpgrp() != group:
        signal_group(group, signal.SIGSTOP)
    for pid in owned:
        if pid == group:
            continue
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    signal_group(group, signal.SIGKILL)


def run(phase, argv, text):
    try:
        ceiling = contract(text)
    except ValueError as fault:
        receipt(phase, argv, 0, str(fault), admitted=False)
        return 75
    if not hasattr(os, "waitid") or not hasattr(os, "WNOWAIT"):
        receipt(phase, argv, ceiling, "process-observation-unavailable")
        return 75
    receipt(phase, argv, ceiling, "admitted")

    child = None
    owned = ()
    lifeline_read, lifeline_write = os.pipe()
    try:
        child = subprocess.Popen(
            [
                sys.executable,
                os.path.abspath(__file__),
                "--child",
                str(lifeline_read),
                *argv,
            ],
            start_new_session=True,
            pass_fds=(lifeline_read,),
        )
        os.close(lifeline_read)
        lifeline_read = None
        witnessed = time.monotonic()
        peak = 0
        while True:
            rss, largest, owned = resident(child.pid)
            peak = max(peak, rss)
            if rss > ceiling:
                interrupt(child.pid, owned)
                child.wait(timeout=5)
                receipt(
                    phase,
                    argv,
                    ceiling,
                    "ceiling-exceeded",
                    resident_bytes=rss,
                    peak_resident_bytes=peak,
                    process=largest,
                )
                return 75
            exited = os.waitid(
                os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT
            )
            if exited is not None:
                interrupt(child.pid, owned)
                status = child.wait(timeout=5)
                receipt(
                    phase,
                    argv,
                    ceiling,
                    "exited",
                    exit_status=status,
                    peak_resident_bytes=peak,
                )
                return status if status >= 0 else 128 - status
            now = time.monotonic()
            if now - witnessed >= 30:
                receipt(phase, argv, ceiling, "running", resident_bytes=rss)
                witnessed = now
            time.sleep(0.25)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as fault:
        receipt(phase, argv, ceiling, "supervision-failed", fault=str(fault))
        return 75
    finally:
        os.close(lifeline_write)
        if lifeline_read is not None:
            os.close(lifeline_read)
        if child is not None and child.returncode is None:
            interrupt(child.pid, owned)
            child.wait(timeout=5)


def supervised_child(lifeline, argv):
    child = subprocess.Popen(argv)
    while True:
        status = child.poll()
        if status is not None:
            return status if status >= 0 else 128 - status
        ready, _, _ = select.select([lifeline], [], [], 0.25)
        if ready and not os.read(lifeline, 1):
            try:
                _, _, owned = resident(os.getpgrp())
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
                owned = ()
            interrupt(os.getpgrp(), owned)
            return 75


def self_test():
    import contextlib
    import io
    import tempfile
    import unittest

    class MemoryTests(unittest.TestCase):
        def test_build_budget_is_a_positive_bounded_byte_count(self):
            for text in ("", "0", "-1", "1.0", "²", str(2**64)):
                with self.assertRaises(ValueError):
                    contract(text)
            self.assertEqual(6144 * 1024 * 1024, contract("6442450944"))

        def test_invalid_budget_never_starts_child(self):
            with tempfile.TemporaryDirectory() as directory:
                marker = os.path.join(directory, "started")
                output = io.StringIO()
                with contextlib.redirect_stderr(output):
                    status = run("maker-check", ["/usr/bin/touch", marker], "0")
                self.assertEqual(75, status)
                self.assertFalse(os.path.exists(marker))
                self.assertEqual("maker-check", json.loads(output.getvalue())["phase"])

        def test_resident_ceiling_interrupts_process_group(self):
            output = io.StringIO()
            with contextlib.redirect_stderr(output):
                status = run(
                    "generation-check",
                    [
                        sys.executable,
                        "-c",
                        "import time; data=bytearray(64*1024*1024); time.sleep(10)",
                    ],
                    str(32 * 1024 * 1024),
                )
            self.assertEqual(75, status)
            final = json.loads(output.getvalue().splitlines()[-1])
            self.assertEqual("ceiling-exceeded", final["reason"])
            self.assertEqual("generation-check", final["phase"])
            self.assertEqual(32 * 1024 * 1024, final["ceiling_bytes"])

        def test_resident_ceiling_includes_nested_process_groups(self):
            output = io.StringIO()
            program = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c','import time; data=bytearray(128*1024*1024); time.sleep(10)'],start_new_session=True); time.sleep(10)"
            with contextlib.redirect_stderr(output):
                status = run(
                    "nested-build",
                    [sys.executable, "-c", program],
                    str(64 * 1024 * 1024),
                )
            self.assertEqual(75, status)
            final = json.loads(output.getvalue().splitlines()[-1])
            self.assertEqual("ceiling-exceeded", final["reason"])
            self.assertGreater(final["peak_resident_bytes"], final["ceiling_bytes"])
            self.assertGreater(final["process"], 1)

        def test_watchdog_exit_interrupts_the_workload(self):
            with tempfile.TemporaryDirectory() as directory:
                ready = os.path.join(directory, "ready")
                escaped = os.path.join(directory, "escaped")
                program = (
                    "import os,pathlib,time; pathlib.Path(%r).write_text(str(os.getppid())); time.sleep(2); pathlib.Path(%r).touch()"
                    % (ready, escaped)
                )
                with subprocess.Popen(
                    [
                        sys.executable,
                        os.path.abspath(__file__),
                        str(64 * 1024 * 1024),
                        "maker-check",
                        sys.executable,
                        "-c",
                        program,
                    ],
                    stderr=subprocess.DEVNULL,
                ) as watchdog:
                    deadline = time.monotonic() + 5
                    while not os.path.exists(ready) and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(os.path.exists(ready))
                    watchdog.kill()
                    watchdog.wait(timeout=5)
                time.sleep(2.1)
                self.assertFalse(os.path.exists(escaped))
                with open(ready) as recorded:
                    supervisor = int(recorded.read())
                self.assertFalse(processes().live(supervisor))

        def test_native_layout_and_workload_scope(self):
            self.assertEqual(136, ctypes.sizeof(BsdInfo))
            self.assertEqual(96, ctypes.sizeof(TaskInfo))
            argv = [sys.executable, "-c", "import time; time.sleep(10)"]
            with (
                subprocess.Popen(argv, start_new_session=True) as workload,
                subprocess.Popen(argv, start_new_session=True) as unrelated,
            ):
                try:
                    rss, _, owned = resident(workload.pid)
                    self.assertGreater(rss, 0)
                    self.assertIn(workload.pid, owned)
                    self.assertNotIn(unrelated.pid, owned)
                    self.assertNotIn(os.getpid(), owned)
                finally:
                    workload.kill()
                    unrelated.kill()

        def test_success_has_terminal_receipt(self):
            output = io.StringIO()
            with contextlib.redirect_stderr(output):
                status = run(
                    "maker-check",
                    [sys.executable, "-c", "pass"],
                    str(64 * 1024 * 1024),
                )
            self.assertEqual(0, status)
            self.assertEqual(
                0, json.loads(output.getvalue().splitlines()[-1])["exit_status"]
            )

    result = unittest.TextTestRunner().run(
        unittest.defaultTestLoader.loadTestsFromTestCase(MemoryTests)
    )
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    if len(sys.argv) > 3 and sys.argv[1] == "--child":
        sys.exit(supervised_child(int(sys.argv[2]), sys.argv[3:]))
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    if len(sys.argv) < 4:
        sys.exit("expected memory budget in bytes, phase and workload argv")
    sys.exit(run(sys.argv[2], sys.argv[3:], sys.argv[1]))
