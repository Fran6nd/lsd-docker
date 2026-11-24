# editor.py -- the text pane and the outline's model
# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""A plain-text editor for one tree text (line numbers, tabs, colours
from the engine's schema, mistakes underlined) and a read-only model of
the engine's JSON tree for the outline. Neither knows the grammar: the
colours come from the schema's word lists, the outline from the fields
the engine's parser gave."""

from __future__ import annotations

import re

from PySide6.QtCore import QAbstractItemModel, QModelIndex, QRect, QSize, Qt
from PySide6.QtGui import (QColor, QFont, QFontDatabase, QFontInfo, QPainter, QSyntaxHighlighter, QTextCharFormat,
                           QTextCursor, QTextFormat)
from PySide6.QtWidgets import QPlainTextEdit, QTextEdit, QWidget

NUMBER = re.compile(r"^x?-?\d+(\.\d+)?$")


def fixed_font(size: int) -> QFont:
    """A monospace font: the system's, or the first well-known one there is."""
    font = QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont)
    if not QFontInfo(font).fixedPitch():
        font = QFont()
        font.setFamilies(["Menlo", "Consolas", "DejaVu Sans Mono", "Liberation Mono", "Courier New"])
        font.setStyleHint(QFont.StyleHint.Monospace)
        font.setFixedPitch(True)
    font.setPointSize(size)
    return font


def _dark(widget: QWidget) -> bool:
    return widget.palette().base().color().lightness() < 128


def _colours(dark: bool) -> dict[str, str]:
    if dark:
        return {"kind": "#6cb6ff", "action": "#7ee787", "question": "#f0b060", "trait": "#d2a8ff",
                "place": "#79d9d9", "number": "#e6c07b", "comment": "#8b949e", "name": "#ffffff"}
    return {"kind": "#0550ae", "action": "#1a7f37", "question": "#9a5b00", "trait": "#8250df",
            "place": "#0b7285", "number": "#7a4e00", "comment": "#6e7781", "name": "#000000"}


class TreeHighlighter(QSyntaxHighlighter):
    """Colours by the schema: node keywords, known words by kind, comments."""

    def __init__(self, document, dark: bool):
        super().__init__(document)
        self._formats: dict[str, QTextCharFormat] = {}
        for key, colour in _colours(dark).items():
            f = QTextCharFormat()
            f.setForeground(QColor(colour))
            if key in ("kind", "name"):
                f.setFontWeight(QFont.Weight.Bold)
            if key == "comment":
                f.setFontItalic(True)
            self._formats[key] = f
        self._kinds: set[str] = set()
        self._params: set[str] = set()
        self._words: dict[str, str] = {}

    def set_schema(self, schema: dict | None) -> None:
        self._kinds, self._params, self._words = set(), set(), {}
        for kind in (schema or {}).get("kinds", []):
            self._kinds.add(kind.get("name", ""))
            for p in kind.get("params", []):
                self._params.add(p.get("name", ""))
        for key, style in (("places", "place"), ("traits", "trait"), ("scores", "question"),
                           ("conditions", "question"), ("actions", "action")):
            for w in (schema or {}).get(key, []):
                for name in (w.get("name"), w.get("alias")):
                    if name:
                        self._words[name] = style
        self.rehighlight()

    def highlightBlock(self, text: str) -> None:
        hash_at = text.find("#")
        code = text if hash_at < 0 else text[:hash_at]
        if hash_at >= 0:
            self.setFormat(hash_at, len(text) - hash_at, self._formats["comment"])
        first = True
        for m in re.finditer(r"\S+", code):
            word, style = m.group(), None
            if first and word in self._kinds:
                style = "kind"
            elif word.endswith(":") and not first:
                style = "name"
            elif "=" in word and word.split("=", 1)[0] in self._params:
                style = "number"
            elif NUMBER.match(word):
                style = "number"
            elif not first and word in self._words:
                style = self._words[word]
            if style:
                self.setFormat(m.start(), len(word), self._formats[style])
            first = False


class _LineNumbers(QWidget):
    def __init__(self, editor: "CodeEditor"):
        super().__init__(editor)
        self.editor = editor

    def sizeHint(self) -> QSize:
        return QSize(self.editor.number_width(), 0)

    def paintEvent(self, event) -> None:
        self.editor.paint_numbers(event)


