# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""The automatic layout: no two cards overlap, children in their order,
the same every time, and fast enough on a large tree."""
import json
import random
import time

import pytest

from conftest import FIXTURES
from lsd_tree_editor import layout as L
from lsd_tree_editor import model as M

SHIPPED = sorted(p.stem for p in (FIXTURES / "trees").glob("*.json"))


def height(box, w):
    """Like the cards: a row a node, comments make a row taller (no Qt)."""
    b = box.key
    return sum(28 + (14 if M.comments(n) else 0) for _, n in b.rows)


def natural(b):
    return 160 + 7 * max(len(n.get("text", n.get("kind", ""))) for _, n in b.rows)


def boxes(block):
    return L.Box(block, [boxes(k) for k in block.kids], natural(block), frame=block.opened)


def check(root, view):
    all_ = list(root.walk())
    rects = [(b.x, b.y, b.x + b.w, b.y + b.h) for b in all_]
    # no two cards overlap
    srt = sorted(range(len(rects)), key=lambda i: rects[i][0])
    for a in range(len(srt)):
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
        for k1, k2 in zip(ks, ks[1:]):              # children in their order
            if view == "B" or b.column:
                assert k2.y >= k1.y + k1.h
            else:
                assert k2.x >= k1.x + k1.w
        for k in ks:                                 # a child is after its parent
            if view == "B":
                assert k.x > b.x + b.w
            else:
                assert k.y > b.y + b.h - 0.01
        if b.fr:                                     # a frame holds what it frames
            fx, fy, fw, fh = b.fr
            for k in ks:
                for d in k.walk():
                    assert fx <= d.x and d.x + d.w <= fx + fw and fy <= d.y and d.y + d.h <= fy + fh


def roots(name):
    d = json.loads((FIXTURES / "trees" / f"{name}.json").read_text())
    return d, M.tree_names(d)


@pytest.mark.parametrize("name", SHIPPED)
@pytest.mark.parametrize("view", ["A", "B"])
@pytest.mark.parametrize("refs", ["closed", "opened"])
def test_every_shipped_tree(name, view, refs):
    d, names = roots(name)
    for t in names:
        block = M.build_blocks(d, t, open_all=refs == "opened")
        root = boxes(block)
        (L.layout_a if view == "A" else L.layout_b)(root, height)
        check(root, view)


def test_deterministic():
    d, _ = roots("ctf")
    out = []
    for _ in range(2):
        root = boxes(M.build_blocks(d, "ctf", open_all=True))
        L.layout_a(root, height)
        out.append([(b.key.key, b.x, b.y, b.w, b.h) for b in root.walk()])
    assert out[0] == out[1]


def test_a_wide_pick_is_a_column_in_a():
    d, _ = roots("ctf")
    root = boxes(M.build_blocks(d, "ctf_duty"))
    L.layout_a(root, height)
    assert root.column and len(root.kids) == 13
    x, y, w, h = L.bounds(root)
    assert w < 400                                   # not 3,800 px
    root = boxes(M.build_blocks(d, "ctf_duty"))
    L.layout_a(root, height, column=99)              # without the column rule: side by side
    assert L.bounds(root)[2] > 3500


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
            root = boxes(M.build_blocks(d, "big"))
            lay(root, height)
        ms = (time.perf_counter() - t) / 10 * 1000
        check(root, view)
        print(f"300 nodes, layout {view}: {ms:.1f} ms")
        assert ms < 50
