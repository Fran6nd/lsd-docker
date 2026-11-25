# server.py -- the one server of this run, and what can be asked of it
# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""The session: one lock, at most one server, the lsdctl operations.

Every operation is a typed method that returns the parsed JSON the
image's own tools gave (bot/TREES.md, sections 15 and 16), or raises
ServerError with the diagnostics. Nothing here reads or writes tree
text: checking, formatting and turning a text into a structure are the
engine's (`lsdctl bots ...`, `bttree`), run in the container.
"""

from __future__ import annotations

import atexit
import collections
import json
import os
import secrets
import socket
import threading
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

from .docker import Docker, DockerError, Gone
from .lock import Lock, is_tree_editor

DEFAULT_IMAGE = "ghcr.io/fran6nd/lsd-docker:latest"
LOCAL_IMAGE = "lsd-docker:demo"            # offered when it is on this computer; never built or changed here
FIRST_PORT = 32888                         # 32887 is the port of a server one runs by hand
FALLBACK_GAMEMODES = ["tdm", "ctf", "parkour"]
ONE_TEAM = {"parkour"}                     # until the image says (lsdctl bots games), which games have one team

HEARTBEAT = "/tmp/lsd-tree-editor.heartbeat"
HEARTBEAT_EVERY = 3                        # seconds, from the app
LEASH_STALE = 20                           # seconds without a heartbeat ...
LEASH_CHECK = 5                            # ... seen at two checks in a row: the server stops

# The container's command: the image's own `entrypoint serve`, with a
# watcher beside it. The app touches HEARTBEAT every few seconds; when
# the app is gone (killed, crashed, the computer lost power) the file
# goes stale and the watcher stops the server. The container was run
# with --rm, so it is removed as it stops.
LEASH = f"""
hb={HEARTBEAT}; touch "$hb"; main=$$
( strikes=0
  while sleep {LEASH_CHECK}; do
    now=$(date +%s); seen=$(stat -c %Y "$hb" 2>/dev/null || echo 0)
    if [ $((now - seen)) -gt {LEASH_STALE} ]; then strikes=$((strikes + 1)); else strikes=0; fi
    if [ "$strikes" -ge 2 ]; then
      echo "lsd-tree-editor: the editor is gone: stopping the server"
      kill -TERM "$main"; sleep 10; kill -KILL "$main"; exit 0
    fi
  done ) &
exec entrypoint serve
"""

# Before the first start, as dev/demo-new.sh does it.
SETUP = """
set -e
lsdctl gamemode "$GAME" --yes --no-restart >/dev/null
lsdctl set masterlist_enabled false --no-restart >/dev/null
lsdctl bots "$BOTS" --no-restart >/dev/null
if [ "$BOTS" -gt 0 ]; then
  [ -z "$TEAM1" ] || lsdctl set engine_bots_team1 "$TEAM1" --no-restart >/dev/null
  [ -z "$TEAM2" ] || lsdctl set engine_bots_team2 "$TEAM2" --no-restart >/dev/null
  lsdctl set engine_bots_level "$LEVEL" --no-restart >/dev/null
fi
if [ "$MAP" = random ] && out=$(lsdctl map web-random "$GAME" 2>&1); then
  echo "$out"
  map=$(echo "$out" | sed -n "s/^added \\([^ ]*\\)\\.vxl.*/\\1/p" | head -1)
  if [ -n "$map" ]; then
    lsdctl set map_rotation "$map" --no-restart >/dev/null
    lsdctl set map_web_random true --no-restart >/dev/null
  fi
else
  echo "no map from the web: a generated one"
