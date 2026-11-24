# model.py -- the tree as a structure: where a node is, the edits, the blocks drawn
# Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
"""The engine's `lsd-bt` document (bot/TREES.md, section 16), and what
the diagram does to it. Pure Python: no Qt, no Docker.

A node is found by a *path*: the name of its tree and the indices of
the children that lead to it from the root, `("tdm", (0, 3, 0))`. Every
edit is a function that takes the document and gives a new one (the old
one is never changed) and the path of what should be selected after.
The new document is made text by the engine (`bttree --from-json`) and
checked by it; nothing here writes tree text or knows the grammar
beyond the field names of the JSON format and the schema's `children`.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass, field

Path = tuple  # (tree name, (index, index, ...))

# Nodes that hold one child and are drawn as a band on top of it.
BANDS = {"option", "invert", "always", "never", "cooldown", "limit"}
# What the format describes a node by (the rest is its words and numbers).
READ_ONLY_FIELDS = ("id", "line", "column", "text")


class EditError(Exception):
    """An edit that cannot be made; the message is for a person."""


# ---- reading ---------------------------------------------------------------

def file_of(doc: dict) -> dict:
    files = (doc or {}).get("files") or [{}]
    return files[0]


def trees(doc: dict) -> list[dict]:
    return file_of(doc).get("trees", [])


def tree(doc: dict, name: str) -> dict | None:
    return next((t for t in trees(doc) if t.get("name") == name), None)


def tree_names(doc: dict) -> list[str]:
    return [t.get("name", "") for t in trees(doc)]


def node_at(doc: dict, path: Path) -> dict:
    t = tree(doc, path[0])
    if t is None or "root" not in t:
        raise EditError(f"There is no tree called {path[0]}.")
    n = t["root"]
    for i in path[1]:
        kids = n.get("children", [])
        if not 0 <= i < len(kids):
            raise EditError("That node is not there any more.")
        n = kids[i]
    return n


def find(doc: dict, path: Path) -> dict | None:
    try:
        return node_at(doc, path)
    except EditError:
        return None


def parent_path(path: Path) -> Path | None:
    return (path[0], path[1][:-1]) if path[1] else None


def walk(doc: dict):
    """(path, node) of every node, tree by tree, in the order of the text."""
    for t in trees(doc):
        if "root" not in t:
            continue
        stack = [((t["name"], ()), t["root"])]
        while stack:
            path, n = stack.pop()
            yield path, n
            kids = n.get("children", [])
            for i in range(len(kids) - 1, -1, -1):
                stack.append(((path[0], path[1] + (i,)), kids[i]))


def count(node: dict) -> int:
    return 1 + sum(count(c) for c in node.get("children", []))


def uses(doc: dict, name: str) -> list[Path]:
    """Where `tree <name>` is written."""
    return [p for p, n in walk(doc) if n.get("kind") == "tree" and n.get("ref") == name]


def path_for_line(doc: dict, line: int) -> Path | None:
    for p, n in walk(doc):
        if n.get("line") == line:
            return p
    return None


def comments(node: dict) -> list[str]:
    out = [a.lstrip("#").strip() for a in node.get("above", []) if a.strip()]
    if node.get("comment"):
        out.append(node["comment"].strip())
    return [c for c in out if c]


def about(t: dict | None) -> str:
    return " ".join(a.lstrip("#").strip() for a in (t or {}).get("above", []) if a.strip())


# ---- the schema --------------------------------------------------------------

def kind_info(schema: dict | None, kind: str) -> dict:
    return next((k for k in (schema or {}).get("kinds", []) if k.get("name") == kind), {})


def children_rule(schema: dict | None, kind: str) -> str:
    """none | one | many | options, as the schema says."""
    return kind_info(schema, kind).get("children", "none")


def may_hold(schema: dict | None, parent: dict, kind: str) -> bool:
    """Could a node of `kind` be put under `parent` (one more child)?"""
    rule = children_rule(schema, parent.get("kind", ""))
    has = len(parent.get("children", []))
    if rule == "none" or (rule == "one" and has >= 1):
        return False
    if rule == "options":
        return kind == "option"
    if kind == "option":
        return False
    return True


def word_list(schema: dict | None, field_name: str) -> list[dict]:
    key = {"action": "actions", "cond": "conditions", "score": "scores", "trait": "traits"}[field_name]
    return (schema or {}).get(key, [])


def word_info(schema: dict | None, field_name: str, name: str) -> dict:
    for w in word_list(schema, field_name):
        if name in (w.get("name"), w.get("alias")):
            return w
    return {}


WORD_FIELD = {"do": "action", "if": "cond", "unless": "cond", "option": "score"}


def required_args(schema: dict | None, field_name: str, name: str) -> list[str]:
    """A first value for each argument the word needs: its default, else the first allowed."""
    out = []
    for a in word_info(schema, field_name, name).get("args", []):
        if not a.get("required"):
            break
        if a.get("type") == "number":
            v = a.get("default", a.get("min", 1))
            out.append(f"{v:g}" if isinstance(v, (int, float)) else str(v))
        elif a.get("type") == "enum":
            out.append((a.get("values") or ["?"])[0])
        elif a.get("type") == "place":
            places = (schema or {}).get("places", [])
            out.append(places[0]["name"] if places else "self")
        else:
            out.append(str(a.get("default", "x")))
    return out


PLACEHOLDER = {"kind": "wait", "seconds": 1}


def new_node(schema: dict | None, kind: str, word: str | None = None, doc: dict | None = None,
             here: str | None = None) -> dict:
    """A node of that kind (and word), with what it needs to compile. A
    node that must hold a child is given `wait 1`, to be replaced."""
    n: dict = {"kind": kind}
    rule = children_rule(schema, kind)
    if kind == "pick":
        n["children"] = [new_node(schema, "option", None, doc)]
        return n
    if kind == "option":
        scores = [w["name"] for w in word_list(schema, "score")]
        n.update(trait="none", score=word or ("always" if "always" in scores else (scores or ["always"])[0]),
                 factor=1, defaults=["factor"])
        n["args"] = required_args(schema, "score", n["score"])
    elif kind in WORD_FIELD:
        f = WORD_FIELD[kind]
        words = [w["name"] for w in word_list(schema, f)]
        n[f] = word or (words[0] if words else "")
        n["args"] = required_args(schema, f, n[f])
    elif kind in ("wait", "cooldown", "limit"):
        n["seconds"] = 1
    elif kind == "tree":
        others = [t for t in tree_names(doc or {}) if t != here]
        n["ref"] = word or (others[0] if others else "items")
    if rule in ("one", "many"):
        n["children"] = [dict(PLACEHOLDER)]
    return n


# ---- edits: each gives (new document, the path to select) ------------------------

def _copy(doc: dict) -> dict:
    return copy.deepcopy(doc)


def _parent_and_index(doc: dict, path: Path) -> tuple[dict, int]:
    pp = parent_path(path)
    if pp is None:
        raise EditError("The root of a tree has no siblings: it cannot be moved or removed. "
                        "Change it, or wrap it in another node.")
    return node_at(doc, pp), path[1][-1]


def clean(node: dict) -> dict:
    """A copy of a subtree without what describes where it was read."""
    out = {k: v for k, v in node.items() if k not in READ_ONLY_FIELDS and k != "children"}
    if "children" in node:
        out["children"] = [clean(c) for c in node["children"]]
    return out


def set_fields(doc: dict, path: Path, changes: dict) -> tuple[dict, Path]:
    """Change a node's words, numbers or comments; a value of None removes the field."""
    d = _copy(doc)
    n = node_at(d, path)
    for k, v in changes.items():
        if v is None:
            n.pop(k, None)
        else:
            n[k] = v
        if k in n.get("defaults", []):
            n["defaults"] = [x for x in n["defaults"] if x != k]
    return d, path


