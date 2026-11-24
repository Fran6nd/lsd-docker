# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""Only one tree editor at a time."""
import json
import os
import signal
import subprocess

import pytest

from conftest import read_until
from lsd_tree_editor.lock import AlreadyRunning, Lock


def test_stale_lock_of_a_dead_process_is_reclaimed(tmp_path):
    p = subprocess.Popen(["true"])
    p.wait()
    (tmp_path / "lock").write_text(json.dumps({"pid": p.pid, "session": "old"}))
    lock = Lock("new", tmp_path)
    lock.acquire()
    assert lock.holder() == os.getpid()
    lock.release()
    assert not (tmp_path / "lock").exists()


def test_lock_of_a_pid_that_is_another_program_is_reclaimed(tmp_path):
    other = subprocess.Popen(["sleep", "30"])
    try:
        (tmp_path / "lock").write_text(json.dumps({"pid": other.pid, "session": "old"}))
        Lock("new", tmp_path).acquire()
        assert json.loads((tmp_path / "lock").read_text())["session"] == "new"
    finally:
        other.kill()


def test_unreadable_lock_is_reclaimed(tmp_path):
    (tmp_path / "lock").write_text("not json")
    Lock("new", tmp_path).acquire()


def test_second_process_is_refused_while_the_first_runs(fake, tmp_path):
    first = fake.app("--headless")
    try:
        read_until(first, "READY")
        holder = json.loads((tmp_path / "state" / "lock").read_text())["pid"]
        assert holder == first.pid
        with pytest.raises(AlreadyRunning):   # this process, asking
            Lock("mine", tmp_path / "state").acquire()
        second = fake.app("--headless")       # and a second program
        out, err = second.communicate(timeout=20)
        assert second.returncode == 3
        assert "already running" in err
        assert first.poll() is None           # the first was not disturbed
        assert json.loads((tmp_path / "state" / "lock").read_text())["pid"] == first.pid
    finally:
        first.send_signal(signal.SIGTERM)
        assert first.wait(timeout=20) == 0
    assert not (tmp_path / "state" / "lock").exists()
    third = fake.app("--headless")            # and now one may start again
    read_until(third, "READY")
    third.send_signal(signal.SIGINT)
    assert third.wait(timeout=20) == 0
