# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""The session: the one server, the operations, and how it ends."""
import collections
import json
import signal

import pytest

from conftest import FIXTURES, acting, read_until, wait_for
from lsd_tree_editor.docker import LABEL, LABEL_PID, LABEL_SESSION
from lsd_tree_editor.server import ImageTooOld, ServerError, Setup

IMAGE = "lsd-tree-editor-test:dev"
GOOD = (FIXTURES / "first.bt").read_text()
BAD = (FIXTURES / "bad.bt").read_text()


def launch(session):
    return session.launch(Setup(image=IMAGE, gamemode="tdm", bots_team1=3, bots_team2=2))


def test_only_one_server(session, fake):
    inst = launch(session)
    assert inst.state == "running" and inst.name.startswith("lsd-tree-editor-") and inst.port >= 32888
    assert inst.urls[-1] == f"aos://127.0.0.1:{inst.port}"
    with pytest.raises(ServerError, match="only one"):
        launch(session)
    assert len([c for c in fake.calls() if c[:2] == ["run", "-d"]]) == 1
    assert len(fake.state()["containers"]) == 1


def test_the_server_is_set_up_as_asked_and_unlisted(session, fake):
    inst = launch(session)
    run = next(c for c in fake.calls() if c[:2] == ["run", "-d"])
    assert f"{inst.port}:32887/udp" in run and f"{inst.name}:/data" in run and "--rm" in run
    assert f"{LABEL_SESSION}={session.id}" in run and f"{LABEL}=1" in run
    assert "--restart" not in run
    setup = next(c for c in fake.calls() if c[0] == "run" and "GAME=tdm" in c)
    assert {"BOTS=3", "TEAM1=3", "TEAM2=2", "LEVEL=5", "MAP=random"} <= set(setup)
    assert "masterlist_enabled false" in setup[-1]


def test_an_image_without_the_bots_commands_is_refused(session, fake):
    with pytest.raises(ImageTooOld, match="too old"):
        session.launch(Setup(image="old:image"))
    assert session.instance is None
    assert not [c for c in fake.calls() if c[:2] == ["run", "-d"] or c[:2] == ["volume", "create"]]


def test_a_failed_start_leaves_nothing(session, fake, monkeypatch):
    monkeypatch.setenv("FAKE_DOCKER_RUN_FAILS", "1")
    with pytest.raises(ServerError, match="could not be started"):
        launch(session)
    assert session.instance is None
    assert fake.state()["containers"] == {} and fake.state()["volumes"] == {}
    monkeypatch.delenv("FAKE_DOCKER_RUN_FAILS")
    assert launch(session).state == "running"      # and it can be tried again


def test_check_gives_every_diagnostic(session):
    launch(session)
    doc = session.check(BAD)
    assert doc["ok"] is False
    assert [(d["line"], d["column"]) for d in doc["diagnostics"]] == [(4, 19), (5, 6), (6, 11)]
    assert "figth" in doc["diagnostics"][1]["message"]
    assert session.check(GOOD) == json.loads((FIXTURES / "check_ok.json").read_text())


def test_check_without_a_server_uses_the_image(session, fake):
    with pytest.raises(ServerError, match="No usable image"):
        session.check(GOOD)
    session.probe_image(IMAGE)
    assert session.gamemodes == ["tdm", "ctf", "parkour"]
    assert session.check(BAD)["ok"] is False
    assert session.ast(GOOD)["files"][0]["trees"][0]["name"] == "first"
    last = fake.calls()[-1]
    assert last[:2] == ["run", "--rm"] and last[-3:] == [IMAGE, "--json", "-"] and "bttree" in last
    assert not [c for c in fake.calls() if c[0] == "exec"]
    with pytest.raises(ServerError, match="not running"):
        session.bots()
    with pytest.raises(ServerError, match="not running"):
        session.apply_all(GOOD)


