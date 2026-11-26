# diagram.py -- the tree drawn: cards, automatic layout, selection, edits by hand
# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""The diagram of one tree: a QGraphicsView over cards laid out by
layout.py (A, top-down, the main view; B, left to right). It draws the
engine's JSON document (model.py) and asks for edits; it never changes
the document itself: the window has the engine make the text again,
and gives the diagram the new document."""

from __future__ import annotations

import functools
import math

from PySide6.QtCore import QPointF, QRectF, QSize, Qt, QTimer, Signal
from PySide6.QtGui import (QAction, QBrush, QColor, QFont, QFontMetricsF, QKeySequence, QPainter,
                           QPainterPath, QPen, QPixmap, QPolygonF)
from PySide6.QtWidgets import (QDialog, QFrame, QGraphicsItem, QGraphicsScene, QGraphicsView, QHBoxLayout, QLabel,
                               QLineEdit, QListWidget, QListWidgetItem, QMenu, QToolButton, QToolTip, QVBoxLayout,
                               QWidget)

from . import layout as L
from . import model as M

# ---- the look: the proof of concept's palette ---------------------------------------------

LIGHT = {
    "bg": "#f5f6f8", "canvas": "#f1f3f6", "dot": "#dde1e8", "panel": "#ffffff", "card": "#ffffff", "band": "#f7f8fa",
    "border": "#d6dae1", "border_strong": "#a9b0bc", "text": "#1c2230", "muted": "#5d6779", "faint": "#8b95a6",
    "hover": "#eef2fb", "sel": "#2f6fed", "run": "#14975a", "edge": "#aeb5c1", "frame": "#b4458f", "chip": "#eef0f4",
    "warn": "#b42318", "warn_bg": "#fdecea",
    "k_comp": "#5b6677", "k_pick": "#b8740a", "k_dec": "#7454c0", "k_cond": "#0d8585", "k_act": "#2d6bd0",
    "k_ref": "#b4458f",
    "t_none": "#7c8595", "t_aggression": "#cf3f35", "t_caution": "#0f8577", "t_objective": "#c96f00",
    "t_teamwork": "#2f6fd6", "t_builder": "#8f6237", "t_marksman": "#8350d0", "t_flank": "#c4417f",
    "t_stealth": "#556479", "t_curiosity": "#8d8500", "t_greed": "#3d8f24",
}
DARK = {
    "bg": "#121418", "canvas": "#15181d", "dot": "#23272f", "panel": "#1a1d23", "card": "#1f232a", "band": "#242931",
    "border": "#3a414c", "border_strong": "#596170", "text": "#e5e8ee", "muted": "#a1aaba", "faint": "#6f7886",
    "hover": "#262d3a", "sel": "#6b98ff", "run": "#3fcf7a", "edge": "#4b525e", "frame": "#e07ac0", "chip": "#2a2f38",
    "warn": "#ff8a80", "warn_bg": "#3a1d1d",
    "k_comp": "#a6afbd", "k_pick": "#f0aa3c", "k_dec": "#a98cf2", "k_cond": "#3dc6c0", "k_act": "#73a3ff",
    "k_ref": "#e07ac0",
    "t_none": "#9aa3b2", "t_aggression": "#ff7b70", "t_caution": "#3fcfb9", "t_objective": "#ffa53d",
    "t_teamwork": "#75a6ff", "t_builder": "#d09a63", "t_marksman": "#b994ff", "t_flank": "#ff7fb8",
    "t_stealth": "#93a3ba", "t_curiosity": "#d6cc3a", "t_greed": "#7fd35f",
}
def family(schema: dict | None, kind: str) -> str:
    """The colour family of a kind, from its shape in the schema: its children,
    and the type of the word it takes."""
    info = M.kind_info(schema, kind)
    rule = info.get("children", "none")
    types = {p.get("type") for p in info.get("params", [])}
    if rule == "options" or info.get("parent"):
        return "pick"
    if rule == "many":
        return "comp"
    if rule == "one":
        return "dec"
    if "tree" in types:
        return "ref"
    if "cond" in types:
        return "cond"
    return "act"


class Theme:
    def __init__(self, dark: bool, schema: dict | None = None):
        self.dark = dark
        self.schema = schema
        self.c = {k: QColor(v) for k, v in (DARK if dark else LIGHT).items()}

    def __getitem__(self, key: str) -> QColor:
        return self.c[key]

    def kind(self, kind: str) -> QColor:
        return self.c["k_" + family(self.schema, kind)]

    def trait(self, name: str) -> QColor:
        return self.c.get("t_" + (name or "none"), self.c["t_none"])

    @staticmethod
    def alpha(c: QColor, a: float) -> QColor:
        c = QColor(c)
        c.setAlphaF(a)
        return c


@functools.lru_cache(maxsize=None)
def _font(px: float, weight: int = 400, italic: bool = False) -> QFont:
    """A font of the cards. Made when it is first used -- by then the
    application exists: a QFont made before it has no family, and is
    measured wider than it is drawn (the cards' widths went wrong)."""
    f = QFont()
    f.setPixelSize(max(1, round(px)))
    f.setWeight(QFont.Weight(weight))
    f.setItalic(italic)
    return f


def _qf(spec: tuple) -> QFont:
    return _font(*spec)


F_LABEL = (12.5, 600)
F_REST = (12,)
F_KW = (11.5, 500)
F_CMT = (11.3, 400, True)
F_NUM = (11.5,)
F_CHIP = (10.8,)
F_TAG = (10.8, 600)
F_BADGE = (10, 650)
F_FRAME = (11, 600)

G_LABEL, G_COMMENT, G_CHIPS, G_STRIP, G_PAD = 28.0, 14.0, 22.0, 12.0, 5.0


def _tw(font: tuple, text: str) -> float:
    return QFontMetricsF(_qf(font)).horizontalAdvance(text)


def _clip(font: tuple, text: str, width: float) -> str:
    return QFontMetricsF(_qf(font)).elidedText(text, Qt.TextElideMode.ElideRight, max(0.0, width))


def _wrap(text: str, width: float, most: int = 2) -> list[str]:
    fm = QFontMetricsF(_qf(F_CMT))
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = cur + " " + w if cur else w
        if fm.horizontalAdvance(t) <= width or not cur:
            cur = t
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    if len(lines) > most:
        lines = lines[:most]
        lines[-1] = fm.elidedText(lines[-1] + " …", Qt.TextElideMode.ElideRight, width)
        if not lines[-1].endswith("…"):
            lines[-1] = fm.elidedText(lines[-1] + " xxxxxxxxxxxx", Qt.TextElideMode.ElideRight, width)
    return [fm.elidedText(x, Qt.TextElideMode.ElideRight, width) for x in lines]


def _n(v) -> str:
    if v is None:
        return ""
    if isinstance(v, float):
        return f"{round(v, 2):g}"
    return str(v)


# ---- what a row says ------------------------------------------------------------------

def _unit(spec: dict) -> str:
    return " s" if "secs" in spec.get("written", "") else ""


def row_words(schema: dict | None, node: dict) -> tuple[str, str, str]:
    """(keyword, main word, the rest) of a node, from its fields and the
    schema's params of its kind."""
    k = node.get("kind", "")
    if k in M.chooser_kinds(schema):
        if M.is_roll(node):
            return k, "a lottery at every choice" if "every" not in M.left_out(node) else "a role, drawn by lot", ""
        return k, "a priority list" if M.is_priority_list(node) else "the option worth most", ""
    if M.is_ref(node):
        return k, node.get("ref", ""), ""
    main, rest = "", []
    for p in M.params(schema, k):
        name, t = p.get("name", ""), p.get("type")
        if name not in node or name in node.get("defaults", []) or t == "trait":
            continue
        if t in M.WORD_LISTS:
            main = str(node[name])
            rest += [str(a) for a in node.get("args", [])]
        elif not main and p.get("required"):
            main = _n(node[name]) + _unit(p)
        else:
            rest.append(f"{name} {_n(node[name])}{_unit(p)}")
    if not main and k in M.TRIES:
        main = {"all": "in order, while each succeeds", "first": "the first that does not fail"}[M.TRIES[k]]
        return k, "", main
    return k, main, " ".join(rest)


def pick_chips(schema: dict | None, node: dict) -> list[tuple[str, bool]]:
    """(text, is a default) for each setting of a pick, as drawn: from its kind's params."""
    defaults, gone = set(node.get("defaults", [])), M.left_out(node)
    out = []
    for p in M.params(schema, node.get("kind", "")):
        name = p.get("name", "")
        if name in gone or name not in node and "default" not in p:
            continue
        v = node.get(name, p.get("default"))
        if p.get("type") == "enum" and v == p.get("default"):
            continue
        out.append((f"{name} {_n(v)}{_unit(p)}", name in defaults or name not in node))
    if M.log_scale(node) and not M.is_priority_list(node):
        out.append(("bars log scale", False))
    return out


def node_title(schema: dict | None, node: dict) -> str:
    return node.get("text") or " ".join(x for x in row_words(schema, node) if x)


# ---- the scene's geometry: one record a block -------------------------------------------

class RowGeo:
    __slots__ = ("path", "node", "y", "h", "lines", "band")

    def __init__(self, path, node, y, h, lines, band):
        self.path, self.node, self.y, self.h, self.lines, self.band = path, node, y, h, lines, band


class Drawing:
    """A laid-out tree: its blocks, boxes, rows and the zones one can click."""

    def __init__(self):
        self.root: M.Block | None = None
        self.blocks: list[M.Block] = []
        self.box: dict[str, L.Box] = {}
        self.rows: dict[str, list[RowGeo]] = {}
        self.zones: list[tuple[QRectF, str, object]] = []     # (rect, what, payload)
        self.bounds = QRectF()
        self.companion: Companion | None = None


class Companion:
    """A tree drawn beside the one shown, read-only: its `<name>_also`."""

    def __init__(self, name: str, root: M.Block, box: L.Box, frame: QRectF):
        self.name, self.root, self.box, self.frame = name, root, box, frame


def natural_width(schema: dict | None, block: M.Block) -> float:
    if block.note:
        return 300.0
    w = 0.0
    for path, node in block.rows:
        kw, main, rest = row_words(schema, node)
        x = 34 + (_tw(F_KW, kw) + 6 if kw else 0) + _tw(F_LABEL, main) + (_tw(F_REST, rest) + 7 if rest else 0)
        if "trait" in node:
            x += _tw(F_TAG, node.get("trait", "")) + 20 + 104
        if M.is_ref(node):
            x += REF_CHIP + 10
        if node.get("kind") in M.chooser_kinds(schema) and node is block.core[1]:
            chips = pick_chips(schema, node)
            x = max(x, 12 + sum(_tw(F_CHIP, t) + 17 for t, _ in chips) + 8)
        w = max(w, x + 16)
        cm = " · ".join(M.comments(node))
        if cm:
            w = max(w, min(_tw(F_CMT, cm) + 30, 300))
    return w


def measure(schema: dict | None, block: M.Block, width: float) -> list[RowGeo]:
    if block.note:
        lines = _wrap(block.note, width - 26, most=6)
        return [RowGeo(block.top[0], block.top[1], 0.0, 12 + len(lines) * G_COMMENT + 8, lines, False)]
    out, y = [], 0.0
    for i, (path, node) in enumerate(block.rows):
        core = i == len(block.rows) - 1
        h = G_LABEL
        cm = M.comments(node)
        lines = _wrap(" · ".join(cm), width - 26) if cm else []
        h += len(lines) * G_COMMENT + (G_PAD if lines else 0)
        if core and node.get("kind") in M.chooser_kinds(schema):
            h += G_CHIPS * len(chip_lines(pick_chips(schema, node), width)) + (G_STRIP if M.is_roll(node) else 0)
        out.append(RowGeo(path, node, y, h, lines, not core))
        y += h
    return out


def chip_lines(chips: list[tuple[str, bool]], width: float) -> list[list[tuple[float, str, bool]]]:
    """The settings' chips in lines that fit the card: (x, text, is a default)."""
    lines, cur, x = [], [], 12.0
    for text, is_def in chips:
        cw = _tw(F_CHIP, text) + 12
        if cur and x + cw > width - 12:
            lines.append(cur)
            cur, x = [], 12.0
        cur.append((x, text, is_def))
        x += cw + 5
    return lines + [cur] if cur else lines or [[]]


REF_CHIP = 78.0           # the chip that shows a reference in place, or hides it
FOLD_NOTE = 18.0          # the line under a folded card: "12 hidden"


def build_drawing(doc: dict, root: str, view: str, opened: set, folded: set, open_all: bool,
                  schema: dict | None = None, also: bool = False) -> Drawing:
    """The tree `root` laid out; with `also`, its `<root>_also` beside it, read-only."""
    d = Drawing()
    d.root = M.build_blocks(doc, root, schema, opened, folded, open_all)
    if d.root is None:
        return d
    rows: dict[str, list[RowGeo]] = {}

    def box(b: M.Block) -> L.Box:
        bx = L.Box(b, [box(k) for k in b.kids], natural_width(schema, b), frame=b.opened,
                   foot=FOLD_NOTE if b.folded else 0.0)
        d.box[b.key] = bx
        d.blocks.append(b)
        return bx

    def height(bx: L.Box, w: float) -> float:
        r = measure(schema, bx.key, w)
        rows[bx.key.key] = r
        return r[-1].y + r[-1].h

    lay = L.layout_a if view == "A" else L.layout_b
    top = box(d.root)
    lay(top, height)
    name = root + M.ALSO
    d.companion = None
    if also and M.tree(doc, name) is not None and not root.endswith(M.ALSO):
        other = M.build_blocks(doc, name, schema, opened, folded, open_all, via=("also",), chain=(root,))
        obox = box(other)
        lay(obox, height)
        L.place_beside(top, obox, gap=64)
        x, y, w, h = L.bounds(obox)
        d.companion = Companion(name, other, obox, QRectF(x - L.FRAME_PAD, y - L.FRAME_HEAD - 6,
                                                         w + 2 * L.FRAME_PAD, h + L.FRAME_HEAD + 6 + L.FRAME_PAD))
    d.rows = rows
    x, y, w, h = L.bounds(top)
    r = QRectF(x, y, w, h)
    if d.companion:
        r = r.united(d.companion.frame)
    d.bounds = r.adjusted(-40, -30, 100, 40)
    # what can be clicked besides a row
    for b in d.blocks:
        bx = d.box[b.key]
        if b.ref is not None and b.ref_known:
            d.zones.append((QRectF(bx.x + bx.w - REF_CHIP - 8, bx.y + rows[b.key][-1].y + 5, REF_CHIP, 20), "ref", b))
        if bx.fr and b.ref_state == "text":
            fx, fy, fw, fh = bx.fr
            d.zones.append((QRectF(fx, fy, fw, 22), "frame", b))
        if (b.kids or b.folded) and b.ref is None:
            cx, cy = knob_at(bx, view)
            d.zones.append((QRectF(cx - 8, cy - 8, 16, 16), "fold", b))
    if d.companion:
        f = d.companion.frame
        d.zones.append((QRectF(f.x(), f.y(), f.width(), 22), "also", d.companion))
    return d


def knob_at(bx: L.Box, view: str) -> tuple[float, float]:
    """Where the knob that folds a card's children is: on the line down to them."""
    if view == "A":
        return bx.x + L.A_RAIL, bx.y + bx.h
    return bx.x + bx.w, bx.y + 14


def edge_points(bx: L.Box, kx: L.Box, view: str) -> list[tuple[float, float]]:
    """The line from a card to one of its children: down the parent's rail and
    across into the child (A), or across and down (B); never through a card."""
    if view == "A":
        sx = bx.x + L.A_RAIL
        return [(sx, bx.y + bx.h), (sx, kx.y + 14), (kx.x, kx.y + 14)]
    sx, sy = bx.x + bx.w, bx.y + 14
    return [(sx, sy), (sx + 20, sy), (sx + 20, kx.y + 14), (kx.x, kx.y + 14)]


def badge_at(bx: L.Box, kx: L.Box, view: str) -> QPointF:
    """Where a child's number is drawn: on the line into it."""
    if view == "A":
        return QPointF(bx.x + L.A_RAIL, kx.y + 14)
    return QPointF(kx.x - 13, kx.y + 14)


def _rounded(points: list[tuple[float, float]], r: float = 6.0) -> QPainterPath:
    p = QPainterPath(QPointF(*points[0]))
    for i in range(1, len(points) - 1):
        (x0, y0), (x1, y1), (x2, y2) = points[i - 1], points[i], points[i + 1]
        d1, d2 = math.hypot(x1 - x0, y1 - y0), math.hypot(x2 - x1, y2 - y1)
        rr = min(r, d1 / 2, d2 / 2)
        if rr < 0.5:
            p.lineTo(x1, y1)
            continue
        p.lineTo(x1 - (x1 - x0) / d1 * rr, y1 - (y1 - y0) / d1 * rr)
        p.quadTo(x1, y1, x1 + (x2 - x1) / d2 * rr, y1 + (y2 - y1) / d2 * rr)
    p.lineTo(*points[-1])
    return p


# ---- icons, 14 x 14 ------------------------------------------------------------------------

ICONS = {"seq", "select", "pick", "option", "if", "unless", "do", "wait", "cooldown", "limit", "tree"}

def draw_icon(p: QPainter, kind: str, fam: str, x: float, y: float, c: QColor, card: QColor) -> None:
    """The icon of a kind: the shipped kinds have their own; a kind the
    engine adds later is drawn with its family's (composite, pick, condition,
    action, reference, decorator)."""
    if kind not in ICONS:
        kind = {"comp": "seq", "pick": "pick", "cond": "if", "act": "do", "ref": "tree"}.get(fam, "")
    p.save()
    p.translate(x, y)
    pen = QPen(c, 1.6)
    pen.setCapStyle(Qt.PenCapStyle.RoundCap)
    pen.setJoinStyle(Qt.PenJoinStyle.RoundJoin)
    p.setPen(pen)
    p.setBrush(Qt.BrushStyle.NoBrush)
    if kind == "seq":
        p.setPen(QPen(c, 1.8, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin))
        p.drawLine(QPointF(1, 7), QPointF(12, 7))
        p.drawPolyline(QPolygonF([QPointF(8, 3), QPointF(12, 7), QPointF(8, 11)]))
    elif kind == "select":
        p.drawEllipse(QPointF(7, 7), 6.2, 6.2)
        p.setFont(_font(10, 800))
        p.drawText(QRectF(0, 0, 14, 14), Qt.AlignmentFlag.AlignCenter, "?")
    elif kind == "pick":
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(c)
        for yy, ww in ((1.5, 12), (5.7, 8), (9.9, 4.5)):
            p.drawRoundedRect(QRectF(1, yy, ww, 2.6), 1.3, 1.3)
    elif kind == "option":
        p.drawPolygon(QPolygonF([QPointF(7, 1.5), QPointF(12.5, 7), QPointF(7, 12.5), QPointF(1.5, 7)]))
    elif kind in ("if", "unless"):
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(c)
        p.drawPolygon(QPolygonF([QPointF(7, 1), QPointF(13, 7), QPointF(7, 13), QPointF(1, 7)]))
        if kind == "unless":
            p.setPen(QPen(card, 1.8))
            p.drawLine(QPointF(4.5, 7), QPointF(9.5, 7))
    elif kind == "do":
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(c)
        p.drawPolygon(QPolygonF([QPointF(3, 1.8), QPointF(3, 12.2), QPointF(12.2, 7)]))
    elif kind in ("wait", "cooldown", "limit"):
        p.drawEllipse(QPointF(7, 7), 5.8, 5.8)
        p.drawPolyline(QPolygonF([QPointF(7, 3.8), QPointF(7, 7), QPointF(9.3, 8.6)]))
    elif kind == "tree":
        pen.setStyle(Qt.PenStyle.CustomDashLine)
        pen.setDashPattern([1.9, 1.25])
        p.setPen(pen)
        p.drawRoundedRect(QRectF(1, 1, 12, 12), 3, 3)
        p.setPen(QPen(c, 1.6, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
        p.drawLine(QPointF(5, 9), QPointF(9, 5))
        p.drawPolyline(QPolygonF([QPointF(6, 5), QPointF(9, 5), QPointF(9, 8)]))
    else:   # decorators, and what has no icon: a hexagon
        p.drawPolygon(QPolygonF([QPointF(7, 1), QPointF(12.6, 4.2), QPointF(12.6, 9.8), QPointF(7, 13),
                                 QPointF(1.4, 9.8), QPointF(1.4, 4.2)]))
    p.restore()


# ---- the items ---------------------------------------------------------------------------------

class BackItem(QGraphicsItem):
    """Behind the cards: the dotted canvas, frames, edges, order badges, fold knobs."""

    def __init__(self, view: "Diagram"):
        super().__init__()
        self.view = view
        self.setZValue(-10)

    def boundingRect(self) -> QRectF:
        return self.view.drawing.bounds.adjusted(-2000, -2000, 2000, 2000)

    def paint(self, p: QPainter, option, widget=None) -> None:
        v, d, t = self.view, self.view.drawing, self.view.theme
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        # dots, in what is exposed
        r = option.exposedRect
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(t["dot"])
        step = 22.0
        if v.transform().m11() > 0.45:
            x0, y0 = math.floor(r.left() / step) * step, math.floor(r.top() / step) * step
            yy = y0
            while yy < r.bottom():
                xx = x0
                while xx < r.right():
                    p.drawEllipse(QPointF(xx + 1, yy + 1), 1, 1)
                    xx += step
                yy += step
        view = v.view
        for b in d.blocks:                                   # frames
            bx = d.box[b.key]
            if bx.fr:
                if b.ref_state == "text":
                    label = f"{b.ref} · read-only here · click to edit it"
                else:
                    label = f"{b.ref} · written by the server at run time"
                _frame(p, t, QRectF(*bx.fr), label)
        if d.companion:
            c = d.companion
            _frame(p, t, c.frame, f"{c.name} · ticked just before {d.root.top[0][0]} · read-only · click to edit")
        p.setPen(QPen(t["edge"], 1.3))
        p.setBrush(Qt.BrushStyle.NoBrush)
        for b in d.blocks:                                   # edges
            bx = d.box[b.key]
            for k in b.kids:
                p.drawPath(_rounded(edge_points(bx, d.box[k.key], view)))
        p.setFont(_qf(F_BADGE))
        for b in d.blocks:                                   # order badges
            many = len(b.kids) > 1 or (b.kids and b.core[1].get("kind") in M.chooser_kinds(v.schema))
            if not many or b.ref is not None:
                continue
            bx = d.box[b.key]
            for k in b.kids:
                c = badge_at(bx, d.box[k.key], view)
                p.setPen(QPen(t["border_strong"], 1))
                p.setBrush(t["card"])
                p.drawEllipse(c, 8.5, 8.5)
                p.setPen(t["muted"])
                p.drawText(QRectF(c.x() - 9, c.y() - 9, 18, 18), Qt.AlignmentFlag.AlignCenter, str(k.order))
        for b in d.blocks:                                   # fold knobs
            if b.ref is not None or not (b.kids or b.folded):
                continue
            bx = d.box[b.key]
            cx, cy = knob_at(bx, view)
            p.setPen(QPen(t["border_strong"], 1))
            p.setBrush(t["card"])
            p.drawEllipse(QPointF(cx, cy), 6.5, 6.5)
            p.setPen(QPen(t["muted"], 1.5))
            p.drawLine(QPointF(cx - 3, cy), QPointF(cx + 3, cy))
            if b.folded:
                p.drawLine(QPointF(cx, cy - 3), QPointF(cx, cy + 3))
                p.setFont(_qf(F_KW))
                p.setPen(t["muted"])
                text = f"{b.folded} hidden: click + to show"
                if view == "B":
                    p.drawText(QPointF(cx + 11, cy + 4), text)
                else:
                    p.drawText(QPointF(cx + 12, cy + 13), text)
                p.setFont(_qf(F_BADGE))


def _frame(p: QPainter, t: Theme, r: QRectF, label: str) -> None:
    """A dashed frame round what is shown in place, read-only, with its title."""
    pen = QPen(t["frame"], 1.2, Qt.PenStyle.CustomDashLine)
    pen.setDashPattern([5 / 1.2, 4 / 1.2])
    p.setPen(pen)
    p.setBrush(Theme.alpha(t["frame"], 0.05))
    p.drawRoundedRect(r, 12, 12)
    p.setFont(_qf(F_FRAME))
    p.setPen(t["frame"])
    p.drawText(QPointF(r.x() + 10, r.y() + 15), _clip(F_FRAME, label, r.width() - 20))


class CardItem(QGraphicsItem):
    def __init__(self, view: "Diagram", block: M.Block):
        super().__init__()
        self.view, self.block = view, block
        bx = view.drawing.box[block.key]
        self.w, self.h = bx.w, bx.h
        self.setPos(bx.x, bx.y)
        self.setAcceptHoverEvents(True)

    def boundingRect(self) -> QRectF:
        return QRectF(-3, -3, self.w + 6, self.h + 6)

    def paint(self, p: QPainter, option, widget=None) -> None:
        paint_card(p, self.view, self.block, self.w, self.h)


def paint_card(p: QPainter, view: "Diagram", b: M.Block, w: float, h: float, ghost: bool = False) -> None:
    t, d = view.theme, view.drawing
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    p.setRenderHint(QPainter.RenderHint.TextAntialiasing)
    rows = d.rows[b.key]
    selected = view.selected
    card = QRectF(0.5, 0.5, w - 1, h - 1)
    if b.note:
        p.setPen(QPen(t["frame"], 1, Qt.PenStyle.DashLine))
        p.setBrush(Theme.alpha(t["frame"], 0.06))
        p.drawRoundedRect(card, 8, 8)
        p.setFont(_qf(F_CMT))
        p.setPen(t["muted"])
        for j, line in enumerate(rows[0].lines):
            p.drawText(QPointF(12, 12 + j * G_COMMENT + 9), line)
        return
    # a soft shadow
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(Theme.alpha(QColor("#101828"), 0.10 if not t.dark else 0.35))
    p.drawRoundedRect(card.translated(0, 1.2), 8, 8)
    p.setBrush(t["card"])
    pen = QPen(t["sel"] if ghost else t["border"], 1.5 if ghost else 1)
    if b.ref is not None:
        pen.setStyle(Qt.PenStyle.CustomDashLine)
        pen.setDashPattern([5, 3])
    p.setPen(pen)
    p.drawRoundedRect(card, 8, 8)
    clip = QPainterPath()
    clip.addRoundedRect(card, 8, 8)
    p.save()
    p.setClipPath(clip)
    schema = view.schema
    for i, r in enumerate(rows):
        node = r.node
        kind = node.get("kind", "")
        is_core = i == len(rows) - 1
        is_option, is_ref = "trait" in node, M.is_ref(node)
        rect = QRectF(0, r.y, w, r.h)
        if r.band:
            p.fillRect(rect, t["band"])
        if selected is not None and r.path == selected and not b.read_only or \
                (selected is not None and r.path == selected and b.read_only and view.selected_key == b.key):
            p.fillRect(rect, t["hover"])
        if i > 0:
            p.setPen(QPen(t["border"], 1))
            p.drawLine(QPointF(1, r.y), QPointF(w - 1, r.y))
        # the stripe of its kind
        top = 6 if i == 0 else 4
        bot = 6 if i == len(rows) - 1 else 4
        stripe = t.kind(kind)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(Theme.alpha(stripe, 0.55) if is_option else stripe)
        p.drawRoundedRect(QRectF(0, r.y + top, 3, r.h - top - bot), 1.5, 1.5)
        x, ly = 12.0, r.y + 18.5
        if is_option:
            _paint_option(p, view, b, r, w, x, ly)
        elif is_ref:
            _paint_ref(p, view, b, r, w, x, ly)
        else:
            kw, main, rest = row_words(schema, node)
            if is_core and b.decision:
                main, rest = "", "decide: the first that holds"
            elif is_core and b.guards:
                main, rest = "", "then, in order:" if len(b.kids) > 1 else "then:"
            draw_icon(p, kind, family(schema, kind), x, r.y + 7, t.kind(kind), t["card"])
            x += 21
            if kw:
                p.setFont(_qf(F_KW))
                p.setPen(t["muted"])
                p.drawText(QPointF(x, ly), kw)
                x += _tw(F_KW, kw) + 5
            avail = w - x - 12
            p.setFont(_qf(F_LABEL))
            p.setPen(t["text"])
            m = _clip(F_LABEL, main, avail)
            p.drawText(QPointF(x, ly), m)
            if rest and m == main:
                x2 = x + _tw(F_LABEL, main) + (6 if main else 0)
                p.setFont(_qf(F_REST))
                p.setPen(t["muted"])
                p.drawText(QPointF(x2, ly), _clip(F_REST, rest, w - x2 - 12))
            if is_core and kind in M.chooser_kinds(schema):
                _paint_pick_settings(p, view, node, r, w)
        p.setFont(_qf(F_CMT))
        p.setPen(t["faint"])
        for j, line in enumerate(r.lines):
            p.drawText(QPointF(12, r.y + G_LABEL + j * G_COMMENT + 3), line)
        if i == 0 and b.otherwise:
            _tag(p, t, w, r.y, "otherwise")
        elif b.guards and i == len(rows) - 1 - b.guards and b.parent is not None and b.parent.decision:
            _tag(p, t, w, r.y, "when")
    p.restore()
    # the selection's outline
    for r in rows:
        if selected is not None and r.path == selected and (not b.read_only or view.selected_key == b.key):
            p.setPen(QPen(t["sel"], 1.6))
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.drawRoundedRect(QRectF(1, r.y + 1, w - 2, r.h - 2), 7, 7)


def _tag(p: QPainter, t: Theme, w: float, y: float, text: str) -> None:
    """A word at the right of a row that says what the row is in a decision."""
    tw = _tw(F_TAG, text) + 12
    rect = QRectF(w - tw - 8, y + 5.5, tw, 17)
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(Theme.alpha(t["k_cond"], 0.15))
    p.drawRoundedRect(rect, 8.5, 8.5)
    p.setFont(_qf(F_TAG))
    p.setPen(t["k_cond"])
    p.drawText(rect, Qt.AlignmentFlag.AlignCenter, text)


def _paint_option(p, view, b, r, w, x, ly):
    t, node = view.theme, r.node
    pick = M.find(view.doc, M.parent_path(r.path)) if r.path[1] else None
    pick = pick or {}
    trait = node.get("trait", "none")
    prio = M.is_priority_list(pick)
    if not (prio and trait == "none"):
        tw = _tw(F_TAG, trait) + 12
        c = t.trait(trait)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(Theme.alpha(c, 0.15))
        p.drawRoundedRect(QRectF(x, r.y + 5.5, tw, 17), 8.5, 8.5)
        p.setFont(_qf(F_TAG))
        p.setPen(c)
        p.drawText(QPointF(x + 6, r.y + 17.8), trait)
        x += tw + 7
    else:
        draw_icon(p, node.get("kind", ""), "pick", x, r.y + 7, t["k_pick"], t["card"])
        x += 21
    bar_w = 0 if prio else (40 if view.view == "A" else 56)
    f = float(node.get("factor", 1))
    is_def = "factor" in node.get("defaults", [])
    opts = M.options(pick)
    vals = M.bar_values(pick) if pick else []
    idx = r.path[1][-1] if r.path[1] else 0
    v = vals[idx] if idx < len(vals) else 0
    if M.is_roll(pick):
        s = sum(float(o.get("factor", 1)) for o in opts) or 1
        label = f"{round(f / s * 100)}%"
    else:
        label = "×" + _n(f)
    right = bar_w + _tw(F_NUM, label) + 12 + (8 if bar_w else 0)
    wp, _ = M.node_word(view.schema, node)
    main, rest = str(node.get(wp.get("name", ""), "")), " ".join(str(a) for a in node.get("args", []))
    avail = w - x - right - 8
    p.setFont(_qf(F_LABEL))
    p.setPen(t["text"])
    m = _clip(F_LABEL, main, avail)
    p.drawText(QPointF(x, ly), m)
    if rest and m == main:
        x2 = x + _tw(F_LABEL, main) + 5
        p.setFont(_qf(F_REST))
        p.setPen(t["muted"])
        p.drawText(QPointF(x2, ly), _clip(F_REST, rest, avail - (x2 - x)))
    bx = w - 12 - bar_w
    p.setFont(_qf(F_NUM))
    p.setPen(t["faint"] if is_def else t["muted"])
    p.drawText(QRectF(bx - 106, r.y + 6, 100, 16), Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter, label)
    if bar_w:
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(t["chip"])
        p.drawRoundedRect(QRectF(bx, r.y + 11, bar_w, 7), 3.5, 3.5)
        p.setBrush(Theme.alpha(t.trait(trait), 0.85))
        p.drawRoundedRect(QRectF(bx, r.y + 11, max(2.0, bar_w * max(0.0, min(1.0, v))), 7), 3.5, 3.5)


REF_SAYS = {"engine": "by the server", "cycle": "leads back here", "missing": "not in this text"}


def ref_chip_text(view: "Diagram", b: M.Block) -> str:
    if b.opened:
        return "▾ hide"
    if b.ref_state == "engine":
        return "▸ what is it"
    return f"▸ show · {M.ref_size(view.doc, b.ref)}"


def _paint_ref(p, view, b, r, w, x, ly):
    t, node = view.theme, r.node
    kind = node.get("kind", "")
    draw_icon(p, kind, "ref", x, r.y + 7, t["k_ref"], t["card"])
    x += 21
    p.setFont(_qf(F_KW))
    p.setPen(t["muted"])
    p.drawText(QPointF(x, ly), kind)
    x += _tw(F_KW, kind) + 5
    p.setFont(_qf(F_LABEL))
    p.setPen(t["k_ref"])
    p.drawText(QPointF(x, ly), _clip(F_LABEL, node.get("ref", ""), w - x - REF_CHIP - 16))
    if b.ref_known:
        chip = QRectF(w - REF_CHIP - 8, r.y + 6, REF_CHIP, 18)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(Theme.alpha(t["k_ref"], 0.12))
        p.drawRoundedRect(chip, 9, 9)
        p.setFont(_qf(F_TAG))
        p.setPen(t["k_ref"])
        p.drawText(chip, Qt.AlignmentFlag.AlignCenter, ref_chip_text(view, b))
    if b.ref_state in ("cycle", "missing"):
        p.setFont(_qf(F_CMT))
        p.setPen(t["warn"] if b.ref_state != "engine" else t["faint"])
        right = w - (REF_CHIP + 16 if b.ref_known else 12)
        p.drawText(QRectF(right - 130, r.y + 6, 130 - 6, 18),
                   Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter, REF_SAYS[b.ref_state])


def _paint_pick_settings(p, view, node, r, w):
    t = view.theme
    cy = r.y + G_LABEL + len(r.lines) * G_COMMENT + (G_PAD if r.lines else 0) - 2
    p.setFont(_qf(F_CHIP))
    lines = chip_lines(pick_chips(view.schema, node), w)
    for line in lines:
        for cx, text, is_def in line:
            cw = _tw(F_CHIP, text) + 12
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(t["chip"])
            p.drawRoundedRect(QRectF(cx, cy, cw, 17), 4, 4)
            p.setPen(t["faint"] if is_def else t["muted"])
            p.drawText(QPointF(cx + 6, cy + 12.2), text)
        cy += G_CHIPS
    cy -= G_CHIPS
    if M.is_roll(node):
        opts = M.options(node)
        s = sum(max(0.0, float(o.get("factor", 1))) for o in opts) or 1
        sx, sw, sy = 12.0, w - 24, cy + 21
        p.setPen(Qt.PenStyle.NoPen)
        for o in opts:
            ww = sw * max(0.0, float(o.get("factor", 1))) / s
            p.setBrush(Theme.alpha(t.trait(o.get("trait", "none")), 0.8))
            p.drawRoundedRect(QRectF(sx, sy, max(1.0, ww - 2), 6), 2, 2)
            sx += ww


# ---- the view ------------------------------------------------------------------------------------

class Overview(QWidget):
    """A small map of the whole tree and of what is in view; click to go there."""

    def __init__(self, view: "Diagram"):
        super().__init__(view)
        self.view = view
        self.setFixedSize(150, 96)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setToolTip("The whole tree; the frame is what is in view. Click or drag to move.")

    def _scale(self):
        b = self.view.drawing.bounds
        s = min((self.width() - 12) / max(1, b.width()), (self.height() - 12) / max(1, b.height()))
        ox = 6 + (self.width() - 12 - b.width() * s) / 2 - b.x() * s
        oy = 6 + (self.height() - 12 - b.height() * s) / 2 - b.y() * s
        return s, ox, oy

    def paintEvent(self, e) -> None:
        t = self.view.theme
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setPen(QPen(t["border"], 1))
        p.setBrush(Theme.alpha(t["panel"], 0.94))
        p.drawRoundedRect(QRectF(0.5, 0.5, self.width() - 1, self.height() - 1), 8, 8)
        s, ox, oy = self._scale()
        d = self.view.drawing
        p.setPen(Qt.PenStyle.NoPen)
        for blk in d.blocks:
            bx = d.box[blk.key]
            c = t.kind(blk.core[1].get("kind", "")) if blk.ref is None else t["k_ref"]
            p.setBrush(Theme.alpha(c, 0.55))
            p.drawRect(QRectF(ox + bx.x * s, oy + bx.y * s, max(1.5, bx.w * s), max(1.5, bx.h * s)))
        vr = self.view.mapToScene(self.view.viewport().rect()).boundingRect()
        p.setPen(QPen(t["sel"], 1.4))
        p.setBrush(Theme.alpha(t["sel"], 0.08))
        p.drawRect(QRectF(ox + vr.x() * s, oy + vr.y() * s, vr.width() * s, vr.height() * s))
        p.end()

    def mousePressEvent(self, e) -> None:
        self._go(e.position())

    def mouseMoveEvent(self, e) -> None:
        self._go(e.position())

    def _go(self, pos) -> None:
        s, ox, oy = self._scale()
        self.view.centerOn((pos.x() - ox) / s, (pos.y() - oy) / s)


class Palette(QDialog):
    """What may be put there, from the schema, with a search."""

    def __init__(self, entries: list[tuple[str, str | None, str, str]], title: str, parent=None):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.resize(560, 460)
        self.entries = entries
        lay = QVBoxLayout(self)
        self.title = QLabel(title)
        lay.addWidget(self.title)
        self.search = QLineEdit(placeholderText="Type to search the words and what they do...")
        self.list = QListWidget()
        self.list.setAlternatingRowColors(True)
        lay.addWidget(self.search)
        lay.addWidget(self.list)
        self.search.textChanged.connect(self._fill)
        self.list.itemActivated.connect(lambda *_: self.accept())
        self.list.itemDoubleClicked.connect(lambda *_: self.accept())
        self.search.returnPressed.connect(self.accept)
        self._fill("")

    def _fill(self, text: str) -> None:
        self.list.clear()
        words = text.lower().split()
        for kind, word, label, doc in self.entries:
            hay = (label + " " + doc).lower()
            if all(w in hay for w in words):
                it = QListWidgetItem(f"{label}    —  {doc}" if doc else label)
                it.setToolTip(doc)
                it.setData(Qt.ItemDataRole.UserRole, (kind, word))
                self.list.addItem(it)
        if self.list.count():
            self.list.setCurrentRow(0)

    def chosen(self) -> tuple[str, str | None] | None:
        it = self.list.currentItem()
        return it.data(Qt.ItemDataRole.UserRole) if it else None


def palette_entries(schema: dict | None, parent: dict | None, doc: dict, here: str) -> list[tuple[str, str | None, str, str]]:
    """(kind, word, label, doc) of all that may go under `parent` (None: a
    tree's root), in the schema's order: each kind, and for a kind that takes
    a word, each word of the vocabulary with what it does."""
    out = []
    first = lambda d: (d or "").split(". ")[0][:160]
    for k in M.kinds(schema):
        kind = k.get("name", "")
        if parent is not None and not M.may_hold(schema, parent, kind):
            continue
        if parent is None and k.get("parent"):
            continue
        wp = M.word_param(schema, kind)
        if wp:
            for w in M.word_list(schema, wp.get("type", "")):
                usage = f" {w['usage']}" if w.get("usage") else ""
                out.append((kind, w["name"], f"{kind} {w['name']}{usage}", first(w.get("doc"))))
        elif M.is_ref(M.new_node(schema, kind, None, doc, here)):
            for name in M.tree_names(doc):
                if name != here:
                    out.append((kind, name, f"{kind} {name}", "another tree of this text, as if written here"))
            for name, says in M.ENGINE_TREES.items():
                out.append((kind, name, f"{kind} {name}", first(says)))
        else:
            out.append((kind, None, kind, first(k.get("doc"))))
    return out


READABLE = 0.85           # the smallest zoom a first view takes: below it a card's words are hard to read


class Diagram(QGraphicsView):
    """The tree drawn. Signals: `selected(path or None)`, `edit(name, args)`
    for the window to make, `open_tree(name)`."""

    selected_changed = Signal(object)
    edit = Signal(str, tuple)
    open_tree = Signal(str)
    status = Signal(str)

    def __init__(self, parent=None):
        self._scene = QGraphicsScene()
        super().__init__(self._scene, parent)
        self.doc: dict = {}
        self.schema: dict | None = None
        self.root: str = ""
        self.view = "A"
        self.opened: set[str] = set()           # references shown in place, by block key
        self.folded: set[str] = set()           # cards whose children are hidden, by block key
        self.open_all = False                   # every reference shown, to any depth
        self.also = True                        # the tree's `<name>_also` drawn beside it
        self._kept: dict[str, tuple] = {}       # what was opened and folded in each tree drawn before
        self.selected = None              # a path
        self.selected_key: str | None = None
        self.stale = False
        self.theme = Theme(False)
        self.drawing = Drawing()
        self.items: dict[str, CardItem] = {}
        self._fitted_for: tuple | None = None
        self._press = None
        self._drag = None
        self._pan = None
        self._history: list[str] = []
        self.setRenderHints(QPainter.RenderHint.Antialiasing | QPainter.RenderHint.TextAntialiasing
                            | QPainter.RenderHint.SmoothPixmapTransform)
        self.setViewportUpdateMode(QGraphicsView.ViewportUpdateMode.FullViewportUpdate)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setTransformationAnchor(QGraphicsView.ViewportAnchor.AnchorUnderMouse)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self.setFrameShape(QFrame.Shape.NoFrame)
        self.setMouseTracking(True)
        self._build_overlays()

    # -- overlays: the head, the zoom bar, the overview, a message
    def _build_overlays(self) -> None:
        self.head = QLabel(self)
        self.head.setTextFormat(Qt.TextFormat.RichText)
        self.head.setWordWrap(True)
        self.head.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self.back = QToolButton(self)
        self.back.setText("← Back")
        self.back.setToolTip("Back to the tree you came from")
        self.back.hide()
        self.bar = QFrame(self)
        self.bar.setObjectName("zoombar")
        hb = QHBoxLayout(self.bar)
        hb.setContentsMargins(4, 3, 4, 3)
        hb.setSpacing(2)

        def tb(text, tip, slot):
            b = QToolButton(self.bar)
            b.setText(text)
            b.setToolTip(tip)
            b.setAutoRaise(True)
            b.clicked.connect(slot)
            hb.addWidget(b)
            return b

        self.b_out = tb("−", "Zoom out (Ctrl+-)", lambda: self.zoom_by(1 / 1.2))
        self.zoom_label = QLabel("100%", self.bar)
        self.zoom_label.setMinimumWidth(40)
        self.zoom_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        hb.addWidget(self.zoom_label)
        self.b_in = tb("+", "Zoom in (Ctrl++)", lambda: self.zoom_by(1.2))
        self.b_fit = tb("Fit", "The whole tree in view (F)", self.fit)
        self.b_expand = tb("Expand all", "Show every `tree <name>` in place, to any depth, and every folded "
                           "node (Ctrl+Shift+Right)", self.expand_all)
        self.b_collapse = tb("Collapse all", "Hide every tree shown in place, and show what was folded "
                             "(Ctrl+Shift+Left)", self.collapse_all)
        self.b_also = tb("Beside", "Show or hide the tree ticked beside this one (its _also)", self.toggle_also)
        self.b_also.setCheckable(True)
        self.b_map = tb("Map", "Show or hide the map of the whole tree", self.toggle_map)
        self.b_map.setCheckable(True)
        self.b_map.setChecked(False)
        self.overview = Overview(self)
        self.message = QLabel(self)
        self.message.setWordWrap(True)
        self.message.setTextFormat(Qt.TextFormat.RichText)
        self.message.hide()
        self._message_timer = QTimer(self, singleShot=True)
        self._message_timer.timeout.connect(self.message.hide)
        self.stale_label = QLabel(self)
        self.stale_label.setWordWrap(True)
        self.stale_label.hide()
        self._style_overlays()

    def _style_overlays(self) -> None:
        t = self.theme
        c = lambda k: t[k].name()
        self.setBackgroundBrush(t["canvas"])
        bg = Theme.alpha(t["canvas"], 0.88)
        self.head.setStyleSheet(f"color: {c('text')}; background: rgba({bg.red()},{bg.green()},{bg.blue()},"
                                f"{bg.alpha()}); border-radius: 6px; padding: 2px 6px;")
        self.bar.setStyleSheet(
            f"#zoombar {{ background: {c('panel')}; border: 1px solid {c('border')}; border-radius: 8px; }}"
            f"QToolButton {{ color: {c('muted')}; border: 0; padding: 3px 8px; border-radius: 5px; }}"
            f"QToolButton:hover {{ background: {c('hover')}; color: {c('text')}; }}"
            f"QLabel {{ color: {c('muted')}; }}")
        self.back.setStyleSheet(
            f"QToolButton {{ background: {c('panel')}; color: {c('text')}; border: 1px solid {c('border')};"
            f" border-radius: 6px; padding: 3px 8px; }}")
        self.message.setStyleSheet(
            f"background: {c('warn_bg')}; color: {c('warn')}; border: 1px solid {c('warn')};"
            f" border-radius: 8px; padding: 8px 12px;")
        self.stale_label.setStyleSheet(
            f"background: {c('panel')}; color: {c('warn')}; border: 1px dashed {c('warn')};"
            f" border-radius: 8px; padding: 6px 10px;")

    def resizeEvent(self, e) -> None:
        super().resizeEvent(e)
        self._place_overlays()

    def _place_overlays(self) -> None:
        w, h = self.viewport().width(), self.viewport().height()
        x0 = 16 + (self.back.sizeHint().width() + 8 if self.back.isVisible() else 0)
        self.back.move(14, 12)
        self.head.setFixedWidth(max(200, min(900, w - x0 - 16)))
        self.head.adjustSize()
        self.head.move(x0, 8)
        self.bar.adjustSize()
        self.bar.move(w - self.bar.width() - 12, h - self.bar.height() - 12)
        self.overview.move(w - self.overview.width() - 12, h - self.bar.height() - self.overview.height() - 20)
        self.message.setFixedWidth(min(640, w - 40))
        self.message.adjustSize()
        self.message.move((w - self.message.width()) // 2, h - self.message.height() - 64)
        self.stale_label.setFixedWidth(min(560, w - 40))
        self.stale_label.adjustSize()
        self.stale_label.move(w - self.stale_label.width() - 12, 12)

    def head_height(self) -> int:
        return self.head.y() + self.head.height() + 10

    # -- what is shown
    def set_theme(self, dark: bool) -> None:
        self.theme = Theme(dark, self.schema)
        self._style_overlays()
        self._update_head()
        self.viewport().update()
        self.overview.update()

    def set_schema(self, schema: dict | None) -> None:
        self.schema = schema
        self.theme = Theme(self.theme.dark, schema)

    def set_document(self, doc: dict | None, select=None) -> None:
        """A new document (the text compiled). Keeps the view where it was
        when the tree is the same one; else fits it."""
        self.doc = doc or {}
        self.stale = False
        self.stale_label.hide()
        names = M.tree_names(self.doc)
        if self.root not in names:
            self.root = names[0] if names else ""
            self.opened, self.folded, self.open_all = self._kept.get(self.root, (set(), set(), False))
        if select is not None:
            self.selected, self.selected_key = select, None
        elif self.selected is not None and M.find(self.doc, self.selected) is None:
            self.selected = None
        self.relayout()

    def set_stale(self, why: str) -> None:
        self.stale = True
        self.stale_label.setText("The text does not compile: this is the last tree that did. " + why)
        self.stale_label.show()
        self._place_overlays()

    def set_root(self, name: str, remember: bool = True) -> None:
        if name == self.root or M.tree(self.doc, name) is None:
            return
        if remember:
            self._history.append(self.root)
        self._kept[self.root] = (self.opened, self.folded, self.open_all)
        self.root = name
        self.opened, self.folded, self.open_all = self._kept.get(name, (set(), set(), False))
        self.selected, self.selected_key = (name, ()), None
        self._fitted_for = None
        self.relayout()
        self.open_tree.emit(name)
        self.selected_changed.emit(self.selected)

    def go_back(self) -> None:
        while self._history:
            name = self._history.pop()
            if M.tree(self.doc, name) is not None:
                self.set_root(name, remember=False)
                return

    def set_view(self, view: str) -> None:
        if view != self.view:
            self.view = view
            self._fitted_for = None
            self.relayout()

    def expand_all(self) -> None:
        """Every reference shown in place, to any depth (a circle stops where it
        comes back), and every fold opened."""
        self.open_all, self.opened, self.folded = True, set(), set()
        self.relayout()

    def collapse_all(self) -> None:
        """The tree as written: no reference shown in place, nothing folded."""
        self.open_all, self.opened, self.folded = False, set(), set()
        self.relayout()

    def unfold_all(self) -> None:
        self.folded = set()
        self.relayout()

    def toggle_also(self) -> None:
        self.also = not self.also
        self.relayout()

    def set_open(self, b: M.Block, show: bool) -> None:
        """Show a reference in place, or hide it; or unfold a card, or fold it."""
        if b.ref is not None:
            if not b.ref_known or b.opened == show:
                return
            if self.open_all:                    # from "everything" to "everything but this"
                self.open_all = False
                self.opened = {x.key for x in self.drawing.blocks if x.opened}
            self.opened ^= {b.key}
        elif b.kids or b.folded:
            if bool(b.folded) == (not show):
                return
            self.folded ^= {b.key}
        else:
            return
        self.relayout()
        self.select(self.selected, b.key, ensure_visible=False)

    def relayout(self) -> None:
        old_center = self.mapToScene(self.viewport().rect().center())
        key = (self.root, self.view)
        first = self._fitted_for != key
        self._scene.clear()
        self.items = {}
        self.drawing = build_drawing(self.doc, self.root, self.view, self.opened, self.folded, self.open_all,
                                     self.schema, self.also) if self.root else Drawing()
        self._scene.addItem(BackItem(self))
        for b in self.drawing.blocks:
            it = CardItem(self, b)
            self.items[b.key] = it
            self._scene.addItem(it)
        self._scene.setSceneRect(self.drawing.bounds.adjusted(-600, -400, 600, 400))
        has_also = M.tree(self.doc, self.root + M.ALSO) is not None and not self.root.endswith(M.ALSO)
        self.b_also.setVisible(has_also)
        self.b_also.setChecked(self.also and has_also)
        self.b_also.setText(f"Beside: {self.root}{M.ALSO}")
        self._update_head()
        if first:
            self._fitted_for = key
            self.initial_view()
        else:
            self.centerOn(old_center)
        self._show_map()

    def toggle_map(self) -> None:
        self._show_map()

    def _show_map(self) -> None:
        """The map, when it is asked for and the tree is larger than the view."""
        b = self.drawing.bounds
        vr = self.mapToScene(self.viewport().rect()).boundingRect()
        self.overview.setVisible(self.b_map.isChecked() and len(self.drawing.blocks) > 1
                                 and not vr.contains(b))
        self.overview.update()

    def _update_head(self) -> None:
        t = M.tree(self.doc, self.root)
        if t is None:
            self.head.setText("")
            return
        c = self.theme
        n = M.ref_size(self.doc, self.root)
        uses = len(M.uses(self.doc, self.root))
        where = f"line {t.get('line', '?')} · {n} nodes with references opened"
        shared = (f" · <span style='color:{c['k_ref'].name()}'>used in {uses} place{'s' if uses != 1 else ''}: "
                  f"an edit here changes every one</span>" if uses else "")
        if self.root == M.run_tree(self.doc):
            shared += " · <b>the tree a bot given this text runs</b> (the first of the text)"
        main = self.root[:-len(M.ALSO)] if self.root.endswith(M.ALSO) else ""
        if main and M.tree(self.doc, main) is not None:
            shared += f" · ticked beside {_esc(main)}, just before it, at every decision"
        ab = M.about(t)
        if len(ab) > 220:
            ab = ab[:217] + "…"
        self.head.setText(
            f"<div style='font-size:16px;font-weight:650'>{_esc(self.root)}"
            f"<span style='font-size:12px;font-weight:400;color:{c['faint'].name()}'>&nbsp;&nbsp;{where}{shared}</span></div>"
            f"<div style='font-size:12px;font-style:italic;color:{c['muted'].name()}'>{_esc(ab)}</div>")
        self.back.setVisible(bool(self._history))
        self._place_overlays()

    # -- the view
    def zoom(self) -> float:
        return self.transform().m11()

    def zoom_to(self, k: float) -> None:
        k = max(0.15, min(2.5, k))
        self.setTransform(self.transform().fromScale(k, k))
        self.zoom_label.setText(f"{round(k * 100)}%")
        self._show_map()

    def zoom_by(self, f: float) -> None:
        self.zoom_to(self.zoom() * f)

    def fit(self) -> None:
        b = self.drawing.bounds
        if b.isEmpty():
            return
        vw, vh = self.viewport().width(), self.viewport().height() - self.head_height()
        k = min(1.2, (vw - 48) / b.width(), (vh - 24) / b.height())
        self.zoom_to(k)
        self._top_at(b.center().x(), b.y(), center_x=True)

    def initial_view(self) -> None:
        """A first view a person can read: the whole tree if it fits at 85 %
        or more; else readable (at least 85 %, as wide as fits), from its
        top-left corner, the rest a scroll down."""
        b = self.drawing.bounds
        if b.isEmpty() or not self.drawing.blocks:
            return
        vw, vh = self.viewport().width(), self.viewport().height() - self.head_height()
        k = min(1.0, (vw - 56) / b.width(), (vh - 28) / b.height())
        if k < READABLE:
            k = min(1.0, max(READABLE, (vw - 56) / b.width()))
        self.zoom_to(k)
        if b.width() * k <= vw - 56:
            self._top_at(b.center().x(), b.y(), center_x=True)
        else:
            self._top_at(b.x(), b.y(), center_x=False)
        self.overview.update()

    def _top_at(self, sx: float, sy: float, center_x: bool) -> None:
        k = self.zoom()
        vw, vh = self.viewport().width(), self.viewport().height()
        top = self.head_height()
        cx = sx if center_x else sx + (vw / 2 - 28) / k
        cy = sy + (vh / 2 - top) / k
        self.centerOn(cx, cy)

    def scrollContentsBy(self, dx: int, dy: int) -> None:
        super().scrollContentsBy(dx, dy)
        self._show_map()

    def wheelEvent(self, e) -> None:
        if e.modifiers() & (Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.MetaModifier):
            self.zoom_by(1.0015 ** e.angleDelta().y())
            e.accept()
            return
        super().wheelEvent(e)

    # -- finding what is under the pointer
    def row_at(self, sp: QPointF) -> tuple[M.Block, RowGeo] | None:
        for b in reversed(self.drawing.blocks):
            bx = self.drawing.box[b.key]
            if bx.x <= sp.x() <= bx.x + bx.w and bx.y <= sp.y() <= bx.y + bx.h:
                for r in self.drawing.rows[b.key]:
                    if bx.y + r.y <= sp.y() <= bx.y + r.y + r.h:
                        return b, r
        return None

    def zone_at(self, sp: QPointF):
        for rect, what, payload in self.drawing.zones:
            if rect.contains(sp):
                return what, payload
        return None

    def viewportEvent(self, e) -> bool:
        if e.type() == e.Type.ToolTip:
            sp = self.mapToScene(e.pos())
            hit = self.row_at(sp)
            z = self.zone_at(sp)
            tip = ""
            if z and z[0] == "frame":
                n = len(M.uses(self.doc, z[1].ref))
                tip = (f"Click to edit the tree {z[1].ref} itself (Enter on its reference). It is used in "
                       f"{n} place{'s' if n != 1 else ''}: a change there is made in every one.")
            elif z and z[0] == "also":
                tip = f"Click to edit the tree {z[1].name} itself."
            elif z and z[0] == "ref":
                tip = ("Show it here, read-only, or hide it (Right and Left arrows). Enter edits that tree itself."
                       if z[1].ref_state == "text" else "What fills it, and who writes it (Right and Left arrows).")
            elif z and z[0] == "fold":
                tip = "Hide or show what is under it (Left and Right arrows)."
            elif hit:
                b, r = hit
                lines = [b.note] if b.note else [node_title(self.schema, r.node)] + M.comments(r.node)
                if b.read_only and not b.note:
                    lines.append(f"(in the tree {r.path[0]}, shown here read-only: click its frame to edit it)")
                tip = "\n".join(lines)
            if tip:
                QToolTip.showText(e.globalPos(), tip, self)
            else:
                QToolTip.hideText()
            return True
        return super().viewportEvent(e)

    # -- selection
    def select(self, path, key: str | None = None, ensure_visible: bool = True, emit: bool = False) -> bool:
        """Select a node by path; False if it is not drawn."""
        hit = None
        for b in self.drawing.blocks:
            if key is not None and b.key != key:
                continue
            for r in self.drawing.rows[b.key]:
                if r.path == path and (hit is None or (hit[0].read_only and not b.read_only)):
                    hit = (b, r)
        self.selected = path
        self.selected_key = hit[0].key if hit else None
        self.viewport().update()
        if hit and ensure_visible:
            bx = self.drawing.box[hit[0].key]
            self.ensureVisible(QRectF(bx.x, bx.y + hit[1].y, bx.w, hit[1].h), 40, 40)
        if emit:
            self.selected_changed.emit(path)
        return hit is not None

    def selected_block(self) -> M.Block | None:
        for b in self.drawing.blocks:
            if self.selected_key is not None and b.key != self.selected_key:
                continue
            if any(r.path == self.selected for r in self.drawing.rows[b.key]):
                return b
        return None

    def movable_path(self):
        """What moving the selection moves: a condition of a guard alone, else
        the whole card (its top band: the option, the decorator)."""
        b = self.selected_block()
        if b is None:
            return None
        return self.selected if b.is_guard(self.selected) else b.top[0]

    # -- the mouse
    def mousePressEvent(self, e) -> None:
        self.setFocus()
        sp = self.mapToScene(e.position().toPoint())
        if e.button() == Qt.MouseButton.LeftButton:
            z = self.zone_at(sp)
            if z:
                what, b = z
                if what in ("ref", "fold"):
                    self.set_open(b, not (b.opened if what == "ref" else not b.folded))
                elif what == "frame":
                    self.set_root(b.ref)
                elif what == "also":
                    self.set_root(b.name)
                return
            hit = self.row_at(sp)
            if hit:
                b, r = hit
                self.select(r.path, b.key, ensure_visible=False, emit=True)
                self._press = (e.position(), b, sp)
                return
            self._pan = e.position()
            self.viewport().setCursor(Qt.CursorShape.ClosedHandCursor)
            return
        super().mousePressEvent(e)

    def mouseDoubleClickEvent(self, e) -> None:
        hit = self.row_at(self.mapToScene(e.position().toPoint()))
        if hit and M.is_ref(hit[1].node) and hit[0].ref_state == "text":
            self.set_root(hit[1].node.get("ref"))
            return
        if hit and hit[0].read_only and not hit[0].note:
            self.set_root(hit[1].path[0])

    def mouseMoveEvent(self, e) -> None:
        if self._pan is not None:
            d = e.position() - self._pan
            self._pan = e.position()
            self.horizontalScrollBar().setValue(self.horizontalScrollBar().value() - round(d.x()))
            self.verticalScrollBar().setValue(self.verticalScrollBar().value() - round(d.y()))
            return
        if self._press is not None:
            start, b, sp0 = self._press
            if self._drag is None and (e.position() - start).manhattanLength() > 6:
                self.begin_drag(b, sp0)
            if self._drag is not None:
                self.drag_to(self.mapToScene(e.position().toPoint()))
            return
        sp = self.mapToScene(e.position().toPoint())
        self.viewport().setCursor(Qt.CursorShape.PointingHandCursor if (self.zone_at(sp) or self.row_at(sp))
                                  else Qt.CursorShape.OpenHandCursor)
        super().mouseMoveEvent(e)

    def mouseReleaseEvent(self, e) -> None:
        if self._pan is not None:
            self._pan = None
            self.viewport().setCursor(Qt.CursorShape.OpenHandCursor)
            return
        if self._drag is not None:
            self.drop()
        self._press = None
        super().mouseReleaseEvent(e)

    # -- moving a node by hand
    def drop_targets(self, b: M.Block) -> list[tuple[QPointF, QPointF, M.Block, int]]:
        """Each line where the block could be put: (from, to, the new parent, index)."""
        out = []
        node_kind = b.top[1].get("kind", "")
        moved_path = b.top[0]
        for p in self.drawing.blocks:
            if p.read_only or p.ref is not None or p.folded:
                continue
            ppath, pnode = p.core
            if ppath[0] == moved_path[0] and ppath[1][:len(moved_path[1])] == moved_path[1]:
                continue                       # itself or inside itself
            same = M.parent_path(moved_path) == ppath
            if not same and not M.may_hold(self.schema, pnode, node_kind):
                continue
            if same and M.children_rule(self.schema, pnode.get("kind", "")) == "one":
                continue
            kids = p.kids
            if not kids:
                continue
            boxes = [self.drawing.box[k.key] for k in kids]
            x0, x1 = boxes[0].x - 4, boxes[0].x + boxes[0].w + 4
            for i in range(len(kids) + 1):          # children are stacked in both views: a line across
                if i < len(kids):
                    y = boxes[i].y - (L.A_VGAP if self.view == "A" else L.B_VGAP) / 2
                else:
                    y = L.bounds(boxes[-1])[1] + L.bounds(boxes[-1])[3] + 4
                out.append((QPointF(x0, y), QPointF(x1, y), p, i + p.guards))   # counted as in the text
        return out

    def begin_drag(self, b: M.Block, sp: QPointF) -> None:
        if b.read_only or b.parent is None or self.stale:
            self.status.emit("This node cannot be moved here: " + (
                "it belongs to a tree opened read-only; open that tree to edit it." if b.read_only else
                "the root of a tree stays where it is." if b.parent is None else "the text does not compile."))
            self._press = None
            return
        bx = self.drawing.box[b.key]
        self._drag = {"block": b, "offset": sp - QPointF(bx.x, bx.y), "targets": self.drop_targets(b),
                      "target": None}
        ghost = _GhostItem(self, b)
        self._scene.addItem(ghost)
        self._drag["ghost"] = ghost
        line = _DropLine(self)
        self._scene.addItem(line)
        self._drag["line"] = line
        self.items[b.key].setOpacity(0.35)

    def drag_to(self, sp: QPointF) -> None:
        d = self._drag
        d["ghost"].setPos(sp - d["offset"])
        best, dist = None, 70.0
        for a, bb, p, i in d["targets"]:
            dd = abs(sp.y() - a.y()) + max(0.0, a.x() - sp.x(), sp.x() - bb.x()) * 0.5
            if dd < dist:
                best, dist = (a, bb, p, i), dd
        d["target"] = best
        d["line"].set_line(best)
        self.ensureVisible(QRectF(sp.x() - 20, sp.y() - 20, 40, 40), 10, 10)

    def drop(self) -> None:
        d, self._drag = self._drag, None
        self._scene.removeItem(d["ghost"])
        self._scene.removeItem(d["line"])
        self.items[d["block"].key].setOpacity(1.0)
        if not d["target"]:
            self.status.emit("Not moved: drop it on a blue line between two nodes.")
            return
        _, _, p, i = d["target"]
        path = d["block"].top[0]
        here = M.parent_path(path)
        if here == p.core[0] and i in (path[1][-1], path[1][-1] + 1):
            return                              # where it was
        self.edit.emit("move", (path, p.core[0], i))

    # -- the keyboard
    def reading_order(self) -> list[tuple[M.Block, int]]:
        """Every row drawn, (block, row), in the order the tree reads: from the
        top down, the same in both views; the tree beside it last."""
        out = []
        tops = [self.drawing.root] + ([self.drawing.companion.root] if self.drawing.companion else [])
        for top in tops:
            for b in (top.walk() if top else []):
                out += [(b, i) for i in range(len(self.drawing.rows[b.key]))]
        return out

    def keyPressEvent(self, e) -> None:
        """Up and Down: the row before or after, in reading order. Left: hide what
        is under it (a reference shown, the children), else to its parent.
        Right: show what is under it, else to its first child. Alt+Up and
        Alt+Down: move it earlier or later among its siblings. The same in both
        views: order is always downwards."""
        b = self.selected_block()
        key, mods = e.key(), e.modifiers()
        alt = bool(mods & Qt.KeyboardModifier.AltModifier)
        arrows = (Qt.Key.Key_Up, Qt.Key.Key_Down, Qt.Key.Key_Left, Qt.Key.Key_Right)
        if key == Qt.Key.Key_F and not mods:
            self.fit()
            return
        if b is None:
            if key in arrows and self.drawing.root:
                r = self.drawing.root
                self.select(r.top[0], r.key, emit=True)
                return
            super().keyPressEvent(e)
            return
        if alt and key in (Qt.Key.Key_Up, Qt.Key.Key_Down):
            if b.read_only or (b.parent is None and not b.is_guard(self.selected)):
                self.status.emit("It cannot be moved: " + (
                    "it belongs to a tree shown here read-only; edit that tree to move it." if b.read_only
                    else "it is the root of its tree; wrap it, or change it."))
            else:
                self.edit.emit("move_by", (self.movable_path(), -1 if key == Qt.Key.Key_Up else 1))
            return
        if key not in arrows or mods & ~Qt.KeyboardModifier.KeypadModifier:
            super().keyPressEvent(e)
            return
        order = self.reading_order()
        ri = next((i for i, r in enumerate(self.drawing.rows[b.key]) if r.path == self.selected), 0)
        at = order.index((b, ri)) if (b, ri) in order else 0
        target = None
        shown = b.opened if b.ref is not None else bool(b.kids)
        hidden = (b.ref_known and not b.opened) if b.ref is not None else bool(b.folded)
        if key == Qt.Key.Key_Up and at > 0:
            target = order[at - 1]
        elif key == Qt.Key.Key_Down and at + 1 < len(order):
            target = order[at + 1]
        elif key == Qt.Key.Key_Left:
            if shown:
                self.set_open(b, False)
                return
            if b.parent is not None:
                target = (b.parent, len(self.drawing.rows[b.parent.key]) - 1)
        elif key == Qt.Key.Key_Right:
            if hidden:
                self.set_open(b, True)
                return
            if b.kids:
                target = (b.kids[0], 0)
        if target is not None:
            blk, i = target
            self.select(self.drawing.rows[blk.key][i].path, blk.key, emit=True)

    def contextMenuEvent(self, e) -> None:
        sp = self.mapToScene(e.pos())
        hit = self.row_at(sp)
        if hit:
            self.select(hit[1].path, hit[0].key, ensure_visible=False, emit=True)
        menu = QMenu(self)
        for a in self.actions():
            if a.isSeparator():
                menu.addSeparator()
            elif a.isVisible():
                menu.addAction(a)
        menu.exec(e.globalPos())


class _GhostItem(QGraphicsItem):
    def __init__(self, view: Diagram, b: M.Block):
        super().__init__()
        self.view, self.block = view, b
        bx = view.drawing.box[b.key]
        self.w, self.h = bx.w, bx.h
        self.setPos(bx.x, bx.y)
        self.setZValue(50)
        self.setOpacity(0.92)

    def boundingRect(self) -> QRectF:
        return QRectF(-8, -8, self.w + 16, self.h + 20)

    def paint(self, p, option, widget=None) -> None:
        p.setPen(Qt.PenStyle.NoPen)
        for i in range(6, 0, -1):
            p.setBrush(Theme.alpha(QColor("#000000"), 0.025))
            p.drawRoundedRect(QRectF(-i, -i + 6, self.w + 2 * i, self.h + 2 * i), 8 + i, 8 + i)
        paint_card(p, self.view, self.block, self.w, self.h, ghost=True)


class _DropLine(QGraphicsItem):
    def __init__(self, view: Diagram):
        super().__init__()
        self.view = view
        self.line = None
        self.setZValue(40)

    def set_line(self, target) -> None:
        self.prepareGeometryChange()
        self.line = target
        self.update()

    def boundingRect(self) -> QRectF:
        if not self.line:
            return QRectF()
        a, b = self.line[0], self.line[1]
        return QRectF(a, b).normalized().adjusted(-40, -30, 40, 30)

    def paint(self, p, option, widget=None) -> None:
        if not self.line:
            return
        a, b, parent, i = self.line
        t = self.view.theme
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setPen(QPen(t["sel"], 3, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
        p.drawLine(a, b)
        p.setFont(_font(10.5, 700))
        kw, main, _ = row_words(self.view.schema, parent.core[1])
        text = f"put it here: {i + 1 - parent.guards} under {main or kw}"
        p.drawText(QPointF(b.x() + 8, a.y() + 4), text)


def _esc(s: str) -> str:
    return (s or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
