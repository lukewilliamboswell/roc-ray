"""Temporary diagnostic: report native overflow frames in a child compiler."""

import ctypes
from ctypes import wintypes
import os
import struct
import subprocess
import sys
import time


def main():
    if os.name != "nt":
        raise SystemExit("This diagnostic requires Windows")
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)

    class DebugEvent(ctypes.Structure):
        _fields_ = [("code", wintypes.DWORD), ("pid", wintypes.DWORD),
                    ("tid", wintypes.DWORD), ("padding", wintypes.DWORD),
                    ("data", ctypes.c_ubyte * 160)]

    signatures = {
        "WaitForDebugEvent": ([ctypes.POINTER(DebugEvent), wintypes.DWORD], wintypes.BOOL),
        "ContinueDebugEvent": ([wintypes.DWORD, wintypes.DWORD, wintypes.DWORD], wintypes.BOOL),
        "OpenThread": ([wintypes.DWORD, wintypes.BOOL, wintypes.DWORD], wintypes.HANDLE),
        "GetThreadContext": ([wintypes.HANDLE, ctypes.c_void_p], wintypes.BOOL),
        "CloseHandle": ([wintypes.HANDLE], wintypes.BOOL),
        "ReadProcessMemory": ([wintypes.HANDLE, ctypes.c_void_p, ctypes.c_void_p,
                               ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)], wintypes.BOOL),
        "VirtualQueryEx": ([wintypes.HANDLE, ctypes.c_void_p, ctypes.c_void_p,
                            ctypes.c_size_t], ctypes.c_size_t),
    }
    for name, (arguments, result) in signatures.items():
        function = getattr(kernel, name)
        function.argtypes = arguments
        function.restype = result

    process = subprocess.Popen(sys.argv[1:], creationflags=2, close_fds=False)
    handle = wintypes.HANDLE(int(process._handle))

    def read(address, size):
        data = ctypes.create_string_buffer(size)
        count = ctypes.c_size_t()
        if not kernel.ReadProcessMemory(handle, address, data, size, ctypes.byref(count)):
            return None
        return data.raw[:count.value]

    def describe(address):
        memory = ctypes.create_string_buffer(48)
        if kernel.VirtualQueryEx(handle, address, memory, len(memory)):
            base = struct.unpack_from("<Q", memory.raw, 8)[0]
            return f"0x{address:016x} (allocation 0x{base:016x}+0x{address - base:x})"
        return f"0x{address:016x}"

    def trace(thread_id):
        thread = kernel.OpenThread(0x48, False, thread_id)
        if not thread:
            print("OpenThread failed", ctypes.get_last_error(), flush=True)
            return
        try:
            storage = ctypes.create_string_buffer(1248)
            offset = (-ctypes.addressof(storage)) % 16
            address = ctypes.addressof(storage) + offset
            struct.pack_into("<I", storage, offset + 48, 0x100003)
            if not kernel.GetThreadContext(thread, address):
                print("GetThreadContext failed", ctypes.get_last_error(), flush=True)
                return
            context = ctypes.string_at(address, 256)
            rsp, rbp = struct.unpack_from("<QQ", context, 152)
            rip = struct.unpack_from("<Q", context, 248)[0]
            print(f"Native overflow: RIP={describe(rip)} RSP=0x{rsp:x} RBP=0x{rbp:x}", flush=True)
            for index in range(64):
                frame = read(rbp, 16)
                if frame is None or len(frame) != 16:
                    break
                previous, returned = struct.unpack("<QQ", frame)
                print(f"  frame {index}: {describe(returned)}", flush=True)
                if previous <= rbp or previous - rbp > 64 * 1024 * 1024:
                    break
                rbp = previous
        finally:
            kernel.CloseHandle(thread)

    overflows = 0
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        event = DebugEvent()
        if not kernel.WaitForDebugEvent(ctypes.byref(event), 500):
            continue
        continuation = 0x10002
        if event.code == 1:
            exception = struct.unpack_from("<I", bytes(event.data))[0]
            if exception == 0xC00000FD:
                overflows += 1
                if overflows <= 3:
                    trace(event.tid)
            if exception != 0x80000003:
                continuation = 0x80010001
        kernel.ContinueDebugEvent(event.pid, event.tid, continuation)
        if event.code == 5:
            result = process.wait()
            print(f"Compiler exit={result}; native stack-overflow exceptions={overflows}", flush=True)
            return result
    process.kill()
    process.wait()
    raise SystemExit("Compiler debugger observation timed out")


if __name__ == "__main__":
    raise SystemExit(main())
