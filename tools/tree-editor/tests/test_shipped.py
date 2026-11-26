# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""Every shipped tree (bot/trees/*.bt, read by the real engine), drawn as
the diagram draws it -- its cards measured with the fonts -- in both views,
references closed and every one shown in place, the `_also` beside: order
reads downwards, nothing overlaps, every frame holds what it frames, no
line runs through a card, and the first view at 1440 x 900 is readable."""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("PySide6")

from PySide6.QtWidgets import QApplication  # noqa: E402

from conftest import SHIPPED  # noqa: E402
from test_layout import check  # noqa: E402
from lsd_tree_editor import diagram as D  # noqa: E402
from lsd_tree_editor import layout as L  # noqa: E402
from lsd_tree_editor import model as M  # noqa: E402

app = QApplication.instance() or QApplication([])


def crosses(seg, rect):
    """Does an axis-aligned segment pass through the inside of a rectangle?"""
    (x0, y0), (x1, y1) = seg
    rx0, ry0, rx1, ry1 = rect
    if x0 == x1:
        lo, hi = sorted((y0, y1))
        return rx0 < x0 < rx1 and lo < ry1 and hi > ry0
    lo, hi = sorted((x0, x1))
    return ry0 < y0 < ry1 and lo < rx1 and hi > rx0


def check_lines(d, view):
    """No connector runs through a card other than the two it joins."""
    cards = {b.key: (d.box[b.key].x, d.box[b.key].y, d.box[b.key].x + d.box[b.key].w,
                     d.box[b.key].y + d.box[b.key].h) for b in d.blocks}
    for b in d.blocks:
        for k in b.kids:
            pts = D.edge_points(d.box[b.key], d.box[k.key], view)
            for seg in zip(pts, pts[1:]):
                for key, r in cards.items():
                    if key in (b.key, k.key):
                        continue
                    assert not crosses(seg, r), f"{view}: the line {b.key} -> {k.key} runs through {key}"


@pytest.mark.parametrize("name", SHIPPED)
@pytest.mark.parametrize("view", ["A", "B"])
@pytest.mark.parametrize("refs", ["closed", "all shown"])
def test_every_shipped_tree_reads_downwards(shipped, name, view, refs):
    docs, schema = shipped
    doc = docs[name]
    for t in M.tree_names(doc):
        d = D.build_drawing(doc, t, view, set(), set(), refs == "all shown", schema, also=True)
        check(d.box[d.root.key], view)
        if d.companion:
            check(d.companion.box, view)
            main = L.bounds(d.box[d.root.key])
            assert d.companion.frame.left() > main[0] + main[2]          # beside, not over it
        check_lines(d, view)
        for b in d.blocks:                                              # a child's number is its place
            assert [k.order for k in b.kids] == list(range(1, len(b.kids) + 1))


@pytest.mark.parametrize("name", SHIPPED)
def test_a_circle_of_references_stops(shipped, name):
    """Every reference shown, to any depth: it ends (the engine refuses a
    circle; drawn, a reference back to a tree it is inside is not opened)."""
    docs, schema = shipped
    doc = docs[name]
    first = M.tree_names(doc)[0]
    loop = M.new_tree(doc, "loop_a", {"kind": "tree", "ref": "loop_b"})[0]
    loop = M.new_tree(loop, "loop_b", {"kind": "seq", "children": [{"kind": "tree", "ref": "loop_a"},
                                                                  {"kind": "tree", "ref": first}]})[0]
    top = M.build_blocks(loop, "loop_a", schema, open_all=True)
    blocks = list(top.walk())
    back = [b for b in blocks if b.ref == "loop_a"]
    assert back and all(b.ref_state == "cycle" and not b.opened for b in back)
    assert any(b.ref == first and b.opened for b in blocks)


def test_a_card_is_measured_with_the_font_it_is_drawn_with(fake, tmp_path):
    """The program imports the window before it makes the application
    (app.py). Fonts made then had no family; resolved later, once the window
    was up, they were measured nearly twice as wide as they are drawn (86
    px for "every 1 s" drawn in 48): the cards were too wide, their words
    clipped and wrapped too soon. Measured here as the program runs."""
    import subprocess
    import sys
    from pathlib import Path
    code = f"""
import time
from lsd_tree_editor.ui import MainWindow
from lsd_tree_editor import diagram as D, server
from PySide6.QtCore import QSettings
from PySide6.QtGui import QFont, QFontMetricsF
from PySide6.QtWidgets import QApplication
app = QApplication([])
s = server.Session(); s.start()
st = QSettings({str(tmp_path / 's.ini')!r}, QSettings.Format.IniFormat); st.setValue("image", "lsd-tree-editor-test:dev")
w = MainWindow(s, st); w.show()
end = time.monotonic() + 15
while (s.schema is None or w._busy) and time.monotonic() < end:
    app.processEvents(); time.sleep(0.01)
f = QFont(); f.setPixelSize(11)
print(D._tw(D.F_CHIP, "every 1 s") / QFontMetricsF(f).horizontalAdvance("every 1 s"))
s.shutdown()
"""
    r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=60,
                       cwd=Path(__file__).resolve().parent.parent, env={**os.environ, "QT_QPA_PLATFORM": "offscreen"})
    assert r.returncode == 0, r.stderr
    assert 0.9 < float(r.stdout.split()[-1]) < 1.1


def test_a_kind_the_engine_adds_is_offered_drawn_and_edited(shipped):
    """Nothing about the kinds is in the editor: a kind the schema brings
    (here an imagined `compare <value> <below>`) is in the palette, made with
    its params' first values, drawn with its words, edited in the panel."""
    import copy
    from lsd_tree_editor.diagram import palette_entries, row_words
    from lsd_tree_editor.panel import PropertyPanel
    _, schema = shipped
    schema = copy.deepcopy(schema)
    schema["kinds"].append({"name": "compare", "children": "none", "doc": "a value below a number", "params": [
        {"name": "value", "type": "enum", "values": ["health", "ammo"], "required": True},
        {"name": "below", "type": "number", "min": 0, "max": 100, "required": True, "doc": "the number"}]})
    doc = {"format": "lsd-bt", "files": [{"trees": [{"name": "t", "root": {"kind": "seq", "children": []}}]}]}
    assert ("compare", None) in [(k, w) for k, w, *_ in palette_entries(schema, M.node_at(doc, ("t", ())), doc, "t")]
    n = M.new_node(schema, "compare", None, doc, "t")
    assert n == {"kind": "compare", "value": "health", "below": 0.0}
    doc["files"][0]["trees"][0]["root"]["children"] = [n]
    assert row_words(schema, n)[:2] == ("compare", "health")
    dr = D.build_drawing(doc, "t", "A", set(), set(), False, schema)
    assert len(dr.blocks) == 2 and D.family(schema, "compare") == "act"
    panel = PropertyPanel()
    panel.set_schema(schema)
    got = []
    panel.changed.connect(lambda path, fields: got.append(fields))
    panel.show_node(("t", (0,)), n, doc)
    assert set(panel.fields) >= {"value", "below"}
    panel.fields["below"].setValue(5)
    panel.fields["below"].editingFinished.emit()
    assert got == [{"below": 5.0}]
