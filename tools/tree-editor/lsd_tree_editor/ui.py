# ui.py -- the window
# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""The window: the server on the left, the tree text in the middle with
its outline, the problems, the log and the bots below. Every call to
Docker runs on another thread (`MainWindow.run`), so the window never
waits for one."""

from __future__ import annotations

import os
import subprocess
import sys
import threading
from pathlib import Path

from PySide6.QtCore import QObject, QSettings, Qt, QTimer, Signal
from PySide6.QtGui import QAction, QKeySequence
from PySide6.QtWidgets import (QAbstractItemView, QApplication, QComboBox, QDialog, QDialogButtonBox,
                               QFileDialog, QFormLayout, QGroupBox, QHBoxLayout, QHeaderView, QInputDialog,
                               QLabel, QLineEdit, QMainWindow, QMessageBox, QPlainTextEdit, QProgressBar,
                               QPushButton, QRadioButton, QSpinBox, QSplitter, QTableWidget, QTableWidgetItem,
                               QTabWidget, QToolBar, QTreeView, QTreeWidget, QTreeWidgetItem, QVBoxLayout, QWidget)

from .editor import CodeEditor, OutlineModel, fixed_font
from .server import DEFAULT_IMAGE, ImageTooOld, ServerError, Session, Setup, one_team

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
        self.apply_button = QPushButton("Apply to all bots")
        self.apply_button.setToolTip("Every bot that has no tree of its own runs this text from now on. "
                                     "A text that does not compile changes nothing.")
        self.apply_button.clicked.connect(self.apply_all)
        self.revert_button = QPushButton("Revert")
        self.revert_button.setToolTip("The bots go back to the tree of the game.")
        self.revert_button.clicked.connect(self.revert_all)
        self.apply_selected_button = QPushButton("Apply to selected")
        self.watch_button = QPushButton("Watch")
        for later in (self.apply_selected_button, self.watch_button):
            later.setEnabled(False)
            later.setToolTip("Not built yet: it comes with choosing bots and watching one think.")
        self.result_label = QLabel("The bots show here when the server runs.")
        self.result_label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        bar = QHBoxLayout()
        for b in (self.apply_button, self.revert_button, self.apply_selected_button, self.watch_button):
            bar.addWidget(b)
        bar.addStretch(1)
        bots_side = QWidget()
        bv = QVBoxLayout(bots_side)
        bv.setContentsMargins(0, 0, 0, 0)
        bv.addLayout(bar)
        bv.addWidget(self.result_label)
        bv.addWidget(self.roster)

        top = QSplitter(Qt.Orientation.Horizontal)
        top.addWidget(self.editor)
        top.addWidget(outline_side)
        top.setSizes([560, 530])
        bottom = QSplitter(Qt.Orientation.Horizontal)
        bottom.addWidget(self.lower_tabs)
        bottom.addWidget(bots_side)
        bottom.setSizes([430, 660])
        right = QSplitter(Qt.Orientation.Vertical)
        right.addWidget(top)
        right.addWidget(bottom)
        right.setSizes([580, 280])
        central = QWidget()
        h = QHBoxLayout(central)
        h.addWidget(left)
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
        self._gamemode_changed()

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

    def _show_outline(self, ast: dict) -> None:
        self.outline_model.set_document(ast)
        self.outline.expandAll()
        for c in range(self.outline_model.columnCount() - 1):
            self.outline.resizeColumnToContents(c)
        self.outline_fresh = True
        self.outline_label.setText("Outline")
        self._cursor_moved()

    def _outline_chosen(self, current, _previous=None) -> None:
        if self._syncing or not self.outline_fresh or not current.isValid():
            return
        self._syncing = True
        try:
            self.editor.goto(self.outline_model.line_of(current), select_line=True)
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

    # ---- apply -----------------------------------------------------------------

    def _applied(self, doc: dict) -> None:
        bots = doc.get("bots", [])
        what = "Applied" if doc.get("action") == "apply" else "Reverted"
        text = (f"{what}: the bots now run \"{doc.get('world')}\" ({len(bots)} bot{'s' if len(bots) != 1 else ''}).")
        self.result_label.setText(text)
        self.status(text)
        self._tick()

    def apply_all(self) -> None:
        text = self.text()
        self.run(lambda: self.session.apply_all(text), self._applied,
                 lambda e: self._refused("The tree was not applied: nothing changed", e),
                 busy="Applying the tree to all bots...")

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
        if chosen:
            self.roster.blockSignals(True)
            mode = self.roster.selectionMode()
            self.roster.setSelectionMode(QAbstractItemView.SelectionMode.MultiSelection)
            for row in range(self.roster.rowCount()):
                if self.roster.item(row, 0).data(Qt.ItemDataRole.UserRole) in chosen:
                    self.roster.selectRow(row)
            self.roster.setSelectionMode(mode)
            self.roster.blockSignals(False)
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
