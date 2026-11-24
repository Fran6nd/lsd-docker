# layout.py -- where each card goes: automatic, from the structure alone
# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""Two layouts of the same tree of boxes, computed and never stored:

- **A, top-down** (the main one): a parent above its children, the
  children left to right in their order, every card the same width.
  A parent of many children none of which shows children of its own
  (a pick's options, folded or leaves) stacks them in a numbered column
  under it instead: a pick of 13 options is not 3,800 px wide.
- **B, left to right**: a parent left of its children, the children top
  to bottom in their order; the cards of one parent share a width, so
  their bars can be compared.

A box that is an opened reference draws its child inside a frame. The
layout knows nothing of what is drawn: the caller gives each box its
natural width and a function for its height at a width. Pure Python.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(eq=False)
class Box:
    key: object
    kids: list["Box"] = field(default_factory=list)
    natural: float = 220.0                 # the width its words want (layout B)
    frame: bool = False                    # its kids are drawn inside a frame (an opened reference)
    x: float = 0.0
    y: float = 0.0
    w: float = 0.0
    h: float = 0.0
    fr: tuple[float, float, float, float] | None = None   # the frame: x, y, w, h
    sw: float = 0.0                        # A: the width of its whole subtree
    column: bool = False                   # A: its kids are stacked in a column under it, not side by side
    _kw: float = 0.0

    def walk(self):
        yield self
        for k in self.kids:
            yield from k.walk()


FRAME_PAD = 12.0          # inside a frame, around what it holds
FRAME_HEAD = 22.0         # the frame's title line

# A
A_WIDTH = 268.0
A_HGAP = 22.0
A_VGAP = 48.0
A_COLUMN = 4              # more children than this, all without children shown: a column
A_INDENT = 26.0
A_COL_GAP = 10.0
# B
B_MIN, B_MAX = 210.0, 350.0
B_HGAP = 46.0
B_VGAP = 10.0


def layout_a(root: Box, height, width: float = A_WIDTH, hgap: float = A_HGAP, vgap: float = A_VGAP,
             column: int = A_COLUMN) -> None:
    """Top-down. `height(box, w)` gives a box's height at width w."""
    for b in root.walk():
        b.w = width
        b.h = height(b, width)
        b.column = len(b.kids) > column and all(not k.kids for k in b.kids)

    def span(b: Box) -> float:
        if b.column:
            for k in b.kids:
                span(k)
            b._kw = A_INDENT + width
            b.sw = b._kw
            return b.sw
        kw = sum(span(k) for k in b.kids) + hgap * max(0, len(b.kids) - 1)
        b._kw = kw
        b.sw = max(width, kw) + (2 * FRAME_PAD if b.frame else 0)
        return b.sw

    span(root)

    def place(b: Box, left: float, y: float) -> float:
        f = FRAME_PAD if b.frame else 0.0
        if b.column:
            b.x, b.y, b.fr = left, y, None
            cy = y + b.h + vgap / 2
            for k in b.kids:
                place(k, left + A_INDENT, cy)
                cy += k.h + A_COL_GAP
            return cy - A_COL_GAP
        b.x, b.y = left + b.sw / 2 - width / 2, y
        ky = y + b.h + vgap + (FRAME_HEAD if b.frame else 0.0)
        cx = left + (b.sw - b._kw) / 2
        bottom = y + b.h
        for k in b.kids:
            bottom = max(bottom, place(k, cx, ky))
            cx += k.sw + hgap
        b.fr = None
        if b.frame and b.kids:
            fy = y + b.h + vgap - 8
            b.fr = (left, fy, b.sw, bottom + f - fy)
            bottom += f
        return bottom

    place(root, 0.0, 0.0)


def layout_b(root: Box, height, lo: float = B_MIN, hi: float = B_MAX, hgap: float = B_HGAP,
             vgap: float = B_VGAP) -> None:
    """Left to right; the children of one parent share one width."""
    def widths(b: Box, w: float) -> None:
        b.w = w
        b.h = height(b, w)
        if b.kids:
            kw = min(max(max(k.natural for k in b.kids), lo), hi)
            for k in b.kids:
                widths(k, kw)

    widths(root, min(max(root.natural, lo), hi))

    def place(b: Box, x: float, y: float) -> tuple[float, float]:
        b.x, b.y = x, y
        f = FRAME_PAD if b.frame else 0.0
        kx = x + b.w + hgap + f
        cy = y + (FRAME_HEAD if b.frame else 0.0)
        right = x + b.w
        for k in b.kids:
            bottom, r = place(k, kx, cy)
            cy = bottom + vgap
            right = max(right, r)
        bottom = max(y + b.h, cy - vgap if b.kids else 0.0)
        b.fr = None
        if b.frame and b.kids:
            fx = x + b.w + hgap - 8
            b.fr = (fx, y - 6, right + f - fx, bottom + f - (y - 6))
            bottom += f
            right += f
        return bottom, right

    place(root, 0.0, 0.0)


def bounds(root: Box) -> tuple[float, float, float, float]:
    """x, y, w, h around every box and frame."""
    x0 = y0 = float("inf")
    x1 = y1 = float("-inf")
    for b in root.walk():
        for (x, y, w, h) in [(b.x, b.y, b.w, b.h)] + ([b.fr] if b.fr else []):
            x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x + w), max(y1, y + h)
    return x0, y0, x1 - x0, y1 - y0