def test_apply_ok_refused_and_revert(session, fake):
    launch(session)
    done = session.apply_all(GOOD)
    assert done["ok"] and done["scope"] == "world" and done["world"] == "mine" and len(done["bots"]) == 6
    sent = [r for r in fake.records() if r["argv"][0] == "exec" and "apply" in r["argv"]][-1]
    assert sent["argv"][-6:] == ["lsdctl", "bots", "apply", "-", "--all", "--json"] and sent["stdin"] == GOOD
    with pytest.raises(ServerError) as e:
        session.apply_all(BAD)
    assert "nothing was changed" in e.value.message
    assert [d["line"] for d in e.value.diagnostics] == [4, 5, 6]
    assert session.revert_all()["action"] == "revert"


def test_save_and_its_refusal_for_a_bad_name(session):
    launch(session)
    assert session.save("mine", GOOD)["file"] == "/data/trees/mine.bt"
    with pytest.raises(ServerError, match="letters, digits"):
        session.save("../evil", GOOD)


def test_format_and_the_other_reads(session):
    launch(session)
    assert session.format(GOOD).startswith("tree mine:")
    with pytest.raises(ServerError) as e:
        session.format(BAD)
    assert len(e.value.diagnostics) == 3
    assert len(session.bots()["bots"]) == 6
    assert session.file_text("/opt/botd/trees/ctf.bt")
    with pytest.raises(ServerError, match="no tree file"):
        session.file_text("/etc/passwd")          # only a path the server listed is ever passed on


def test_exit_removes_the_server_and_its_volume_once(session, fake):
    inst = launch(session)
    assert session.shutdown() is None
    assert session.shutdown() is None              # again (atexit after the window's own): nothing more
    calls = fake.calls()
    assert [c for c in calls if c[0] == "rm"] == [["rm", "-f", inst.cid]]
    assert [c for c in calls if c[:2] == ["volume", "rm"]] == [["volume", "rm", inst.name]]
    assert fake.state()["containers"] == {} and fake.state()["volumes"] == {}
    assert not session.lock.path.exists()
    with pytest.raises(ServerError):
        launch(session)                            # closing: no new server


def test_a_whole_session_runs_nothing_outside_the_allowed_set(session, fake):
    """Launch, edit, apply, exit: every docker command, by verb and target."""
    fake.seed(containers={"demo": {"name": "lsd-demo", "labels": {}}}, volumes={"lsd-demo": {}})
    inst = launch(session)
    wait_for(lambda: any(c[0] == "logs" for c in fake.calls()))
    session.check(BAD), session.check(GOOD), session.ast(GOOD), session.format(GOOD)
    session.trees(), session.bots(), session.apply_all(GOOD), session.revert_all(), session.save("mine", GOOD)
    session.set_bots(4, 4)
    session.shutdown()
    calls = fake.calls()
    cid, name = inst.cid, inst.name

    # 1. what is not aimed at a container or a volume: only these verbs
    free = collections.Counter((c[0], c[1]) if c[0] in ("volume", "image") else (c[0],) for c in calls
                               if c[0] not in ("exec", "rm", "logs", "inspect") and c[:2] not in (["volume", "rm"], ["volume", "inspect"]))
    assert free == {("ps",): 1, ("volume", "ls"): 1,      # the sweep at start
                    ("version",): 1,
                    ("run",): 5,                               # two questions to the image, two set-up steps, the server
                    ("volume", "create"): 1}
    runs = [c for c in calls if c[0] == "run"]
    assert all(IMAGE in c and f"{LABEL_SESSION}={session.id}" in c and any(x.startswith(LABEL_PID) for x in c)
               for c in runs)
    assert all(v == f"{name}:/data" for c in runs for i, v in enumerate(c) if c[i - 1] == "-v")
    assert [c[:2] for c in calls if c[0] == "ps"] == [["ps", "-a"]]
    assert all(f"label={LABEL}=1" in c for c in calls if c[0] == "ps" or c[:2] == ["volume", "ls"])

    # 2. what is aimed at one: only at this run's container and volume, exactly these
    acts = acting(calls)
    assert {t for _, t in acts} == {cid, name}
    assert collections.Counter(acts) == {
        ("volume inspect", name): 4,   # before each use of the volume: two set-up runs, the server's run, its removal
        ("inspect", cid): 17,          # before each command on the container
        # revert_all is two commands now (--all, then --each for the bots given a tree of their own)
        ("exec", cid): 15, ("logs", cid): 1, ("rm", cid): 1, ("volume rm", name): 1}
    assert acts[-4:] == [("inspect", cid), ("rm", cid), ("volume inspect", name), ("volume rm", name)]
    execs = [c[c.index(cid) + 1:] for c in calls if c[0] == "exec"]
    assert all(e[0] in ("lsdctl", "bttree") for e in execs)
    # 3. the owner's demo is as it was
    assert fake.state() == {"containers": {"demo": {"name": "lsd-demo", "labels": {}}}, "volumes": {"lsd-demo": {}},
                            "images": fake.state()["images"]}


