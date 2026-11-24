# docker.py -- the only place that runs the docker command
# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""The docker command, and the rules about what it may touch.

Nothing else in the program runs docker. The rules:

- A command that acts on a container or a volume (exec, logs, inspect,
  rm, volume rm, volume inspect) goes through `Docker._act`, which
  refuses unless the target is one this run created -- or an orphan of
  an earlier run that `sweep_orphans` adopted -- AND an inspect shows
  the session label that goes with it.
- `Docker._run` refuses every docker verb that is not in ALLOWED, and
  the acting verbs unless they come from `_act`. There is no prune, no
  stop, no image removal, and no way to hand in a container's name.
- What this program makes carries labels: LABEL=1, the run's session
  (a uuid) and the pid of the program that made it.
"""

from __future__ import annotations

import json
import subprocess
import threading

LABEL = "org.lsd-docker.tree-editor"
LABEL_SESSION = LABEL + ".session"
LABEL_PID = LABEL + ".owner-pid"
LABEL_ROLE = LABEL + ".role"        # server | helper | volume

# What `_run` lets through at all, and which of them act on a target.
ALLOWED = {
    ("version",), ("image", "inspect"), ("pull",), ("run",), ("volume", "create"),
    ("ps",), ("volume", "ls"),
    ("exec",), ("logs",), ("inspect",), ("rm",), ("volume", "rm"), ("volume", "inspect"),
}
ACTING = {("exec",), ("logs",), ("inspect",), ("rm",), ("volume", "rm"), ("volume", "inspect")}


class DockerError(Exception):
    """A docker command that failed; `detail` is what it wrote."""

    def __init__(self, message: str, detail: str = "", returncode: int | None = None):
        super().__init__(message)
        self.message = message
        self.detail = detail
        self.returncode = returncode

    def __str__(self) -> str:
        return self.message + (": " + self.detail.strip() if self.detail.strip() else "")


class Refused(DockerError):
    """The guard said no: the target is not this run's."""


class Gone(DockerError):
    """The target is not there any more."""


class Result:
    def __init__(self, returncode: int, stdout: str, stderr: str):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


def _verb(args: list[str]) -> tuple[str, ...]:
    if args and args[0] in ("image", "volume") and len(args) > 1:
        return (args[0], args[1])
    return (args[0],) if args else ()


