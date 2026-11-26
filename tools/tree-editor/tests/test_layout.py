# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""The automatic layout: order is downwards in both views (siblings one
under the other in their order, never side by side), a parent before its
children, no two cards overlap, a frame holds what it frames, the same
every time, and fast enough on a large tree."""
import json
import random
import time

import pytest

from conftest import FIXTURES
from lsd_tree_editor import layout as L
from lsd_tree_editor import model as M

SCHEMA = json.loads((FIXTURES / "schema.json").read_text())
TREES = sorted(p.stem for p in (FIXTURES / "trees").glob("*.json"))


def height(box, w):
    """Like the cards: a row a node, comments make a row taller (no Qt)."""
    b = box.key
    return sum(28 + (14 if M.comments(n) else 0) for _, n in b.rows)


def natural(b):
    return 160 + 7 * max(len(n.get("text", n.get("kind", ""))) for _, n in b.rows)


def boxes(block):
    return L.Box(block, [boxes(k) for k in block.kids], natural(block), frame=block.opened,
                 foot=18 if block.folded else 0)


def bottom(b):
    """The lowest point of a box and everything under it."""
    x, y, w, h = L.bounds(b)
    return y + h


def check(root, view):
    """Every rule of the layout, on a laid-out tree of boxes."""
    all_ = list(root.walk())
    rects = [(b.x, b.y, b.x + b.w, b.y + b.h) for b in all_]
    srt = sorted(range(len(rects)), key=lambda i: rects[i][0])
    for a in range(len(srt)):                       # no two cards overlap
        x0, y0, x1, y1 = rects[srt[a]]
        for c in srt[a + 1:]:
            u0, v0, u1, v1 = rects[c]
            if u0 >= x1:
                break
            assert not (u0 < x1 and x0 < u1 and v0 < y1 and y0 < v1), \
                f"{view}: {all_[srt[a]].key.key} overlaps {all_[c].key.key}"
    for b in all_:
        assert b.w > 0 and b.h > 0
        ks = b.kids
        for k1, k2 in zip(ks, ks[1:]):              # siblings in their order, downwards, never side by side
            assert k2.y >= bottom(k1), f"{view}: {k2.key.key} is not below all of {k1.key.key}"
            assert k2.x == k1.x, f"{view}: {k1.key.key} and {k2.key.key} are not in one column"
        for k in ks:                                 # a child after its parent: below it (A), right of it (B)
            if view == "A":
                assert k.y >= b.y + b.h and k.x > b.x
            else:
                assert k.x > b.x + b.w and k.y >= b.y
        if b.fr:                                     # a frame holds what it frames
            fx, fy, fw, fh = b.fr
            for k in ks:
                for d in k.walk():
                    assert fx <= d.x and d.x + d.w <= fx + fw and fy <= d.y and d.y + d.h <= fy + fh


def roots(name):
    d = json.loads((FIXTURES / "trees" / f"{name}.json").read_text())
    return d, M.tree_names(d)


@pytest.mark.parametrize("name", TREES)
@pytest.mark.parametrize("view", ["A", "B"])
@pytest.mark.parametrize("refs", ["closed", "opened"])
def test_every_kept_tree(name, view, refs):
    d, names = roots(name)
    for t in names:
        block = M.build_blocks(d, t, SCHEMA, open_all=refs == "opened")
        root = boxes(block)
        (L.layout_a if view == "A" else L.layout_b)(root, height)
        check(root, view)


def test_deterministic():
    d, _ = roots("ctf")
    out = []
    for _ in range(2):
        root = boxes(M.build_blocks(d, "ctf", SCHEMA, open_all=True))
        L.layout_a(root, height)
        out.append([(b.key.key, b.x, b.y, b.w, b.h) for b in root.walk()])
    assert out[0] == out[1]


def test_a_wide_pick_is_one_narrow_column_in_its_order():
    """ctf_duty, 13 options: one under the other, in their order, the
    width of a card and an indent (not 3,800 px)."""
    d, _ = roots("ctf")
    root = boxes(M.build_blocks(d, "ctf_duty", SCHEMA))
    L.layout_a(root, height)
    assert len(root.kids) == 13
    assert [k.y for k in root.kids] == sorted(k.y for k in root.kids)
    x, y, w, h = L.bounds(root)
    assert w <= L.A_WIDTH + 2 * L.A_INDENT


def test_a_deep_tree_costs_an_indent_a_level():
    """Depth moves a card right by an indent in A, by a card's width in B."""
    node = {"kind": "do", "action": "fight", "args": [], "text": "do fight"}
    for _ in range(8):
        node = {"kind": "seq", "text": "seq", "children": [node, {"kind": "do", "action": "seek", "args": [],
                                                                    "text": "do seek"}]}
    d = {"format": "lsd-bt", "files": [{"trees": [{"name": "deep", "root": node}]}]}
    a, b = boxes(M.build_blocks(d, "deep", SCHEMA)), boxes(M.build_blocks(d, "deep", SCHEMA))
    L.layout_a(a, height)
    L.layout_b(b, height)
    check(a, "A")
    check(b, "B")
    assert L.bounds(a)[2] == L.A_WIDTH + 8 * L.A_INDENT
    assert L.bounds(b)[2] > 8 * L.B_MIN


def generated(n, seed=7):
    """A tree text's structure of about n nodes, as the engine's JSON."""
    rnd = random.Random(seed)
    count = [0]

    def node(depth):
        count[0] += 1
        if depth > 6 or count[0] > n - 3:
            return {"kind": "do", "action": "fight", "args": [], "text": "do fight"}
        k = rnd.choice(["seq", "select", "pick", "pick", "cooldown"])
        if k == "pick":
            opts = []
            for _ in range(rnd.randint(2, 9)):
                count[0] += 1
                opts.append({"kind": "option", "trait": "none", "score": "always", "args": [],
                             "factor": rnd.choice([1, 2, 5]), "children": [node(depth + 1)]})
            return {"kind": "pick", "children": opts, "text": "pick"}
        if k == "cooldown":
            return {"kind": "cooldown", "seconds": 1, "children": [node(depth + 1)], "text": "cooldown 1"}
        return {"kind": k, "children": [node(depth + 1) for _ in range(rnd.randint(2, 5))], "text": k}

    root = node(0)
    while count[0] < n:
        root = {"kind": "seq", "children": [root, node(1)], "text": "seq"}
    return {"format": "lsd-bt", "files": [{"trees": [{"name": "big", "root": root}]}]}


def test_300_nodes_is_fast():
    d = generated(300)
    assert M.count(M.tree(d, "big")["root"]) >= 300
    for view, lay in (("A", L.layout_a), ("B", L.layout_b)):
        t = time.perf_counter()
        for _ in range(10):
            root = boxes(M.build_blocks(d, "big", SCHEMA))
            lay(root, height)
        ms = (time.perf_counter() - t) / 10 * 1000
        check(root, view)
        print(f"300 nodes, layout {view}: {ms:.1f} ms")
        assert ms < 50
