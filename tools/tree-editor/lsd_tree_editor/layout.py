# layout.py -- where each card goes: automatic, from the structure alone
# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""Two layouts of the same tree of boxes, computed and never stored. In
both, ORDER IS DOWNWARDS: the children of a node are stacked under one
another in their order (a select's priority, a seq's steps, a pick's
options), so a tree reads from the top as the text does.

- **A, outline** (the main one): a parent above its children, the
  children one indent to the right, every card the same width. Depth
  costs an indent, not a card's width: a deep tree stays narrow beside
  the text.
- **B, left to right**: a parent at the left of its children, level with
  the first; the cards of one parent share a width, so their bars can be
  compared. Depth costs a card's width: for a wide screen.

A box that is an opened reference draws its children inside a frame. A
box may ask for room under it (`foot`: what the diagram writes under a
folded card). The layout knows nothing of what is drawn: the caller
gives each box its natural width and a function for its height at a
width. Pure Python.
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(eq=False)
class Box:
    key: object
    kids: list["Box"] = field(default_factory=list)
    natural: float = 220.0                 # the width its words want (layout B)
    frame: bool = False                    # its kids are drawn inside a frame (an opened reference)
    foot: float = 0.0                      # room kept under the card, for a line of the diagram's
    x: float = 0.0
    y: float = 0.0
    w: float = 0.0
    h: float = 0.0
    fr: tuple[float, float, float, float] | None = None   # the frame: x, y, w, h

    def walk(self):
        yield self
        for k in self.kids:
            yield from k.walk()


FRAME_PAD = 12.0          # inside a frame, around what it holds
FRAME_HEAD = 22.0         # the frame's title line

# A
A_WIDTH = 300.0
A_INDENT = 34.0           # a child's left edge, from its parent's
A_RAIL = 15.0             # the line down to the children, from the parent's left edge
A_VGAP = 8.0              # between a card and the next one down
# B
B_MIN, B_MAX = 210.0, 350.0
B_HGAP = 46.0
B_VGAP = 10.0


def layout_a(root: Box, height, width: float = A_WIDTH) -> None:
    """The outline. `height(box, w)` gives a box's height at width w."""
    for b in root.walk():
        b.w = width
        b.h = height(b, width)

    def place(b: Box, x: float, y: float) -> tuple[float, float]:
        """Put b and what is under it at (x, y); gives (bottom, right)."""
        b.x, b.y, b.fr = x, y, None
        bottom, right = y + b.h + b.foot, x + b.w
        if not b.kids:
            return bottom, right
        if b.frame:
            fx, fy = x + A_INDENT - FRAME_PAD, bottom + A_VGAP
            cy, kx = fy + FRAME_HEAD, x + A_INDENT
        else:
            cy, kx = bottom + A_VGAP, x + A_INDENT
        for k in b.kids:
            kb, kr = place(k, kx, cy)
            cy, right = kb + A_VGAP, max(right, kr)
        bottom = cy - A_VGAP
        if b.frame:
            right += FRAME_PAD
            bottom += FRAME_PAD
            b.fr = (fx, fy, right - fx, bottom - fy)
        return bottom, right

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
        bottom = max(y + b.h + b.foot, cy - vgap if b.kids else 0.0)
        b.fr = None
        if b.frame and b.kids:
            fx = x + b.w + hgap - 8
            b.fr = (fx, y - 6, right + f - fx, bottom + f - (y - 6))
            bottom += f
            right += f
        return bottom, right

    place(root, 0.0, 0.0)


def bounds(root: Box) -> tuple[float, float, float, float]:
    """x, y, w, h around every box (with the room under it) and frame."""
    x0 = y0 = float("inf")
    x1 = y1 = float("-inf")
    for b in root.walk():
        for (x, y, w, h) in [(b.x, b.y, b.w, b.h + b.foot)] + ([b.fr] if b.fr else []):
            x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x + w), max(y1, y + h)
    return x0, y0, x1 - x0, y1 - y0


def place_beside(main: Box, other: Box, gap: float = 48.0) -> None:
    """Move `other` (laid out on its own) to the right of `main`, tops level."""
    mx, my, mw, _ = bounds(main)
    ox, oy, _, _ = bounds(other)
    dx, dy = mx + mw + gap - ox, my - oy
    for b in other.walk():
        b.x += dx
        b.y += dy
        if b.fr:
            fx, fy, fw, fh = b.fr
            b.fr = (fx + dx, fy + dy, fw, fh)
