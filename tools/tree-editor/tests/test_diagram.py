# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""The diagram in the window, on the fake docker -- with the real engine
(built for this computer) behind the fake where an edit must be made text."""
import json
import os
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("PySide6")

from PySide6.QtCore import QPointF  # noqa: E402
from PySide6.QtWidgets import QApplication, QLineEdit  # noqa: E402

from conftest import FIXTURES  # noqa: E402
from test_layout import generated  # noqa: E402
from test_ui import launch, type_text, until, window  # noqa: E402,F401
from lsd_tree_editor import model as M  # noqa: E402

TDM = (FIXTURES / "trees" / "tdm.bt").read_text()


@pytest.fixture
def real(engine, monkeypatch):
    """The fake docker answers bttree with the real engine."""
    monkeypatch.setenv("FAKE_DOCKER_BTTREE", engine)


def load(window, text=TDM):
    type_text(window, text)
    window.check()
    assert until(lambda: window.outline_fresh and window._busy == 0 and window.doc is not None
                 and "tdm" in M.tree_names(window.doc))


def idle(window):
    assert until(lambda: window._busy == 0)
    QApplication.processEvents()


def test_the_diagram_draws_the_text_and_follows_it_three_ways(window, real):
    load(window)
    d = window.diagram
    assert d.root == "tdm" and d.view == "A" and len(d.drawing.blocks) >= 9
    # the first view: refs closed, the priority list a column, readable and narrow
    assert d.drawing.box[d.drawing.root.kids[0].key].column
    assert d.drawing.bounds.width() < 900 and d.zoom() >= 0.85
    assert sum(1 for _, what, _ in d.drawing.zones if what == "ref") == 3      # its three references, closed
    # diagram -> text and outline
    d.select(("tdm", (0, 5)), emit=True)
    idle(window)
    assert window.editor.textCursor().selectedText().startswith("option curiosity search x2.5")
    assert window.outline_model.line_of(window.outline.currentIndex()) == window.editor.current_line()
    assert window.panel.node["score"] == "search"
    # text -> diagram
    window.editor.goto(M.node_at(window.doc, ("tdm", (0, 2)))["line"])
    QApplication.processEvents()
    assert d.selected == ("tdm", (0, 2))
    # outline -> diagram
    window.outline.setCurrentIndex(window.outline_model.index_for_line(M.node_at(window.doc, ("tdm", (1,)))["line"]))
    QApplication.processEvents()
    assert d.selected == ("tdm", (1,))
    # the keyboard: down to the child, across to a sibling
    d.select(("tdm", (0,)), emit=True)
    from PySide6.QtCore import Qt
    from PySide6.QtTest import QTest
    QTest.keyClick(d, Qt.Key.Key_Down)
    assert d.selected == ("tdm", (0, 0))
    QTest.keyClick(d, Qt.Key.Key_Right)
    assert d.selected == ("tdm", (0, 1))           # in a column: the next sibling
    d.set_view("B")
    assert not any(b.column for b in d.drawing.box.values())


def test_a_sub_tree_is_read_only_in_place_and_opened_by_a_click(window, real):
    load(window)
    d = window.diagram
    ref = next(b for b in d.drawing.blocks if b.ref == "tdm_contact")
    zone = next(r for r, what, b in d.drawing.zones if what == "ref" and b is ref)
    from PySide6.QtCore import Qt
    from PySide6.QtTest import QTest
    QTest.mouseClick(d.viewport(), Qt.MouseButton.LeftButton, pos=d.mapFromScene(zone.center()))
    inside = [b for b in d.drawing.blocks if b.read_only]
    assert inside and all(b.top[0][0] == "tdm_contact" for b in inside)
    d.select(inside[0].top[0], inside[0].key, emit=True)
    idle(window)
    assert window.panel.read_only
    assert not any(e.isEnabled() for e in window.panel.widget().findChildren(QLineEdit))
    assert not window.act_delete.isEnabled() and not window.act_insert_after.isEnabled()
    window.delete_selected()                        # refused quietly: nothing to do
    assert window._busy == 0
    # the frame's title opens the tree itself, as the edited root; Back returns
    frame = next(r for r, what, b in d.drawing.zones if what == "frame")
    QTest.mouseClick(d.viewport(), Qt.MouseButton.LeftButton, pos=d.mapFromScene(frame.center()))
    assert d.root == "tdm_contact" and not any(b.read_only for b in d.drawing.blocks)
    assert "used in 1 place" in d.head.text()
    d.go_back()
    assert d.root == "tdm"


def test_edits_go_through_the_engine_and_undo(window, real):
    load(window)
    d = window.diagram
    d.select(("tdm", (0, 1)), emit=True)
    window._move_selected(-1)
    idle(window)
    assert window.text() == (FIXTURES / "edits" / "reorder.bt").read_text()
    assert d.selected == ("tdm", (0, 0))
    window.undo()
    idle(window)
    assert window.text() == TDM
    window.redo()
    idle(window)
    assert window.text() == (FIXTURES / "edits" / "reorder.bt").read_text()
    window.undo()
    idle(window)
    # the factor, from the panel
    window.panel.changed.emit(("tdm", (0, 2)), {"factor": 33})
    idle(window)
    assert window.text() == (FIXTURES / "edits" / "factor.bt").read_text()
    window.undo()
    idle(window)
    # a cooldown around an action
    d.select(("tdm", (0, 0, 0)), emit=True)
    window.wrap_selected("cooldown")
    idle(window)
    assert "\t\t\tcooldown 1\n\t\t\t\tdo evade\n" in window.text()
    # insert from the palette (the palette is answered by the test)
    entries = []
    window.pick_from_palette = lambda e, title: (entries.extend(e), ("do", "fight"))[1]
    d.select(("tdm", (1,)), emit=True)
    window.insert_node("after")
    idle(window)
    assert ("do", "fight") in [(k, w) for k, w, *_ in entries] and not any(k == "option" for k, *_ in entries)
    assert M.node_at(window.doc, ("tdm", (2,)))["action"] == "fight" and d.selected == ("tdm", (2,))
    # under a pick the palette offers options only
    d.select(("tdm", (0, 0)), emit=True)
    entries.clear()
    window.pick_from_palette = lambda e, title: (entries.extend(e), None)[1]
    window.insert_node("after")
    assert entries and all(k == "option" for k, *_ in entries)
    # cut and paste, extract, rename
    d.select(("tdm", (2,)), emit=True)
    window.cut_selected()
    idle(window)
    assert M.find(window.doc, ("tdm", (2,))) is None
    window.ask_text = lambda *a: "tdm_net"
    d.select(("tdm", (1,)), emit=True)
    window.extract_selected()
    idle(window)
    assert "tree tdm_net:" in window.text() and M.node_at(window.doc, ("tdm", (1,)))["ref"] == "tdm_net"
    window.ask_text = lambda *a: "tdm_waiter"
    window.rename_tree("tdm_camper")
    idle(window)
    assert "tdm_camper" not in window.text() and window.text().count("tree tdm_waiter") == 3
    assert d.root == "tdm"


def test_a_drag_moves_a_node(window, real):
    load(window)
    d = window.diagram
    for view in ("B", "A"):
        window.set_view(view)
        b = next(x for x in d.drawing.blocks if x.top[0] == ("tdm", (0, 5)))
        bx = d.drawing.box[b.key]
        d.begin_drag(b, QPointF(bx.x + 10, bx.y + 10))
        tgt = d.drawing.box[b.parent.kids[2].key]
        d.drag_to(QPointF(tgt.x + 40, tgt.y - 3))     # the line above the third
        assert d._drag["target"][3] == 2 and d._drag["target"][2] is b.parent
        d.drop()
        idle(window)
        assert M.node_at(window.doc, ("tdm", (0, 2)))["score"] == "search"
        window.undo()
        idle(window)


def test_a_refused_edit_changes_nothing(window, real):
    load(window)
    d = window.diagram
    d.select(("tdm", (0, 0, 0)), emit=True)
    window.delete_selected()                         # the option's only child
    idle(window)
    assert window.text() == TDM and "only child" in window.last_report and d.message.isVisible()
    # one the engine refuses: an action that does not exist
    window.panel.changed.emit(("tdm", (0, 0, 0)), {"action": "figth"})
    idle(window)
    assert window.text() == TDM and "no action called figth" in window.last_report


def test_a_text_that_does_not_compile_keeps_the_last_tree(window, real):
    load(window)
    type_text(window, TDM + "\tdo figth\n")
    assert until(lambda: window.diagram.stale and window._busy == 0)
    assert window.diagram.stale_label.isVisible() and window.diagram.drawing.blocks
    assert not window.act_delete.isEnabled()
    window.diagram.select(("tdm", (0, 1)), emit=True)
    window._move_selected(-1)
    assert "does not compile" in window.last_report
    type_text(window, TDM)
    assert until(lambda: not window.diagram.stale and window._busy == 0)


def test_apply_to_the_selected_bots_a_team_a_kind(window, fake):
    launch(window)
    assert not window.apply_selected_button.isEnabled()
    window.roster.selectRow(1)
    assert window.apply_selected_button.isEnabled()
    pid = window.roster.item(1, 0).data(0x0100)
    window.apply_to("selected")
    assert until(lambda: window.result_label.text().startswith("Applied") and window._busy == 0)
    assert any(c[-5:] == ["apply", "-", "--bot", str(pid), "--json"] for c in fake.calls())
    kinds = [window.scope.itemData(i) for i in range(window.scope.count())]
    assert ("team", 1) in kinds and any(k[0] == "kind" for k in kinds)
    window.scope.setCurrentIndex(kinds.index(("team", 1)))
    window.apply_to("scope")
    assert until(lambda: window._busy == 0)
    assert any(c[-3:] == ["--team", "1", "--json"] for c in fake.calls())
    window.revert_to("selected")
    assert until(lambda: window._busy == 0)
    assert any(c[-4:] == ["revert", "--bot", str(pid), "--json"] for c in fake.calls()), ([c for c in fake.calls() if "revert" in c], window.last_report)


def test_who_chooses_what(window, real, monkeypatch):
    load(window)
    window.diagram.set_root("tdm_contact")
    window.side_tabs.setCurrentWidget(window.tuning)
    window.diagram.select(("tdm_contact", ()), emit=True)
    assert until(lambda: window.tuning.result is not None and window._busy == 0)
    assert "enemy_visible" in window.tuning.sliders
    window.tuning.sliders["enemy_visible"].setValue(100)
    assert until(lambda: window.tuning.values.get("enemy_visible") == 1 and not window.tuning._timer.isActive()
                 and not window.tuning._pending and window._busy == 0)
    rows = [window.tuning.pick_table.item(r, 0).text() for r in range(window.tuning.pick_table.rowCount())]
    assert "option aggression enemy_visible" in rows
    assert window.tuning.result["outcomes"][0]["what"] == "pick:aggression > fight"


def test_300_nodes_do_not_block_the_window(window, real):
    d = generated(300)
    t = time.perf_counter()
    window.diagram.set_document(d)
    QApplication.processEvents()
    first = time.perf_counter() - t
    window.diagram.unfold_all()
    t = time.perf_counter()
    window.diagram.set_view("B")
    QApplication.processEvents()
    again = time.perf_counter() - t
    print(f"300 nodes: drawn in {first * 1000:.0f} ms, B unfolded in {again * 1000:.0f} ms")
    assert first < 0.3 and again < 0.3


def test_a_slow_engine_does_not_block_an_edit(window, real, fake, monkeypatch):
    launch(window)
    load(window)
    monkeypatch.setenv("FAKE_DOCKER_SLOW", "1.2")
    window.diagram.select(("tdm", (0, 1)), emit=True)
    started = time.monotonic()
    window._move_selected(-1)
    assert time.monotonic() - started < 0.3
    longest, last = 0.0, time.monotonic()
    while window._busy and time.monotonic() - started < 20:
        QApplication.processEvents()
        longest, last = max(longest, time.monotonic() - last), time.monotonic()
        time.sleep(0.005)
    assert time.monotonic() - started > 1.1 and longest < 0.3
    assert M.node_at(window.doc, ("tdm", (0, 0)))["score"] == "harmful_water"