fi
"""


# An edited structure made text, checked and read again, in one call
# (Session.remake): the text, a mark, the check, a mark, the structure.
MARK = "@@lsd-tree-editor@@"
REMAKE = f"""
t=$(mktemp); e=$(mktemp)
if ! bttree --from-json - > "$t" 2> "$e"; then cat "$e" >&2; rm -f "$t" "$e"; exit 3; fi
cat "$t"; echo "{MARK}"
lsdctl bots check - --json < "$t"; echo "{MARK}"
bttree --json "$t"; rm -f "$t" "$e"
"""


class ServerError(Exception):
    """An operation that could not be done; `diagnostics` when a text does not compile."""

    def __init__(self, message: str, diagnostics: list[dict] | None = None):
        super().__init__(message)
        self.message = message
        self.diagnostics = diagnostics or []


class ImageTooOld(ServerError):
    pass


@dataclass
class Setup:
    image: str = DEFAULT_IMAGE
    gamemode: str = "tdm"
    map: str = "random"                    # random (from the web) | generated
    bots_team1: int = 3
    bots_team2: int = 3                    # ignored in a game of one team
    level: int = 10


@dataclass
class Instance:
    name: str                              # the container's and the volume's
    cid: str
    image: str
    port: int
    gamemode: str
    lan: str | None
    state: str = "starting"                # starting | running | stopping | error
    notes: list[str] = field(default_factory=list)

    @property
    def addresses(self) -> list[str]:
        return [f"{ip}:{self.port}" for ip in ([self.lan] if self.lan else []) + ["127.0.0.1"]]

    @property
    def urls(self) -> list[str]:
        return ["aos://" + a for a in self.addresses]


def lan_address() -> str | None:
    """This computer's address on its network (no packet is sent)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.0.2.1", 9))
        ip = s.getsockname()[0]
        return None if ip.startswith("127.") or ip == "0.0.0.0" else ip
    except OSError:
        return None
    finally:
        s.close()


def free_udp_port(first: int = FIRST_PORT, tries: int = 100) -> int:
    for port in range(first, first + tries):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.bind(("0.0.0.0", port))
            return port
        except OSError:
            continue
        finally:
            s.close()
    raise ServerError(f"No free UDP port between {first} and {first + tries - 1}.")


def one_team(gamemode: str) -> bool:
    return gamemode in ONE_TEAM


