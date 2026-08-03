# Copyright 2026 Cisco Systems, Inc. and its affiliates
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

"""Injectable, native evidence collectors for Doctor gateway diagnostics.

This module deliberately returns small status objects rather than rendering
diagnostics.  Tests can inject a fake collector on any host, while the real
Windows collector uses read-only, least-privilege APIs and never reads process
memory or environment blocks.
"""

from __future__ import annotations

import ctypes
import json
import ntpath
import os
import socket
import stat
import sys
from dataclasses import dataclass
from typing import Literal

from defenseclaw.safety import is_symlink

EvidenceStatus = Literal["ok", "missing", "malformed", "denied", "unavailable"]
WatchdogOwnershipStatus = Literal["held", "unlocked", "missing", "unsafe", "denied", "unavailable"]
GATEWAY_PROCESS_NAMES = frozenset({"defenseclaw-gateway", "defenseclaw-gateway.exe"})


@dataclass(frozen=True)
class PIDRecord:
    status: EvidenceStatus
    pid: int = 0
    executable: str = ""
    start_identity: str = ""
    start_time: str = ""
    reason: str = ""


@dataclass(frozen=True)
class ProcessEvidence:
    status: EvidenceStatus
    pid: int = 0
    executable: str = ""
    start_identity: str = ""
    reason: str = ""


@dataclass(frozen=True)
class ListenerEvidence:
    status: EvidenceStatus
    pid: int = 0
    reason: str = ""


@dataclass(frozen=True)
class WatchdogStateEvidence:
    status: EvidenceStatus
    state: str = ""
    reason: str = ""


@dataclass(frozen=True)
class WatchdogOwnershipEvidence:
    status: WatchdogOwnershipStatus
    source: str = ""
    reason: str = ""


def canonical_path(path: str) -> str:
    """Return a comparison-only canonical path without exposing it."""
    normalized = os.path.realpath(os.path.abspath(path))
    return os.path.normcase(os.path.normpath(normalized))


def read_pid_record(path: str) -> PIDRecord:
    """Read a regular, non-link PID record from the configured data home."""
    try:
        if is_symlink(path):
            return PIDRecord("malformed", reason="PID file is a symbolic link or reparse point")
        info = os.lstat(path)
        reparse_point = 0x400
        if getattr(info, "st_file_attributes", 0) & reparse_point:
            return PIDRecord("malformed", reason="PID file is a symbolic link or reparse point")
        if not stat.S_ISREG(info.st_mode):
            return PIDRecord("malformed", reason="PID file is not a regular file")
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(path, flags)
        try:
            opened_info = os.fstat(fd)
            if not os.path.samestat(info, opened_info):
                return PIDRecord("unavailable", reason="PID file changed while it was being inspected")
            handle = os.fdopen(fd, encoding="utf-8")
            fd = -1  # fdopen owns the descriptor from this point onward.
            with handle:
                raw = handle.read(16_385)
        finally:
            if fd >= 0:
                os.close(fd)
    except FileNotFoundError:
        return PIDRecord("missing", reason="PID file is missing")
    except PermissionError:
        return PIDRecord("denied", reason="PID file access denied")
    except OSError:
        return PIDRecord("unavailable", reason="PID file could not be inspected")

    if len(raw) > 16_384:
        return PIDRecord("malformed", reason="PID file exceeds the inspection limit")
    return _decode_pid_record(raw)


def _decode_pid_record(raw: str) -> PIDRecord:
    raw = raw.strip()
    if not raw:
        return PIDRecord("malformed", reason="PID file is empty")
    try:
        pid = int(raw)
        payload: dict[str, object] = {}
    except ValueError:
        try:
            decoded = json.loads(raw)
            if not isinstance(decoded, dict):
                raise ValueError
            payload = decoded
            pid = int(payload.get("pid", 0))
        except (json.JSONDecodeError, TypeError, ValueError):
            return PIDRecord("malformed", reason="PID file is malformed")
    if pid <= 0:
        return PIDRecord("malformed", reason="PID file contains an invalid PID")
    executable = payload.get("executable", "")
    start_identity = payload.get("start_identity", "")
    start_time = payload.get("start_time", "")
    return PIDRecord(
        "ok",
        pid=pid,
        executable=executable if isinstance(executable, str) else "",
        start_identity=start_identity if isinstance(start_identity, str) else "",
        start_time=str(start_time) if isinstance(start_time, (str, int)) else "",
    )


