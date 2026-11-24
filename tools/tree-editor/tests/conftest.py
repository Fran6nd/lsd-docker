# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""The tests never reach a real Docker: `docker` on their PATH is
tests/fake_docker.py, which records every call."""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
FIXTURES = HERE / "fixtures"


class Fake:
    def __init__(self, home: Path):
        self.home = home

    def calls(self) -> list[list[str]]:
        f = self.home / "calls.jsonl"
        return [json.loads(line)["argv"] for line in f.read_text().splitlines()] if f.exists() else []

    def records(self) -> list[dict]:
        f = self.home / "calls.jsonl"
        return [json.loads(line) for line in f.read_text().splitlines()] if f.exists() else []

    def state(self) -> dict:
        f = self.home / "state.json"
        return json.loads(f.read_text()) if f.exists() else {"containers": {}, "volumes": {}}

    def seed(self, containers=None, volumes=None) -> None:
        (self.home / "state.json").write_text(json.dumps({"containers": containers or {}, "volumes": volumes or {}}))

    def env(self) -> dict:
        return dict(os.environ)

    def app(self, *args, **env) -> subprocess.Popen:
        """The program itself, in a process of its own."""
        return subprocess.Popen([sys.executable, "-m", "lsd_tree_editor", *args], cwd=HERE.parent,
                                env={**os.environ, "QT_QPA_PLATFORM": "offscreen", **env},
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def acting(calls):
    """(verb, target) of every recorded call that names a container or a volume."""
    out = []
    for a in calls:
        if a[0] in ("exec", "rm", "logs", "inspect"):
            target = [x for x in a[1:] if not x.startswith("-")]
            if a[0] == "inspect":
                target = [a[-1]]
            elif a[0] == "logs":
                target = [a[-1]]
            elif a[0] == "rm":
                target = [a[-1]]
            out.append((a[0], target[0]))
        elif a[0] == "volume" and a[1] in ("rm", "inspect"):
            out.append(("volume " + a[1], a[-1]))
    return out


def wait_for(condition, timeout=10.0, step=0.05):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if condition():
            return True
        time.sleep(step)
    return False


def read_until(process, word, timeout=20.0):
    """Read the program's output until a line starts with `word`."""
    end = time.monotonic() + timeout
    lines = []
    while time.monotonic() < end:
        line = process.stdout.readline()
        if not line:
            break
        lines.append(line.rstrip())
        if line.startswith(word):
            return lines
    raise AssertionError(f"no {word!r} from the program: {lines} {process.stderr.read() if process.poll() is not None else ''}")


@pytest.fixture
def fake(tmp_path, monkeypatch):
    home = tmp_path / "fake"
    bin_dir = tmp_path / "bin"
    home.mkdir()
    bin_dir.mkdir()
    script = bin_dir / "docker"
    script.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{HERE / "fake_docker.py"}" "$@"\n')
    script.chmod(0o755)
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_DOCKER_DIR", str(home))
    monkeypatch.setenv("LSD_TREE_EDITOR_STATE", str(tmp_path / "state"))
    return Fake(home)


@pytest.fixture
def session(fake, monkeypatch):
    from lsd_tree_editor import server
    monkeypatch.setattr(server, "HEARTBEAT_EVERY", 3600)     # keeps the recorded calls exact
    monkeypatch.setattr(server.time, "sleep", lambda s: None)
    s = server.Session()
    s.start()
    yield s
    s.shutdown()