def insert(doc: dict, parent: Path, index: int, node: dict, schema: dict | None = None) -> tuple[dict, Path]:
    d = _copy(doc)
    p = node_at(d, parent)
    if schema is not None and not may_hold(schema, p, node.get("kind", "")):
        raise EditError(_why_not(schema, p, node.get("kind", "")))
    kids = p.setdefault("children", [])
    index = max(0, min(index, len(kids)))
    kids.insert(index, copy.deepcopy(node))
    return d, (parent[0], parent[1] + (index,))


def _why_not(schema, parent: dict, kind: str) -> str:
    rule = children_rule(schema, parent.get("kind", ""))
    pk = parent.get("kind", "")
    if rule == "none":
        return f"A {pk} has no children."
    if rule == "one":
        return f"A {pk} holds one child, and it has one: wrap that child instead, or replace it."
    if rule == "options":
        return "Under a pick there are only options."
    return f"An option goes only directly under a pick, not under a {pk}."


def delete(doc: dict, path: Path, schema: dict | None = None) -> tuple[dict, Path]:
    d = _copy(doc)
    p, i = _parent_and_index(d, path)
    kids = p["children"]
    rule = children_rule(schema, p.get("kind", "")) if schema else "many"
    if len(kids) == 1 and rule != "none":
        raise EditError(f"It is the only child of its {p.get('kind')}, which needs one: "
                        "replace it, or remove the parent.")
    del kids[i]
    if i < len(kids):
        return d, path
    return d, (path[0], path[1][:-1] + (i - 1,)) if i > 0 else parent_path(path)


