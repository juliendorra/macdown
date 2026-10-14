"""Preflight for local AppKit test processes (never shipped in the app)."""
import ctypes
import os
import sys


def require_desktop_access():
    if sys.platform != 'darwin':
        raise SystemExit('These GUI checks require a local macOS desktop session.')
    # A restricted parent passes its sandbox to the child. AppKit may abort
    # during LaunchServices registration before any test code can report it.
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    check = library.sandbox_check
    check.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
    check.restype = ctypes.c_int
    if check(os.getpid(), None, 0) != 0:
        raise SystemExit('GUI checks need desktop access outside the restricted sandbox; no app was launched.')
