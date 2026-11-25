# tuning.py -- who chooses what: the engine's --split, beside the tree being edited
# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""A preview, offline: the situation is set with a slider for each word
the tree asks about (the list is the engine's own "asked and not given"),
a crowd of bots is rolled and the tree ticked once for each by the
engine (`bttree --split --json`), and what they end up doing is shown,
in all and by kind of bot; for a selected pick, how often each of its
options was chosen. It runs again after every change, off the window's
thread, while this tab is shown."""

from __future__ import annotations

from PySide6.QtCore import Qt, QTimer
from PySide6.QtWidgets import (QComboBox, QGridLayout, QHBoxLayout, QHeaderView, QLabel, QProgressBar,
                               QPushButton, QScrollArea, QSlider, QSpinBox, QTableWidget, QTableWidgetItem,
                               QVBoxLayout, QWidget)

from . import model as M


class TuningPanel(QWidget):
    def __init__(self, window):
        super().__init__()
        self.window = window
        self.values: dict[str, float] = {}       # the situation: word (with its arguments) -> 0..1
        self.words: list[str] = []               # every word the tree was seen to ask about
        self.result: dict | None = None
        self.path = None
        self._generation = 0
        self._pending = False
        self._timer = QTimer(self, singleShot=True, interval=150)
        self._timer.timeout.connect(self.refresh)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(8, 8, 8, 8)
        self.head = QLabel()
        self.head.setWordWrap(True)
        lay.addWidget(self.head)
        row = QHBoxLayout()
        self.level = QSpinBox(minimum=1, maximum=10, value=5)
        self.level.setPrefix("level ")
        self.crowd = QComboBox()
        for n in (300, 700, 2000):
            self.crowd.addItem(f"{n} bots", n)
        self.crowd.setCurrentIndex(1)
        self.reset = QPushButton("All to 0")
        self.reset.clicked.connect(self._reset)
        for w in (self.level, self.crowd, self.reset):
            row.addWidget(w)
        row.addStretch(1)
        self.level.valueChanged.connect(self.changed)
        self.crowd.currentIndexChanged.connect(self.changed)
        lay.addLayout(row)
        self.sliders_box = QWidget()
        self.grid = QGridLayout(self.sliders_box)
        self.grid.setContentsMargins(0, 0, 0, 0)
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setWidget(self.sliders_box)
        scroll.setMaximumHeight(150)
        lay.addWidget(scroll)
        self.pick_label = QLabel()
        self.pick_label.setWordWrap(True)
        lay.addWidget(self.pick_label)
        self.pick_table = QTableWidget(0, 3)
        self.pick_table.setHorizontalHeaderLabels(["Option", "Chosen", "Mean worth"])
        self._table(self.pick_table)
        lay.addWidget(self.pick_table)
        self.out_label = QLabel("What the crowd ends up doing")
        self.out_label.setWordWrap(True)
        lay.addWidget(self.out_label)
        self.out_table = QTableWidget(0, 2)
        self._table(self.out_table)
        lay.addWidget(self.out_table, 1)
        self._say()

    @staticmethod
    def _table(t: QTableWidget) -> None:
        t.verticalHeader().setVisible(False)
        t.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        t.setSelectionMode(QTableWidget.SelectionMode.NoSelection)
        t.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.ResizeToContents)
        t.horizontalHeader().setStretchLastSection(True)
        t.setMinimumWidth(100)
        t.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAsNeeded)

    # -- when to run
    def shown(self) -> bool:
        tabs = getattr(self.window, "side_tabs", None)
        return tabs is not None and tabs.currentWidget() is not None and \
            self in (tabs.currentWidget(), getattr(tabs.currentWidget(), "widget", lambda: None)())

    def document_changed(self) -> None:
        self.changed()

    def node_selected(self, path) -> None:
        self.path = path
        if self.result is not None:
            self._show_pick()
        self._say()

    def changed(self, *_) -> None:
        if self.shown():
            self._timer.start()

    def _reset(self) -> None:
        self.values = {}
        self._sliders()
        self.changed()

    # -- running the engine
    def tree(self) -> str:
        return self.window.diagram.root

    def refresh(self) -> None:
        if self.window.doc is None or self.window.diagram.stale:
            self.head.setText("The text does not compile: there is nothing to try.")
            return
        if self._pending:                            # one at a time; the last change runs after
            self._timer.start()
            return
        self._pending = True
        self._generation += 1
        gen, text, tree = self._generation, self.window.text(), self.tree()
        words, n, level = dict(self.values), self.crowd.currentData(), self.level.value()

        def done(doc):
            self._pending = False
            if gen != self._generation:
                return
            self.result = doc
            for w in doc.get("asked", []):
                if w not in self.words:
                    self.words.append(w)
            self._sliders()
            self._show()

        def failed(e):
            self._pending = False
            self.result = None
            self.head.setText(str(e))

        self.window.run(lambda: self.window.session.split(text, tree, words, n, level), done, failed)

    # -- showing
    def _say(self) -> None:
        node = M.find(self.window.doc or {}, self.path) if self.path else None
        what = "this pick" if node and node.get("kind") == "pick" else "a pick (choose one in the diagram)"
        self.head.setText(f"Who chooses what, by the engine (bttree --split): a crowd of bots is rolled and the "
                          f"tree <b>{self.tree()}</b> ticked once for each, in the situation set below "
                          f"(a word not set is 0). Shown: what they end up doing, and at {what}, how often each "
                          f"option is chosen.")

    def _sliders(self) -> None:
        while self.grid.count():
            w = self.grid.takeAt(0).widget()
            if w is not None:
                w.deleteLater()
        for i, word in enumerate(self.words):
            lab = QLabel(word)
            s = QSlider(Qt.Orientation.Horizontal)
            s.setRange(0, 100)
            s.setValue(round(self.values.get(word, 0) * 100))
            val = QLabel(f"{self.values.get(word, 0):.2f}")
            val.setMinimumWidth(34)

            def moved(v, word=word, val=val):
                self.values[word] = v / 100
                val.setText(f"{v / 100:.2f}")
                self.changed()

            s.valueChanged.connect(moved)
            self.grid.addWidget(lab, i, 0)
            self.grid.addWidget(s, i, 1)
            self.grid.addWidget(val, i, 2)
        self.sliders = {w: self.grid.itemAtPosition(i, 1).widget() for i, w in enumerate(self.words)}

    def _show(self) -> None:
        doc = self.result or {}
        kinds = list(doc.get("crowd", {}).keys())
        rows = doc.get("outcomes", [])
        t = self.out_table
        t.setColumnCount(2 + len(kinds))
        t.setHorizontalHeaderLabels(["All", "Doing"] + kinds)
        t.setRowCount(len(rows))
        for r, o in enumerate(rows):
            bar = QProgressBar()
            bar.setRange(0, 1000)
            bar.setValue(round(o.get("all", 0) * 1000))
            bar.setFormat(f"{o.get('all', 0) * 100:.1f}%")
            bar.setMaximumWidth(110)
            t.setCellWidget(r, 0, bar)
            t.setItem(r, 1, QTableWidgetItem(o.get("what", "").replace("pick:", "")))
            for c, k in enumerate(kinds):
                t.setItem(r, 2 + c, QTableWidgetItem(f"{o.get('by', {}).get(k, 0) * 100:.0f}%"))
        t.resizeColumnsToContents()
        self.out_label.setText(f"What the crowd ends up doing ({doc.get('n', '?')} bots, level {doc.get('level')})"
                               + (f". Asked and not given (so 0): {', '.join(doc['asked'])}" if doc.get("asked") else ""))
        self._show_pick()
        self._say()

    def _show_pick(self) -> None:
        node = M.find(self.window.doc or {}, self.path) if self.path else None
        if node is not None and node.get("kind") == "option" and self.path[1]:
            node = M.find(self.window.doc, M.parent_path(self.path))
        t = self.pick_table
        if node is None or node.get("kind") != "pick" or not self.result:
            self.pick_label.setText("Choose a pick (or one of its options) to see how often each option is chosen.")
            t.setRowCount(0)
            return
        src = node.get("id")
        picks = [p for p in self.result.get("picks", []) if p.get("file") == 0 and p.get("source") == src]
        if not picks:
            self.pick_label.setText("No bot of the crowd came to this pick in that situation.")
            t.setRowCount(0)
            return
        p = max(picks, key=lambda x: x.get("bots", 0))
        self.pick_label.setText(f"At this pick ({p.get('bots')} bots came to it): how often each option was chosen")
        t.setRowCount(len(p.get("options", [])))
        for r, o in enumerate(p.get("options", [])):
            t.setItem(r, 0, QTableWidgetItem(o.get("text", "")))
            bar = QProgressBar()
            bar.setRange(0, 1000)
            bar.setValue(round(o.get("chosen", 0) * 1000))
            bar.setFormat(f"{o.get('chosen', 0) * 100:.1f}%")
            bar.setMaximumWidth(120)
            t.setCellWidget(r, 1, bar)
            t.setItem(r, 2, QTableWidgetItem(f"{o.get('worth', 0):.3g}"))