def move_by(doc: dict, path: Path, delta: int) -> tuple[dict, Path]:
    """Up (-1) or down (+1) among its siblings: order is priority."""
    d = _copy(doc)
    p, i = _parent_and_index(d, path)
    kids = p["children"]
    j = i + delta
    if not 0 <= j < len(kids):
        raise EditError("It is first already." if delta < 0 else "It is last already.")
    kids[i], kids[j] = kids[j], kids[i]
    return d, (path[0], path[1][:-1] + (j,))


def move(doc: dict, path: Path, new_parent: Path, index: int, schema: dict | None = None) -> tuple[dict, Path]:
    """Take a subtree from where it is and put it under another parent, at `index`
    (counted among the new parent's children as they are before the move)."""
    if new_parent[0] == path[0] and new_parent[1][:len(path[1])] == path[1]:
        raise EditError("A node cannot be put inside itself.")
    d = _copy(doc)
    p, i = _parent_and_index(d, path)
    node = p["children"][i]
    target = node_at(d, new_parent)
    same = target is p
    if not same and schema is not None and not may_hold(schema, target, node.get("kind", "")):
        raise EditError(_why_not(schema, target, node.get("kind", "")))
    if not same and len(p["children"]) == 1 and schema is not None:
        raise EditError(f"It is the only child of its {p.get('kind')}, which needs one.")
    del p["children"][i]
    if same and index > i:
        index -= 1
    kids = target.setdefault("children", [])
    kids.insert(max(0, min(index, len(kids))), node)
    return d, path_of(d, node)


def path_of(doc: dict, obj: dict) -> Path | None:
    """The path of that very node (by identity)."""
    return next((p for p, n in walk(doc) if n is obj), None)


def wrap(doc: dict, path: Path, decorator: dict, schema: dict | None = None) -> tuple[dict, Path]:
    """Put a node of one child (a decorator) above this one."""
    d = _copy(doc)
    kind = decorator.get("kind", "")
    if schema is not None and children_rule(schema, kind) not in ("one", "many"):
        raise EditError(f"A {kind} cannot hold a child.")
    n = node_at(d, path)
    if n.get("kind") == "option":
        raise EditError("An option stays directly under its pick: wrap what it does instead.")
    w = {k: v for k, v in decorator.items() if k != "children"}
    w["children"] = [n]
    if path[1]:
        p, i = _parent_and_index(d, path)
        p["children"][i] = w
    else:
        tree(d, path[0])["root"] = w
    return d, path


def unwrap(doc: dict, path: Path) -> tuple[dict, Path]:
    """Remove a node of one child, keeping the child in its place."""
    d = _copy(doc)
    n = node_at(d, path)
    kids = n.get("children", [])
    if len(kids) != 1:
        raise EditError("Only a node with exactly one child can be removed around it.")
    if n.get("kind") == "option":
        raise EditError("An option cannot be removed around its child: under a pick there are only options.")
    if path[1]:
        p, i = _parent_and_index(d, path)
        p["children"][i] = kids[0]
    else:
        tree(d, path[0])["root"] = kids[0]
    return d, path


def replace(doc: dict, path: Path, node: dict) -> tuple[dict, Path]:
    d = _copy(doc)
    if path[1]:
        p, i = _parent_and_index(d, path)
        p["children"][i] = copy.deepcopy(node)
    else:
        tree(d, path[0])["root"] = copy.deepcopy(node)
    return d, path