def read_watchdog_pid_record(path: str, *, platform_name: str | None = None) -> PIDRecord:
    """Read watchdog.pid from one private, identity-bound Windows handle.

    Gateway PID diagnostics retain their established reader. This stricter
    reader is watchdog-specific because a held lifetime lock is meaningful
    only when the replaceable canonical publication has private custody too.
    """
    if (platform_name or sys.platform) != "win32":
        return read_pid_record(path)

    from defenseclaw.windows_acl import (
        WindowsAclError,
        assert_not_broadly_readable,
        assert_not_broadly_writable,
        assert_trusted_owner,
        capture_fd,
        open_regular_read_fd_shared_delete,
    )

    try:
        if is_symlink(path):
            return PIDRecord("malformed", reason="watchdog PID file is a symbolic link or reparse point")
        named_info = os.lstat(path)
        reparse_point = 0x400
        if getattr(named_info, "st_file_attributes", 0) & reparse_point:
            return PIDRecord("malformed", reason="watchdog PID file is a symbolic link or reparse point")
        if not stat.S_ISREG(named_info.st_mode):
            return PIDRecord("malformed", reason="watchdog PID file is not a regular file")
        fd = open_regular_read_fd_shared_delete(path)
        try:
            opened_info = os.fstat(fd)
            if not os.path.samestat(named_info, opened_info):
                return PIDRecord("unavailable", reason="watchdog PID file changed while it was inspected")
            security = capture_fd(fd)
            assert_trusted_owner(security)
            assert_not_broadly_readable(security)
            assert_not_broadly_writable(security)
            os.lseek(fd, 0, os.SEEK_SET)
            data = os.read(fd, 16_385)
        finally:
            os.close(fd)
    except FileNotFoundError:
        return PIDRecord("missing", reason="watchdog PID file is missing")
    except PermissionError:
        return PIDRecord("denied", reason="watchdog PID file access denied")
    except WindowsAclError as exc:
        code = getattr(exc, "winerror", None) or getattr(exc, "errno", None)
        if code in {2, 3}:
            return PIDRecord("missing", reason="watchdog PID file is missing")
        if code == 5:
            return PIDRecord("denied", reason="watchdog PID custody inspection access denied")
        message = str(exc).lower()
        if any(marker in message for marker in ("regular file", "reparse")):
            return PIDRecord("malformed", reason="watchdog PID file is not a private regular non-reparse file")
        if code is not None:
            return PIDRecord("unavailable", reason="watchdog PID file could not be inspected safely")
        return PIDRecord("malformed", reason="watchdog PID file owner or DACL is not private")
    except OSError:
        return PIDRecord("unavailable", reason="watchdog PID file could not be inspected safely")

    if len(data) > 16_384:
        return PIDRecord("malformed", reason="watchdog PID file exceeds the inspection limit")
    try:
        raw = data.decode("utf-8")
    except UnicodeError:
        return PIDRecord("malformed", reason="watchdog PID file is malformed")
    return _decode_pid_record(raw)


def read_watchdog_state(path: str) -> WatchdogStateEvidence:
    """Read the bounded, non-link last-known watchdog health state."""
    try:
        if is_symlink(path):
            return WatchdogStateEvidence("malformed", reason="state file is a symbolic link or reparse point")
        info = os.lstat(path)
        reparse_point = 0x400
        if getattr(info, "st_file_attributes", 0) & reparse_point:
            return WatchdogStateEvidence("malformed", reason="state file is a symbolic link or reparse point")
        if not stat.S_ISREG(info.st_mode):
            return WatchdogStateEvidence("malformed", reason="state file is not a regular file")
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(path, flags)
        try:
            opened_info = os.fstat(fd)
            if not os.path.samestat(info, opened_info):
                return WatchdogStateEvidence("unavailable", reason="state file changed while it was inspected")
            handle = os.fdopen(fd, encoding="utf-8")
            fd = -1
            with handle:
                raw = handle.read(65)
        finally:
            if fd >= 0:
                os.close(fd)
    except FileNotFoundError:
        return WatchdogStateEvidence("missing", reason="last-known state is missing")
    except PermissionError:
        return WatchdogStateEvidence("denied", reason="last-known state access denied")
    except (OSError, UnicodeError):
        return WatchdogStateEvidence("unavailable", reason="last-known state could not be inspected")

    if len(raw) > 64:
        return WatchdogStateEvidence("malformed", reason="last-known state exceeds the inspection limit")
    state = raw.strip().lower()
    if state not in {"healthy", "degraded", "down"}:
        return WatchdogStateEvidence("malformed", reason="last-known state is invalid")
    return WatchdogStateEvidence("ok", state=state)


