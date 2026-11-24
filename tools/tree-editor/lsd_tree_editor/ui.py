# ui.py -- the window
# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""The window: the trees and the server on the left, the diagram in the
middle, the text beside it (always visible: it is what is kept) with the
properties, the outline and the preview of who chooses what under it;
the problems, the log and the bots below. Every call to Docker runs on
another thread (`MainWindow.run`), so the window never waits for one.

An edit in the diagram is made on the engine's JSON structure
(model.py), made text by the engine, checked by it, and only then put in
the text pane, whole; one the engine refuses changes nothing."""

from __future__ import annotations

import os
import subprocess
import sys
import threading
from pathlib import Path

from PySide6.QtCore import QItemSelectionModel, QObject, QSettings, Qt, QTimer, Signal
from PySide6.QtGui import QAction, QActionGroup, QColor, QKeySequence, QPalette
from PySide6.QtWidgets import (QAbstractItemView, QApplication, QComboBox, QDialog, QDialogButtonBox,
                               QFileDialog, QFormLayout, QGroupBox, QHBoxLayout, QHeaderView, QInputDialog,
                               QLabel, QLineEdit, QMainWindow, QMenu, QMessageBox, QPlainTextEdit, QProgressBar,
                               QPushButton, QRadioButton, QSpinBox, QSplitter, QTableWidget, QTableWidgetItem,
                               QTabWidget, QToolBar, QTreeView, QTreeWidget, QTreeWidgetItem, QVBoxLayout, QWidget)

from . import model as M
from .diagram import Diagram, Palette, palette_entries
from .editor import CodeEditor, OutlineModel, fixed_font
from .panel import PropertyPanel
from .server import DEFAULT_IMAGE, ImageTooOld, ServerError, Session, Setup, one_team
from .tuning import TuningPanel

APP_NAME = "LSD tree editor"

# What "New" starts from. The engine checks it like any other text.
TEMPLATE = """# What every bot does. Apply it to try it; Save as to keep it.
tree mine:
select
\tseq
\t\tif enemy_visible
\t\tdo fight
\tdo seek
"""

ROSTER = [("name", "Name"), ("team", "Team"), ("archetype", "Kind"), ("level", "Level"), ("health", "Health"),
          ("tree", "Tree"), ("doing", "Doing")]


def open_in_client(url: str, client: str = "") -> tuple[bool, str]:
    """Open an aos:// address with the chosen client, else with whatever
    the system has for the scheme. Returns (opened, what to tell the user)."""
    nothing = ("Nothing on this computer opens aos:// links. Choose the ZeroSpades program with "
               "\"Choose client...\", or paste the address into ZeroSpades.")
    try:
        if client:
            if sys.platform == "darwin" and client.rstrip("/").endswith(".app"):
                r = subprocess.run(["open", "-n", "-a", client, "--args", url], capture_output=True, text=True,
                                   timeout=20)
                return (r.returncode == 0, "" if r.returncode == 0 else r.stderr.strip())
            subprocess.Popen([client, url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True, ""
        if sys.platform == "darwin":
            r = subprocess.run(["open", url], capture_output=True, text=True, timeout=20)
            return (True, "") if r.returncode == 0 else (False, nothing)
        if os.name == "nt":
            os.startfile(url)  # type: ignore[attr-defined]
            return True, ""
        q = subprocess.run(["xdg-mime", "query", "default", "x-scheme-handler/aos"], capture_output=True,
                           text=True, timeout=10)
        if not q.stdout.strip():
            return False, nothing
        subprocess.Popen(["xdg-open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True, ""
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, nothing if not client else f"The client could not be started: {e}"


def _html(text: str) -> str:
    return (text or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def _dark_palette() -> QPalette:
    p = QPalette()
    for role, colour in ((QPalette.ColorRole.Window, "#1a1d23"), (QPalette.ColorRole.WindowText, "#e5e8ee"),
                         (QPalette.ColorRole.Base, "#15181d"), (QPalette.ColorRole.AlternateBase, "#1f232a"),
                         (QPalette.ColorRole.Text, "#e5e8ee"), (QPalette.ColorRole.Button, "#242931"),
                         (QPalette.ColorRole.ButtonText, "#e5e8ee"), (QPalette.ColorRole.Highlight, "#3b5bab"),
                         (QPalette.ColorRole.HighlightedText, "#ffffff"), (QPalette.ColorRole.ToolTipBase, "#242931"),
                         (QPalette.ColorRole.ToolTipText, "#e5e8ee"), (QPalette.ColorRole.PlaceholderText, "#6f7886"),
                         (QPalette.ColorRole.Link, "#6b98ff")):
        p.setColor(role, QColor(colour))
    for role in (QPalette.ColorRole.WindowText, QPalette.ColorRole.Text, QPalette.ColorRole.ButtonText):
        p.setColor(QPalette.ColorGroup.Disabled, role, QColor("#6f7886"))
    return p


class _Bridge(QObject):
    """Brings a result from a worker thread back to the window's thread."""
    done = Signal(object, object, object)