def extract(doc: dict, path: Path, name: str) -> tuple[dict, Path]:
    """The subtree becomes a tree of its own, called `name`; where it was, `tree <name>`."""
    if tree(doc, name) is not None:
        raise EditError(f"There is a tree called {name} already.")
    d = _copy(doc)
    n = node_at(d, path)
    if n.get("kind") == "option":
        raise EditError("An option cannot be a tree's root: extract what it does instead.")
    ref = {"kind": "tree", "ref": name}
    for k in ("comment", "above"):
        if k in n:
            ref[k] = n.pop(k)
    if path[1]:
        p, i = _parent_and_index(d, path)
        p["children"][i] = ref
    else:
        tree(d, path[0])["root"] = ref
    ts = file_of(d)["trees"]
    at = next(i for i, t in enumerate(ts) if t.get("name") == path[0]) + 1
    ts.insert(at, {"name": name, "header": True, "above": [""], "root": clean(n)})
    return d, path


def inline(doc: dict, path: Path) -> tuple[dict, Path]:
    """`tree <name>` replaced by a copy of that tree (which stays, for its other uses)."""
    n = node_at(doc, path)
    if n.get("kind") != "tree":
        raise EditError("Only a `tree <name>` node can be inlined.")
    t = tree(doc, n.get("ref", ""))
    if t is None or "root" not in t:
        raise EditError(f"The tree {n.get('ref')} is not in this text: it cannot be copied here.")
    body = clean(t["root"])
    for k in ("comment", "above"):
        if k in n:
            body[k] = n[k]
    return replace(doc, path, body)


def rename_tree(doc: dict, old: str, new: str) -> tuple[dict, str]:
    if tree(doc, old) is None:
        raise EditError(f"There is no tree called {old}.")
    if old != new and tree(doc, new) is not None:
        raise EditError(f"There is a tree called {new} already.")
    d = _copy(doc)
    tree(d, old)["name"] = new
    tree(d, new)["header"] = True
    for _, n in walk(d):
        if n.get("kind") == "tree" and n.get("ref") == old:
            n["ref"] = new
    return d, new


# ---- history: the texts the engine made, to go back and forth -----------------

class History:
    """Each text that compiled, in order. Undo and redo move along it."""

    def __init__(self, limit: int = 200):
        self.states: list[tuple[str, Path | None]] = []
        self.at = -1
        self.limit = limit

    def push(self, text: str, selection: Path | None = None) -> None:
        if self.at >= 0 and self.states[self.at][0] == text:
            self.states[self.at] = (text, selection)
            return
        del self.states[self.at + 1:]
        self.states.append((text, selection))
        if len(self.states) > self.limit:
            del self.states[0]
        self.at = len(self.states) - 1

    def can_undo(self) -> bool:
        return self.at > 0

    def can_redo(self) -> bool:
        return self.at < len(self.states) - 1

    def undo(self) -> tuple[str, Path | None] | None:
        if not self.can_undo():
            return None
        sel = self.states[self.at][1]
        self.at -= 1
        return self.states[self.at][0], sel

    def redo(self) -> tuple[str, Path | None] | None:
        if not self.can_redo():
            return None
        self.at += 1
        return self.states[self.at]

    def clear(self) -> None:
        self.states, self.at = [], -1


# ---- blocks: what the diagram draws -------------------------------------------------

@dataclass(eq=False)
class Block:
    """One card: bands (an option, decorators of one child) stacked on a core node."""
    key: str                               # unique in a drawing, kept across redraws of the same text
    rows: list[tuple[Path, dict]]          # (path, node), top band first, the core last
    via: tuple[str, ...] = ()              # the references opened to get here: read-only when not empty
    kids: list["Block"] = field(default_factory=list)
    ref: str | None = None                 # the core is `tree <ref>`
    ref_known: bool = False                # ... and that tree is in the text
    opened: bool = False                   # ... and it is opened in place (its root is kids[0])
    folded: int = 0                        # nodes hidden under it by a fold
    parent: "Block | None" = None
    order: int = 0                         # its place among its parent's children, from 1

    @property
    def top(self) -> tuple[Path, dict]:
        return self.rows[0]

    @property
    def core(self) -> tuple[Path, dict]:
        return self.rows[-1]

    @property
    def read_only(self) -> bool:
        return bool(self.via)

    def walk(self):
        yield self
        for k in self.kids:
            yield from k.walk()