class CodeEditor(QPlainTextEdit):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setFont(fixed_font(13))
        self.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        self.setTabStopDistance(4 * self.fontMetrics().horizontalAdvance(" "))
        self.highlighter = TreeHighlighter(self.document(), _dark(self))
        self._numbers = _LineNumbers(self)
        self._diagnostics: list[dict] = []
        self._problem_lines: set[int] = set()
        self.blockCountChanged.connect(self._layout_numbers)
        self.updateRequest.connect(self._scroll_numbers)
        self.cursorPositionChanged.connect(self._decorate)
        self._layout_numbers()

    # -- line numbers
    def number_width(self) -> int:
        digits = max(3, len(str(self.blockCount())))
        return 14 + self.fontMetrics().horizontalAdvance("9") * digits

    def _layout_numbers(self, *_):
        self.setViewportMargins(self.number_width(), 0, 0, 0)

    def _scroll_numbers(self, rect: QRect, dy: int):
        if dy:
            self._numbers.scroll(0, dy)
        else:
            self._numbers.update(0, rect.y(), self._numbers.width(), rect.height())

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        r = self.contentsRect()
        self._numbers.setGeometry(QRect(r.left(), r.top(), self.number_width(), r.height()))

    def paint_numbers(self, event) -> None:
        painter = QPainter(self._numbers)
        painter.fillRect(event.rect(), self.palette().alternateBase())
        block = self.firstVisibleBlock()
        top = round(self.blockBoundingGeometry(block).translated(self.contentOffset()).top())
        normal, bad = self.palette().placeholderText().color(), QColor("#d1242f")
        while block.isValid() and top <= event.rect().bottom():
            height = round(self.blockBoundingRect(block).height())
            if block.isVisible() and top + height >= event.rect().top():
                n = block.blockNumber() + 1
                painter.setPen(bad if n in self._problem_lines else normal)
                painter.drawText(0, top, self._numbers.width() - 6, self.fontMetrics().height(),
                                 Qt.AlignmentFlag.AlignRight, ("! " if n in self._problem_lines else "") + str(n))
            block = block.next()
            top += height
        painter.end()

    # -- typing: a tab a step, and a new line keeps the indentation
    def keyPressEvent(self, event) -> None:
        if event.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter) and not event.modifiers() & ~Qt.KeyboardModifier.KeypadModifier:
            line = self.textCursor().block().text()
            indent = line[:len(line) - len(line.lstrip(" \t"))]
            self.textCursor().insertText("\n" + indent)
            self.ensureCursorVisible()
            return
        super().keyPressEvent(event)

    # -- places
    def current_line(self) -> int:
        return self.textCursor().blockNumber() + 1

    def goto(self, line: int, column: int = 0, select_line: bool = False) -> None:
        block = self.document().findBlockByNumber(max(0, line - 1))
        if not block.isValid():
            return
        cursor = QTextCursor(block)
        if select_line:
            cursor.movePosition(QTextCursor.MoveOperation.EndOfBlock)
            cursor.setPosition(block.position() + len(block.text()) - len(block.text().lstrip(" \t")),
                               QTextCursor.MoveMode.KeepAnchor)
        elif column > 0:
            cursor.setPosition(block.position() + min(column - 1, len(block.text())))
        self.setTextCursor(cursor)
        self.centerCursor()

    # -- mistakes
    def set_diagnostics(self, diagnostics: list[dict]) -> None:
        self._diagnostics = list(diagnostics)
        self._problem_lines = {d.get("line", 0) for d in diagnostics if d.get("line", 0) > 0}
        self._decorate()
        self._numbers.update()

    def diagnostic_selections(self) -> list[QTextEdit.ExtraSelection]:
        out = []
        for d in self._diagnostics:
            block = self.document().findBlockByNumber(d.get("line", 0) - 1)
            if d.get("line", 0) < 1 or not block.isValid():
                continue
            text, column = block.text(), d.get("column", 0)
            if column >= 1 and column <= len(text):
                start = column - 1
                m = re.match(r"\S+", text[start:])
                end = start + (len(m.group()) if m else 1)
            else:                              # not in one word: the whole line's words
                start, end = len(text) - len(text.lstrip(" \t")), max(len(text.rstrip()), 1)
            sel = QTextEdit.ExtraSelection()
            sel.cursor = QTextCursor(block)
            sel.cursor.setPosition(block.position() + start)
            sel.cursor.setPosition(block.position() + min(end, len(text)), QTextCursor.MoveMode.KeepAnchor)
            sel.format.setUnderlineStyle(QTextCharFormat.UnderlineStyle.WaveUnderline)
            sel.format.setUnderlineColor(QColor("#d1242f"))
            sel.format.setBackground(QColor(209, 36, 47, 40))
            sel.format.setToolTip(d.get("message", ""))
            out.append(sel)
        return out

    def _decorate(self) -> None:
        line = QTextEdit.ExtraSelection()
        line.format.setBackground(self.palette().alternateBase())
        line.format.setProperty(QTextFormat.Property.FullWidthSelection, True)
        line.cursor = self.textCursor()
        line.cursor.clearSelection()
        self.setExtraSelections([line, *self.diagnostic_selections()])


# ---- the outline ------------------------------------------------------------