class ServerTreesDialog(QDialog):
    def __init__(self, listing: dict, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Open a tree from the server")
        self.resize(760, 460)
        layout = QVBoxLayout(self)
        layout.addWidget(QLabel("The trees the server has: the built-in ones, and the ones saved to it."))
        self.list = QTreeWidget()
        self.list.setHeaderLabels(["Tree", "From", "Nodes", "File", "About"])
        self.list.setRootIsDecorated(False)
        for t in listing.get("trees", []):
            if t.get("replaced"):
                continue
            item = QTreeWidgetItem([t.get("name", ""), "built in" if t.get("from") == "builtin" else "saved",
                                    str(t.get("nodes", "")), os.path.basename(t.get("file", "")), t.get("about", "")])
            item.setData(0, Qt.ItemDataRole.UserRole, t)
            self.list.addTopLevelItem(item)
        for c in range(4):
            self.list.resizeColumnToContents(c)
        self.list.setCurrentItem(self.list.topLevelItem(0))
        self.list.itemDoubleClicked.connect(lambda *_: self.accept())
        layout.addWidget(self.list)
        self.whole = QRadioButton("Open its whole file (the tree with the trees it refers to)")
        self.alone = QRadioButton("Open this tree alone")
        self.whole.setChecked(True)
        layout.addWidget(self.whole)
        layout.addWidget(self.alone)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Open | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def chosen(self) -> dict | None:
        item = self.list.currentItem()
        return item.data(0, Qt.ItemDataRole.UserRole) if item else None


class MainWindow(QMainWindow):
    def __init__(self, session: Session, settings: QSettings | None = None):
        super().__init__()
        self.session = session
        self.settings = settings or QSettings("lsd-docker", "tree-editor")
        self.path: Path | None = None
        self.server_name: str | None = None        # set when the text came from the server
        self.last_report = ""                      # the last thing told in a dialog (the tests read it)
        self.outline_fresh = False
        self._busy = 0
        self._check_generation = 0
        self._syncing = False
        self._roster_pending = False
        self._log_seen = 0
        self._closing = False
        self._may_close = False
        self._server_error = ""
        self._progress_text = ""
        self.doc: dict | None = None               # the structure of the text as it last compiled
        self.history = M.History()
        self.clipboard: dict | None = None
        self._editing = 0                          # edits on their way through the engine
        self._theme: bool | None = None            # None: the system's
        self._bridge = _Bridge()
        self._bridge.done.connect(self._finished)

        self.resize(1480, 900)
        self._build()
        self._refresh_title()
        self._refresh_server()

        self._check_timer = QTimer(self, singleShot=True, interval=700)
        self._check_timer.timeout.connect(self.check)
        self._poll = QTimer(self, interval=2000)
        self._poll.timeout.connect(self._tick)
        self._poll.start()
        self._log_timer = QTimer(self, interval=400)
        self._log_timer.timeout.connect(self._pump_log)
        self._log_timer.start()

        self.set_theme(None)
        self.new_document(ask=False)
        if session.swept:
            self.status("Removed what an earlier run of the tree editor had left: " + ", ".join(session.swept))
        self.run(self._look_at_docker, self._docker_seen, self._docker_missing)

    # ---- threads ------------------------------------------------------------

    def run(self, work, done=None, failed=None, busy: str = "") -> None:
        """Do `work()` on another thread; then `done(result)` or `failed(error)` here."""
        self._busy += 1
        self.spinner.setVisible(True)
        if busy:
            self.status(busy)

        def body():
            try:
                result, error = work(), None
            except Exception as e:      # shown by `failed`, never dropped
                result, error = None, e
            self._bridge.done.emit(done, failed, (result, error))

        threading.Thread(target=body, daemon=True).start()

    def _finished(self, done, failed, outcome) -> None:
        self._busy -= 1
        self.spinner.setVisible(self._busy > 0)
        result, error = outcome
        if error is None:
            if done:
                done(result)
        elif failed:
            failed(error)
        else:
            self.report("That did not work", str(error))

    # ---- talking to the user ---------------------------------------------------

    def status(self, text: str) -> None:
        self.statusBar().showMessage(text)

    def report(self, title: str, text: str) -> None:
        self.last_report = text
        self.status(text.splitlines()[0] if text else title)
        box = QMessageBox(QMessageBox.Icon.Warning, title, text, QMessageBox.StandardButton.Ok, self)
        box.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose)
        box.open()

    def ask(self, title: str, text: str, yes: str = "Yes") -> bool:
        box = QMessageBox(QMessageBox.Icon.Question, title, text, QMessageBox.StandardButton.Cancel, self)
        button = box.addButton(yes, QMessageBox.ButtonRole.AcceptRole)
        box.exec()
        return box.clickedButton() is button

    def ask_save_changes(self) -> str:
        """save | discard | cancel"""
        box = QMessageBox(QMessageBox.Icon.Question, APP_NAME,
                          f"The tree \"{self.document_name()}\" has changes that are not saved.",
                          QMessageBox.StandardButton.Save | QMessageBox.StandardButton.Discard
                          | QMessageBox.StandardButton.Cancel, self)
        answer = box.exec()
        return {QMessageBox.StandardButton.Save: "save", QMessageBox.StandardButton.Discard: "discard"}.get(
            QMessageBox.StandardButton(answer), "cancel")

    def pick_open_path(self) -> str:
        return QFileDialog.getOpenFileName(self, "Open a tree", self.settings.value("dir", ""),
                                           "Behaviour trees (*.bt);;All files (*)")[0]

    def pick_save_path(self) -> str:
        start = str(self.path or Path(self.settings.value("dir", "") or Path.home()) / (self.document_name() + ".bt"))
        return QFileDialog.getSaveFileName(self, "Save the tree as", start, "Behaviour trees (*.bt)")[0]

    def pick_name(self, suggestion: str) -> str:
        name, ok = QInputDialog.getText(self, "Save to the server",
                                        "Name of the tree file on the server (letters, digits, _ and -):",
                                        text=suggestion)
        return name.strip() if ok else ""

    # ---- building ----------------------------------------------------------------

    def _build(self) -> None:
        mono = fixed_font(11)

        # the server, on the left
        self.image = QComboBox(editable=True)
        self.image.addItem(self.settings.value("image", DEFAULT_IMAGE) or DEFAULT_IMAGE)
        self.image.setToolTip("The server's Docker image. It must have the bots commands.")
        self.image.lineEdit().editingFinished.connect(self._image_changed)
        self.image.activated.connect(self._image_changed)
        self.gamemode = QComboBox()
        self.gamemode.addItems(self.session.gamemodes)
        self.gamemode.currentTextChanged.connect(self._gamemode_changed)
        self.map = QComboBox()
        self.map.addItem("A random map from the web", "random")
        self.map.addItem("A generated map (no network needed)", "generated")
        self.team1 = QSpinBox(minimum=0, maximum=50, value=3)
        self.team2 = QSpinBox(minimum=0, maximum=50, value=3)
        self.team1_label, self.team2_label = QLabel("Bots, team 1"), QLabel("Bots, team 2")
        self.level = QSpinBox(minimum=1, maximum=10, value=5)
        self.set_bots_button = QPushButton("Change the bots now")
        self.set_bots_button.setToolTip("Changing the number of bots restarts the server: players are put back in.")
        self.set_bots_button.clicked.connect(self.change_bots)
        self.bots_note = QLabel("Changing the bots on a running server restarts it.")
        self.bots_note.setWordWrap(True)
        self.bots_note.setEnabled(False)
        form = QFormLayout()
        form.addRow("Image", self.image)
        form.addRow("Game", self.gamemode)
        form.addRow("Map", self.map)
        form.addRow(self.team1_label, self.team1)
        form.addRow(self.team2_label, self.team2)
        form.addRow("Bot level", self.level)
        form.addRow(self.set_bots_button)
        form.addRow(self.bots_note)

        self.launch_button = QPushButton("Launch the server")
        self.launch_button.clicked.connect(self.launch)
        self.stop_button = QPushButton("Stop the server")
        self.stop_button.clicked.connect(self.stop)
        buttons = QHBoxLayout()
        buttons.addWidget(self.launch_button)
        buttons.addWidget(self.stop_button)
        self.state_label = QLabel()
        self.state_label.setWordWrap(True)
        self.state_label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)

        self.address_choice = QComboBox()
        self.address = QLineEdit(readOnly=True)
        self.address.setFont(mono)
        self.address.setPlaceholderText("The address shows here when the server runs.")
        self.address_plain = QLabel()
        self.address_plain.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self.address_choice.currentIndexChanged.connect(self._address_chosen)
        self.copy_button = QPushButton("Copy")
        self.copy_button.clicked.connect(self.copy_address)
        self.open_button = QPushButton("Open in ZeroSpades")
        self.open_button.clicked.connect(self.open_in_zerospades)
        self.client_button = QPushButton("Choose client...")
        self.client_button.setToolTip("The ZeroSpades program to start, when aos:// links are not opened by the system.")
        self.client_button.clicked.connect(self.choose_client)
        join = QHBoxLayout()
        join.addWidget(self.copy_button)
        join.addWidget(self.open_button)
        join.addWidget(self.client_button)

        server_box = QGroupBox("The server")
        box = QVBoxLayout(server_box)
        box.addLayout(form)
        box.addLayout(buttons)
        box.addWidget(self.state_label)
        address_box = QGroupBox("Join it")
        ab = QVBoxLayout(address_box)
        ab.addWidget(self.address_choice)
        ab.addWidget(self.address)
        ab.addWidget(self.address_plain)
        ab.addLayout(join)
        self.owns_label = QLabel("This program runs one server of its own and removes it when it closes. "
                                 "It never touches another container.")
        self.owns_label.setWordWrap(True)
        self.owns_label.setEnabled(False)
        left = QWidget()
        lv = QVBoxLayout(left)
        lv.addWidget(server_box)
        lv.addWidget(address_box)
        lv.addWidget(self.owns_label)
        lv.addStretch(1)
        left.setMinimumWidth(330)
        left.setMaximumWidth(420)

        # the text and its outline
        self.editor = CodeEditor()
        self.editor.textChanged.connect(self._text_changed)
        self.editor.document().modificationChanged.connect(self._refresh_title)
        self.editor.cursorPositionChanged.connect(self._cursor_moved)
        self.outline_model = OutlineModel(self)
        self.outline = QTreeView()
        self.outline.setModel(self.outline_model)
        self.outline.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.outline.setUniformRowHeights(True)
        self.outline.setAlternatingRowColors(True)
        self.outline.selectionModel().currentRowChanged.connect(self._outline_chosen)
        self.outline_label = QLabel("Outline")
        outline_side = QWidget()
        ov = QVBoxLayout(outline_side)
        ov.setContentsMargins(0, 0, 0, 0)
        ov.addWidget(self.outline_label)
        ov.addWidget(self.outline)

        # the diagram, its properties, the trees of the text
        self.diagram = Diagram()
        self.diagram.selected_changed.connect(lambda path: self._node_selected(path, "diagram"))
        self.diagram.edit.connect(self._diagram_edit)
        self.diagram.open_tree.connect(self._tree_opened)
        self.diagram.status.connect(self.status)
        self.diagram.back.clicked.connect(self.diagram.go_back)
        self.panel = PropertyPanel()
        self.panel.changed.connect(lambda path, fields: self.edit_doc(
            "change it", lambda d: M.set_fields(d, path, fields)))
        self.panel.open_tree.connect(self.diagram.set_root)
        self.tuning = TuningPanel(self)
        self.tree_list = QTreeWidget()
        self.tree_list.setHeaderLabels(["Tree", "Nodes", "Used"])
        self.tree_list.setRootIsDecorated(False)
        self.tree_list.setToolTip("The trees of this text. Click one to draw it; the right button renames it.")
        self.tree_list.itemClicked.connect(lambda item, *_: self.diagram.set_root(item.text(0)))
        self.tree_list.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.tree_list.customContextMenuRequested.connect(self._tree_list_menu)

        # below: problems and log, and the bots
        self.problems = QTreeWidget()
        self.problems.setHeaderLabels(["Line", "Column", "Problem"])
        self.problems.setRootIsDecorated(False)
        self.problems.itemClicked.connect(self._problem_chosen)
        self.problems.itemActivated.connect(self._problem_chosen)
        self.log = QPlainTextEdit(readOnly=True)
        self.log.setFont(mono)
        self.log.setMaximumBlockCount(5000)
        self.log.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        self.log.setPlaceholderText("The server's log shows here while it runs.")
        self.lower_tabs = QTabWidget()
        self.lower_tabs.addTab(self.problems, "Problems")
        self.lower_tabs.addTab(self.log, "Server log")

        self.roster = QTableWidget(0, len(ROSTER))
        self.roster.setHorizontalHeaderLabels([title for _, title in ROSTER])
        self.roster.setSelectionBehavior(QAbstractItemView.SelectionBehavior.SelectRows)
        self.roster.setEditTriggers(QAbstractItemView.EditTrigger.NoEditTriggers)
        self.roster.verticalHeader().setVisible(False)
        self.roster.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.ResizeToContents)
        self.roster.horizontalHeader().setStretchLastSection(True)
        self.roster.itemSelectionChanged.connect(self._refresh_server)
        self.apply_button = QPushButton("Apply to all bots")
        self.apply_button.setToolTip("Every bot that has no tree of its own runs this text from now on. "
                                     "A text that does not compile changes nothing.")
        self.apply_button.clicked.connect(self.apply_all)
        self.revert_button = QPushButton("Revert all")
        self.revert_button.setToolTip("The bots go back to the tree of the game.")
        self.revert_button.clicked.connect(self.revert_all)
        self.apply_selected_button = QPushButton("Apply to selected")
        self.apply_selected_button.setToolTip("The bots chosen in the table run this text, each as its own tree.")
        self.apply_selected_button.clicked.connect(lambda: self.apply_to("selected"))
        self.revert_selected_button = QPushButton("Revert selected")
        self.revert_selected_button.setToolTip("The bots chosen in the table go back to the world's tree.")
        self.revert_selected_button.clicked.connect(lambda: self.revert_to("selected"))
        self.scope = QComboBox()
        self.scope.setToolTip("A team, or every bot of a kind")
        self.apply_scope_button = QPushButton("Apply to them")
        self.apply_scope_button.setToolTip("The bots of that team or kind run this text, each as its own tree.")
        self.apply_scope_button.clicked.connect(lambda: self.apply_to("scope"))
        self.result_label = QLabel("The bots show here when the server runs.")
        self.result_label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self.result_label.setWordWrap(True)
        bar = QHBoxLayout()
        for b in (self.apply_button, self.apply_selected_button, self.scope, self.apply_scope_button,
                  self.revert_selected_button, self.revert_button):
            bar.addWidget(b)
        bar.addStretch(1)
        bots_side = QWidget()
        bv = QVBoxLayout(bots_side)
        bv.setContentsMargins(0, 0, 0, 0)
        bv.addLayout(bar)
        bv.addWidget(self.result_label)
        bv.addWidget(self.roster)

        # the diagram's own bar: the view, undo, redo
        self.view_a = QPushButton("A  Top-down")
        self.view_b = QPushButton("B  Left to right")
        for b, v in ((self.view_a, "A"), (self.view_b, "B")):
            b.setCheckable(True)
            b.setFlat(True)
            b.clicked.connect(lambda _=False, v=v: self.set_view(v))
        self.view_a.setChecked(True)
        self.view_a.setToolTip("The tree from the top down: the main view")
        self.view_b.setToolTip("The tree from left to right: the options of a pick in one column")
        self.undo_button = QPushButton("Undo")
        self.redo_button = QPushButton("Redo")
        self.undo_button.clicked.connect(self.undo)
        self.redo_button.clicked.connect(self.redo)
        self.insert_button = QPushButton("Insert...")
        self.insert_button.setToolTip("Put a node after the selected one (Insert), from the engine's words")
        self.insert_button.clicked.connect(lambda: self.insert_node("after"))
        dbar = QHBoxLayout()
        dbar.setContentsMargins(6, 4, 6, 4)
        for b in (self.view_a, self.view_b):
            dbar.addWidget(b)
        dbar.addSpacing(16)
        for b in (self.undo_button, self.redo_button, self.insert_button):
            dbar.addWidget(b)
        dbar.addStretch(1)
        self.diagram_label = QLabel("")
        self.diagram_label.setEnabled(False)
        dbar.addWidget(self.diagram_label)
        diagram_side = QWidget()
        dv = QVBoxLayout(diagram_side)
        dv.setContentsMargins(0, 0, 0, 0)
        dv.setSpacing(0)
        dv.addLayout(dbar)
        dv.addWidget(self.diagram, 1)

        text_label = QLabel("The text: what is kept, and what the engine runs")
        text_label.setEnabled(False)
        text_side = QWidget()
        tv = QVBoxLayout(text_side)
        tv.setContentsMargins(0, 0, 0, 0)
        tv.addWidget(text_label)
        tv.addWidget(self.editor)
        self.side_tabs = QTabWidget()
        self.side_tabs.addTab(self.panel, "Properties")
        self.side_tabs.addTab(outline_side, "Outline")
        self.side_tabs.addTab(self.tuning, "Who chooses what")
        self.side_tabs.currentChanged.connect(lambda *_: self.tuning.changed())
        right_side = QSplitter(Qt.Orientation.Vertical)
        right_side.addWidget(text_side)
        right_side.addWidget(self.side_tabs)
        right_side.setSizes([400, 400])

        self.left_tabs = QTabWidget()
        self.left_tabs.addTab(self.tree_list, "Trees")
        self.left_tabs.addTab(left, "Server")
        self.left_tabs.setCurrentIndex(1)
        left.setMaximumWidth(16777215)
        left.setMinimumWidth(0)
        self.left_tabs.setMinimumWidth(240)
        self.left_tabs.setMaximumWidth(280)
        self.left_tabs.resize(250, 600)

        top = QSplitter(Qt.Orientation.Horizontal)
        top.addWidget(diagram_side)
        top.addWidget(right_side)
        top.setStretchFactor(0, 1)
        top.setSizes([880, 440])
        bottom = QSplitter(Qt.Orientation.Horizontal)
        bottom.addWidget(self.lower_tabs)
        bottom.addWidget(bots_side)
        bottom.setSizes([430, 760])
        right = QSplitter(Qt.Orientation.Vertical)
        right.addWidget(top)
        right.addWidget(bottom)
        right.setSizes([760, 170])
        central = QWidget()
        h = QHBoxLayout(central)
        h.setContentsMargins(4, 4, 4, 4)
        h.addWidget(self.left_tabs)
        h.addWidget(right, 1)
        self.setCentralWidget(central)

        self.spinner = QProgressBar()
        self.spinner.setRange(0, 0)
        self.spinner.setMaximumWidth(120)
        self.spinner.setVisible(False)
        self.statusBar().addPermanentWidget(self.spinner)

        # actions
        def action(text, slot, shortcut=None):
            a = QAction(text, self)
            a.triggered.connect(lambda *_: slot())
            if shortcut:
                a.setShortcut(shortcut)
            return a

        self.act_new = action("New", self.new_document, QKeySequence.StandardKey.New)
        self.act_open = action("Open...", self.open_file, QKeySequence.StandardKey.Open)
        self.act_open_server = action("Open from the server...", self.open_from_server, "Ctrl+Shift+O")
        self.act_save = action("Save", self.save, QKeySequence.StandardKey.Save)
        self.act_save_as = action("Save as...", self.save_as, QKeySequence.StandardKey.SaveAs)
        self.act_save_server = action("Save to the server...", self.save_to_server)
        self.act_quit = action("Quit", self.close, QKeySequence.StandardKey.Quit)
        self.act_check = action("Check", self.check, "Ctrl+K")
        self.act_format = action("Format", self.format_text, "Ctrl+Shift+F")
        self.act_apply = action("Apply to all bots", self.apply_all, "Ctrl+Return")
        self.act_revert = action("Revert", self.revert_all)
        file_menu = self.menuBar().addMenu("File")
        for a in (self.act_new, self.act_open, self.act_open_server, None, self.act_save, self.act_save_as,
                  self.act_save_server, None, self.act_quit):
            file_menu.addAction(a) if a else file_menu.addSeparator()
        tree_menu = self.menuBar().addMenu("Tree")
        for a in (self.act_check, self.act_format, None, self.act_apply, self.act_revert):
            tree_menu.addAction(a) if a else tree_menu.addSeparator()
        bar = self.addToolBar("Tree")
        bar.setMovable(False)
        bar.setToolButtonStyle(Qt.ToolButtonStyle.ToolButtonTextOnly)
        for a in (self.act_new, self.act_open, self.act_open_server, None, self.act_save, self.act_save_as,
                  self.act_save_server, None, self.act_check, self.act_format):
            bar.addAction(a) if a else bar.addSeparator()
        self._build_edit_actions()
        self._gamemode_changed()

    def _build_edit_actions(self) -> None:
        """The edits of the diagram: its right-button menu, the Edit menu, the keys."""
        d = self.diagram

        def action(text, slot, shortcut=None, tip=""):
            a = QAction(text, d)
            a.triggered.connect(lambda *_: slot())
            if shortcut:
                a.setShortcut(shortcut)
                a.setShortcutContext(Qt.ShortcutContext.WidgetWithChildrenShortcut)
            if tip:
                a.setToolTip(tip)
            d.addAction(a)
            return a

        def sep():
            a = QAction(d)
            a.setSeparator(True)
            d.addAction(a)
            return a

        self.act_undo = action("Undo", self.undo, QKeySequence.StandardKey.Undo)
        self.act_redo = action("Redo", self.redo, QKeySequence.StandardKey.Redo)
        sep()
        self.act_edit_words = action("Edit its words", lambda: self.side_tabs.setCurrentWidget(self.panel)
                                     or self.panel.setFocus(), "F2")
        self.act_insert_after = action("Insert after it...", lambda: self.insert_node("after"), "Ins")
        self.act_insert_before = action("Insert before it...", lambda: self.insert_node("before"))
        self.act_insert_child = action("Add a child...", lambda: self.insert_node("child"), "Shift+Ins")
        self.act_move_up = action("Move earlier (Alt+arrow)", lambda: self._move_selected(-1))
        self.act_move_down = action("Move later (Alt+arrow)", lambda: self._move_selected(1))
        sep()
        self.act_wrap = action("Wrap in...", self.wrap_selected)
        self.act_unwrap = action("Remove around its child", self.unwrap_selected)
        self.act_extract = action("Make it a tree of its own...", self.extract_selected)
        self.act_inline = action("Copy that tree here (inline)", self.inline_selected)
        self.act_open_ref = action("Open that tree", self.open_selected_ref, "Return")
        sep()
        self.act_cut = action("Cut", self.cut_selected, QKeySequence.StandardKey.Cut)
        self.act_copy = action("Copy", self.copy_selected, QKeySequence.StandardKey.Copy)
        self.act_paste = action("Paste after it", lambda: self.paste("after"), QKeySequence.StandardKey.Paste)
        self.act_paste_child = action("Paste as its child", lambda: self.paste("child"))
        self.act_delete = action("Delete", self.delete_selected, QKeySequence.StandardKey.Delete)
        sep()
        self.act_rename = action("Rename this tree...", self.rename_tree)
        edit_menu = self.menuBar().addMenu("Edit")
        for a in d.actions():
            edit_menu.addAction(a)
        view_menu = self.menuBar().addMenu("View")
        for text, v in (("Top-down (A)", "A"), ("Left to right (B)", "B")):
            a = QAction(text, self)
            a.triggered.connect(lambda *_, v=v: self.set_view(v))
            view_menu.addAction(a)
        view_menu.addSeparator()
        for text, slot in (("Fit the tree", d.fit), ("Zoom in", lambda: d.zoom_by(1.2)),
                           ("Zoom out", lambda: d.zoom_by(1 / 1.2))):
            a = QAction(text, self)
            a.triggered.connect(lambda *_, f=slot: f())
            view_menu.addAction(a)
        view_menu.addSeparator()
        group = QActionGroup(self)
        for text, theme in (("Colours of the system", None), ("Light", False), ("Dark", True)):
            a = QAction(text, self, checkable=True)
            a.setChecked(theme is None)
            a.triggered.connect(lambda *_, t=theme: self.set_theme(t))
            group.addAction(a)
            view_menu.addAction(a)
        try:
            QApplication.styleHints().colorSchemeChanged.connect(lambda *_: self._theme is None and self.set_theme(None))
        except AttributeError:
            pass
        self._refresh_edit_actions()

    # ---- the document ---------------------------------------------------------

    def document_name(self) -> str:
        if self.path:
            return self.path.stem
        return self.server_name or "untitled"

    def text(self) -> str:
        return self.editor.toPlainText()

    def _refresh_title(self, *_) -> None:
        where = str(self.path) if self.path else (
            f"{self.server_name} (from the server)" if self.server_name else "untitled")
        dirty = self.editor.document().isModified()
        self.setWindowTitle(f"{where}{' *' if dirty else ''} - {APP_NAME}")

    def _set_text(self, text: str, path: Path | None, server_name: str | None, modified: bool = False) -> None:
        self.history.clear()
        self.doc = None
        self.diagram.root = ""
        self.diagram._history = []
        self.diagram.selected = None
        self.diagram.message.hide()
        self.panel.show_node(None)
        self.editor.setPlainText(text)
        self.path, self.server_name = path, server_name
        self.editor.document().setModified(modified)
        self._refresh_title()
        self.check()

    def confirm_discard(self) -> bool:
        """True when the text may be replaced (saved, or the user let it go)."""
        if not self.editor.document().isModified():
            return True
        answer = self.ask_save_changes()
        if answer == "save":
            return self.save()
        return answer == "discard"

    def new_document(self, ask: bool = True) -> None:
        if ask and not self.confirm_discard():
            return
        self._set_text(TEMPLATE, None, None)

    def open_file(self, path: str = "") -> None:
        if not self.confirm_discard():
            return
        path = path or self.pick_open_path()
        if not path:
            return
        try:
            text = Path(path).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as e:
            self.report("The file could not be opened", str(e))
            return
        self.settings.setValue("dir", str(Path(path).parent))
        self._set_text(text, Path(path), None)

    def save(self) -> bool:
        if self.path is None:
            return self.save_as()
        return self._write(self.path)

    def save_as(self, path: str = "") -> bool:
        path = path or self.pick_save_path()
        if not path:
            return False
        if not Path(path).suffix:
            path += ".bt"
        return self._write(Path(path))

    def _write(self, path: Path) -> bool:
        try:
            path.write_text(self.text(), encoding="utf-8")
        except OSError as e:
            self.report("The file could not be saved", str(e))
            return False
        self.path, self.server_name = path, None
        self.settings.setValue("dir", str(path.parent))
        self.editor.document().setModified(False)
        self._refresh_title()
        self.status(f"Saved {path}")
        return True

    def open_from_server(self) -> None:
        if not self.confirm_discard():
            return

        def choose(listing):
            dialog = ServerTreesDialog(listing, self)
            if dialog.exec() and dialog.chosen():
                self.load_server_tree(dialog.chosen(), dialog.whole.isChecked())

        self.run(self.session.trees, choose, busy="Asking the server for its trees...")

    def load_server_tree(self, tree: dict, whole_file: bool = True) -> None:
        name = tree["name"]
        work = (lambda: self.session.file_text(tree["file"])) if whole_file else (lambda: self.session.tree_text(name))
        self.run(work, lambda text: self._set_text(text, None, name), busy=f"Opening {name}...")

    def save_to_server(self, name: str = "") -> None:
        name = name or self.pick_name(self.document_name() if self.document_name() != "untitled" else "mine")
        if not name:
            return

        def saved(doc):
            self.status(f"Saved on the server as {doc.get('file')}. The bots read it at the next map; "
                        "Apply runs it now.")
            self.result_label.setText(f"Saved on the server: {doc.get('file')}")

        self.run(lambda: self.session.save(name, self.text()), saved,
                 lambda e: self._refused("The server did not save it", e), busy="Saving to the server...")

    # ---- check, format, outline -------------------------------------------------

    def _text_changed(self) -> None:
        self.outline_fresh = False
        self.outline_label.setText("Outline (of the text as it was last checked)")
        self._check_timer.start()

    def check(self) -> None:
        self._check_timer.stop()
        self._check_generation += 1
        generation, text = self._check_generation, self.text()

        def work():
            doc = self.session.check(text)
            return doc, (self.session.ast(text) if doc.get("ok") else None)

        def done(result):
            if generation != self._check_generation:
                return
            doc, ast = result
            self._show_problems(doc.get("diagnostics", []))
            if ast is not None:
                self._show_outline(ast)
                self.status("The tree is right: " + ", ".join(doc.get("trees", [])))
            else:
                n = len(doc.get("diagnostics", []))
                self.status(f"{n} problem{'s' if n != 1 else ''} in the tree.")
                first = (doc.get("diagnostics") or [{}])[0]
                self.diagram.set_stale(f"Line {first.get('line', '?')}: {first.get('message', '')}"
                                       + (f" (and {n - 1} more: see Problems)" if n > 1 else ""))
                self._refresh_edit_actions()

        def failed(error):
            if generation != self._check_generation:
                return
            if isinstance(error, ServerError) and error.diagnostics:
                self._show_problems(error.diagnostics)
            else:
                self._show_problems([])
            self.status("Not checked: " + str(error).splitlines()[0])

        self.run(work, done, failed)

    def _show_problems(self, diagnostics: list[dict]) -> None:
        self.editor.set_diagnostics(diagnostics)
        self.problems.clear()
        for d in diagnostics:
            item = QTreeWidgetItem([str(d.get("line", "")), str(d.get("column", "")), d.get("message", "")])
            item.setData(0, Qt.ItemDataRole.UserRole, d)
            self.problems.addTopLevelItem(item)
        for c in range(2):
            self.problems.resizeColumnToContents(c)
        self.lower_tabs.setTabText(0, f"Problems ({len(diagnostics)})" if diagnostics else "Problems")
        if diagnostics:
            self.lower_tabs.setCurrentIndex(0)

    def _problem_chosen(self, item, *_) -> None:
        d = item.data(0, Qt.ItemDataRole.UserRole) or {}
        if d.get("line", 0) > 0:
            self.editor.goto(d["line"], d.get("column", 0))
            self.editor.setFocus()

    def _show_outline(self, ast: dict, select=None, root: str | None = None) -> None:
        self.outline_model.set_document(ast)
        self.outline.expandAll()
        for c in range(self.outline_model.columnCount() - 1):
            self.outline.resizeColumnToContents(c)
        self.outline_fresh = True
        self.outline_label.setText("Outline")
        self.doc = ast
        self.panel.set_schema(self.session.schema)
        self.diagram.set_schema(self.session.schema)
        if root:
            self.diagram.root = root
        self.diagram.set_document(ast, select)
        self.history.push(self.text(), select)
        self._refresh_tree_list()
        self.tuning.document_changed()
        if select is not None:
            self._node_selected(select, "edit")
        else:
            self._cursor_moved()
        self._refresh_edit_actions()

    def _outline_chosen(self, current, _previous=None) -> None:
        if self._syncing or not self.outline_fresh or not current.isValid():
            return
        line = self.outline_model.line_of(current)
        self._syncing = True
        try:
            self.editor.goto(line, select_line=True)
            path = M.path_for_line(self.doc or {}, line)
            if path is not None:
                self._show_in_diagram(path)
        finally:
            self._syncing = False

    def _cursor_moved(self) -> None:
        if self._syncing or not self.outline_fresh:
            return
        index = self.outline_model.index_for_line(self.editor.current_line())
        if not index.isValid():
            return
        self._syncing = True
        try:
            self.outline.setCurrentIndex(index)
            self.outline.scrollTo(index)
            path = M.path_for_line(self.doc or {}, self.editor.current_line())
            if path is not None:
                self._show_in_diagram(path)
        finally:
            self._syncing = False

    def format_text(self) -> None:
        text = self.text()

        def done(canonical):
            if self.text() != text:
                self.status("The text changed while it was formatted: not replaced.")
            elif canonical != text:
                cursor = self.editor.textCursor()
                line = cursor.blockNumber() + 1
                cursor.select(cursor.SelectionType.Document)
                cursor.insertText(canonical)        # one step to undo
                self.editor.goto(line)
                self.status("Formatted.")
            else:
                self.status("The text is formatted already.")

        self.run(lambda: self.session.format(text), done, lambda e: self._refused("It was not formatted", e),
                 busy="Formatting...")

    def _refused(self, title: str, error: Exception) -> None:
        diagnostics = getattr(error, "diagnostics", [])
        if diagnostics:
            self._show_problems(diagnostics)
        lines = [f"line {d.get('line')}, column {d.get('column')}: {d.get('message')}" for d in diagnostics]
        self.result_label.setText(str(error).splitlines()[0])
        self.report(title, "\n".join([str(error), *lines]))

    # ---- the diagram: selection, edits through the engine ---------------------------

    def _show_in_diagram(self, path) -> None:
        """The text or the outline chose a node: show it in the diagram and the panel."""
        if not self.diagram.select(path):
            # a node of another tree: draw that tree
            if path[0] != self.diagram.root and M.tree(self.doc or {}, path[0]) is not None:
                self.diagram.set_root(path[0])
                self.diagram.select(path)
        self._show_properties(path)
        self.tuning.node_selected(path)
        self._refresh_edit_actions()

    def _node_selected(self, path, source: str) -> None:
        """The diagram chose a node (or an edit did): the text, the outline and the panel follow."""
        node = M.find(self.doc or {}, path) if path is not None else None
        if node is not None and not self._syncing:
            self._syncing = True
            try:
                self.editor.goto(node.get("line", 0), select_line=True)
                index = self.outline_model.index_for_line(node.get("line", 0))
                if index.isValid():
                    self.outline.setCurrentIndex(index)
                    self.outline.scrollTo(index)
                if source == "edit":
                    self.diagram.select(path)
            finally:
                self._syncing = False
        self._show_properties(path)
        self.tuning.node_selected(path)
        self._refresh_edit_actions()

    def _show_properties(self, path) -> None:
        node = M.find(self.doc or {}, path) if path is not None else None
        b = self.diagram.selected_block()
        ro = b is not None and b.read_only
        note = (f"This node belongs to the tree {path[0]}, opened here read-only. Open {path[0]} "
                f"(click its frame) to change it: a change there is made everywhere it is used.") if ro else ""
        self.panel.show_node(path if node else None, node, self.doc or {}, read_only=ro or self.diagram.stale,
                             note=note)

    def _refresh_edit_actions(self) -> None:
        if not hasattr(self, "act_undo"):
            return
        b = self.diagram.selected_block()
        path = self.diagram.selected
        node = M.find(self.doc or {}, path) if path is not None else None
        ok = node is not None and b is not None and not b.read_only and not self.diagram.stale and self.doc
        root = ok and not path[1]
        kind = node.get("kind", "") if node else ""
        self.act_undo.setEnabled(self.history.can_undo() and not self._editing)
        self.act_redo.setEnabled(self.history.can_redo() and not self._editing)
        self.undo_button.setEnabled(self.act_undo.isEnabled())
        self.redo_button.setEnabled(self.act_redo.isEnabled())
        for a in (self.act_edit_words, self.act_copy, self.act_extract, self.act_insert_child):
            a.setEnabled(bool(ok))
        self.insert_button.setEnabled(bool(ok))
        for a in (self.act_insert_after, self.act_insert_before, self.act_move_up, self.act_move_down,
                  self.act_cut, self.act_delete, self.act_paste):
            a.setEnabled(bool(ok) and not root)
        self.act_wrap.setEnabled(bool(ok) and kind != "option")
        self.act_unwrap.setEnabled(bool(ok) and len(node.get("children", [])) == 1 and kind != "option")
        self.act_inline.setEnabled(bool(ok) and kind == "tree" and M.tree(self.doc, node.get("ref", "")) is not None)
        self.act_open_ref.setEnabled(node is not None and kind == "tree"
                                     and M.tree(self.doc or {}, node.get("ref", "")) is not None)
        self.act_paste_child.setEnabled(bool(ok) and self.clipboard is not None)
        self.act_paste.setEnabled(bool(ok) and not root and self.clipboard is not None)
        self.act_rename.setEnabled(bool(self.doc) and not self.diagram.stale)


    def edit_doc(self, what: str, change, root: str | None = None) -> None:
        """Make an edit: `change(document)` gives (new document, what to select).
        The engine makes the new document text and checks it; only then is
        the text replaced. Refused, nothing changes, and the reason is shown."""
        if self.doc is None or self.diagram.stale:
            self._edit_refused(what, "The text does not compile: fix it first (see Problems). "
                                     "The diagram shows the last tree that compiled.")
            return
        try:
            new, select = change(self.doc)
        except M.EditError as e:
            self._edit_refused(what, str(e))
            return
        base = self.text()
        self._editing += 1
        self._refresh_edit_actions()

        def done(result):
            self._editing -= 1
            text, _checked, ast = result
            if self.text() != base:
                self._edit_refused(what, "The text was changed while the engine made the edit: it was not applied.")
                return
            self._put_text(text, ast, select, root)
            self.status(f"Done: {what}. The text was made again by the engine.")

        def failed(error):
            self._editing -= 1
            self._edit_refused(what, str(error))

        self.run(lambda: self.session.remake(new), done, failed, busy=f"The engine makes it: {what}...")

    def _put_text(self, text: str, ast: dict, select=None, root: str | None = None) -> None:
        """The engine's text in the text pane, whole, as one step of its own undo."""
        if text != self.text():
            self._replace_text(text)
        self._check_timer.stop()
        self._check_generation += 1                   # what the engine gave is checked already
        self._show_problems([])
        self._show_outline(ast, select, root)

    def _replace_text(self, text: str) -> None:
        """The whole text replaced, as one step of the text's own undo; the
        cursor that moves meanwhile chooses nothing."""
        self._syncing = True
        try:
            cursor = self.editor.textCursor()
            cursor.beginEditBlock()
            cursor.select(cursor.SelectionType.Document)
            cursor.insertText(text)
            cursor.endEditBlock()
        finally:
            self._syncing = False

    def _edit_refused(self, what: str, why: str) -> None:
        text = f"Not done ({what}): {why}"
        self.last_report = text
        self.status(text.splitlines()[0])
        self.diagram.message.setText("<b>That change was refused; nothing was changed.</b><br>" +
                                     _html(why).replace("\n", "<br>"))
        self.diagram.message.show()
        self.diagram._place_overlays()
        self.diagram._message_timer.start(9000)
        self._refresh_edit_actions()

    def undo(self) -> None:
        self._step(self.history.undo(), "undone")

    def redo(self) -> None:
        self._step(self.history.redo(), "redone")

    def _step(self, state, word: str) -> None:
        if state is None or self._editing:
            return
        text, select = state
        root = self.diagram.root
        self._replace_text(text)
        self._check_timer.stop()
        self._check_generation += 1
        generation = self._check_generation

        def done(ast):
            if generation != self._check_generation:
                return
            at = self.history.at
            self._show_problems([])
            self._show_outline(ast, select if select and M.find(ast, select) else None,
                               root if M.tree(ast, root) else None)
            self.history.at = at                     # moving along the history is not a new step
            self.status(f"The last change is {word}.")
            self._refresh_edit_actions()

        self.run(lambda: self.session.ast(text), done, lambda e: self.check())

    def _diagram_edit(self, name: str, args: tuple) -> None:
        if name == "move_by":
            path, delta = args
            self.edit_doc("move it", lambda d: M.move_by(d, path, delta))
        elif name == "move":
            path, parent, index = args
            self.edit_doc("move it", lambda d: M.move(d, path, parent, index, self.session.schema))

    def _selected_path(self):
        b = self.diagram.selected_block()
        if b is None or b.read_only:
            return None
        return self.diagram.selected

    def _move_selected(self, delta: int) -> None:
        path = self._selected_path()
        if path is not None:
            self.edit_doc("move it", lambda d: M.move_by(d, path, delta))

    def insert_node(self, where: str) -> None:
        """A palette of what may go there (from the schema), then the node is put in."""
        path = self._selected_path()
        if path is None or self.doc is None:
            self.status("Choose a node of the tree drawn first.")
            return
        node = M.node_at(self.doc, path)
        if where == "child":
            parent_path, index = path, len(node.get("children", []))
        else:
            if not path[1]:
                self.status("A root has no siblings: add a child, or wrap it.")
                return
            parent_path = M.parent_path(path)
            index = path[1][-1] + (1 if where == "after" else 0)
        parent = M.node_at(self.doc, parent_path)
        entries = palette_entries(self.session.schema, parent, self.doc, path[0])
        if not entries:
            self._edit_refused("insert", M._why_not(self.session.schema, parent, "do"))
            return
        title = {"after": "Put after it", "before": "Put before it", "child": "Add a child"}[where] + \
            f" (under {parent.get('kind')})"
        chosen = self.pick_from_palette(entries, title)
        if not chosen:
            return
        kind, word = chosen
        new = M.new_node(self.session.schema, kind, word, self.doc, path[0])
        self.edit_doc(f"put {kind} {word or ''}".strip(),
                      lambda d: M.insert(d, parent_path, index, new, self.session.schema))

    def pick_from_palette(self, entries, title):
        """The palette as a dialog (the tests replace this)."""
        dialog = Palette(entries, title, self)
        self._palette = dialog
        return dialog.chosen() if dialog.exec() else None

    def delete_selected(self) -> None:
        path = self._selected_path()
        if path is not None:
            self.edit_doc("delete it", lambda d: M.delete(d, path, self.session.schema))

    def copy_selected(self) -> None:
        path = self.diagram.selected
        node = M.find(self.doc or {}, path) if path is not None else None
        if node is not None:
            self.clipboard = M.clean(node)
            self.status(f"Copied: {node.get('text', node.get('kind'))} and what is under it.")
            self._refresh_edit_actions()

    def cut_selected(self) -> None:
        path = self._selected_path()
        if path is not None:
            self.copy_selected()
            self.delete_selected()

    def paste(self, where: str) -> None:
        path, node = self._selected_path(), self.clipboard
        if path is None or node is None:
            return
        if where == "child":
            self.edit_doc("paste it", lambda d: M.insert(d, path, len(M.node_at(d, path).get("children", [])), node,
                                                         self.session.schema))
        else:
            self.edit_doc("paste it", lambda d: M.insert(d, M.parent_path(path), path[1][-1] + 1, node,
                                                         self.session.schema))

    def wrap_selected(self, kind: str | None = None) -> None:
        path = self._selected_path()
        if path is None:
            return
        if kind is None:
            entries = [(k["name"], None, k["name"], (k.get("doc") or "")[:160])
                       for k in (self.session.schema or {}).get("kinds", [])
                       if k.get("children") in ("one", "many")]
            chosen = self.pick_from_palette(entries, "Wrap it in")
            if not chosen:
                return
            kind = chosen[0]
        deco = {k: v for k, v in M.new_node(self.session.schema, kind, None, self.doc).items() if k != "children"}
        self.edit_doc(f"wrap it in {kind}", lambda d: M.wrap(d, path, deco, self.session.schema))

    def unwrap_selected(self) -> None:
        path = self._selected_path()
        if path is not None:
            self.edit_doc("remove it around its child", lambda d: M.unwrap(d, path))

    def extract_selected(self) -> None:
        path = self._selected_path()
        if path is None:
            return
        name = self.ask_text("Make it a tree of its own",
                             "The new tree's name (letters, digits and _); where it was, `tree <name>`:",
                             f"{path[0]}_part")
        if name:
            self.edit_doc(f"make it the tree {name}", lambda d: M.extract(d, path, name))

    def inline_selected(self) -> None:
        path = self._selected_path()
        if path is not None:
            self.edit_doc("copy the tree here", lambda d: M.inline(d, path))

    def open_selected_ref(self) -> None:
        node = M.find(self.doc or {}, self.diagram.selected) if self.diagram.selected else None
        if node and node.get("kind") == "tree":
            self.diagram.set_root(node.get("ref", ""))

    def rename_tree(self, old: str | None = None) -> None:
        old = old or self.diagram.root
        new = self.ask_text("Rename the tree", f"New name for {old} (every `tree {old}` follows):", old)
        if new and new != old:
            drawn = self.diagram.root == old
            self.edit_doc(f"rename {old} to {new}",
                          lambda d: (M.rename_tree(d, old, new)[0], (new, ()) if drawn else self.diagram.selected),
                          root=new if drawn else None)

    def ask_text(self, title: str, label: str, text: str) -> str:
        value, ok = QInputDialog.getText(self, title, label, text=text)
        return value.strip() if ok else ""

    def _tree_opened(self, name: str) -> None:
        self._refresh_tree_list()
        self.tuning.changed()
        self._refresh_edit_actions()

    def _refresh_tree_list(self) -> None:
        doc = self.doc or {}
        self.tree_list.clear()
        for name in M.tree_names(doc):
            n = len(M.uses(doc, name))
            item = QTreeWidgetItem([name, str(M.ref_size(doc, name)), f"{n}×" if n else ""])
            item.setToolTip(0, M.about(M.tree(doc, name)) or name)
            item.setToolTip(2, f"used in {n} place{'s' if n != 1 else ''}" if n else "not used by another tree")
            self.tree_list.addTopLevelItem(item)
            if name == self.diagram.root:
                item.setSelected(True)
                self.tree_list.setCurrentItem(item)
        for c in range(3):
            self.tree_list.resizeColumnToContents(c)

    def _tree_list_menu(self, pos) -> None:
        item = self.tree_list.itemAt(pos)
        if item is None:
            return
        menu = QMenu(self)
        menu.addAction("Draw it", lambda: self.diagram.set_root(item.text(0)))
        menu.addAction("Rename...", lambda: self.rename_tree(item.text(0)))
        menu.exec(self.tree_list.viewport().mapToGlobal(pos))

    def set_view(self, view: str) -> None:
        self.view_a.setChecked(view == "A")
        self.view_b.setChecked(view == "B")
        self.diagram.set_view(view)

    def set_theme(self, dark: bool | None) -> None:
        """Light, dark, or (None) as the system is."""
        self._theme = dark
        app = QApplication.instance()
        if dark is None:
            try:
                dark = QApplication.styleHints().colorScheme() == Qt.ColorScheme.Dark
            except AttributeError:
                dark = self.palette().window().color().lightness() < 128
        if self._theme is not None and app is not None:
            app.setPalette(_dark_palette() if dark else app.style().standardPalette())
        self.diagram.set_theme(dark)
        self.editor.highlighter.set_dark(dark)

    # ---- apply -----------------------------------------------------------------

    def _applied(self, doc: dict) -> None:
        bots = doc.get("bots", [])
        what = "Applied" if doc.get("action") == "apply" else "Reverted"
        if doc.get("scope") == "bots":
            runs = ", ".join(f"{b.get('name')} runs {b.get('tree')}" + ("" if b.get("ok", True) else " (NOT taken)")
                             for b in bots)
            text = f"{what}: {runs or 'nobody'}. The others run \"{doc.get('world')}\"."
        else:
            text = (f"{what}: the bots now run \"{doc.get('world')}\" "
                    f"({len(bots)} bot{'s' if len(bots) != 1 else ''}).")
        self.result_label.setText(text)
        self.status(text)
        self._tick()

    def apply_all(self) -> None:
        text = self.text()
        self.run(lambda: self.session.apply_all(text), self._applied,
                 lambda e: self._refused("The tree was not applied: nothing changed", e),
                 busy="Applying the tree to all bots...")

    def _whom(self, how: str) -> dict | None:
        if how == "selected":
            pids = sorted({self.roster.item(i.row(), 0).data(Qt.ItemDataRole.UserRole)
                           for i in self.roster.selectionModel().selectedRows()})
            if not pids:
                self.report("No bot chosen", "Choose one or more bots in the table first.")
                return None
            return {"bots": pids}
        data = self.scope.currentData()
        if not data:
            self.report("Nobody chosen", "Choose a team or a kind of bot first.")
            return None
        return {"team": data[1]} if data[0] == "team" else {"kind": data[1]}

    def apply_to(self, how: str) -> None:
        whom = self._whom(how)
        if whom is None:
            return
        text = self.text()
        self.run(lambda: self.session.apply_to(text, **whom), self._applied,
                 lambda e: self._refused("The tree was not applied: nothing changed", e),
                 busy="Applying the tree to those bots...")

    def revert_to(self, how: str) -> None:
        whom = self._whom(how)
        if whom is None:
            return
        self.run(lambda: self.session.revert_to(**whom), self._applied, lambda e: self._refused("Not reverted", e),
                 busy="Reverting those bots...")

    def revert_all(self) -> None:
        self.run(self.session.revert_all, self._applied, lambda e: self._refused("Not reverted", e),
                 busy="Reverting...")

    # ---- the server ----------------------------------------------------------------

    _looked_at = ""

    def _look_at_docker(self):
        self._looked_at = self.image.currentText().strip()
        self.session.docker.check_running()
        images = self.session.local_images()
        image = self.image.currentText().strip()
        usable = None
        if self.session.docker.image_present(image):
            try:
                self.session.probe_image(image)
                usable = True
            except ImageTooOld:
                usable = False
        return images, image, usable

    def _docker_seen(self, seen) -> None:
        images, image, usable = seen
        for name in images:
            if self.image.findText(name) < 0:
                self.image.addItem(name)
        if usable:
            self._schema_ready()
            self.check()
        elif usable is False:
            self.status(f"The image {image} is too old: it does not have the bots commands. Choose a newer image.")
        else:
            self.status(f"The image {image} is not on this computer yet: Launch offers to download it. "
                        "Until then the text cannot be checked.")

    def _docker_missing(self, error) -> None:
        self._looked_at = ""                       # asked again when the image field is left
        self.status(str(error) + ". Until then the text cannot be checked.")

    def _schema_ready(self) -> None:
        self.editor.highlighter.set_schema(self.session.schema)
        current = self.gamemode.currentText()
        self.gamemode.blockSignals(True)
        self.gamemode.clear()
        self.gamemode.addItems(self.session.gamemodes)
        if current in self.session.gamemodes:
            self.gamemode.setCurrentText(current)
        self.gamemode.blockSignals(False)
        self._gamemode_changed()

    def _image_changed(self, *_) -> None:
        image = self.image.currentText().strip()
        if image and image != self._looked_at and self.session.instance is None:
            self._looked_at = image
            self.run(self._look_at_docker, self._docker_seen, self._docker_missing,
                     busy="Asking the image what it can do...")

    def _gamemode_changed(self, *_) -> None:
        solo = one_team(self.gamemode.currentText())
        self.team1_label.setText("Bots" if solo else "Bots, team 1")
        self.team2.setVisible(not solo)
        self.team2_label.setVisible(not solo)
        self.map.setEnabled(not solo)
        self.map.setToolTip("This game plays a course generated for it." if solo else "")

    def setup(self) -> Setup:
        return Setup(image=self.image.currentText().strip(), gamemode=self.gamemode.currentText(),
                     map=self.map.currentData(), bots_team1=self.team1.value(), bots_team2=self.team2.value(),
                     level=self.level.value())

    def launch(self) -> None:
        setup = self.setup()
        if not setup.image:
            self.report("No image", "Say which Docker image the server is made from.")
            return
        self._server_error = ""
        self._starting = True
        self._refresh_server()

        def present():
            self.session.docker.check_running()
            return self.session.docker.image_present(setup.image)

        def known(here):
            if here:
                self._launch(setup, pull=False)
            elif self.ask("Download the image?", f"The image {setup.image} is not on this computer.\n\n"
                          "Download it now? It is a few hundred megabytes.", "Download"):
                self._launch(setup, pull=True)
            else:
                self._launch_failed(ServerError("The image was not downloaded."), quiet=True)

        self.run(present, known, self._launch_failed, busy="Asking Docker...")

    def _launch(self, setup: Setup, pull: bool) -> None:
        def progress(text):
            self._progress_text = text

        def work():
            if pull:
                progress("Downloading the image (this can take minutes)...")
                self.session.docker.pull(setup.image)
            return self.session.launch(setup, progress)

        def done(instance):
            self._starting = False
            self.settings.setValue("image", setup.image)
            self._schema_ready()
            self._refresh_server()
            self.status("The server runs. " + " ".join(instance.notes))
            self.check()
            self._tick()

        self.run(work, done, self._launch_failed)

    def _launch_failed(self, error, quiet: bool = False) -> None:
        self._starting = False
        self._server_error = str(error)
        self._refresh_server()
        if not quiet:
            self.lower_tabs.setCurrentIndex(1)
            self.report("The server did not start", str(error))

    def stop(self) -> None:
        if self.session.instance is None:
            return
        self.session.instance.state = "stopping"
        self._refresh_server()

        def done(problem):
            self._refresh_server()
            if problem:
                self.report("The server could not be removed", problem)
            else:
                self.status("The server is stopped and removed.")
                self.roster.setRowCount(0)

        self.run(self.session.stop_instance, done, busy="Stopping the server...")

    def change_bots(self) -> None:
        inst = self.session.instance
        if inst is None:
            return
        team1, team2 = self.team1.value(), None if one_team(inst.gamemode) else self.team2.value()
        self.run(lambda: self.session.set_bots(team1, team2),
                 lambda said: self.status("The bots are changed; the server is restarting."),
                 busy="Changing the bots: the server restarts...")

    _starting = False

    def _refresh_server(self) -> None:
        inst = self.session.instance
        state = inst.state if inst else ("starting" if self._starting else "none")
        if state == "none" and self._server_error:
            text = "Error: " + self._server_error.splitlines()[0]
        else:
            text = {"none": "No server. Launch one to try a tree on bots.",
                    "starting": "Starting... " + self._progress_text,
                    "running": f"Running: {inst.gamemode}, container {inst.name}, UDP port {inst.port}." if inst else "",
                    "stopping": "Stopping the server...",
                    "error": "Error: the server stopped by itself. See the server log."}[state]
        self.state_label.setText(text)
        idle, running = state == "none", state == "running"
        self.launch_button.setEnabled(idle and not self._closing)
        self.stop_button.setEnabled(state in ("starting", "running", "error") and inst is not None)
        for w in (self.image, self.gamemode, self.map, self.level):
            w.setEnabled(idle)
        self.map.setEnabled(idle and not one_team(self.gamemode.currentText()))
        for w in (self.set_bots_button, self.apply_button, self.revert_button, self.act_apply, self.act_revert,
                  self.act_save_server, self.copy_button, self.open_button):
            w.setEnabled(running)
        chosen = running and bool(self.roster.selectionModel().selectedRows())
        self.apply_selected_button.setEnabled(chosen)
        self.revert_selected_button.setEnabled(chosen)
        self.scope.setEnabled(running)
        self.apply_scope_button.setEnabled(running and self.scope.count() > 0)
        if inst and running:
            if self.address_choice.count() == 0:
                for url, plain in zip(inst.urls, inst.addresses):
                    here = plain.startswith("127.")
                    self.address_choice.addItem("This computer" if here else "Your network", (url, plain))
                self.address_choice.setCurrentIndex(self.address_choice.count() - 1)
        elif self.address_choice.count():
            self.address_choice.clear()
            self.address.clear()
            self.address_plain.clear()

    def _address_chosen(self, *_) -> None:
        data = self.address_choice.currentData()
        if data:
            self.address.setText(data[0])
            self.address_plain.setText("Without the aos:// form: " + data[1])

    def copy_address(self) -> None:
        if self.address.text():
            QApplication.clipboard().setText(self.address.text())
            self.status("Copied " + self.address.text())

    def choose_client(self) -> None:
        path = QFileDialog.getOpenFileName(self, "Choose the ZeroSpades program",
                                           self.settings.value("client", "") or "/Applications")[0]
        if path:
            self.settings.setValue("client", path)
            self.status("ZeroSpades will be started from " + path)

    def open_in_zerospades(self) -> None:
        url = self.address.text()
        if not url:
            return
        client = self.settings.value("client", "") or ""
        self.run(lambda: open_in_client(url, client), self._client_opened, busy="Opening ZeroSpades...")

    def _client_opened(self, outcome) -> None:
        opened, message = outcome
        if opened:
            self.status("Asked ZeroSpades to join " + self.address.text())
            return
        self.address.setFocus()
        self.address.selectAll()
        self.report("ZeroSpades was not opened", message)

    # ---- every two seconds: the bots, and is the server still there ------------------

    def _tick(self) -> None:
        inst = self.session.instance
        if self._starting or (inst and inst.state != "running"):
            self._refresh_server()
        if inst is None or inst.state != "running" or self._roster_pending or self._closing:
            return
        self._roster_pending = True

        def work():
            try:
                return self.session.bots(), None
            except ServerError as e:
                return None, (str(e), self.session.check_alive())

        def done(result):
            self._roster_pending = False
            doc, problem = result
            if doc is not None:
                self._show_roster(doc)
            elif not problem[1]:
                self._refresh_server()
                self.lower_tabs.setCurrentIndex(1)
                self.report("The server stopped", "The server's container is gone. Its log is in the Server log tab. "
                            "Launch a new one when you want.")
                self.run(self.session.forget_dead_instance, lambda _: self._refresh_server())
            else:
                self.result_label.setText("No answer from the bots yet: " + problem[0].splitlines()[0])

        self.run(work, done)

    def _show_roster(self, doc: dict) -> None:
        bots = doc.get("bots", [])
        chosen = {self.roster.item(i.row(), 0).data(Qt.ItemDataRole.UserRole)
                  for i in self.roster.selectionModel().selectedRows()}
        self.roster.setRowCount(len(bots))
        for row, bot in enumerate(bots):
            for column, (key, _) in enumerate(ROSTER):
                value = bot.get(key, "")
                if key == "tree" and bot.get("tree_set") == "bot":
                    value = f"{value} (its own)"
                if key == "health" and not bot.get("alive", True):
                    value = "dead"
                item = QTableWidgetItem(str(value))
                if column == 0:
                    item.setData(Qt.ItemDataRole.UserRole, bot.get("pid"))
                self.roster.setItem(row, column, item)
        if chosen:                             # the same bots stay chosen (selectRow would toggle them)
            model, flags = self.roster.selectionModel(), QItemSelectionModel.SelectionFlag
            model.blockSignals(True)
            model.clearSelection()
            for row in range(self.roster.rowCount()):
                if self.roster.item(row, 0).data(Qt.ItemDataRole.UserRole) in chosen:
                    model.select(self.roster.model().index(row, 0), flags.Select | flags.Rows)
            model.blockSignals(False)
            self.roster.viewport().update()
        scopes = [("team", t) for t in sorted({b.get("team") for b in bots if b.get("team") is not None})] + \
                 [("kind", k) for k in sorted({b.get("archetype") for b in bots if b.get("archetype")})]
        if scopes != [self.scope.itemData(i) for i in range(self.scope.count())]:
            keep = self.scope.currentData()
            self.scope.clear()
            for what, v in scopes:
                self.scope.addItem(f"team {v}" if what == "team" else f"every {v}", (what, v))
            if keep in scopes:
                self.scope.setCurrentIndex(scopes.index(keep))
            self._refresh_server()
        world = (doc.get("world") or {}).get("tree")
        if not self.result_label.text().startswith(("Applied", "Reverted", "Saved")):
            self.result_label.setText(f"{len(bots)} bots. They run \"{world}\".")

    def _pump_log(self) -> None:
        self._log_seen, lines = self.session.log_since(self._log_seen)
        if lines:
            self.log.appendPlainText("\n".join(lines))

    # ---- closing: the server goes first ------------------------------------------------

    def closeEvent(self, event) -> None:
        if self._may_close:
            event.accept()
            return
        event.ignore()
        if self._closing:
            return
        if not self.confirm_discard():
            return
        self.shut_down()

    def shut_down(self) -> None:
        """Remove the server, then close. The window stays, saying so, until it is gone."""
        if self._closing:
            return
        self._closing = True
        self._poll.stop()
        had_server = self.session.instance is not None
        self.centralWidget().setEnabled(False)
        self.menuBar().setEnabled(False)
        for bar in self.findChildren(QToolBar):
            bar.setEnabled(False)
        self.state_label.setText("Stopping the server...")

        def done(problem):
            if problem:
                self.last_report = problem
                sys.stderr.write(problem + "\n")
                if QApplication.platformName() != "offscreen":
                    QMessageBox.warning(self, "The server could not be removed", problem)
            self._may_close = True
            self.close()
            QApplication.quit()

        self.run(self.session.shutdown, done, lambda e: done(str(e)),
                 busy="Stopping the server..." if had_server else "Closing...")
