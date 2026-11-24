#!/usr/bin/env python3
# fake_docker.py -- a stand-in for the docker command, for the tests
# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""Installed as `docker` on the tests' PATH. It records every call in
$FAKE_DOCKER_DIR/calls.jsonl, keeps containers and volumes in
state.json, and answers the server's commands from tests/fixtures (real
answers, captured from a real run)."""
import fcntl
import json
import os
import re
import secrets
import sys
import time
from pathlib import Path

HOME = Path(os.environ["FAKE_DOCKER_DIR"])
FIXTURES = Path(__file__).resolve().parent / "fixtures" if "FAKE_DOCKER_FIXTURES" not in os.environ \
    else Path(os.environ["FAKE_DOCKER_FIXTURES"])
argv = sys.argv[1:]
stdin = sys.stdin.read() if ("-i" in argv and argv[0] in ("run", "exec")) else ""


def fixture(name):
    return (FIXTURES / name).read_text()


def out(text, code=0):
    sys.stdout.write(text if text.endswith("\n") or not text else text + "\n")
    sys.exit(code)


def fail(text, code=1):
    sys.stderr.write(text + "\n")
    sys.exit(code)


BTTREE = os.environ.get("FAKE_DOCKER_BTTREE")       # the real engine, built for this computer, when a test wants it
MARK = "@@lsd-tree-editor@@"


def real(argv, text):
    import subprocess
    p = subprocess.run([BTTREE, *argv], input=text, capture_output=True, text=True)
    return p.stdout, p.stderr, p.returncode


def remake(text):
    """What the editor's one-call remake gives (server.REMAKE), from the real engine."""
    import tempfile
    if not BTTREE:
        sys.stderr.write("fake docker: no engine to make the text\n")
        sys.exit(3)
    made, err, code = real(["--from-json", "-"], text)
    if code != 0:
        sys.stderr.write(err)
        sys.exit(3)
    with tempfile.NamedTemporaryFile("w", suffix=".bt", delete=False) as f:
        f.write(made)
    chk, _, _ = real(["--check", "--json", f.name], None)
    names, _, _ = real(["--list", "--json", f.name], None)
    doc = json.loads(chk)
    for d in doc["diagnostics"]:
        d.pop("file", None)
    checked = {"format": "lsd-bt-check", "version": 1, "ok": doc["ok"],
               "trees": [t["name"] for t in json.loads(names or '{"trees": []}').get("trees", [])] if doc["ok"] else [],
               "diagnostics": doc["diagnostics"]}
    tree, _, _ = real(["--json", f.name], None)
    os.unlink(f.name)
    return made + MARK + "\n" + json.dumps(checked) + "\n" + MARK + "\n" + tree, 0


def tool(args, text):
    """What the image's tools answer: (output, exit status)."""
    if args[:2] == ["sh", "-c"] and MARK in args[2]:
        return remake(text)
    if args[:1] == ["bttree"] and "--split" in args:
        if BTTREE:
            o, e, c = real(args[1:], text)
            return o, c
        return fixture("split.json"), 0
    if args[:1] == ["bttree"] and BTTREE:
        o, e, c = real(args[1:], text)
        if c:
            sys.stderr.write(e)
        return o, c
    if args[:1] == ["bttree"]:
        if "--json" in args:
            return (fixture("ast.json"), 0) if "figth" not in text else ("", 1)
        if "--format" in args:
            return fixture("first.bt"), 0
    if args[:2] == ["lsdctl", "status"]:
        return "lsd-docker dev\nserver:     running\ngamemode:   tdm\n", 0
    if args[:2] == ["lsdctl", "bots"]:
        sub = args[2] if len(args) > 2 else ""
        bad = "figth" in text
        if sub == "schema":
            return fixture("schema.json"), 0
        if sub == "trees":
            return fixture("trees.json"), 0
        if sub == "tree":
            return fixture("first.bt"), 0
        if sub == "list":
            return fixture("bots.json"), 0
        if sub == "check":
            if not text:
                return fixture("check_empty.json"), 1
            return (fixture("check_bad.json"), 1) if bad else (fixture("check_ok.json"), 0)
        if sub == "format":
            return (fixture("format_refused.json"), 1) if bad else (fixture("format_ok.json"), 0)
        if sub == "apply":
            return (fixture("apply_refused.json"), 1) if bad else (fixture("apply_ok.json"), 0)
        if sub == "revert":
            return fixture("revert_ok.json"), 0
        if sub == "save":
            ok = re.fullmatch(r"[A-Za-z0-9_-]{1,31}", args[3] if len(args) > 3 else "")
            return (fixture("save_ok.json"), 0) if ok and not bad else (fixture("save_bad_name.json"), 1)
        return "server restarting\n", 0
    if args[:1] == ["lsdctl"]:
        return "ok\n", 0
    return "", 0


