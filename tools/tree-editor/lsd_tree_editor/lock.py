# lock.py -- one tree editor at a time
# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""A lock file in the user's state directory: the pid and the session of
the tree editor that runs. A second one is refused at start. The lock is
stale when that pid is not alive, or is not this program."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

PROGRAM_MARKS = ("lsd_tree_editor", "lsd-tree-editor")


def state_dir() -> Path:
    override = os.environ.get("LSD_TREE_EDITOR_STATE")
    if override:
        return Path(override)
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "lsd-tree-editor"
    if os.name == "nt":
        return Path(os.environ.get("LOCALAPPDATA", Path.home())) / "lsd-tree-editor"
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "lsd-tree-editor"


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        import ctypes
        handle = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)
        if not handle:
            return False
        ctypes.windll.kernel32.CloseHandle(handle)
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def is_tree_editor(pid: int) -> bool:
    """Is that pid a running tree editor? (On Windows: is it alive.)"""
    if not pid_alive(pid):
        return False
    if os.name == "nt":
        return True
    try:
        out = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True,
                             timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return True                    # cannot tell: say yes, and touch nothing
    return any(mark in out for mark in PROGRAM_MARKS)


class AlreadyRunning(Exception):
    def __init__(self, pid: int):
        super().__init__(f"The tree editor is already running (process {pid}). Only one may run at a time, "
                         "because it owns one server.")
        self.pid = pid


class Lock:
    def __init__(self, session: str, directory: Path | None = None):
        self.session = session
        self.path = (directory or state_dir()) / "lock"
        self.held = False

    def acquire(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        body = json.dumps({"pid": os.getpid(), "session": self.session, "started": time.time()})
        for _ in range(2):
            try:
                fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            except FileExistsError:
                holder = self.holder()
                if holder and holder != os.getpid() and is_tree_editor(holder):
                    raise AlreadyRunning(holder) from None
                try:                   # stale: its owner is dead, or is another program now
                    self.path.unlink()
                except FileNotFoundError:
                    pass
                continue
            with os.fdopen(fd, "w") as f:
                f.write(body)
            self.held = True
            return
        raise AlreadyRunning(self.holder() or 0)

    def holder(self) -> int | None:
        try:
            return int(json.loads(self.path.read_text())["pid"])
        except (OSError, ValueError, KeyError, TypeError):
            return None

    def release(self) -> None:
        if self.held and self.holder() == os.getpid():
            try:
                self.path.unlink()
            except FileNotFoundError:
                pass
        self.held = False