STRUCTURE = {"id", "kind", "line", "column", "text", "children", "comment", "above", "defaults", "args",
             "name", "header", "root"}
WORD_FIELDS = ("action", "cond", "score", "ref")


class _Item:
    def __init__(self, data: dict, parent: "_Item | None", is_tree: bool = False):
        self.data, self.parent, self.is_tree = data, parent, is_tree
        self.children: list[_Item] = []

    @property
    def row(self) -> int:
        return self.parent.children.index(self) if self.parent else 0


def _number(v) -> str:
    return f"{v:g}" if isinstance(v, float) else str(v)


class OutlineModel(QAbstractItemModel):
    """The engine's `lsd-bt` document, read-only. Phase 2 edits this
    structure and makes text again through the engine (`--from-json`)."""

    COLUMNS = ["Node", "Word", "Settings", "Defaults", "Comment"]

    def __init__(self, parent=None):
        super().__init__(parent)
        self._root = _Item({}, None)
        self._by_line: dict[int, _Item] = {}
        self.document: dict | None = None

    def set_document(self, doc: dict | None) -> None:
        self.beginResetModel()
        self.document = doc
        self._root = _Item({}, None)
        self._by_line = {}
        for file in (doc or {}).get("files", []):
            for tree in file.get("trees", []):
                t = _Item(tree, self._root, is_tree=True)
                self._root.children.append(t)
                if tree.get("header", True):
                    self._by_line[tree.get("line", 0)] = t
                if tree.get("root"):
                    self._add(tree["root"], t)
        self.endResetModel()

    def _add(self, node: dict, parent: _Item) -> None:
        item = _Item(node, parent)
        parent.children.append(item)
        self._by_line[node.get("line", 0)] = item
        for child in node.get("children", []):
            self._add(child, item)

    # -- lines
    def line_of(self, index: QModelIndex) -> int:
        return index.internalPointer().data.get("line", 0) if index.isValid() else 0

    def index_for_line(self, line: int) -> QModelIndex:
        item = self._by_line.get(line)
        return self.createIndex(item.row, 0, item) if item else QModelIndex()

    # -- the model
    def index(self, row, column, parent=QModelIndex()) -> QModelIndex:
        p = parent.internalPointer() if parent.isValid() else self._root
        return self.createIndex(row, column, p.children[row]) if 0 <= row < len(p.children) else QModelIndex()

    def parent(self, index: QModelIndex) -> QModelIndex:
        if not index.isValid():
            return QModelIndex()
        p = index.internalPointer().parent
        return QModelIndex() if p is None or p is self._root else self.createIndex(p.row, 0, p)

    def rowCount(self, parent=QModelIndex()) -> int:
        if parent.column() > 0:
            return 0
        return len((parent.internalPointer() if parent.isValid() else self._root).children)

    def columnCount(self, parent=QModelIndex()) -> int:
        return len(self.COLUMNS)

    def headerData(self, section, orientation, role=Qt.ItemDataRole.DisplayRole):
        if orientation == Qt.Orientation.Horizontal and role == Qt.ItemDataRole.DisplayRole:
            return self.COLUMNS[section]
        return None

    def flags(self, index):
        return Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable if index.isValid() else Qt.ItemFlag.NoItemFlags

    def _cells(self, item: _Item) -> list[str]:
        d = item.data
        above = " ".join(a.lstrip("# ") for a in d.get("above", []) if a.strip())
        comment = " / ".join(c for c in (above, d.get("comment", "")) if c)
        if item.is_tree:
            return ["tree", d.get("name", ""), "", "", comment]
        defaults = set(d.get("defaults", []))
        word = next((str(d[f]) for f in WORD_FIELDS if f in d), "")
        written = [f"{k}={_number(v)}" for k, v in d.items()
                   if k not in STRUCTURE and k not in WORD_FIELDS and k not in defaults]
        written += [str(a) for a in d.get("args", [])]
        greyed = [f"{k}={_number(d[k])}" for k in d.get("defaults", []) if k in d]
        return [d.get("kind", ""), word, " ".join(written), " ".join(greyed), comment]

    def data(self, index, role=Qt.ItemDataRole.DisplayRole):
        if not index.isValid():
            return None
        item = index.internalPointer()
        if role == Qt.ItemDataRole.DisplayRole:
            return self._cells(item)[index.column()]
        if role == Qt.ItemDataRole.ToolTipRole:
            return "line %d: %s" % (item.data.get("line", 0), item.data.get("text", "tree " + item.data.get("name", "")))
        if role == Qt.ItemDataRole.ForegroundRole and index.column() in (3, 4):
            return QColor("#8b949e")
        if role == Qt.ItemDataRole.FontRole and index.column() < (2 if item.is_tree else 1):
            f = QFont()
            f.setBold(True)
            return f
        return None