class Session:
    def __init__(self, state_directory: Path | None = None, docker_exe: str = "docker"):
        self.id = str(uuid.uuid4())
        self.docker = Docker(self.id, os.getpid(), docker_exe)
        self.lock = Lock(self.id, state_directory)
        self.instance: Instance | None = None
        self.image: str | None = None      # the image that was asked what it can do, and can
        self.schema: dict | None = None
        self.gamemodes: list[str] = list(FALLBACK_GAMEMODES)
        self.swept: list[str] = []
        self._log: collections.deque[str] = collections.deque(maxlen=5000)
        self._log_count = 0
        self._launching = False
        self._mutex = threading.Lock()
        self._shutdown_done = False
        self._stop_threads = threading.Event()

    # ---- start and end of the program -------------------------------------

    def start(self, sweep: bool = True) -> None:
        """Take the lock (raises AlreadyRunning), then clear what a killed run left."""
        self.lock.acquire()
        atexit.register(self.shutdown)
        if sweep:
            try:
                self.swept = self.docker.sweep_orphans(is_tree_editor)
            except DockerError:
                self.swept = []            # Docker is not running: nothing to sweep now

    def shutdown(self) -> str | None:
        """Remove the server and its volume, release the lock. Safe to call
        again. Returns None, or what could not be removed, as a sentence."""
        with self._mutex:
            if self._shutdown_done:
                return None
            self._shutdown_done = True
        problem = self.stop_instance()
        self.lock.release()
        return problem

    def stop_instance(self) -> str | None:
        inst = self.instance
        if inst is None:
            return None
        inst.state = "stopping"
        self._stop_threads.set()
        problem = None
        try:
            self.docker.remove_container(inst.cid)
        except DockerError as e:
            problem = f"The server's container could not be removed ({e}). Remove it by hand: docker rm -f {inst.name}"
        try:
            self.docker.remove_volume(inst.name)
        except DockerError as e:
            problem = (problem + " " if problem else "") + \
                f"Its volume could not be removed ({e}). Remove it by hand: docker volume rm {inst.name}"
        if problem is None:
            self.instance = None
        else:
            inst.state = "error"
        return problem

    # ---- the image --------------------------------------------------------

    def local_images(self) -> list[str]:
        """The images to offer: the default, and the local one if it is here."""
        out = [DEFAULT_IMAGE]
        if self.docker.image_present(LOCAL_IMAGE):
            out.append(LOCAL_IMAGE)
        return out

    def probe_image(self, image: str) -> dict:
        """Ask the image what a tree may be made of. Raises ImageTooOld when
        it predates the bots commands. Keeps the schema and the gamemodes."""
        r = self.docker.run_helper(image, ["bots", "schema", "--json"], timeout=60)
        try:
            schema = json.loads(r.stdout)
            if schema.get("format") != "lsd-bt-schema":
                raise ValueError
        except (ValueError, AttributeError):
            raise ImageTooOld(
                f"The image {image} is too old for the tree editor: it does not have the bots commands "
                "(lsdctl bots schema). Use a newer image.") from None
        self.image, self.schema = image, schema
        self.gamemodes = self._gamemodes(image)
        return schema

    def _gamemodes(self, image: str) -> list[str]:
        """The gamemodes the image lists that the bot engine has a tree for."""
        try:
            r = self.docker.run_helper(image, ["-c", "lsdctl setup --defaults >/dev/null 2>&1; lsdctl gamemode; "
                                               "echo ==; lsdctl bots trees --json; "
                                               "echo ==; lsdctl bots games --json 2>/dev/null"],
                                       entrypoint="sh", timeout=60)
            modes, _, trees = r.stdout.partition("==")
            trees, _, games = trees.partition("==")
            try:                           # an image that says which games have one team (lsdctl bots games)
                rows = json.loads(games)["games"]
                ONE_TEAM.clear()
                ONE_TEAM.update(g["name"] for g in rows if g.get("teams") == 1)
            except (ValueError, KeyError, TypeError):
                pass
            names = {t["name"] for t in json.loads(trees)["trees"]}
            ids = [line.lstrip("* ").split()[0] for line in modes.splitlines() if line.strip()]
            found = [m for m in ids if m in names]
            if found:
                return sorted(found, key=lambda m: (FALLBACK_GAMEMODES + [m]).index(m))
        except (DockerError, ValueError, KeyError, IndexError):
            pass
        return list(FALLBACK_GAMEMODES)

    # ---- the one server ---------------------------------------------------

    def launch(self, setup: Setup, progress=lambda text: None) -> Instance:
        with self._mutex:
            if self.instance is not None or self._launching:
                raise ServerError("A server is already there. This program runs only one: stop it first.")
            if self._shutdown_done:
                raise ServerError("The program is closing.")
            self._launching = True
        name = "lsd-tree-editor-" + secrets.token_hex(3)
        volume = None
        try:
            progress("Asking Docker...")
            self.docker.check_running()
            if self.image != setup.image:
                progress("Asking the image what it can do...")
                self.probe_image(setup.image)
            progress("Setting the server up...")
            volume = self.docker.create_volume(name)
            r = self.docker.run_helper(setup.image, ["setup", "--defaults"], volume=volume, timeout=60)
            if r.returncode != 0:
                raise ServerError("The server could not be set up: " + (r.stderr or r.stdout).strip())
            solo = one_team(setup.gamemode)
            bots = setup.bots_team1 if solo else max(setup.bots_team1, setup.bots_team2)
            env = {"GAME": setup.gamemode, "MAP": setup.map, "BOTS": str(bots), "LEVEL": str(setup.level),
                   "TEAM1": "" if solo else str(setup.bots_team1), "TEAM2": "" if solo else str(setup.bots_team2)}
            progress("Choosing the game and the map...")
            r = self.docker.run_helper(setup.image, ["-c", SETUP], volume=volume, entrypoint="sh", env=env,
                                       timeout=120)
            if r.returncode != 0:
                raise ServerError("The server could not be set up: " + (r.stderr or r.stdout).strip())
            notes = [line for line in r.stdout.splitlines() if line.strip()]
            progress("Starting the server...")
            lan = lan_address()
            cid, port = None, FIRST_PORT
            for attempt in range(5):
                port = free_udp_port(port)
                try:
                    cid = self.docker.run_server(
                        setup.image, name, volume, port, entrypoint="/sbin/tini", args=["--", "sh", "-c", LEASH],
                        env={"LSD_HOST_ADDRESSES": lan or "", "LSD_HOST_PORT": str(port)})
                    break
                except DockerError as e:
                    if attempt == 4 or not any(w in str(e).lower() for w in ("port is already", "address already")):
                        raise
                    port += 1
            inst = Instance(name, cid, setup.image, port, setup.gamemode, lan, notes=notes)
            self.instance = inst
            self._stop_threads = threading.Event()
            threading.Thread(target=self._heartbeat, args=(inst, self._stop_threads), daemon=True).start()
            threading.Thread(target=self._follow_log, args=(inst, self._stop_threads), daemon=True).start()
            self._wait_until_running(inst, progress)
            return inst
        except BaseException as e:
            tail = self.log_tail(30)
            self.stop_instance()
            if self.instance is not None:      # stop_instance could not remove it: say so with the cause
                raise
            if volume is not None:
                try:
                    self.docker.remove_volume(volume)
                except DockerError:
                    pass
            if isinstance(e, DockerError):
                raise ServerError(str(e) + ("\n\nThe log's last lines:\n" + tail if tail else "")) from e
            raise
        finally:
            self._launching = False

    def _wait_until_running(self, inst: Instance, progress, timeout: float = 120) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if inst.state == "stopping":
                raise ServerError("Stopped while starting.")
            r = self.docker.exec(inst.cid, ["lsdctl", "status"], timeout=20)
            if r.returncode == 0 and any(line.startswith("server:") and line.split()[1] == "running"
                                         for line in r.stdout.splitlines()):
                inst.state = "running"
                return
            progress("Waiting for the server to answer...")
            time.sleep(1)
        raise ServerError("The server did not come up in %d seconds.\n\nThe log's last lines:\n%s"
                          % (timeout, self.log_tail(30)))

    def _heartbeat(self, inst: Instance, stop: threading.Event) -> None:
        while not stop.wait(HEARTBEAT_EVERY):
            try:
                self.docker.exec(inst.cid, ["touch", HEARTBEAT], timeout=10)
            except Gone:
                if self.instance is inst and inst.state == "running":
                    inst.state = "error"
                    self._log_add("The server's container is gone.")
                return
            except DockerError:
                pass

    def _follow_log(self, inst: Instance, stop: threading.Event) -> None:
        try:
            p = self.docker.logs_follow(inst.cid)
        except (DockerError, OSError) as e:
            self._log_add(f"(the log cannot be read: {e})")
            return
        try:
            for line in p.stdout:
                self._log_add(line.rstrip("\n"))
                if stop.is_set():
                    break
        finally:
            p.kill()
            p.wait()

    def _log_add(self, line: str) -> None:
        self._log.append(line)
        self._log_count += 1

    def log_since(self, count: int) -> tuple[int, list[str]]:
        """The log lines after the first `count`: (the new count, the lines)."""
        total, lines = self._log_count, list(self._log)
        new = min(total - count, len(lines))
        return total, lines[len(lines) - new:] if new > 0 else []

    def log_tail(self, n: int = 30) -> str:
        return "\n".join(list(self._log)[-n:])

    def check_alive(self) -> bool:
        """Is the server's container still there? Marks the instance if not."""
        inst = self.instance
        if inst is None:
            return False
        if self.docker.is_running(inst.cid):
            return True
        if inst.state in ("running", "starting"):
            inst.state = "error"
        return False

    def forget_dead_instance(self) -> None:
        """After the container went by itself: remove what is left of it."""
        self.stop_instance()

    # ---- operations ---------------------------------------------------------

    def _need(self) -> Instance:
        inst = self.instance
        if inst is None or inst.state not in ("running", "starting"):
            raise ServerError("The server is not running. Launch it first.")
        return inst

    def _tool(self, argv: list[str], text: str | None, timeout: float, need_server: bool):
        """Run a tool of the image: in the server's container when there is one,
        else (for what needs no server) in a short run of the image."""
        inst = self.instance
        if inst is not None and inst.state in ("running", "starting"):
            return self.docker.exec(inst.cid, argv, input=text, timeout=timeout)
        if need_server:
            raise ServerError("The server is not running. Launch it first.")
        if self.image is None:
            raise ServerError("No usable image yet: checking needs Docker and an image that has the bots commands.")
        # the image's entrypoint runs `lsdctl <args>`; bttree is asked for by name
        if argv[0] == "lsdctl":
            return self.docker.run_helper(self.image, argv[1:], input=text, timeout=timeout)
        return self.docker.run_helper(self.image, argv[1:], entrypoint=argv[0], input=text, timeout=timeout)

    def _json(self, args: list[str], text: str | None = None, timeout: float = 30, need_server: bool = True) -> dict:
        try:
            r = self._tool(["lsdctl", "bots", *args, "--json"], text, timeout, need_server)
        except DockerError as e:
            raise ServerError(str(e)) from e
        try:
            doc = json.loads(r.stdout)
            if not isinstance(doc, dict):
                raise ValueError
        except ValueError:
            said = (r.stderr.strip() or r.stdout.strip() or "no answer")[:2000]
            raise ServerError("The server's answer could not be read: " + said) from None
        if doc.get("format") == "lsd-bt-error":
            raise ServerError(doc.get("error") or "The command failed.", doc.get("diagnostics"))
        return doc

    def trees(self) -> dict:
        return self._json(["trees"], need_server=False)

    def tree_text(self, name: str) -> str:
        """One tree's canonical text (the operator's, if there is one of that name)."""
        return self._text(["lsdctl", "bots", "tree", name])

    def file_text(self, path: str) -> str:
        """A whole tree file of the server, as canonical text. `path` must be
        one that `trees()` listed: no other path is ever passed on."""
        if path not in {t.get("file") for t in self.trees().get("trees", [])}:
            raise ServerError("The server has no tree file " + path)
        return self._text(["bttree", "--format", path])

    def _text(self, argv: list[str]) -> str:
        try:
            r = self._tool(argv, None, 30, False)
        except DockerError as e:
            raise ServerError(str(e)) from e
        if r.returncode != 0:
            raise ServerError((r.stderr.strip() or r.stdout.strip() or "The command failed.")[:2000])
        return r.stdout

    def check(self, text: str) -> dict:
        """`lsd-bt-check`: ok, trees, every diagnostic. Works without a server."""
        return self._json(["check", "-"], text, need_server=False)

    def format(self, text: str) -> str:
        """The canonical text. Raises ServerError with diagnostics if it does not compile."""
        return self._json(["format", "-"], text, need_server=False)["text"]

    def ast(self, text: str) -> dict:
        """The text as a structure (`lsd-bt`), by the engine's own parser."""
        try:
            r = self._tool(["bttree", "--json", "-"], text, 30, False)
        except DockerError as e:
            raise ServerError(str(e)) from e
        try:
            doc = json.loads(r.stdout)
            if doc.get("format") != "lsd-bt":
                raise ValueError
        except (ValueError, AttributeError):
            raise ServerError((r.stderr.strip() or r.stdout.strip() or "no structure")[:2000]) from None
        return doc

    def from_json(self, doc: dict) -> str:
        """A structure made text by the engine (`bttree --from-json`): refused
        with the engine's own words if it is not a tree."""
        try:
            r = self._tool(["bttree", "--from-json", "-"], json.dumps(doc), 30, False)
        except DockerError as e:
            raise ServerError(str(e)) from e
        if r.returncode != 0 or not r.stdout.strip():
            said = (r.stderr.strip() or r.stdout.strip() or "the engine did not make it text")
            raise ServerError(said.replace("bttree: --from-json: ", "")[:2000])
        return r.stdout

    def remake(self, doc: dict) -> tuple[str, dict, dict]:
        """An edited structure, through the engine, in one call: its text
        (`bttree --from-json`), the check of that text (every mistake,
        references too: `lsdctl bots check`) and its structure again
        (`bttree --json`). Raises ServerError -- with the diagnostics when
        there are some -- if it is not a tree; then nothing is changed."""
        try:
            r = self._tool(["sh", "-c", REMAKE], json.dumps(doc), 30, False)
        except DockerError as e:
            raise ServerError(str(e)) from e
        if r.returncode == 3 or MARK not in r.stdout:
            said = (r.stderr.strip() or r.stdout.strip() or "the engine did not make it text")
            raise ServerError("The engine refused it: " + said.replace("bttree: --from-json: ", "")[:2000])
        text, checked, tree = r.stdout.split(MARK + "\n", 2)
        try:
            checked, tree = json.loads(checked), json.loads(tree)
        except ValueError:
            raise ServerError("The engine's answer could not be read: " + r.stdout[-500:]) from None
        if not checked.get("ok"):
            raise ServerError("The engine refused it: " + "; ".join(
                d.get("message", "") for d in checked.get("diagnostics", [])), checked.get("diagnostics"))
        if tree.get("format") != "lsd-bt":
            raise ServerError("The engine gave no structure back.")
        return text, checked, tree

    def split(self, text: str, tree: str | None, words: dict[str, float], n: int = 700, level: int = 5) -> dict:
        """Who would do what (`bttree --split --json`): a crowd rolled, the
        tree ticked once for each in the situation given."""
        argv = ["bttree", "--split", "--json", "--n", str(n), "--level", str(level)]
        if tree:
            argv += ["--tree", tree]
        argv += ["-"] + [f"{k}={v:g}" for k, v in words.items()]
        try:
            r = self._tool(argv, text, 30, False)
        except DockerError as e:
            raise ServerError(str(e)) from e
        try:
            doc = json.loads(r.stdout)
            if doc.get("format") != "lsd-bt-split":
                raise ValueError
        except (ValueError, AttributeError):
            raise ServerError("This image cannot say who chooses what (its bttree has no --split --json): "
                              "use an image built from this repository.") from None
        return doc

    def bots(self) -> dict:
        self._need()
        return self._json(["list"], timeout=15)

    def apply_all(self, text: str) -> dict:
        """The text becomes the world's tree. Refused whole if it does not compile."""
        self._need()
        return self._json(["apply", "-", "--all"], text, timeout=60)

    def revert_all(self) -> dict:
        """Every bot back to the game's tree: the world's tree reverted, and
        each bot that was given one of its own (`--all` alone leaves those)."""
        self._need()
        world = self._json(["revert", "--all"], timeout=60)
        try:
            each = self._json(["revert", "--each"], timeout=60)
            world["bots"] = each.get("bots", world.get("bots", []))
        except ServerError:
            pass                               # no engine bot: nothing more to give back
        return world

    @staticmethod
    def _whom(bots: list[int] | None = None, team: int | None = None, kind: str | None = None) -> list[str]:
        whom = []
        if bots:
            whom += ["--bot", ",".join(str(int(b)) for b in bots)]
        if team is not None:
            whom += ["--team", str(int(team))]
        if kind:
            if not kind.replace("_", "").isalnum():
                raise ServerError("No kind of bot is called " + kind)
            whom += ["--archetype", kind]
        if not whom:
            raise ServerError("Say which bots: choose some in the table, a team or a kind.")
        return whom

    def apply_to(self, text: str, bots: list[int] | None = None, team: int | None = None,
                 kind: str | None = None) -> dict:
        """The text to those bots only, each as its own tree. Refused whole if it does not compile."""
        self._need()
        return self._json(["apply", "-", *self._whom(bots, team, kind)], text, timeout=60)

    def revert_to(self, bots: list[int] | None = None, team: int | None = None, kind: str | None = None) -> dict:
        """Those bots back to the world's tree."""
        self._need()
        return self._json(["revert", *self._whom(bots, team, kind)], timeout=60)

    def save(self, name: str, text: str) -> dict:
        """Keep the text as the operator's tree file; the server validates the name."""
        self._need()
        return self._json(["save", name, "-"], text)

    def set_bots(self, team1: int, team2: int | None = None) -> str:
        """Change the bot count on the running server. It restarts the server."""
        inst = self._need()
        if team2 is None or one_team(inst.gamemode):
            steps = [["bots", str(team1), "--now"]]
        else:
            steps = [["bots", str(max(team1, team2)), "--no-restart"]]
            if max(team1, team2) > 0:
                steps += [["set", "engine_bots_team1", str(team1), "--no-restart"],
                          ["set", "engine_bots_team2", str(team2), "--no-restart"]]
            steps.append(["restart", "--now"])
        said = []
        for step in steps:
            try:
                r = self.docker.exec(inst.cid, ["lsdctl", *step], timeout=60)
            except DockerError as e:
                raise ServerError(str(e)) from e
            if r.returncode != 0:
                raise ServerError("The bots could not be changed: " + (r.stderr or r.stdout).strip())
            said.append(r.stdout.strip())
        return "\n".join(s for s in said if s)