def inspect_watchdog_ownership(
    stable_path: str,
    legacy_pid_path: str,
    *,
    platform_name: str | None = None,
) -> WatchdogOwnershipEvidence:
    """Probe the stable Windows ownership lock with bounded legacy fallback.

    The probe never writes file content. It attempts the exact lifetime byte
    lock and immediately releases it when available. A held stable lock is
    authoritative for current watchdogs; a held canonical PID lock is accepted
    only as compatibility evidence for an older watchdog publisher.
    """
    if (platform_name or sys.platform) != "win32":
        return WatchdogOwnershipEvidence(
            "unavailable",
            reason="native Windows watchdog ownership inspection is unavailable",
        )

    stable = _windows_watchdog_file_lock_evidence(stable_path, source="stable")
    if stable.status == "held":
        return stable
    if stable.status in {"unsafe", "denied", "unavailable"}:
        return stable

    legacy = _windows_watchdog_file_lock_evidence(legacy_pid_path, source="legacy")
    if legacy.status == "held":
        return legacy
    if legacy.status in {"unsafe", "denied", "unavailable"}:
        return legacy
    if stable.status == "unlocked":
        return stable
    if legacy.status == "unlocked":
        return legacy
    return WatchdogOwnershipEvidence("missing", reason="no watchdog ownership object exists")


def _windows_watchdog_file_lock_evidence(path: str, *, source: str) -> WatchdogOwnershipEvidence:
    """Inspect one private regular Windows lifecycle file and its lock byte."""
    import msvcrt
    from ctypes import wintypes

    from defenseclaw.windows_acl import (
        WindowsAclError,
        assert_not_broadly_readable,
        assert_not_broadly_writable,
        assert_trusted_owner,
        capture_fd,
        open_regular_read_fd_shared_delete,
    )

    try:
        fd = open_regular_read_fd_shared_delete(path)
    except WindowsAclError as exc:
        code = getattr(exc, "winerror", None) or getattr(exc, "errno", None)
        if code in {2, 3}:
            return WatchdogOwnershipEvidence("missing", source=source, reason="ownership file is missing")
        if code == 5:
            return WatchdogOwnershipEvidence("denied", source=source, reason="ownership file access denied")
        message = str(exc).lower()
        if any(marker in message for marker in ("regular file", "reparse", "owner", "dacl", "broad")):
            return WatchdogOwnershipEvidence("unsafe", source=source, reason="ownership file is unsafe")
        return WatchdogOwnershipEvidence(
            "unavailable",
            source=source,
            reason="ownership file could not be opened safely",
        )

    try:
        try:
            security = capture_fd(fd)
            assert_trusted_owner(security)
            assert_not_broadly_readable(security)
            assert_not_broadly_writable(security)
        except WindowsAclError as exc:
            code = getattr(exc, "winerror", None) or getattr(exc, "errno", None)
            if code == 5:
                return WatchdogOwnershipEvidence(
                    "denied",
                    source=source,
                    reason="ownership security inspection access denied",
                )
            return WatchdogOwnershipEvidence(
                "unsafe",
                source=source,
                reason="ownership file owner or DACL is not private",
            )

        class OVERLAPPED(ctypes.Structure):
            _fields_ = [
                ("Internal", ctypes.c_size_t),
                ("InternalHigh", ctypes.c_size_t),
                ("Offset", wintypes.DWORD),
                ("OffsetHigh", wintypes.DWORD),
                ("hEvent", wintypes.HANDLE),
            ]

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        lock_file = kernel32.LockFileEx
        lock_file.argtypes = (
            wintypes.HANDLE,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.DWORD,
            ctypes.POINTER(OVERLAPPED),
        )
        lock_file.restype = wintypes.BOOL
        unlock_file = kernel32.UnlockFileEx
        unlock_file.argtypes = (
            wintypes.HANDLE,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.DWORD,
            ctypes.POINTER(OVERLAPPED),
        )
        unlock_file.restype = wintypes.BOOL

        overlapped = OVERLAPPED(OffsetHigh=0x4000_0000)
        handle = wintypes.HANDLE(msvcrt.get_osfhandle(fd))
        lock_exclusive = 0x00000002
        lock_fail_immediately = 0x00000001
        if not lock_file(
            handle,
            lock_exclusive | lock_fail_immediately,
            0,
            1,
            0,
            ctypes.byref(overlapped),
        ):
            error = ctypes.get_last_error()
            if error == 33:  # ERROR_LOCK_VIOLATION
                return WatchdogOwnershipEvidence("held", source=source, reason="ownership lock is held")
            if error == 5:  # ERROR_ACCESS_DENIED
                return WatchdogOwnershipEvidence(
                    "denied",
                    source=source,
                    reason="ownership lock access denied",
                )
            return WatchdogOwnershipEvidence(
                "unavailable",
                source=source,
                reason="ownership lock state could not be inspected",
            )
        if not unlock_file(handle, 0, 1, 0, ctypes.byref(overlapped)):
            return WatchdogOwnershipEvidence(
                "unavailable",
                source=source,
                reason="ownership probe lock could not be released",
            )
        return WatchdogOwnershipEvidence("unlocked", source=source, reason="ownership lock is not held")
    finally:
        os.close(fd)