def build_blocks(doc: dict, root: str, opened: set[str] | None = None, folded: set[str] | None = None,
                 open_all: bool = False) -> Block | None:
    """The blocks of tree `root`, references opened where `opened` names
    them (by block key) or everywhere with `open_all`; `folded` keys keep
    their children hidden."""
    opened, folded = opened or set(), folded or set()
    t = tree(doc, root)
    if t is None or "root" not in t:
        return None

    def make(path: Path, node: dict, via: tuple[str, ...], chain: tuple[str, ...]) -> Block:
        rows = [(path, node)]
        while node.get("kind") in BANDS and len(node.get("children", [])) == 1:
            path, node = (path[0], path[1] + (0,)), node["children"][0]
            rows.append((path, node))
        key = "/".join(via) + "|" + path[0] + ":" + ".".join(map(str, rows[0][0][1]))
        b = Block(key, rows, via)
        if node.get("kind") == "tree":
            name = node.get("ref", "")
            b.ref = name
            t2 = tree(doc, name)
            b.ref_known = t2 is not None and "root" in t2 and name not in chain
            if b.ref_known and (open_all or key in opened):
                b.opened = True
                k = make((name, ()), t2["root"], via + (key,), chain + (name,))
                k.parent, k.order = b, 1
                b.kids = [k]
            return b
        kids = node.get("children", [])
        if key in folded and kids:
            b.folded = sum(count(c) for c in kids)
            return b
        for i, c in enumerate(kids):
            k = make((path[0], path[1] + (i,)), c, via, chain)
            k.parent, k.order = b, i + 1
            b.kids.append(k)
        return b

    return make((root, ()), t["root"], (), (root,))


def ref_size(doc: dict, name: str, seen: tuple[str, ...] = ()) -> int:
    """Nodes of a tree with its references opened (as the engine runs it)."""
    t = tree(doc, name)
    if t is None or "root" not in t or name in seen:
        return 0

    def n(node):
        c = 1
        if node.get("kind") == "tree":
            c = ref_size(doc, node.get("ref", ""), seen + (name,)) or 1
        return c + sum(n(k) for k in node.get("children", []))

    return n(t["root"])


# ---- how a pick is drawn ---------------------------------------------------------

def is_roll(pick: dict) -> bool:
    return pick.get("roll", "weighed") not in ("weighed", None)


def is_priority_list(pick: dict) -> bool:
    """A pick used as a priority list: weighed, its options (nearly) all of
    trait `none`, the factors far apart. It is drawn as numbered rows."""
    if pick.get("kind") != "pick" or is_roll(pick):
        return False
    opts = [o for o in pick.get("children", []) if o.get("kind") == "option"]
    if len(opts) < 3:
        return False
    nones = sum(1 for o in opts if o.get("trait", "none") == "none")
    fs = [float(o.get("factor", 1)) for o in opts]
    lo = min((f for f in fs if f > 0), default=0)
    return nones >= len(opts) - 1 and lo > 0 and max(fs) / lo >= 10


def bar_values(pick: dict) -> list[float]:
    """Each option's bar, 0 to 1, against its siblings: its share of the draw
    for a pick that rolls; else its factor over the largest (a log scale
    when they are more than 12 times apart)."""
    import math
    opts = [o for o in pick.get("children", []) if o.get("kind") == "option"]
    fs = [max(0.0, float(o.get("factor", 1))) for o in opts]
    if not fs:
        return []
    if is_roll(pick):
        s = sum(fs) or 1.0
        return [f / s for f in fs]
    hi = max(fs) or 1.0
    lo = min((f for f in fs if f > 0), default=hi)
    if hi / lo > 12:
        return [math.log1p(f) / math.log1p(hi) for f in fs]
    return [f / hi for f in fs]


def log_scale(pick: dict) -> bool:
    fs = [float(o.get("factor", 1)) for o in pick.get("children", []) if o.get("kind") == "option"]
    lo = min((f for f in fs if f > 0), default=0)
    return bool(fs) and lo > 0 and not is_roll(pick) and max(fs) / lo > 12
