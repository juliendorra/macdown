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
    graphics = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
    graphics.CGMainDisplayID.restype = ctypes.c_uint32
    graphics.CGDisplayIsAsleep.argtypes = [ctypes.c_uint32]
    graphics.CGDisplayIsAsleep.restype = ctypes.c_bool
    if graphics.CGDisplayIsAsleep(graphics.CGMainDisplayID()):
        raise SystemExit('GUI checks need an awake, unlocked desktop; the display is asleep. No app was launched.')
    graphics.CGSessionCopyCurrentDictionary.restype = ctypes.c_void_p
    foundation = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    foundation.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
    foundation.CFStringCreateWithCString.restype = ctypes.c_void_p
    foundation.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    foundation.CFDictionaryGetValue.restype = ctypes.c_void_p
    foundation.CFBooleanGetValue.argtypes = [ctypes.c_void_p]
    foundation.CFBooleanGetValue.restype = ctypes.c_bool
    foundation.CFGetTypeID.argtypes = [ctypes.c_void_p]
    foundation.CFGetTypeID.restype = ctypes.c_ulong
    foundation.CFBooleanGetTypeID.restype = ctypes.c_ulong
    foundation.CFRelease.argtypes = [ctypes.c_void_p]
    session = graphics.CGSessionCopyCurrentDictionary()
    key = foundation.CFStringCreateWithCString(None, b'CGSSessionScreenIsLocked', 0x08000100)
    try:
        locked = foundation.CFDictionaryGetValue(session, key) if session else None
        if not session or (locked and foundation.CFGetTypeID(locked) == foundation.CFBooleanGetTypeID()
                           and foundation.CFBooleanGetValue(locked)):
            raise SystemExit('GUI checks need an awake, unlocked desktop; no app was launched.')
    finally:
        foundation.CFRelease(key)
        if session:
            foundation.CFRelease(session)
