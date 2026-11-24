# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""The edits on the engine's JSON structure, pure; and each one made text
by the real engine (bttree built for this computer: `engine`), checked,
and read back."""
import json
import subprocess

import pytest

from conftest import FIXTURES
from lsd_tree_editor import model as M

SCHEMA = json.loads((FIXTURES / "schema.json").read_text())


def doc(name="tdm"):
    return json.loads((FIXTURES / "trees" / f"{name}.json").read_text())


def words(n):
    return n.get("text") or n.get("kind")


def test_paths_walk_and_lines():
    d = doc()
    assert M.tree_names(d)[:3] == ["tdm", "tdm_under_fire", "tdm_contact"]
    pick = M.node_at(d, ("tdm", (0,)))
    assert pick["kind"] == "pick" and len(pick["children"]) == 7
    assert M.node_at(d, ("tdm", (0, 0)))["score"] == "grenade_near"
    assert M.path_for_line(d, pick["line"]) == ("tdm", (0,))
    assert M.find(d, ("tdm", (9, 9))) is None
    with pytest.raises(M.EditError):
        M.node_at(d, ("nope", ()))
    assert len(M.uses(d, "tdm_contact")) == 1 and len(M.uses(d, "tdm_camper")) == 2


def test_move_by_reorders_and_keeps_the_original():
    d = doc()
    before = json.dumps(d)
    d2, sel = M.move_by(d, ("tdm", (0, 1)), -1)
    assert json.dumps(d) == before                       # never changed in place
    assert sel == ("tdm", (0, 0))
    assert [o["score"] for o in M.node_at(d2, ("tdm", (0,)))["children"][:2]] == ["harmful_water", "grenade_near"]
    with pytest.raises(M.EditError, match="first already"):
        M.move_by(d, ("tdm", (0, 0)), -1)
    with pytest.raises(M.EditError, match="root"):
        M.move_by(d, ("tdm", ()), 1)


def test_move_to_another_parent_and_not_into_itself():
    d = doc()
    # the `limit 1` (select's 2nd child) put first in the select: same parent
    d2, sel = M.move(d, ("tdm", (1,)), ("tdm", ()), 0, SCHEMA)
    assert sel == ("tdm", (0,)) and M.node_at(d2, sel)["kind"] == "limit"
    # an option moved to another pick, in another tree
    d3, sel = M.move(d, ("tdm", (0, 5)), ("tdm_contact", ()), 1, SCHEMA)
    assert sel == ("tdm_contact", (1,)) and M.node_at(d3, sel)["score"] == "search"
    assert len(M.node_at(d3, ("tdm", (0,)))["children"]) == 6
    # an option under a select: refused, with the reason
    with pytest.raises(M.EditError, match="only directly under a pick"):
        M.move(d, ("tdm", (0, 5)), ("tdm", ()), 0, SCHEMA)
    with pytest.raises(M.EditError, match="inside itself"):
        M.move(d, ("tdm", (0,)), ("tdm", (0, 1)), 0, SCHEMA)


def test_insert_follows_the_schema():
    d = doc()
    n = M.new_node(SCHEMA, "do", "fight", d, "tdm")
    assert n == {"kind": "do", "action": "fight", "args": []}
    d2, sel = M.insert(d, ("tdm", ()), 1, n, SCHEMA)
    assert sel == ("tdm", (1,)) and M.node_at(d2, sel)["action"] == "fight"
    with pytest.raises(M.EditError, match="only options"):
        M.insert(d, ("tdm", (0,)), 0, n, SCHEMA)          # under a pick
    with pytest.raises(M.EditError, match="holds one child"):
        M.insert(d, ("tdm", (0, 0)), 0, n, SCHEMA)        # an option has its child
    opt = M.new_node(SCHEMA, "option", "enemy_far", d)
    assert opt["trait"] == "none" and opt["score"] == "enemy_far" and opt["factor"] == 1
    assert opt["children"] == [M.PLACEHOLDER]
    seq = M.new_node(SCHEMA, "seq", None, d)
    assert seq["children"] == [M.PLACEHOLDER]             # a seq must hold something to compile
    assert M.new_node(SCHEMA, "tree", None, d, "tdm")["ref"] == "tdm_under_fire"


def test_delete_wrap_unwrap():
    d = doc()
    with pytest.raises(M.EditError, match="only child"):
        M.delete(d, ("tdm", (0, 0, 0)), SCHEMA)           # the option needs its child
    d2, sel = M.delete(d, ("tdm", (0, 6)), SCHEMA)
    assert sel == ("tdm", (0, 5)) and len(M.node_at(d2, ("tdm", (0,)))["children"]) == 6
    d3, sel = M.wrap(d, ("tdm", (0, 0, 0)), {"kind": "cooldown", "seconds": 3}, SCHEMA)
    w = M.node_at(d3, sel)
    assert w["kind"] == "cooldown" and w["children"][0]["action"] == "evade"
    d4, _ = M.unwrap(d3, sel)
    assert M.node_at(d4, sel)["action"] == "evade"
    with pytest.raises(M.EditError):
        M.wrap(d, ("tdm", (0, 0)), {"kind": "invert"}, SCHEMA)   # an option stays under its pick
    with pytest.raises(M.EditError):
        M.unwrap(d, ("tdm", (0,)))                       # a pick of seven


def test_extract_inline_rename():
    d = doc()
    d2, sel = M.extract(d, ("tdm", (1,)), "tdm_net")
    assert M.node_at(d2, sel) == {"kind": "tree", "ref": "tdm_net"}
    assert M.tree_names(d2)[1] == "tdm_net" and M.tree(d2, "tdm_net")["root"]["kind"] == "limit"
    with pytest.raises(M.EditError, match="already"):
        M.extract(d2, ("tdm", ()), "tdm_net")
    d3, sel = M.inline(d2, sel)
    assert M.node_at(d3, sel)["kind"] == "limit" and "id" not in M.node_at(d3, sel)
    d4, new = M.rename_tree(d, "tdm_camper", "tdm_waiter")
    assert new == "tdm_waiter" and len(M.uses(d4, "tdm_waiter")) == 2 and not M.uses(d4, "tdm_camper")
    with pytest.raises(M.EditError):
        M.rename_tree(d, "tdm_camper", "tdm_sniper")


def test_set_fields_drops_a_default_mark():
    d = doc()
    path = ("tdm_contact", (1,))                          # option aggression enemy_visible (factor a default)
    assert "factor" in M.node_at(d, path)["defaults"]
    d2, _ = M.set_fields(d, path, {"factor": 2.5, "comment": None})
    n = M.node_at(d2, path)
    assert n["factor"] == 2.5 and "factor" not in n["defaults"] and "comment" not in n


def test_history_moves_along_the_texts():
    h = M.History()
    for t in ("a", "b", "c"):
        h.push(t)
    assert h.undo()[0] == "b" and h.undo()[0] == "a" and h.undo() is None
    assert h.redo()[0] == "b"
    h.push("d")                                           # a new step drops what could be redone
    assert not h.can_redo() and [s[0] for s in h.states] == ["a", "b", "d"]
    h.push("d", ("x", ()))
    assert len(h.states) == 3 and h.states[-1][1] == ("x", ())


def test_blocks_bands_refs_and_folds():
    d = doc()
    top = M.build_blocks(d, "tdm")
    assert top.core[1]["kind"] == "select" and [k.core[1]["kind"] for k in top.kids] == ["pick", "do"]
    limit = top.kids[1]
    assert [n["kind"] for _, n in limit.rows] == ["limit", "do"]          # a band on its child
    opt = top.kids[0].kids[3]
    assert opt.ref == "tdm_under_fire" and opt.ref_known and not opt.opened and not opt.kids
    opened = M.build_blocks(d, "tdm", opened={opt.key})
    o = opened.kids[0].kids[3]
    assert o.opened and o.kids[0].read_only and o.kids[0].rows[0][0] == ("tdm_under_fire", ())
    folded = M.build_blocks(d, "tdm", folded={top.kids[0].key})
    assert folded.kids[0].kids == [] and folded.kids[0].folded == 14
    everything = M.build_blocks(d, "tdm", open_all=True)
    assert sum(1 for _ in everything.walk()) > 40
    assert M.build_blocks(d, "items") is None


def test_priority_lists_rolls_and_bars():
    d, c = doc(), doc("ctf")
    assert M.is_priority_list(M.node_at(d, ("tdm", (0,))))             # the top pick of each tree
    assert M.is_priority_list(M.node_at(c, ("ctf", (0,))))
    assert not M.is_priority_list(M.node_at(d, ("tdm_contact", ())))
    assert not M.is_priority_list(M.node_at(c, ("ctf_duty", ())))
    duty = M.node_at(d, ("tdm_duty", ()))
    assert M.is_roll(duty) and abs(sum(M.bar_values(duty)) - 1) < 1e-9
    bars = M.bar_values(M.node_at(d, ("tdm_contact", ())))
    assert max(bars) == 1 and all(0 <= b <= 1 for b in bars)


# ---- through the real engine -------------------------------------------------

EDITS = {
    "reorder": lambda d: M.move_by(d, ("tdm", (0, 1)), -1),
    "factor": lambda d: M.set_fields(d, ("tdm", (0, 2)), {"factor": 33}),
    "cooldown": lambda d: M.wrap(d, ("tdm", (0, 0, 0)), {"kind": "cooldown", "seconds": 3}, SCHEMA),
    "insert": lambda d: M.insert(d, ("tdm", ()), 1, M.new_node(SCHEMA, "do", "fight", d), SCHEMA),
    "move": lambda d: M.move(d, ("tdm", (0, 5)), ("tdm_contact", ()), 1, SCHEMA),
    "extract": lambda d: M.extract(d, ("tdm", (1,)), "tdm_net"),
    "rename": lambda d: (M.rename_tree(d, "tdm_camper", "tdm_waiter")[0], ("tdm_waiter", ())),
    "comment": lambda d: M.set_fields(d, ("tdm", (1,)), {"comment": "the net", "above": ["# a line above"]}),
}


@pytest.mark.parametrize("name", sorted(EDITS))
def test_each_edit_through_the_engine(name, engine, tmp_path):
    """structure in, the engine's text out; it compiles, and read again it
    is the structure the edit made (up to what describes the reading)."""
    d = doc()
    new, sel = EDITS[name](d)
    src = tmp_path / "in.json"
    src.write_text(json.dumps(new))
    r = subprocess.run([engine, "--from-json", str(src)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    text = r.stdout
    bt = tmp_path / "out.bt"
    bt.write_text(text)
    assert subprocess.run([engine, "--check", str(bt)], capture_output=True).returncode == 0
    back = json.loads(subprocess.run([engine, "--json", str(bt)], capture_output=True, text=True).stdout)
    assert M.tree_names(back) == M.tree_names(new)
    assert M.node_at(back, sel)["kind"] == M.node_at(new, sel)["kind"]
    expected = FIXTURES / "edits" / f"{name}.bt"
    if expected.exists():
        assert text == expected.read_text(), f"{name}: the engine's text changed"


def test_an_edit_the_engine_refuses(engine, tmp_path):
    d = doc()
    bad, _ = M.insert(d, ("tdm", ()), 0, {"kind": "do", "action": "figth", "args": []})
    src = tmp_path / "in.json"
    src.write_text(json.dumps(bad))
    r = subprocess.run([engine, "--from-json", str(src)], capture_output=True, text=True)
    assert r.returncode == 1 and r.stdout == "" and "no action called figth" in r.stderr