class GatewayEvidence:
    """OS evidence seam used by the Windows Doctor checks."""

    def __init__(self, *, platform_name: str | None = None) -> None:
        self.platform_name = platform_name or sys.platform

    def pid_record(self, path: str) -> PIDRecord:
        return read_pid_record(path)

    def watchdog_pid_record(self, path: str) -> PIDRecord:
        return read_watchdog_pid_record(path, platform_name=self.platform_name)

    def process(self, pid: int) -> ProcessEvidence:
        if self.platform_name != "win32":
            return ProcessEvidence("unavailable", pid=pid, reason="native Windows process inspection is unavailable")
        return _windows_process_evidence(pid)

    def listener(self, port: int) -> ListenerEvidence:
        if self.platform_name != "win32":
            return ListenerEvidence("unavailable", reason="native Windows listener inspection is unavailable")
        return _windows_listener_evidence(port)

    def watchdog_state(self, path: str) -> WatchdogStateEvidence:
        return read_watchdog_state(path)

    def watchdog_ownership(self, stable_path: str, legacy_pid_path: str) -> WatchdogOwnershipEvidence:
        return inspect_watchdog_ownership(
            stable_path,
            legacy_pid_path,
            platform_name=self.platform_name,
        )


def _windows_process_evidence(pid: int) -> ProcessEvidence:  # pragma: no cover - native Windows only
    from ctypes import wintypes

    if pid <= 0:
        return ProcessEvidence("missing", pid=pid, reason="invalid PID")
    query_limited = 0x1000
    still_active = 259
    error_access_denied = 5
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

    open_process = kernel32.OpenProcess
    open_process.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
    open_process.restype = wintypes.HANDLE
    close_handle = kernel32.CloseHandle
    close_handle.argtypes = (wintypes.HANDLE,)
    close_handle.restype = wintypes.BOOL

    handle = open_process(query_limited, False, pid)
    if not handle:
        error = ctypes.get_last_error()
        if error == error_access_denied:
            return ProcessEvidence("denied", pid=pid, reason="process inspection access denied")
        return ProcessEvidence("missing", pid=pid, reason="recorded process does not exist")
    try:
        get_exit_code = kernel32.GetExitCodeProcess
        get_exit_code.argtypes = (wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD))
        get_exit_code.restype = wintypes.BOOL
        exit_code = wintypes.DWORD()
        if not get_exit_code(handle, ctypes.byref(exit_code)):
            return ProcessEvidence("unavailable", pid=pid, reason="process state could not be queried")
        if exit_code.value != still_active:
            return ProcessEvidence("missing", pid=pid, reason="recorded process has exited")

        query_image = kernel32.QueryFullProcessImageNameW
        query_image.argtypes = (
            wintypes.HANDLE,
            wintypes.DWORD,
            wintypes.LPWSTR,
            ctypes.POINTER(wintypes.DWORD),
        )
        query_image.restype = wintypes.BOOL
        size = wintypes.DWORD(32_768)
        image = ctypes.create_unicode_buffer(size.value)
        if not query_image(handle, 0, image, ctypes.byref(size)):
            return ProcessEvidence("unavailable", pid=pid, reason="process executable could not be queried")

        class FILETIME(ctypes.Structure):
            _fields_ = [("low", wintypes.DWORD), ("high", wintypes.DWORD)]

        get_times = kernel32.GetProcessTimes
        get_times.argtypes = tuple([wintypes.HANDLE] + [ctypes.POINTER(FILETIME)] * 4)
        get_times.restype = wintypes.BOOL
        creation, exit_time, kernel_time, user_time = FILETIME(), FILETIME(), FILETIME(), FILETIME()
        if not get_times(
            handle,
            ctypes.byref(creation),
            ctypes.byref(exit_time),
            ctypes.byref(kernel_time),
            ctypes.byref(user_time),
        ):
            return ProcessEvidence("unavailable", pid=pid, reason="process start identity could not be queried")
        ticks_100ns = (creation.high << 32) | creation.low
        # Match golang.org/x/sys/windows.Filetime.Nanoseconds(), which is
        # what daemon.writePIDInfo persists through processStartIdentity.
        unix_epoch_100ns = 116_444_736_000_000_000
        return ProcessEvidence(
            "ok",
            pid=pid,
            executable=image.value,
            start_identity=str((ticks_100ns - unix_epoch_100ns) * 100),
        )
    finally:
        close_handle(handle)


