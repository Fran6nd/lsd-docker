# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""The window, without a screen (QT_QPA_PLATFORM=offscreen), on the fake docker."""
import os
import time
from pathlib import Path

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("PySide6")

from PySide6.QtCore import QSettings  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

from conftest import FIXTURES  # noqa: E402
from lsd_tree_editor import server  # noqa: E402
from lsd_tree_editor.ui import MainWindow  # noqa: E402

IMAGE = "lsd-tree-editor-test:dev"
GOOD = (FIXTURES / "first.bt").read_text()
BAD = (FIXTURES / "bad.bt").read_text()
SHOTS = os.environ.get("LSD_TREE_EDITOR_SHOTS")


def until(condition, timeout=15.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        QApplication.processEvents()
        if condition():
            return True
        time.sleep(0.01)
    return False


def type_text(window, text):
    """Replace the text as a person would: the document is then changed."""
    cursor = window.editor.textCursor()
    cursor.select(cursor.SelectionType.Document)
    cursor.insertText(text)


def shot(window, name):
    if SHOTS:
        QApplication.processEvents()
        window.grab().save(str(Path(SHOTS) / name))


@pytest.fixture
def window(fake, tmp_path):
    app = QApplication.instance() or QApplication([])
    session = server.Session()
    session.start()
    settings = QSettings(str(tmp_path / "settings.ini"), QSettings.Format.IniFormat)
    settings.setValue("image", IMAGE)
    w = MainWindow(session, settings)
    w.ask_save_changes = lambda: "discard"
    w.show()
    assert until(lambda: session.schema is not None and w._busy == 0)
    yield w
    session.shutdown()
    w._may_close = True
    w.close()
    app.processEvents()


def launch(window):
    window.launch()
    assert until(lambda: window.session.instance is not None and window.session.instance.state == "running"
                 and window._busy == 0)
    assert until(lambda: window.roster.rowCount() == 6)


def test_the_window_builds_and_the_template_is_checked(window):
    assert "untitled" in window.windowTitle() and "*" not in window.windowTitle()
    assert window.gamemode.count() == 3 and window.gamemode.currentText() == "tdm"
    assert not window.apply_selected_button.isEnabled() and not hasattr(window, "watch_button")   # no live view (the owner)
    assert not window.apply_button.isEnabled() and not window.stop_button.isEnabled()
    assert window.launch_button.isEnabled()
    assert until(lambda: window.outline_fresh)          # checked with the image, no server running
    assert window.problems.topLevelItemCount() == 0
    assert window.editor.highlighter._kinds >= {"select", "pick", "do"}
    shot(window, "1-start.png")


def test_a_text_with_mistakes_shows_each_on_its_line(window):
    type_text(window, BAD)
    assert until(lambda: window.problems.topLevelItemCount() == 3)     # after the pause in typing, by itself
    rows = [[window.problems.topLevelItem(i).text(c) for c in range(3)] for i in range(3)]
    assert rows[0] == ["4", "19", "enemy_within: <voxels> is a number, not 'near'"]
    assert rows[1][:2] == ["5", "6"] and rows[2][:2] == ["6", "11"]
    marks = [(s.cursor.blockNumber() + 1, s.cursor.selectedText()) for s in window.editor.diagnostic_selections()]
    assert marks == [(4, "near"), (5, "figth"), (6, "nowhere")]
    assert "3 problems" in window.statusBar().currentMessage()
    assert not window.outline_fresh
    window._problem_chosen(window.problems.topLevelItem(1))
    assert window.editor.current_line() == 5 and window.editor.textCursor().positionInBlock() == 5
    assert "*" in window.windowTitle()
    shot(window, "2-problems.png")


def test_outline_and_text_follow_each_other(window):
    type_text(window, GOOD)
    window.check()
    assert until(lambda: window.outline_fresh and window.outline_model.rowCount() == 1)
    model = window.outline_model
    tree = model.index(0, 0)
    assert [model.data(model.index(0, c)) for c in range(2)] == ["tree", "first"]
    pick = model.index(0, 0, model.index(0, 0, tree))
    assert [model.data(pick.siblingAtColumn(c)) for c in range(4)] == ["pick", "", "every=3", "sticky=0.25 noise=0.1"]
    option = model.index(0, 0, pick)
    assert [model.data(option.siblingAtColumn(c)) for c in range(5)] == \
        ["option", "enemy_near", "trait=aggression factor=1.2", "", "an enemy close: fight him"]
    # outline -> text
    window.outline.setCurrentIndex(option)
    assert window.editor.current_line() == 4
    assert window.editor.textCursor().selectedText() == "option aggression enemy_near x1.2     # an enemy close: fight him"
    # text -> outline
    window.editor.goto(7)
    QApplication.processEvents()
    assert model.data(window.outline.currentIndex().siblingAtColumn(1)) == "retreat"
    assert model.line_of(window.outline.currentIndex()) == 7
    shot(window, "3-outline.png")


def test_save_as_writes_the_file(window, tmp_path):
    type_text(window, GOOD)
    assert window.editor.document().isModified() and "*" in window.windowTitle()
    target = tmp_path / "kept"
    window.pick_save_path = lambda: str(target)
    assert window.save_as() is True
    assert (tmp_path / "kept.bt").read_text() == GOOD
    assert "*" not in window.windowTitle() and "kept.bt" in window.windowTitle()
    window.editor.insertPlainText("# more\n")
    assert window.save() is True                    # Save goes to the same file now
    assert (tmp_path / "kept.bt").read_text() == GOOD + "# more\n"
    window.editor.setPlainText("")
    window.open_file(str(tmp_path / "kept.bt"))
    assert window.text() == GOOD + "# more\n" and not window.editor.document().isModified()


def test_closing_asks_about_unsaved_changes(window):
    window.editor.insertPlainText("# x\n")
    window.ask_save_changes = lambda: "cancel"
    window.close()
    QApplication.processEvents()
    assert window.isVisible() and not window._closing


def test_launch_apply_revert_and_refusals(window, fake):
    launch(window)
    assert "Running: tdm" in window.state_label.text()
    assert window.address.text() == f"aos://127.0.0.1:{window.session.instance.port}"
    assert window.roster.item(0, 0).text() == "Bot82" and window.roster.horizontalHeaderItem(6).text() == "Doing"
    assert until(lambda: "starting the server" in window.log.toPlainText())
    window.copy_address()
    assert QApplication.clipboard().text() == window.address.text()
    type_text(window, GOOD)
    window.apply_all()
    assert until(lambda: window.result_label.text().startswith("Applied"))
    assert '"mine"' in window.result_label.text()
    shot(window, "4-running.png")
    type_text(window, BAD)
    window.apply_all()
    assert until(lambda: "nothing was changed" in window.last_report)
    assert "line 5, column 6: no action called figth" in window.last_report
    assert window.problems.topLevelItemCount() == 3
    window.revert_all()
    assert until(lambda: window.result_label.text().startswith("Reverted"))
    window.save_to_server("../evil")
    assert until(lambda: "letters, digits" in window.last_report)
    type_text(window, GOOD)
    window.save_to_server("mine")
    assert until(lambda: "Saved on the server" in window.result_label.text())
    # a second launch is not offered, and refused if forced
    assert not window.launch_button.isEnabled()
    window._launch(window.setup(), pull=False)
    assert until(lambda: "only one" in window.last_report)
    assert len([c for c in fake.calls() if c[:2] == ["run", "-d"]]) == 1


def test_a_slow_docker_does_not_block_the_window(window, fake, monkeypatch):
    launch(window)
    monkeypatch.setenv("FAKE_DOCKER_SLOW", "1.5")
    started = time.monotonic()
    type_text(window, GOOD)
    window.apply_all()
    assert time.monotonic() - started < 0.5          # the call came back at once
    assert window.spinner.isVisibleTo(window)        # and the window says it is busy
    longest, last = 0.0, time.monotonic()
    while not window.result_label.text().startswith("Applied") and time.monotonic() - started < 20:
        QApplication.processEvents()
        longest, last = max(longest, time.monotonic() - last), time.monotonic()
        time.sleep(0.005)
    assert window.result_label.text().startswith("Applied") and time.monotonic() - started > 1.4
    assert longest < 0.3                             # the event loop never waited for docker
    monkeypatch.delenv("FAKE_DOCKER_SLOW")


def test_closing_with_a_server_removes_it_first(window, fake):
    launch(window)
    inst = window.session.instance
    window.close()
    assert window.isVisible()                        # it stays, saying so, until the server is gone
    assert window.state_label.text() == "Stopping the server..."
    assert until(lambda: not window.isVisible())
    calls = fake.calls()
    assert [c for c in calls if c[0] == "rm"] == [["rm", "-f", inst.cid]]
    assert [c for c in calls if c[:2] == ["volume", "rm"]] == [["volume", "rm", inst.name]]
    assert fake.state()["containers"] == {} and fake.state()["volumes"] == {}
    assert window.session.instance is None


def test_an_old_image_is_said_in_the_status_bar(fake, tmp_path):
    app = QApplication.instance() or QApplication([])
    session = server.Session()
    session.start()
    settings = QSettings(str(tmp_path / "s.ini"), QSettings.Format.IniFormat)
    settings.setValue("image", "old:image")
    w = MainWindow(session, settings)
    try:
        assert until(lambda: "too old" in w.statusBar().currentMessage())
        w.check()
        assert until(lambda: "Not checked" in w.statusBar().currentMessage())
        w.launch()
        assert until(lambda: "too old" in w.last_report)
        assert session.instance is None and w.launch_button.isEnabled()
    finally:
        session.shutdown()
        w._may_close = True
        w.close()
        app.processEvents()