@pytest.mark.parametrize("sig", [signal.SIGTERM, signal.SIGINT, signal.SIGHUP])
def test_a_signal_removes_the_server_before_the_program_ends(fake, sig):
    app = fake.app("--headless", "--launch", "--image", IMAGE)
    name = read_until(app, "READY")[-1].split()[1]
    (cid,) = fake.state()["containers"]
    app.send_signal(sig)
    assert app.wait(timeout=30) == 0
    calls = fake.calls()
    assert [c for c in calls if c[0] == "rm"] == [["rm", "-f", cid]]
    assert [c for c in calls if c[:2] == ["volume", "rm"]] == [["volume", "rm", name]]
    assert fake.state()["containers"] == {} and fake.state()["volumes"] == {}


def test_sigterm_to_the_window_removes_the_server(fake):
    """The real program with its window (offscreen), launched, then killed politely."""
    app = fake.app("--launch", "--image", IMAGE)
    try:
        assert wait_for(lambda: len(fake.state().get("containers", {})) == 1 and
                        any(c[0] == "exec" and "list" in c for c in fake.calls()), timeout=40)
        (cid,) = fake.state()["containers"]
        (name,) = fake.state()["volumes"]
        app.send_signal(signal.SIGTERM)
        assert app.wait(timeout=30) == 0
    finally:
        if app.poll() is None:
            app.kill()
    calls = fake.calls()
    assert [c for c in calls if c[0] == "rm"] == [["rm", "-f", cid]]
    assert [c for c in calls if c[:2] == ["volume", "rm"]] == [["volume", "rm", name]]
    assert fake.state()["containers"] == {} and fake.state()["volumes"] == {}


def test_the_next_start_sweeps_what_a_killed_run_left(fake):
    """kill -9: nothing is removed by the program; the next start removes its leftovers, and only those."""
    app = fake.app("--headless", "--launch", "--image", IMAGE)
    name = read_until(app, "READY")[-1].split()[1]
    (cid,) = fake.state()["containers"]
    state = fake.state()
    state["containers"]["demo"] = {"name": "lsd-demo", "labels": {}}
    state["volumes"]["lsd-demo"] = {}
    (fake.home / "state.json").write_text(json.dumps(state))
    app.kill()
    app.wait()
    assert set(fake.state()["containers"]) == {cid, "demo"}
    before = len(fake.calls())
    again = fake.app("--headless")
    read_until(again, "READY")
    again.send_signal(signal.SIGTERM)
    assert again.wait(timeout=20) == 0
    assert set(fake.state()["containers"]) == {"demo"} and set(fake.state()["volumes"]) == {"lsd-demo"}
    assert [c for c in acting(fake.calls()[before:]) if c[0] in ("rm", "volume rm")] == [("rm", cid), ("volume rm", name)]