def _windows_listener_evidence(port: int) -> ListenerEvidence:  # pragma: no cover - native Windows only
    """Resolve a TCP listener owner with GetExtendedTcpTable (IPv4/IPv6)."""
    from ctypes import wintypes

    if not 1 <= port <= 65_535:
        return ListenerEvidence("unavailable", reason="configured API port is invalid")
    iphlpapi = ctypes.WinDLL("iphlpapi", use_last_error=True)
    get_table = iphlpapi.GetExtendedTcpTable
    get_table.argtypes = (
        wintypes.LPVOID,
        ctypes.POINTER(wintypes.ULONG),
        wintypes.BOOL,
        wintypes.ULONG,
        wintypes.ULONG,
        wintypes.ULONG,
    )
    get_table.restype = wintypes.DWORD
    tcp_table_owner_pid_listener = 3
    error_insufficient_buffer = 122
    error_access_denied = 5

    class TCP4Row(ctypes.Structure):
        _fields_ = [
            ("state", wintypes.DWORD),
            ("local_addr", wintypes.DWORD),
            ("local_port", wintypes.DWORD),
            ("remote_addr", wintypes.DWORD),
            ("remote_port", wintypes.DWORD),
            ("pid", wintypes.DWORD),
        ]

    class TCP6Row(ctypes.Structure):
        _fields_ = [
            ("local_addr", ctypes.c_ubyte * 16),
            ("local_scope", wintypes.DWORD),
            ("local_port", wintypes.DWORD),
            ("remote_addr", ctypes.c_ubyte * 16),
            ("remote_scope", wintypes.DWORD),
            ("remote_port", wintypes.DWORD),
            ("state", wintypes.DWORD),
            ("pid", wintypes.DWORD),
        ]

    for family, row_type in ((socket.AF_INET, TCP4Row), (socket.AF_INET6, TCP6Row)):
        size = wintypes.ULONG(0)
        result = get_table(None, ctypes.byref(size), False, family, tcp_table_owner_pid_listener, 0)
        if result not in (0, error_insufficient_buffer):
            if result == error_access_denied:
                return ListenerEvidence("denied", reason="listener ownership access denied")
            return ListenerEvidence("unavailable", reason="listener ownership could not be queried")
        if not size.value:
            continue
        buffer = ctypes.create_string_buffer(size.value)
        result = get_table(buffer, ctypes.byref(size), False, family, tcp_table_owner_pid_listener, 0)
        if result != 0:
            if result == error_access_denied:
                return ListenerEvidence("denied", reason="listener ownership access denied")
            return ListenerEvidence("unavailable", reason="listener ownership could not be queried")
        count = ctypes.cast(buffer, ctypes.POINTER(wintypes.DWORD)).contents.value
        offset = ctypes.sizeof(wintypes.DWORD)
        # The table aligns its row array to the row's native alignment.
        alignment = ctypes.alignment(row_type)
        offset = (offset + alignment - 1) & ~(alignment - 1)
        for index in range(count):
            row = row_type.from_buffer_copy(buffer, offset + index * ctypes.sizeof(row_type))
            if socket.ntohs(row.local_port & 0xFFFF) == port:
                return ListenerEvidence("ok", pid=int(row.pid))
    return ListenerEvidence("missing", reason="no TCP listener on the configured API port")


def gateway_executable_name(path: str) -> str:
    """Normalize a Windows executable basename for exact allowlist matching."""
    return ntpath.basename(path.strip()).lower()