class Docker:
    def __init__(self, session: str, pid: int, exe: str = "docker"):
        self.session = session
        self.pid = pid
        self.exe = exe
        # (kind, id or volume name) -> the session label it must carry
        self._owned: dict[tuple[str, str], str] = {}
        self._helpers = 0
        self._mutex = threading.Lock()

    # ---- the two doors ---------------------------------------------------

    def _run(self, args: list[str], *, input: str | None = None, timeout: float = 30,
             _acting: bool = False) -> Result:
        verb = _verb(args)
        if verb not in ALLOWED:
            raise Refused("this program never runs docker " + " ".join(verb))
        if verb in ACTING and not _acting:
            raise Refused("docker " + " ".join(verb) + " may only be used on what this run created")
        try:
            p = subprocess.run([self.exe, *args], input=input, capture_output=True, text=True,
                               timeout=timeout, errors="replace")
        except FileNotFoundError:
            raise DockerError("Docker is not installed (the docker command was not found)") from None
        except subprocess.TimeoutExpired:
            raise DockerError(f"docker {' '.join(verb)} did not answer in {timeout:g} seconds") from None
        return Result(p.returncode, p.stdout, p.stderr)

    def _labels(self, kind: str, target: str) -> dict | None:
        args = (["inspect", "--type", "container", "--format", "{{json .Config.Labels}}", target]
                if kind == "container" else
                ["volume", "inspect", "--format", "{{json .Labels}}", target])
        r = self._run(args, timeout=15, _acting=True)
        if r.returncode != 0:
            if "no such" in r.stderr.lower():
                return None
            raise DockerError("docker could not inspect " + target, r.stderr, r.returncode)
        try:
            return json.loads(r.stdout) or {}
        except ValueError:
            return {}

    def _check(self, kind: str, target: str) -> None:
        """The guard. Raises Refused unless `target` is ours, by record AND by label."""
        expected = self._owned.get((kind, target))
        if expected is None:
            raise Refused(f"refused: the {kind} {target!r} was not created by this run of the tree editor")
        labels = self._labels(kind, target)
        if labels is None:
            raise Gone(f"the {kind} {target} is not there any more")
        if labels.get(LABEL) != "1" or labels.get(LABEL_SESSION) != expected:
            raise Refused(f"refused: the {kind} {target!r} does not carry this run's label")

    def _act(self, kind: str, target: str, before: list[str], after: list[str] | None = None, *,
             input: str | None = None, timeout: float = 30) -> Result:
        """Every command that acts on a container or a volume: checked, then run."""
        self._check(kind, target)
        return self._run([*before, target, *(after or [])], input=input, timeout=timeout, _acting=True)

    # ---- nothing targeted ------------------------------------------------

    def _label_args(self, role: str) -> list[str]:
        return ["--label", f"{LABEL}=1", "--label", f"{LABEL_SESSION}={self.session}",
                "--label", f"{LABEL_PID}={self.pid}", "--label", f"{LABEL_ROLE}={role}"]

    def check_running(self) -> str:
        r = self._run(["version", "--format", "{{.Server.Version}}"], timeout=15)
        if r.returncode != 0 or not r.stdout.strip():
            raise DockerError("Docker is not running. Start Docker Desktop (or the docker service) and try again",
                              r.stderr, r.returncode)
        return r.stdout.strip()

    def image_present(self, image: str) -> bool:
        return self._run(["image", "inspect", "--format", "{{.Id}}", image], timeout=15).returncode == 0

    def pull(self, image: str, timeout: float = 900) -> None:
        """Only ever called after the user said yes."""
        r = self._run(["pull", "-q", image], timeout=timeout)
        if r.returncode != 0:
            raise DockerError("the image could not be downloaded", r.stderr, r.returncode)

    def create_volume(self, name: str) -> str:
        r = self._run(["volume", "create", *self._label_args("volume"), name], timeout=20)
        if r.returncode != 0:
            raise DockerError("the volume could not be created", r.stderr, r.returncode)
        self._owned[("volume", name)] = self.session
        return name

    def run_helper(self, image: str, args: list[str], *, volume: str | None = None,
                   entrypoint: str | None = None, env: dict[str, str] | None = None,
                   input: str | None = None, timeout: float = 60) -> Result:
        """A short `docker run --rm` of the image: a question, or a setup step."""
        with self._mutex:
            self._helpers += 1
            n = self._helpers
        cmd = ["run", "--rm", "--name", f"lsd-tree-editor-helper-{self.session[:8]}-{n}",
               *self._label_args("helper")]
        if input is not None:
            cmd.append("-i")
        if volume is not None:
            self._check("volume", volume)
            cmd += ["-v", f"{volume}:/data"]
        for k, v in (env or {}).items():
            cmd += ["-e", f"{k}={v}"]
        if entrypoint is not None:
            cmd += ["--entrypoint", entrypoint]
        try:
            return self._run([*cmd, image, *args], input=input, timeout=timeout)
        except DockerError:
            self.remove_own_helpers()
            raise

    def run_server(self, image: str, name: str, volume: str, port: int, *, entrypoint: str,
                   args: list[str], env: dict[str, str] | None = None) -> str:
        """The one server container. Returns its id."""
        self._check("volume", volume)
        cmd = ["run", "-d", "--rm", "--name", name, *self._label_args("server"),
               "-p", f"{port}:32887/udp", "-v", f"{volume}:/data"]
        for k, v in (env or {}).items():
            cmd += ["-e", f"{k}={v}"]
        r = self._run([*cmd, "--entrypoint", entrypoint, image, *args], timeout=60)
        cid = r.stdout.strip().splitlines()[-1].strip() if r.stdout.strip() else ""
        if r.returncode != 0 or not cid:
            # docker may have made the container before failing (a port taken): find it by this run's label
            for found in self._own_ids("server"):
                self._owned[("container", found)] = self.session
                self.remove_container(found)
            raise DockerError("the server could not be started", r.stderr, r.returncode)
        self._owned[("container", cid)] = self.session
        return cid

    def _own_ids(self, role: str) -> list[str]:
        """Containers carrying THIS run's session label (nobody else's)."""
        r = self._run(["ps", "-aq", "--no-trunc", "--filter", f"label={LABEL_SESSION}={self.session}",
                       "--filter", f"label={LABEL_ROLE}={role}"], timeout=15)
        return r.stdout.split() if r.returncode == 0 else []

    def remove_own_helpers(self) -> None:
        """A helper that outlived its command (a timeout): removed, through the guard."""
        try:
            for cid in self._own_ids("helper"):
                self._owned[("container", cid)] = self.session
                self.remove_container(cid)
        except DockerError:
            pass

    # ---- on what this run created ---------------------------------------

    def exec(self, cid: str, argv: list[str], *, input: str | None = None, timeout: float = 30) -> Result:
        return self._act("container", cid, ["exec", *(["-i"] if input is not None else [])], argv,
                         input=input, timeout=timeout)

    def logs_follow(self, cid: str) -> subprocess.Popen:
        """`docker logs -f`, as a process to read lines from."""
        self._check("container", cid)
        return subprocess.Popen([self.exe, "logs", "-f", "--tail", "200", cid], stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, errors="replace")

    def is_running(self, cid: str) -> bool:
        try:
            r = self._act("container", cid, ["inspect", "--type", "container", "--format", "{{.State.Running}}"],
                          timeout=15)
        except Gone:
            return False
        return r.returncode == 0 and r.stdout.strip() == "true"

    def remove_container(self, cid: str, timeout: float = 30) -> bool:
        """rm -f. True if it was removed now, False if it was gone already."""
        try:
            r = self._act("container", cid, ["rm", "-f"], timeout=timeout)
        except Gone:
            return False
        if r.returncode != 0 and "no such" not in r.stderr.lower() and "in progress" not in r.stderr.lower():
            raise DockerError("the container could not be removed", r.stderr, r.returncode)
        return True

    def remove_volume(self, name: str, timeout: float = 20) -> bool:
        try:
            r = self._act("volume", name, ["volume", "rm"], timeout=timeout)
        except Gone:
            return False
        if r.returncode != 0 and "no such" not in r.stderr.lower():
            raise DockerError("the volume could not be removed", r.stderr, r.returncode)
        return True

    # ---- orphans of an earlier run --------------------------------------

    def sweep_orphans(self, owner_alive) -> list[str]:
        """Remove what an earlier run of this program left behind.

        Only containers and volumes that carry this program's label, of
        another session than this one, whose owner (the pid in the
        label) is not a running tree editor: `owner_alive(pid)` says.
        Call it only while holding the lock. Returns what was removed.
        """
        removed: list[str] = []
        fmt = '{{.%s}}\t{{.Label "' + LABEL_SESSION + '"}}\t{{.Label "' + LABEL_PID + '"}}'
        for kind, listing in (
            ("container", ["ps", "-a", "--no-trunc", "--filter", f"label={LABEL}=1", "--format", fmt % "ID"]),
            ("volume", ["volume", "ls", "--filter", f"label={LABEL}=1", "--format", fmt % "Name"]),
        ):
            r = self._run(listing, timeout=20)
            if r.returncode != 0:
                continue
            for line in r.stdout.splitlines():
                parts = line.split("\t")
                if len(parts) != 3 or not parts[0] or not parts[1]:
                    continue                      # no session label: not ours to judge
                target, session, pid = parts
                if session == self.session or (kind, target) in self._owned:
                    continue
                if pid.isdigit() and owner_alive(int(pid)):
                    continue
                self._owned[(kind, target)] = session     # adopted: the guard checks the label again
                try:
                    if kind == "container":
                        self.remove_container(target)
                    else:
                        self.remove_volume(target)
                    removed.append(f"{kind} {target[:12] if kind == 'container' else target}")
                except DockerError:
                    pass
                finally:
                    self._owned.pop((kind, target), None)
        return removed
