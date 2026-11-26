# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""A behaviour of one's own, made with the editor alone, as a user would:
a new text, trees, every kind of node and its settings, the server
script's words, a decision, check, save, apply, revert, and the trees
renamed, copied, removed. Each step through the window's own actions; the
palette and the name boxes are answered by the test; the engine is real."""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("PySide6")

from PySide6.QtWidgets import QApplication  # noqa: E402

from test_diagram import idle, real  # noqa: E402,F401
from test_ui import launch, until, window  # noqa: E402,F401
from lsd_tree_editor import model as M  # noqa: E402
from lsd_tree_editor.ui import IF_THEN_OTHERWISE  # noqa: E402


class Answers:
    """Answers the palette in order; each must be one it offered."""

    def __init__(self, window):
        self.queue, self.titles = [], []
        window.pick_from_palette = self.pick

    def __call__(self, *answers):
        self.queue = list(answers)
        return self

    def pick(self, entries, title):
        self.titles.append(title)
        want = self.queue.pop(0)
        if want is None:
            return None
        offered = [(k, w) for k, w, *_ in entries]
        assert want in offered, f"{want} not offered for {title!r}: {offered[:12]}..."
        return want


def done(window):
    """The last step was made: nothing refused since the one before."""
    idle(window)
    assert not window.last_report.startswith("Not done"), window.last_report


def refused(window, why):
    """The last step was refused, saying why; the next starts afresh."""
    idle(window)
    assert window.last_report.startswith("Not done") and why in window.last_report, window.last_report
    window.last_report = ""


def node(window, path):
    return M.node_at(window.doc, path)


def select(window, path):
    window.diagram.select(path, emit=True)
    idle(window)


def change(window, path, **fields):
    window.panel.changed.emit(path, fields)
    done(window)


def test_a_behaviour_of_ones_own_with_the_editor_alone(real, window, tmp_path):
    w, d = window, window.diagram
    pal = Answers(w)
    asked = []
    w.ask_text = lambda title, label, text: asked.pop(0)
    # a new text: it compiles at once, and is drawn
    w.act_new.trigger()
    assert until(lambda: w.doc is not None and w._busy == 0 and d.root == "mine")
    # a new tree, by name; it begins with a node from the palette, never empty
    asked[:] = ["patrol"]
    pal(("select", None), ("do", "seek"))
    w.act_new_tree.trigger()
    done(w)
    assert d.root == "patrol" and node(w, ("patrol", ()))["kind"] == "select"
    assert node(w, ("patrol", (0,)))["action"] == "seek"           # a select asked what it holds
    # a name it may not have is refused before anything is made, and says why
    asked[:] = ["bad name"]
    w.act_new_tree.trigger()
    refused(w, "letters, digits")
    assert "patrol" in M.tree_names(w.doc)
    # a pick comes with its first option, and that option with what it does
    select(w, ("patrol", (0,)))
    pal(("pick", None), ("option", "enemy_near"), ("do", "fight"))
    w.insert_node("before")
    done(w)
    pick = node(w, ("patrol", (0,)))
    assert pick["kind"] == "pick" and pick["children"][0]["score"] == "enemy_near"
    assert pick["children"][0]["children"][0]["action"] == "fight"
    # its settings, and every way of rolling, from the panel (the schema's params)
    change(w, ("patrol", (0,)), every=3, sticky=0.5, noise=0.2)
    assert "pick every=3 sticky=0.5 noise=0.2" in w.text()
    for roll in ("once", "life", "each"):
        change(w, ("patrol", (0,)), roll=roll)
        assert f"pick roll={roll}" in w.text()
    select(w, ("patrol", (0,)))
    assert "sticky" not in w.panel.fields and "every" in w.panel.fields     # roll=each keeps every only
    change(w, ("patrol", (0,)), roll="weighed")
    # an option: its trait, its score's arguments, its factor
    change(w, ("patrol", (0, 0)), trait="aggression", args=["40"], factor=2)
    assert "option aggression enemy_near 40 x2" in w.text()
    # a second option; the only option cannot be deleted (a pick needs one), and it says why
    select(w, ("patrol", (0, 0)))
    pal(("option", "always"), ("seq", None), ("if", "enemy_within"), )
    pal.queue.append(("do", "take_cover"))
    # (a seq asks for its first child; the rest are added after it)
    w.insert_node("after")
    done(w)
    seq = node(w, ("patrol", (0, 1, 0)))
    assert seq["kind"] == "seq" and seq["children"][0]["cond"] == "enemy_within"
    # a condition's number, an unless after it, an action with its arguments, a wait
    change(w, ("patrol", (0, 1, 0, 0)), args=["5"])
    select(w, ("patrol", (0, 1, 0, 0)))
    pal(("unless", "health_below"))
    w.insert_node("after")
    done(w)
    change(w, ("patrol", (0, 1, 0, 1)), args=["30"])
    select(w, ("patrol", (0, 1, 0, 1)))
    pal(("do", "go_to"))
    w.insert_node("after")
    done(w)
    change(w, ("patrol", (0, 1, 0, 2)), args=["enemy_base", "6"])
    select(w, ("patrol", (0, 1, 0, 2)))
    pal(("wait", None))
    w.insert_node("after")
    done(w)
    change(w, ("patrol", (0, 1, 0, 3)), seconds=2)
    text = w.text()
    assert "if enemy_within 5" in text and "unless health_below 30" in text and "do go_to enemy_base 6" in text
    assert "wait 2" in text
    # decorators: wrap and remove; cooldown and limit with their seconds
    for kind in ("invert", "always", "never", "cooldown", "limit"):
        select(w, ("patrol", (0, 1, 0, 2)))
        w.wrap_selected(kind)
        done(w)
        assert node(w, ("patrol", (0, 1, 0, 2)))["kind"] == kind
        if kind in ("cooldown", "limit"):
            change(w, ("patrol", (0, 1, 0, 2)), seconds=20)
            assert f"{kind} 20" in w.text()
        select(w, ("patrol", (0, 1, 0, 2)))
        w.unwrap_selected()
        done(w)
    # a reference to another tree, and a comment on it, and above it
    select(w, ("patrol", (1,)))
    pal(("tree", "mine"))
    w.insert_node("after")
    done(w)
    change(w, ("patrol", (2,)), comment="the rest", above=["# when nothing else"])
    assert "# when nothing else" in w.text() and "tree mine" in w.text() and "# the rest" in w.text()
    # the server script's words: a fact, a place it names, a word told back, the level, a setting, an item
    select(w, ("patrol", (0, 1, 0, 0)))
    for cond, args in (("fact", ["alarm", "0.5"]), ("level_at_least", ["8"]), ("setting", ["mode", "hard"]),
                       ("has_item", ["medkit"])):
        pal(("if", cond))
        w.insert_node("before")
        done(w)
        change(w, ("patrol", (0, 1, 0, 0)), args=args)
        assert f"if {cond} {' '.join(args)}" in w.text()
    for action, args in (("go_to", ["@church", "3"]), ("tell", ["ring_bell", "church"])):
        select(w, ("patrol", (0, 1, 0, 0)))
        pal(("do", action))
        w.insert_node("after")
        done(w)
        change(w, ("patrol", (0, 1, 0, 1)), args=args)
        assert f"do {action} {' '.join(args)}" in w.text()
    select(w, ("patrol", (0, 1, 0, 2)))
    place = w.panel.fields["args"][0]
    assert place() == "@church"                                   # a script's place, kept in its field
    # the tree beside it: `patrol_also`, ticked just before it
    pal(("always", None), ("tree", "items"))
    w.act_add_also.trigger()
    done(w)
    assert node(w, ("patrol_also", ()))["kind"] == "always" and "tree items" in w.text()
    d.set_root("patrol")
    idle(w)
    assert d.drawing.companion.name == "patrol_also"
    # which tree the bots run: the first of the text; this one is made so
    assert M.run_tree(w.doc) == "mine"
    w.act_make_first.trigger()
    done(w)
    assert M.tree_names(w.doc)[:2] == ["patrol", "patrol_also"] and "the tree a bot given this text runs" in d.head.text()
    # check, save as, save
    w.check()
    assert until(lambda: w._busy == 0 and w.outline_fresh)
    assert w.problems.topLevelItemCount() == 0
    w.pick_save_path = lambda: str(tmp_path / "patrol.bt")
    assert w.save_as() and (tmp_path / "patrol.bt").read_text() == w.text()
    # rename (the _also follows, and every reference), duplicate, delete
    asked[:] = ["guard"]
    w.act_rename.trigger()
    done(w)
    assert "guard" in M.tree_names(w.doc) and "guard_also" in M.tree_names(w.doc) and d.root == "guard"
    asked[:] = ["guard2"]
    w.act_duplicate.trigger()
    done(w)
    assert d.root == "guard2" and M.tree(w.doc, "guard2")["root"]["kind"] == "select"
    w.act_delete_tree.trigger()
    done(w)
    assert "guard2" not in M.tree_names(w.doc)
    d.set_root("mine")
    w.act_delete_tree.trigger()                                  # used by guard: refused, and says where
    refused(w, "used by guard")
    assert "mine" in M.tree_names(w.doc)
    # undo goes back along every step
    before = w.text()
    w.undo()
    idle(w)
    assert w.text() != before
    w.redo()
    idle(w)
    assert w.text() == before
    # the server: save to it, apply to all, to one bot, a team, a kind; revert
    launch(w)
    w.save_to_server("guard")
    assert until(lambda: "Saved on the server" in w.result_label.text())
    w.apply_all()
    assert until(lambda: w.result_label.text().startswith("Applied") and w._busy == 0)
    w.roster.selectRow(0)
    w.apply_to("selected")
    assert until(lambda: w._busy == 0)
    for i in range(w.scope.count()):
        w.scope.setCurrentIndex(i)
        w.apply_to("scope")
        assert until(lambda: w._busy == 0)
    w.revert_to("selected")
    assert until(lambda: w._busy == 0)
    w.revert_all()
    assert until(lambda: w.result_label.text().startswith("Reverted"))


def test_new_from_the_games_tree(window):
    w = window
    w.ask_save_changes = lambda: "discard"
    from lsd_tree_editor import ui
    chosen = {}

    class Pick:
        def __init__(self, listing, parent):
            self.listing = listing
            self.whole = type("R", (), {"isChecked": lambda s: True})()

        def setWindowTitle(self, t):
            chosen["title"] = t

        def exec(self):
            return True

        def chosen(self):
            return next(t for t in self.listing["trees"] if t["name"] == "tdm")

    orig = ui.ServerTreesDialog
    ui.ServerTreesDialog = Pick
    try:
        w.last_report = ""
        w.act_new_game.trigger()
        assert until(lambda: w._busy == 0 and w.doc is not None and w.outline_fresh and "first" in M.tree_names(w.doc))
    finally:
        ui.ServerTreesDialog = orig
    assert w.path is None and w.server_name is None and w.editor.document().isModified()
    assert "untitled" in w.windowTitle() and not w.last_report


def test_conditional_decisions(real, window):
    """"if the nearest enemy is nearer than 5: fight back, otherwise hide", in one
    step, drawn as a decision; and weighed and conditional together."""
    w, d = window, window.diagram
    pal = Answers(w)
    w.act_new.trigger()
    assert until(lambda: w.doc is not None and w._busy == 0 and d.root == "mine")
    # Insert > If ... then ... otherwise ..., after the root's first child
    select(w, ("mine", (0,)))
    pal(IF_THEN_OTHERWISE[:2], ("if", "enemy_within"), ("do", "fight"), ("do", "take_cover"))
    w.insert_node("after")
    done(w)
    path = ("mine", (1,))
    dec = node(w, path)
    assert [c["kind"] for c in dec["children"]] == ["seq", "do"]
    assert d.selected == ("mine", (1, 0, 0))                      # the condition, to set its number
    assert "enemy_within" in w.panel.fields["cond"].currentText()
    change(w, ("mine", (1, 0, 0)), args=["5"])
    assert "\tselect\n\t\tseq\n\t\t\tif enemy_within 5\n\t\t\tdo fight\n\t\tdo take_cover\n" in w.text()
    # drawn as a decision: the guard in the branch's card, "otherwise" on the last
    blk = next(b for b in d.drawing.blocks if b.core[0] == path)
    assert blk.decision and blk.kids[0].guards == 1 and blk.kids[0].is_guard(("mine", (1, 0, 0)))
    assert blk.kids[-1].otherwise and not blk.kids[0].otherwise
    assert [k.core[1].get("action") for k in blk.kids[0].kids] == ["fight"]
    # make an option's child conditional: weighed, then conditional
    w.act_new.trigger()
    assert until(lambda: w.doc is not None and w._busy == 0 and d.root == "mine")
    select(w, ("mine", ()))
    pal(("pick", None), ("option", "always"), ("do", "seek"))
    w.insert_node("child")
    done(w)
    opt_child = ("mine", (2, 0, 0))
    assert node(w, opt_child)["action"] == "seek"
    select(w, opt_child)
    pal(("if", "health_below"), ("do", "retreat"))
    w.act_conditional.trigger()
    done(w)
    inner = node(w, ("mine", (2, 0, 0)))
    assert inner["kind"] == "select" and inner["children"][1]["action"] == "seek"
    assert inner["children"][0]["children"][0]["cond"] == "health_below"
    # and a pick inside a branch: conditional, then weighed
    select(w, ("mine", (2, 0, 0, 0, 1)))
    pal(("pick", None), ("option", "enemy_visible"), ("do", "fight"))
    w.insert_node("after")
    done(w)
    assert node(w, ("mine", (2, 0, 0, 0, 2)))["kind"] == "pick"
    w.check()
    assert until(lambda: w._busy == 0 and w.outline_fresh) and w.problems.topLevelItemCount() == 0
    # the guard moves on its own with Alt+arrows; past the action it is a guard no longer
    d.select(("mine", (2, 0, 0, 0, 0)), emit=True)
    w._move_selected(1)
    idle(w)
    assert node(w, ("mine", (2, 0, 0, 0, 1)))["cond"] == "health_below"
    QApplication.processEvents()


def test_what_a_tree_is_for(real, window):
    w = window
    w.act_new.trigger()
    assert until(lambda: w.doc is not None and w._busy == 0 and w.diagram.root == "mine")
    select(w, ("mine", ()))
    assert "about" in w.panel.fields
    w.panel.about_changed.emit("mine", ["it fights what it sees", "else it searches"])
    done(w)
    assert "# it fights what it sees\n# else it searches\ntree mine:" in w.text()
    assert "it fights what it sees" in w.diagram.head.text()
