# panel.py -- the selected node's properties, from the engine's schema
# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""What the selected node is and says: its kind and word with their
documentation, each argument with its type, its choices and its default,
a pick's settings, an option's trait and factor, the comments. Every
field comes from the schema (`lsdctl bots schema`); a change is asked
for with `changed(path, fields)` and made by the window through the
engine -- this panel never writes text."""

from __future__ import annotations

import math

from PySide6.QtCore import QLocale, Qt, QTimer, Signal
from PySide6.QtGui import QDoubleValidator
from PySide6.QtWidgets import (QComboBox, QCompleter, QDoubleSpinBox, QFormLayout, QFrame, QHBoxLayout, QLabel,
                               QLineEdit, QPlainTextEdit, QPushButton, QScrollArea, QSlider, QVBoxLayout, QWidget)

from . import model as M

def _num(v) -> str:
    return f"{v:g}" if isinstance(v, (int, float)) else str(v)


def arg_type(a: dict) -> str:
    t = a.get("type", "text")
    if t == "enum":
        return "one of " + " | ".join(a.get("values", []))
    if t == "number":
        r = ""
        if "min" in a:
            r += f" ≥ {_num(a['min'])}"
        if "max" in a:
            r += f" ≤ {_num(a['max'])}"
        return "number" + r
    return t


def arg_default(a: dict) -> str:
    if "default" in a:
        return f"default {_num(a['default'])}"
    if a.get("default_note"):
        return a["default_note"]
    return "required" if a.get("required") else ""


class PropertyPanel(QScrollArea):
    changed = Signal(object, dict)          # (path, fields to change)
    open_tree = Signal(str)
    refused = Signal(str)                   # a change the panel cannot make, and why
    about_changed = Signal(str, list)       # (tree, its comment lines): what the tree is for

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWidgetResizable(True)
        self.setFrameShape(QFrame.Shape.NoFrame)
        self.schema: dict | None = None
        self.doc: dict = {}
        self.path = None
        self.node: dict | None = None
        self.read_only = False
        self.fields: dict = {}
        self._factor_timer = QTimer(self, singleShot=True, interval=350)
        self._factor_timer.timeout.connect(self._commit_factor)
        self.show_node(None)

    # -- building
    def set_schema(self, schema: dict | None) -> None:
        self.schema = schema

    def show_node(self, path, node: dict | None = None, doc: dict | None = None, read_only: bool = False,
                  note: str = "") -> None:
        self.path, self.node, self.read_only = path, node, read_only
        if doc is not None:
            self.doc = doc
        self.fields = {}
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(12, 10, 12, 16)
        lay.setSpacing(6)
        if node is None:
            hint = QLabel("Choose a node in the diagram, the text or the outline to see its words, their types "
                          "and defaults, and to change them.\n\nIn the diagram: Up and Down go through the rows "
                          "in reading order; Right shows what is under a node (a tree it names, in place), Left "
                          "hides it; Alt+Up and Alt+Down move a node earlier or later (order is priority); "
                          "Insert adds a node after it, Delete removes it; the right button shows every edit.")
            hint.setWordWrap(True)
            hint.setEnabled(False)
            lay.addWidget(hint)
            lay.addStretch(1)
            self.setWidget(w)
            return
        kind = node.get("kind", "")
        info = M.kind_info(self.schema, kind)
        head = QLabel(f"<span style='font-size:11px;letter-spacing:1px;font-weight:650'>{kind.upper()}</span>")
        lay.addWidget(head)
        title = QLabel(f"<b style='font-size:14px'>{_esc(node.get('text') or kind)}</b>")
        title.setWordWrap(True)
        title.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        lay.addWidget(title)
        where = QLabel(f"tree {path[0]}, line {node.get('line', '?')}")
        where.setEnabled(False)
        lay.addWidget(where)
        if note:
            n = QLabel(note)
            n.setWordWrap(True)
            n.setStyleSheet("color: #b4458f;")
            lay.addWidget(n)
        if info.get("doc"):
            d = QLabel(info["doc"])
            d.setWordWrap(True)
            d.setEnabled(False)
            lay.addWidget(d)
        form = QFormLayout()
        form.setFieldGrowthPolicy(QFormLayout.FieldGrowthPolicy.AllNonFixedFieldsGrow)
        lay.addLayout(form)
        gone = M.left_out(node)
        for p in info.get("params", []):            # every param of its kind, as the schema says
            t, name = p.get("type"), p.get("name", "")
            if name in gone:
                continue
            if t == "trait":
                self._trait(form, node, p)
            elif t in M.WORD_LISTS:
                self._word(form, node, p, lay)
            elif t == "tree":
                self._ref(form, node, p)
            elif t == "enum":
                self._enum(form, node, p)
            elif t == "number" and info.get("parent"):
                self._factor(form, node, p)
            elif t == "number":
                self._number(form, node, name, p)
            else:
                self._text(form, node, p)
        self._comments(form, node)
        if path is not None and not path[1]:
            self._about(form, path[0])
        if read_only:
            for child in w.findChildren(QWidget):
                if isinstance(child, (QLineEdit, QComboBox, QDoubleSpinBox, QSlider, QPlainTextEdit)):
                    child.setEnabled(False)
        lay.addStretch(1)
        self.setWidget(w)

    def _label(self, name: str, type_text: str) -> QLabel:
        lb = QLabel(f"{name}<br><span style='color:#8b95a6;font-size:11px'>{_esc(type_text)}</span>")
        return lb

    def _trait(self, form: QFormLayout, node: dict, spec: dict) -> None:
        name = spec.get("name", "")
        box = QComboBox()
        for t in M.word_list(self.schema, "trait"):
            box.addItem(t["name"], t["name"])
            box.setItemData(box.count() - 1, t.get("doc", ""), Qt.ItemDataRole.ToolTipRole)
        box.setCurrentIndex(max(0, box.findData(node.get(name))))
        box.setToolTip(spec.get("doc", ""))
        box.activated.connect(lambda *_: self._emit({name: box.currentData()}))
        form.addRow(self._label(name, "a trait of the bot"), box)
        self.fields[name] = box

    def _word(self, form: QFormLayout, node: dict, spec: dict, lay: QVBoxLayout) -> None:
        field, ptype = spec.get("name", ""), spec.get("type", "")
        words = M.word_list(self.schema, ptype)
        box = QComboBox()
        box.setEditable(True)
        box.setInsertPolicy(QComboBox.InsertPolicy.NoInsert)
        for w in words:
            box.addItem(w["name"], w["name"])
            box.setItemData(box.count() - 1, w.get("doc", ""), Qt.ItemDataRole.ToolTipRole)
        box.completer().setCompletionMode(QCompleter.CompletionMode.PopupCompletion)
        box.completer().setFilterMode(Qt.MatchFlag.MatchContains)
        box.setCurrentText(node.get(field, ""))
        box.setToolTip(spec.get("doc", ""))

        def chosen(*_):
            word = box.currentText().strip()
            if word and word != node.get(field):
                self._emit({field: word, "args": M.required_args(self.schema, ptype, word)})

        box.activated.connect(chosen)
        box.lineEdit().editingFinished.connect(chosen)
        form.addRow(self._label(field, f"one of the {M.WORD_LISTS[ptype]}"), box)
        self.fields[field] = box
        info = M.word_info(self.schema, ptype, node.get(field, ""))
        if info.get("doc"):
            d = QLabel(info["doc"])
            d.setWordWrap(True)
            d.setEnabled(False)
            form.addRow("", d)
        self._args(form, node, info.get("args", []))

    def _args(self, form: QFormLayout, node: dict, specs: list[dict]) -> None:
        values = [str(a) for a in node.get("args", [])]
        edits = []
        for i, a in enumerate(specs):
            value = " ".join(values[i:]) if a.get("repeat") else (values[i] if i < len(values) else "")
            if a.get("type") in ("enum", "place"):
                e = QComboBox()
                choices = a.get("values", []) if a.get("type") == "enum" else \
                    [p["name"] for p in (self.schema or {}).get("places", [])]
                if not a.get("required"):
                    e.addItem(f"({arg_default(a) or 'not given'})", "")
                for c in choices:
                    e.addItem(c, c)
                if a.get("type") == "place":
                    for p in (self.schema or {}).get("places", []):
                        e.setItemData(e.findData(p["name"]), p.get("doc", ""), Qt.ItemDataRole.ToolTipRole)
                    for sp in M.script_places(self.doc):
                        e.addItem(sp, sp)
                        e.setItemData(e.count() - 1, "a place a server script names (it sets it)",
                                      Qt.ItemDataRole.ToolTipRole)
                e.setEditable(a.get("type") == "place")
                e.setCurrentIndex(max(0, e.findData(value)))
                if value and e.findData(value) < 0:
                    e.setCurrentText(value)
                e.activated.connect(lambda *_: self._commit_args(specs))
                if e.isEditable():
                    e.lineEdit().setPlaceholderText(f"or {M.SCRIPT_PLACE}name: a place a server script sets")
                    e.lineEdit().editingFinished.connect(lambda: self._commit_args(specs))
                get = (lambda e=e: (e.currentData() if e.currentIndex() >= 0 and e.currentText() == e.itemText(
                    e.currentIndex()) else e.currentText()) or "")
            else:
                e = QLineEdit(value)
                e.setPlaceholderText(arg_default(a))
                if a.get("type") == "number" and not a.get("repeat"):
                    v = QDoubleValidator()
                    v.setLocale(QLocale.c())
                    if "min" in a:
                        v.setBottom(float(a["min"]))
                    if "max" in a:
                        v.setTop(float(a["max"]))
                    e.setValidator(v)
                e.editingFinished.connect(lambda: self._commit_args(specs))
                get = (lambda e=e: e.text().strip())
            e.setToolTip(" · ".join(x for x in (arg_default(a), a.get("doc", "")) if x))
            form.addRow(self._label(a.get("name", f"argument {i + 1}"), arg_type(a)), e)
            edits.append(get)
        self.fields["args"] = edits

    def _commit_args(self, specs) -> None:
        """The arguments as the fields say. An argument left empty before one
        that is given is written with its default: the words are read in order,
        so a gap would shift the next one into its place."""
        vals = [g() for g in self.fields.get("args", [])]
        while vals and not vals[-1]:
            vals.pop()
        out = []
        for v, a in zip(vals, specs):
            if not v:
                if "default" not in a:
                    self.refused.emit(f"{a.get('name')} must be given before what follows it: the words are read "
                                      f"in order ({arg_default(a) or 'it has no default'}).")
                    return
                v = M.first_value(self.schema, a)
            if a.get("repeat"):
                out += v.split()
            else:
                out.append(v)
        if out != [str(a) for a in (self.node or {}).get("args", [])]:
            self._emit({"args": out})

    def _factor(self, form: QFormLayout, node: dict, spec: dict) -> None:
        """An option's number (its factor): a slider on a log scale beside the box."""
        name = spec.get("name", "")
        f = float(node.get(name, spec.get("default", 1)))
        default = name in node.get("defaults", [])
        row = QWidget()
        h = QHBoxLayout(row)
        h.setContentsMargins(0, 0, 0, 0)
        slider = QSlider(Qt.Orientation.Horizontal)
        slider.setRange(0, 1000)                 # a log scale: 0.01 to 100
        slider.setValue(self._to_slider(f))
        spin = QDoubleSpinBox()
        spin.setLocale(QLocale.c())
        spin.setDecimals(2)
        spin.setRange(0, 1000)
        spin.setValue(f)
        spin.setPrefix("×")
        if default:
            spin.setToolTip(f"The default: {_num(spec.get('default', 1))} (not written in the text)")
        h.addWidget(slider, 1)
        h.addWidget(spin)
        slider.valueChanged.connect(lambda v: (spin.blockSignals(True), spin.setValue(self._from_slider(v)),
                                               spin.blockSignals(False), self._factor_timer.start()))
        slider.sliderReleased.connect(self._commit_factor)
        spin.editingFinished.connect(self._commit_factor)
        form.addRow(self._label(name, arg_type(spec) + (f", default {_num(spec['default'])}" if "default" in spec
                                                        else "")), row)
        self.fields[name] = spin
        self.fields["factor_slider"] = slider
        self._factor_name = name

    @staticmethod
    def _to_slider(f: float) -> int:
        return round((math.log10(max(0.01, min(100.0, f))) + 2) * 250)

    @staticmethod
    def _from_slider(v: int) -> float:
        f = 10 ** (v / 250 - 2)
        return round(f, 2) if f < 10 else round(f, 1)

    def _commit_factor(self) -> None:
        self._factor_timer.stop()
        name = getattr(self, "_factor_name", "")
        spin = self.fields.get(name)
        if spin is None or self.node is None:
            return
        v = round(spin.value(), 4)
        if abs(v - float(self.node.get(name, 1))) > 1e-9:
            self._emit({name: v})

    def _enum(self, form: QFormLayout, node: dict, spec: dict) -> None:
        name = spec.get("name", "")
        box = QComboBox()
        for v in spec.get("values", []):
            box.addItem(v, v)
        box.setCurrentIndex(max(0, box.findData(node.get(name, spec.get("default")))))
        box.setToolTip(spec.get("doc", ""))
        box.activated.connect(lambda *_: box.currentData() != node.get(name, spec.get("default"))
                              and self._emit({name: box.currentData()}))
        form.addRow(self._label(name, arg_type(spec) + (f", default {spec['default']}" if "default" in spec else "")),
                    box)
        self.fields[name] = box

    def _text(self, form: QFormLayout, node: dict, spec: dict) -> None:
        """A param of a type the panel has no field of its own for: its words."""
        name = spec.get("name", "")
        e = QLineEdit(str(node.get(name, "")))
        e.setToolTip(spec.get("doc", ""))
        e.editingFinished.connect(lambda: e.text().strip() != str(node.get(name, "")) and
                                  self._emit({name: e.text().strip()}))
        form.addRow(self._label(name, spec.get("type", "text")), e)
        self.fields[name] = e

    def _number(self, form: QFormLayout, node: dict, name: str, spec: dict) -> None:
        spin = QDoubleSpinBox()
        spin.setLocale(QLocale.c())
        spin.setDecimals(2)
        spin.setRange(float(spec.get("min", 0)), float(spec.get("max", 100000)))
        spin.setSingleStep(0.1 if spec.get("max", 10) <= 1 else 0.5)
        spin.setValue(float(node.get(name, spec.get("default", 0)) or 0))
        is_default = name in node.get("defaults", [])
        if is_default:
            spin.setStyleSheet("color: #8b95a6;")
            spin.setToolTip(f"The default ({_num(spec.get('default'))}): not written in the text")
        else:
            spin.setToolTip(spec.get("doc", ""))

        def done():
            v = round(spin.value(), 4)
            if abs(v - float(node.get(name, 0) or 0)) > 1e-9:
                self._emit({name: v})

        spin.editingFinished.connect(done)
        t = arg_type(spec) + (f", default {_num(spec['default'])}" if "default" in spec else "")
        form.addRow(self._label(name, t), spin)
        self.fields[name] = spin

    def _ref(self, form: QFormLayout, node: dict, spec: dict) -> None:
        field = spec.get("name", "")
        box = QComboBox()
        here = (self.path or ("",))[0]
        for n in M.tree_names(self.doc):
            if n != here:
                box.addItem(n, n)
        for n, says in M.ENGINE_TREES.items():
            box.addItem(n, n)
            box.setItemData(box.count() - 1, says, Qt.ItemDataRole.ToolTipRole)
        box.setCurrentIndex(max(0, box.findData(node.get(field, ""))))

        def chosen(*_):
            v = box.currentData()
            if v and v != node.get(field):
                self._emit({field: v})

        box.activated.connect(chosen)
        box.setToolTip(spec.get("doc", ""))
        form.addRow(self._label(field, "a tree of this text, or one the server writes"), box)
        self.fields[field] = box
        name = node.get(field, "")
        if M.tree(self.doc, name) is not None:
            n = len(M.uses(self.doc, name))
            b = QPushButton(f"Edit the tree {name} (used in {n} place{'s' if n != 1 else ''})")
            b.clicked.connect(lambda: self.open_tree.emit(name))
            form.addRow("", b)
        elif name in M.ENGINE_TREES:
            d = QLabel(M.ENGINE_TREES[name])
            d.setWordWrap(True)
            d.setEnabled(False)
            form.addRow("", d)

    def _comments(self, form: QFormLayout, node: dict) -> None:
        above = QPlainTextEdit("\n".join(a.lstrip("#").strip() for a in node.get("above", []) if a.strip()))
        above.setPlaceholderText("Lines of comment above the node")
        above.setFixedHeight(54)
        line = QLineEdit(node.get("comment", "").strip())
        line.setPlaceholderText("A comment at the end of its line")

        def commit_line():
            v = line.text().strip()
            if v != node.get("comment", "").strip():
                self._emit({"comment": v or None})

        def commit_above():
            lines = [x.strip() for x in above.toPlainText().splitlines() if x.strip()]
            old = [a.lstrip("#").strip() for a in node.get("above", []) if a.strip()]
            if lines != old:
                keep_blank = [""] if node.get("above", [""])[:1] == [""] else []
                self._emit({"above": keep_blank + ["# " + x for x in lines] or None})

        line.editingFinished.connect(commit_line)
        above.focusOutEvent = lambda e, f=above.focusOutEvent: (commit_above(), f(e))[1]
        form.addRow(self._label("comment", "on its line"), line)
        form.addRow(self._label("above", "comment lines"), above)
        self.fields["comment"] = line
        self.fields["above"] = above

    def _about(self, form: QFormLayout, name: str) -> None:
        """The tree's own comment, above its header: what it is for."""
        lines = [a.lstrip("#").strip() for a in (M.tree(self.doc, name) or {}).get("above", []) if a.strip()]
        box = QPlainTextEdit("\n".join(lines))
        box.setPlaceholderText(f"What the tree {name} is for (comment lines above it)")
        box.setFixedHeight(54)

        def commit():
            new = [x.strip() for x in box.toPlainText().splitlines() if x.strip()]
            if new != lines and not self.read_only:
                self.about_changed.emit(name, new)

        box.focusOutEvent = lambda e, f=box.focusOutEvent: (commit(), f(e))[1]
        form.addRow(self._label("the tree", "what it is for"), box)
        self.fields["about"] = box

    def _emit(self, fields: dict) -> None:
        if self.read_only or self.path is None:
            return
        self.changed.emit(self.path, fields)


def _esc(s: str) -> str:
    return (s or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