def main():
    lock = open(HOME / "lock", "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    state_file = HOME / "state.json"
    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    state.setdefault("containers", {})
    state.setdefault("volumes", {})
    state.setdefault("images", ["lsd-tree-editor-test:dev", "old:image"])
    with open(HOME / "calls.jsonl", "a") as f:
        f.write(json.dumps({"argv": argv, "stdin": stdin, "pid": os.getppid()}) + "\n")

    def save():
        state_file.write_text(json.dumps(state))

    def find(ref):
        for cid, c in state["containers"].items():
            if ref in (cid, c["name"]) or (len(ref) >= 12 and cid.startswith(ref)):
                return cid
        return None

    def matching(things, filters):
        hit = []
        for key, labels in things:
            if all(labels.get(k) == v for k, v in filters):
                hit.append((key, labels))
        return hit

    def filters():
        got = []
        for i, a in enumerate(argv):
            if a == "--filter" and argv[i + 1].startswith("label="):
                k, _, v = argv[i + 1][6:].partition("=")
                got.append((k, v))
        return got

    def formatted(rows):
        fmt = argv[argv.index("--format") + 1] if "--format" in argv else None
        lines = []
        for key, labels in rows:
            if fmt is None:
                lines.append(key)
            else:
                line = re.sub(r"\{\{\.(ID|Name)\}\}", key, fmt)
                line = re.sub(r'\{\{\.Label "([^"]+)"\}\}', lambda m: labels.get(m.group(1), ""), line)
                lines.append(line)
        return "\n".join(lines)

    if os.environ.get("FAKE_DOCKER_DOWN"):
        fail("Cannot connect to the Docker daemon. Is the docker daemon running?")
    verb = argv[0]
    if verb == "version":
        out("27.0.0")
    if verb == "image" and argv[1] == "inspect":
        out("sha256:feed") if argv[-1] in state["images"] else fail("Error: No such image: " + argv[-1])
    if verb == "pull":
        state["images"].append(argv[-1]); save(); out(argv[-1])
    if verb == "volume":
        sub = argv[1]
        if sub == "create":
            labels = dict(a.split("=", 1) for i, a in enumerate(argv) if argv[i - 1] == "--label")
            state["volumes"][argv[-1]] = labels; save(); out(argv[-1])
        if sub == "ls":
            out(formatted(matching(state["volumes"].items(), filters())))
        if sub == "inspect":
            if argv[-1] not in state["volumes"]:
                fail("Error response from daemon: get %s: no such volume" % argv[-1])
            out(json.dumps(state["volumes"][argv[-1]]))
        if sub == "rm":
            if argv[-1] not in state["volumes"]:
                fail("Error response from daemon: get %s: no such volume" % argv[-1])
            del state["volumes"][argv[-1]]; save(); out(argv[-1])
        fail("fake docker: volume " + sub)
    if verb == "ps":
        rows = matching([(cid, c["labels"]) for cid, c in state["containers"].items()], filters())
        out(formatted(rows))
    if verb == "inspect":
        cid = find(argv[-1])
        if cid is None:
            fail("Error response from daemon: No such container: " + argv[-1])
        fmt = argv[argv.index("--format") + 1]
        out(json.dumps(state["containers"][cid]["labels"]) if "Labels" in fmt else "true")
    if verb == "rm":
        cid = find(argv[-1])
        if cid is None:
            fail("Error response from daemon: No such container: " + argv[-1])
        del state["containers"][cid]; save(); out(argv[-1])
    if verb == "logs":
        if find(argv[-1]) is None:
            fail("Error response from daemon: No such container: " + argv[-1])
        out("lsd-docker dev: starting the server on 32887/udp\nbotd: attached")
    if verb == "exec":
        rest = [a for a in argv[1:] if a != "-i"]
        if find(rest[0]) is None:
            fail("Error response from daemon: No such container: " + rest[0])
        if os.environ.get("FAKE_DOCKER_SLOW"):
            lock.close(); time.sleep(float(os.environ["FAKE_DOCKER_SLOW"]))
        out(*tool(rest[1:], stdin))
    if verb == "run":
        opts, labels, i = {}, {}, 1
        valued = {"--name", "--label", "-p", "-v", "-e", "--entrypoint"}
        while i < len(argv) and argv[i].startswith("-"):
            if argv[i] in valued:
                if argv[i] == "--label":
                    k, _, v = argv[i + 1].partition("=")
                    labels[k] = v
                opts.setdefault(argv[i], []).append(argv[i + 1])
                i += 2
            else:
                opts[argv[i]] = True
                i += 1
        image, args = argv[i], argv[i + 1:]
        if image not in state["images"]:
            fail("Unable to find image '%s' locally" % image, 125)
        if "-d" in opts:
            if os.environ.get("FAKE_DOCKER_RUN_FAILS"):
                fail("docker: Error response from daemon: driver failed programming external connectivity", 125)
            cid = secrets.token_hex(32)
            state["containers"][cid] = {"name": opts["--name"][0], "labels": labels, "image": image}
            save(); out(cid)
        if image == "old:image":
            out('lsdctl: no command "bots" (lsdctl help)')
        entry = opts.get("--entrypoint", ["entrypoint"])[0]
        if entry == "sh":
            if MARK in args[-1]:
                out(*tool(["sh", "-c", args[-1]], stdin))
            if "lsdctl gamemode;" in args[-1]:
                out("  ctf        Grab the enemy intel.\n  parkour    One team.\n* tdm        Two teams.\n  babel      A tower.\n==\n"
                    + fixture("trees.json"))
            out("added Fake.vxl from aos.party, with its .txt")
        if entry == "bttree":
            out(*tool(["bttree", *args], stdin))
        out(*tool(["lsdctl", *args], stdin))
    fail("fake docker: unknown command " + " ".join(argv))


main()
