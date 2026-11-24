# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""The docker layer: what it refuses, and what the sweep removes."""
import pytest

from conftest import acting
from lsd_tree_editor.docker import LABEL, LABEL_PID, LABEL_SESSION, Docker, Refused

OURS = "11111111-1111-1111-1111-111111111111"
OTHER = "22222222-2222-2222-2222-222222222222"


def labels(session, pid="1"):
    return {LABEL: "1", LABEL_SESSION: session, LABEL_PID: pid}


def test_refuses_what_it_did_not_create(fake):
    fake.seed(containers={
        "aaa0": {"name": "lsd-demo", "labels": {}},
        "bbb0": {"name": "lsd-tree-editor-abc123", "labels": labels(OTHER)},
    }, volumes={"lsd-demo": {}, "lsd-tree-editor-abc123": labels(OTHER)})
    d = Docker(OURS, 4242)
    for target in ("lsd-demo", "aaa0", "bbb0", "lsd-tree-editor-abc123", "anything"):
        for act in (lambda: d.exec(target, ["lsdctl", "status"]), lambda: d.remove_container(target),
                    lambda: d.logs_follow(target), lambda: d.is_running(target),
                    lambda: d.remove_volume(target),
                    lambda: d.run_helper("lsd-tree-editor-test:dev", ["status"], volume=target),
                    lambda: d.run_server("lsd-tree-editor-test:dev", "x", target, 32888, entrypoint="sh", args=[])):
            with pytest.raises(Refused):
                act()
    assert fake.calls() == []                 # not one docker command was run
    assert set(fake.state()["containers"]) == {"aaa0", "bbb0"}


def test_refuses_a_container_named_like_ours_with_another_label(fake):
    """Even a target wrongly taken for ours is refused when its label says otherwise."""
    fake.seed(containers={"bbb0": {"name": "lsd-tree-editor-abc123", "labels": labels(OTHER)},
                          "ccc0": {"name": "lsd-demo", "labels": {}}},
              volumes={"lsd-demo": {}})
    d = Docker(OURS, 4242)
    d._owned[("container", "bbb0")] = OURS
    d._owned[("container", "lsd-demo")] = OURS
    d._owned[("volume", "lsd-demo")] = OURS
    for act in (lambda: d.remove_container("bbb0"), lambda: d.exec("bbb0", ["sh"]),
                lambda: d.remove_container("lsd-demo"), lambda: d.exec("lsd-demo", ["sh"]),
                lambda: d.remove_volume("lsd-demo")):
        with pytest.raises(Refused):
            act()
    assert {verb for verb, _ in acting(fake.calls())} <= {"inspect", "volume inspect"}   # it looked, and did nothing
    assert set(fake.state()["containers"]) == {"bbb0", "ccc0"}
    assert set(fake.state()["volumes"]) == {"lsd-demo"}


def test_verbs_it_never_runs(fake):
    d = Docker(OURS, 4242)
    for args in (["system", "prune", "-f"], ["container", "prune"], ["volume", "prune"], ["image", "rm", "x"],
                 ["rmi", "x"], ["stop", "lsd-demo"], ["kill", "lsd-demo"], ["restart", "lsd-demo"], ["cp", "a", "b"],
                 ["build", "."], ["tag", "a", "b"], ["network", "rm", "x"]):
        with pytest.raises(Refused):
            d._run(args)
    for args in (["rm", "-f", "lsd-demo"], ["exec", "lsd-demo", "sh"], ["volume", "rm", "lsd-demo"],
                 ["logs", "lsd-demo"], ["inspect", "lsd-demo"]):
        with pytest.raises(Refused):          # the acting verbs: only through the guard
            d._run(args)
    assert fake.calls() == []


def test_what_it_creates_is_labelled_and_can_be_removed(fake):
    d = Docker(OURS, 4242)
    d.create_volume("lsd-tree-editor-zz")
    cid = d.run_server("lsd-tree-editor-test:dev", "lsd-tree-editor-zz", "lsd-tree-editor-zz", 32888,
                       entrypoint="/sbin/tini", args=["--", "sh", "-c", "x"])
    state = fake.state()
    assert state["containers"][cid]["labels"][LABEL_SESSION] == OURS
    assert state["containers"][cid]["labels"][LABEL_PID] == "4242"
    assert state["volumes"]["lsd-tree-editor-zz"][LABEL] == "1"
    assert d.exec(cid, ["lsdctl", "status"]).returncode == 0
    assert d.remove_container(cid) is True
    assert d.remove_container(cid) is False   # gone already: said so, nothing run on it
    assert d.remove_volume("lsd-tree-editor-zz") is True
    assert fake.state()["containers"] == {} and fake.state()["volumes"] == {}


def test_sweep_removes_only_labelled_orphans(fake):
    fake.seed(containers={
        "demo": {"name": "lsd-demo", "labels": {}},
        "dead": {"name": "lsd-tree-editor-dead01", "labels": labels(OTHER, "999001")},
        "live": {"name": "lsd-tree-editor-live01", "labels": labels("33333333", "777")},
        "nosession": {"name": "lsd-tree-editor-odd", "labels": {LABEL: "1"}},
        "foreign": {"name": "postgres", "labels": {"com.example": "1"}},
    }, volumes={
        "lsd-demo": {}, "lsd-data": {},
        "lsd-tree-editor-dead01": labels(OTHER, "999001"),
        "lsd-tree-editor-live01": labels("33333333", "777"),
    })
    d = Docker(OURS, 4242)
    removed = d.sweep_orphans(lambda pid: pid == 777)
    assert removed == ["container dead", "volume lsd-tree-editor-dead01"]
    state = fake.state()
    assert set(state["containers"]) == {"demo", "live", "nosession", "foreign"}
    assert set(state["volumes"]) == {"lsd-demo", "lsd-data", "lsd-tree-editor-live01"}
    assert [c for c in acting(fake.calls()) if c[0] in ("rm", "volume rm", "exec")] == \
        [("rm", "dead"), ("volume rm", "lsd-tree-editor-dead01")]
    assert all(target in ("dead", "lsd-tree-editor-dead01") for _, target in acting(fake.calls()))
    with pytest.raises(Refused):              # adopted for the sweep only
        d.remove_container("dead")
