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
    return [p for p, n in walk(doc) if is_ref(n) and n.get("ref") == name]


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


# ---- the schema: what a tree may be made of ------------------------------------
#
# Every kind of node, its children, its words and their arguments come from
# the engine's schema (`lsdctl bots schema`, bot/TREES.md section 16): a kind
# or a word the engine adds is offered, drawn and edited without a change
# here. A kind's fields in the JSON are its params' names; a param whose
# type names a list of the schema (cond, action, score, trait) takes a word
# of that list, followed by the word's own arguments in `args`.

WORD_LISTS = {"cond": "conditions", "action": "actions", "score": "scores", "trait": "traits"}

# What the schema does not say yet, in one place (each is a fact of the
# language, bot/TREES.md; the editor's report to the engine asks for them):
# - the trees the engine writes at run time, which a text may refer to (9);
ENGINE_TREES = {
    "items": "Written by the server at run time: one rule for each inventory item, brought by whoever "
             "defined the item (a medkit when hurt, a missile at an enemy under open sky). It fails at "
             "once for a bot with nothing to use. Not in this text.",
    "extras": "Written by the server at run time: what its scripts add to every bot (night and "
              "flashlights first of all), each ticked at every decision. Not in this text.",
}
# - the tree ticked beside `<name>` at every decision, just before it (9);
ALSO = "_also"
# - how a place a server script names is written, wherever a place goes (13);
SCRIPT_PLACE = "@"
# - which settings of a node a value of another one leaves out (6: a pick
#   that rolls once or for a life has no every, sticky, noise; one that
#   rolls at each choice, no sticky, noise);
LEFT_OUT = {("roll", "once"): {"every", "sticky", "noise"}, ("roll", "life"): {"every", "sticky", "noise"},
            ("roll", "each"): {"sticky", "noise"}}
# - how a kind's children are tried, for reading a tree as decisions (5):
#   one after another while each succeeds, or until one does not fail.
TRIES = {"seq": "all", "select": "first"}


def kinds(schema: dict | None) -> list[dict]:
    return (schema or {}).get("kinds", [])


def kind_info(schema: dict | None, kind: str) -> dict:
    return next((k for k in kinds(schema) if k.get("name") == kind), {})


def children_rule(schema: dict | None, kind: str) -> str:
    """none | one | many | options, as the schema says."""
    return kind_info(schema, kind).get("children", "none")


def bands(schema: dict | None) -> set[str]:
    """Kinds of exactly one child: drawn as a band on top of it."""
    return {k["name"] for k in kinds(schema) if k.get("children") == "one"}


def chooser_kinds(schema: dict | None) -> set[str]:
    """Kinds whose children are options (a pick)."""
    return {k["name"] for k in kinds(schema) if k.get("children") == "options"}


def option_kinds(schema: dict | None) -> set[str]:
    """Kinds that go only under another (an option, under a pick)."""
    return {k["name"] for k in kinds(schema) if k.get("parent")}


def params(schema: dict | None, kind: str) -> list[dict]:
    return kind_info(schema, kind).get("params", [])


def word_param(schema: dict | None, kind: str) -> dict:
    """The param that takes a word of the vocabulary (`action` of a do), or {}."""
    return next((p for p in params(schema, kind) if p.get("type") in WORD_LISTS and p.get("type") != "trait"), {})


def kinds_with_param_type(schema: dict | None, ptype: str) -> list[str]:
    return [k["name"] for k in kinds(schema) if any(p.get("type") == ptype for p in k.get("params", []))]


def ref_kind(schema: dict | None) -> str:
    """The kind that names another tree."""
    return (kinds_with_param_type(schema, "tree") or [""])[0]


def is_ref(node: dict) -> bool:
    """`tree <name>`: in the format, the node with a `ref`."""
    return "ref" in node


def guard_kinds(schema: dict | None) -> set[str]:
    """Leaves that ask a condition (if, unless): the guards of a branch."""
    return {k["name"] for k in kinds(schema)
            if k.get("children") == "none" and any(p.get("type") == "cond" for p in k.get("params", []))}


def may_hold(schema: dict | None, parent: dict, kind: str) -> bool:
    """Could a node of `kind` be put under `parent` (one more child)?"""
    rule = children_rule(schema, parent.get("kind", ""))
    has = len(parent.get("children", []))
    if rule == "none" or (rule == "one" and has >= 1):
        return False
    below = kind_info(schema, kind).get("parent")
    if rule == "options":
        return kind in option_kinds(schema) and below in (None, parent.get("kind"))
    return not below


def word_list(schema: dict | None, ptype: str) -> list[dict]:
    """The words of a param type: the schema's conditions, actions, scores or traits."""
    return (schema or {}).get(WORD_LISTS.get(ptype, ""), [])


def word_info(schema: dict | None, ptype: str, name: str) -> dict:
    for w in word_list(schema, ptype):
        if name in (w.get("name"), w.get("alias")):
            return w
    return {}


def node_word(schema: dict | None, node: dict) -> tuple[dict, dict]:
    """(the param that takes a word, that word's entry in the schema) of a node."""
    p = word_param(schema, node.get("kind", ""))
    return p, (word_info(schema, p.get("type", ""), node.get(p.get("name", ""), "")) if p else {})


def first_value(schema: dict | None, spec: dict) -> str:
    """A first value for an argument or a param: its default, else the first allowed."""
    t = spec.get("type")
    if "default" in spec:
        v = spec["default"]
        return f"{v:g}" if isinstance(v, (int, float)) and not isinstance(v, bool) else str(v)
    if t == "number":
        v = max(float(spec.get("min", 1)), 1.0) if "max" not in spec else float(spec.get("min", 0))
        return f"{v:g}"
    if t == "enum":
        return (spec.get("values") or [""])[0]
    if t == "place":
        places = (schema or {}).get("places", [])
        return places[0]["name"] if places else ""
    return spec.get("name", "x")


def required_args(schema: dict | None, ptype: str, name: str) -> list[str]:
    """A first value for each argument the word needs."""
    out = []
    for a in word_info(schema, ptype, name).get("args", []):
        if not a.get("required"):
            break
        out.append(first_value(schema, a))
    return out


def plain_words(schema: dict | None, ptype: str) -> list[str]:
    """The words of a list that need no argument, in the schema's order."""
    return [w["name"] for w in word_list(schema, ptype) if not any(a.get("required") for a in w.get("args", []))]


def script_places(doc: dict) -> list[str]:
    """The places of a server script's naming the text uses already (`@church`)."""
    return sorted({str(a) for _, n in walk(doc) for a in n.get("args", []) if str(a).startswith(SCRIPT_PLACE)})


def guard_count(schema: dict | None, node: dict) -> int:
    """How many conditions a seq begins with, when something follows them:
    drawn as the guard of the branch ("if this, then the rest")."""
    if TRIES.get(node.get("kind")) != "all":
        return 0
    kids, guards = node.get("children", []), guard_kinds(schema)
    n = 0
    while n < len(kids) and kids[n].get("kind") in guards:
        n += 1
    return n if n < len(kids) else 0


def next_kind(schema: dict | None, tries: str) -> str:
    """The kind whose children are tried so (TRIES): `all` a seq, `first` a select."""
    return next((k for k, v in TRIES.items() if v == tries and kind_info(schema, k)), "")


def if_then_otherwise(schema: dict | None, guard: dict, then: dict, otherwise: dict) -> dict:
    """A decision in today's language: the first branch whose condition holds.
    `select` (seq (guard, then), otherwise): stored as any tree, drawn as a decision."""
    first = next((k for k, v in TRIES.items() if v == "first"), "")
    every = next((k for k, v in TRIES.items() if v == "all"), "")
    if not (kind_info(schema, first) and kind_info(schema, every)):
        raise EditError("This engine has no kinds to say \"if ... then ... otherwise\" with.")
    return {"kind": first, "children": [{"kind": every, "children": [guard, then]}, otherwise]}


def make_conditional(doc: dict, path: Path, guard: dict, then: dict, schema: dict | None = None) -> tuple[dict, Path]:
    """The node becomes the "otherwise" of a decision: if `guard`, `then`; otherwise it."""
    n = node_at(doc, path)
    _stays(schema, n, "make what it holds conditional instead")
    d, _ = replace(doc, path, if_then_otherwise(schema, guard, then, clean(n)))
    return d, (path[0], path[1] + (0, 0))


def needs_child(schema: dict | None, node: dict) -> bool:
    """A node that must hold a child and has none: it does not compile so."""
    return children_rule(schema, node.get("kind", "")) != "none" and not node.get("children")


def left_out(node: dict) -> set[str]:
    """The settings of a node that another of its values leaves out."""
    out: set[str] = set()
    for (name, value), gone in LEFT_OUT.items():
        if node.get(name) == value:
            out |= gone
    return out


def new_node(schema: dict | None, kind: str, word: str | None = None, doc: dict | None = None,
             here: str | None = None) -> dict:
    """A node of that kind (and word), every required param given its
    first value from the schema. Its children are not made: a node that
    must hold one (`needs_child`: a seq, a pick, an option, a decorator) is
    filled by the caller, who asks what goes there (`complete`)."""
    n: dict = {"kind": kind}
    for p in params(schema, kind):
        name, t = p.get("name", ""), p.get("type")
        if t in WORD_LISTS and t != "trait":
            words = plain_words(schema, t) or [w["name"] for w in word_list(schema, t)]
            n[name] = word or (words[0] if words else "")
            n["args"] = required_args(schema, t, n[name])
        elif t == "trait":
            n[name] = (word_list(schema, "trait") or [{"name": ""}])[0]["name"]
        elif t == "tree":
            others = [x for x in tree_names(doc or {}) if x != here]
            n[name] = word or (others[0] if others else next(iter(ENGINE_TREES)))
        elif p.get("required"):
            v = first_value(schema, p)
            n[name] = float(v) if t == "number" else v
        elif t == "number" and "default" in p:
            n[name] = p["default"]
            n.setdefault("defaults", []).append(name)
    if children_rule(schema, kind) != "none":
        n["children"] = []
    return n


def complete(schema: dict | None, node: dict, fill) -> dict:
    """The node with every child it must have: `fill(parent)` gives one
    (a new node) for each that needs it, or None to give up (then None)."""
    n = dict(node)
    if "children" in n:
        n["children"] = [complete(schema, c, fill) for c in n["children"]]
        if any(c is None for c in n["children"]):
            return None
    if needs_child(schema, n):
        c = fill(n)
        if c is None:
            return None
        c = complete(schema, c, fill)
        if c is None:
            return None
        n["children"] = [c]
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
        raise EditError(why_not(schema, p, node.get("kind", "")))
    kids = p.setdefault("children", [])
    index = max(0, min(index, len(kids)))
    kids.insert(index, copy.deepcopy(node))
    return d, (parent[0], parent[1] + (index,))


def why_not(schema, parent: dict, kind: str) -> str:
    """Why a node of `kind` may not go under `parent`, in the user's words."""
    rule = children_rule(schema, parent.get("kind", ""))
    pk = parent.get("kind", "")
    if rule == "none":
        return f"A {pk} has no children: put it before or after the {pk}, or under its parent."
    if rule == "one":
        return f"A {pk} holds one child, and it has one: wrap that child instead, or replace it."
    if rule == "options":
        return f"Under a {pk} there are only " + " or ".join(sorted(option_kinds(schema))) + "s."
    above = kind_info(schema, kind).get("parent", "")
    return f"A {kind} goes only directly under a {above}, not under a {pk}."


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
        raise EditError(why_not(schema, target, node.get("kind", "")))
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
    _stays(schema, n, "wrap what it holds instead")
    w = {k: v for k, v in decorator.items() if k != "children"}
    w["children"] = [n]
    if path[1]:
        p, i = _parent_and_index(d, path)
        p["children"][i] = w
    else:
        tree(d, path[0])["root"] = w
    return d, path


def _stays(schema: dict | None, n: dict, instead: str) -> None:
    """Refuse to move a node that goes only directly under its parent kind (an option)."""
    above = kind_info(schema, n.get("kind", "")).get("parent")
    if above:
        raise EditError(f"A {n.get('kind')} stays directly under its {above}: {instead}.")


def unwrap(doc: dict, path: Path, schema: dict | None = None) -> tuple[dict, Path]:
    """Remove a node of one child, keeping the child in its place."""
    d = _copy(doc)
    n = node_at(d, path)
    kids = n.get("children", [])
    if len(kids) != 1:
        raise EditError("Only a node with exactly one child can be removed around it.")
    _stays(schema, n, "delete it instead")
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


def extract(doc: dict, path: Path, name: str, schema: dict | None = None) -> tuple[dict, Path]:
    """The subtree becomes a tree of its own, called `name`; where it was, `tree <name>`."""
    _new_name(doc, name)
    d = _copy(doc)
    n = node_at(d, path)
    _stays(schema, n, "make what it holds a tree instead")
    ref = {"kind": ref_kind(schema), "ref": name}
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
    if not is_ref(n):
        raise EditError("Only a reference to a tree can be copied in its place.")
    t = tree(doc, n.get("ref", ""))
    if t is None or "root" not in t:
        raise EditError(f"The tree {n.get('ref')} is not in this text: it cannot be copied here.")
    body = clean(t["root"])
    for k in ("comment", "above"):
        if k in n:
            body[k] = n[k]
    return replace(doc, path, body)


def rename_tree(doc: dict, old: str, new: str) -> tuple[dict, str]:
    """Rename a tree; every `tree <old>` follows, and its `<old>_also` with it."""
    if tree(doc, old) is None:
        raise EditError(f"There is no tree called {old}.")
    if old == new:
        return _copy(doc), new
    pairs = [(old, new)]
    if tree(doc, old + ALSO) is not None and not old.endswith(ALSO):
        pairs.append((old + ALSO, new + ALSO))
    for _, n2 in pairs:
        _new_name(doc, n2)
    d = _copy(doc)
    for o, n2 in pairs:
        tree(d, o)["name"] = n2
        tree(d, n2)["header"] = True
        for _, n in walk(d):
            if is_ref(n) and n.get("ref") == o:
                n["ref"] = n2
    return d, new


NAME_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")


def _new_name(doc: dict, name: str, limit: int = 31) -> None:
    """Refuse a name a new tree may not have, saying why (bot/TREES.md section 3)."""
    if not name:
        raise EditError("A tree needs a name.")
    bad = sorted(set(name) - NAME_CHARS)
    if bad:
        raise EditError(f"A tree's name is letters, digits, _, - and . only: not {' '.join(repr(c) for c in bad)}.")
    if len(name) > limit:
        raise EditError(f"A tree's name is {limit} characters at most: {name} has {len(name)}.")
    if tree(doc, name) is not None:
        raise EditError(f"There is a tree called {name} already.")
    if name in ENGINE_TREES:
        raise EditError(f"{name} is written by the server: a text may refer to it, not define it.")


def new_tree(doc: dict, name: str, root: dict, after: str | None = None, about: str = "",
             limit: int = 31) -> tuple[dict, Path]:
    """A tree more, after `after` (else at the end)."""
    _new_name(doc, name, limit)
    d = _copy(doc)
    if not (d.get("files") or []):
        d["files"] = [{"trees": []}]
    ts = file_of(d).setdefault("trees", [])
    t = {"name": name, "header": True, "above": [""] + ([f"# {about}"] if about else []) if ts else
         ([f"# {about}"] if about else []), "root": copy.deepcopy(root)}
    at = next((i + 1 for i, x in enumerate(ts) if x.get("name") == after), len(ts))
    ts.insert(at, t)
    return d, (name, ())


def set_about(doc: dict, name: str, lines: list[str]) -> tuple[dict, Path]:
    """What a tree is for: the comment lines right above its header."""
    if tree(doc, name) is None:
        raise EditError(f"There is no tree called {name}.")
    d = _copy(doc)
    t = tree(d, name)
    blank = [""] if t.get("above", [""])[:1] == [""] and trees(d)[0] is not t else []
    t["above"] = blank + ["# " + x for x in lines if x.strip()]
    return d, (name, ())


def delete_tree(doc: dict, name: str) -> tuple[dict, Path | None]:
    """Remove a tree that nothing refers to; the tree before it is chosen."""
    t = tree(doc, name)
    if t is None:
        raise EditError(f"There is no tree called {name}.")
    used = sorted({p[0] for p in uses(doc, name) if p[0] != name})
    if used:
        raise EditError(f"{name} is used by {', '.join(used)}: remove those `tree {name}` first, "
                        "or copy it in their place.")
    if len(trees(doc)) == 1:
        raise EditError("It is the only tree of the text: a text needs one. Change it instead.")
    d = _copy(doc)
    ts = file_of(d)["trees"]
    i = next(i for i, x in enumerate(ts) if x.get("name") == name)
    del ts[i]
    return d, (ts[max(0, i - 1)]["name"], ())


def duplicate_tree(doc: dict, name: str, new: str) -> tuple[dict, Path]:
    """A copy of a tree under another name, after it (its references unchanged)."""
    t = tree(doc, name)
    if t is None or "root" not in t:
        raise EditError(f"There is no tree called {name}.")
    d, sel = new_tree(doc, new, clean(t["root"]), after=name)
    tree(d, new)["above"] = [""] + [a for a in t.get("above", []) if a.strip()]
    return d, sel


def make_first(doc: dict, name: str) -> tuple[dict, Path]:
    """Put a tree first in the text: a text applied to bots runs its first tree
    (bot/TREES.md section 17), and its `<name>_also` beside it."""
    if tree(doc, name) is None:
        raise EditError(f"There is no tree called {name}.")
    d = _copy(doc)
    ts = file_of(d)["trees"]
    moved = [x for x in ts if x.get("name") in (name, name + ALSO)]
    moved.sort(key=lambda x: x.get("name") != name)
    rest = [x for x in ts if x not in moved]
    for x in moved + rest:
        x["header"] = True
    ts[:] = moved + rest
    return d, (name, ())


def run_tree(doc: dict) -> str | None:
    """The tree a bot given this text runs: its first."""
    names = tree_names(doc)
    return names[0] if names else None


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
    key: str                               # unique in a drawing, and kept through edits elsewhere
    rows: list[tuple[Path, dict]]          # (path, node), top band first, the core last
    via: tuple[str, ...] = ()              # the references opened to get here: read-only when not empty
    kids: list["Block"] = field(default_factory=list)
    ref: str | None = None                 # the core is `tree <ref>`
    ref_state: str = ""                    # text | engine | cycle | missing: what that name is
    opened: bool = False                   # ... and it is shown in place (kids[0]: its root, or a note)
    folded: int = 0                        # nodes hidden under it by a fold
    note: str = ""                         # not a node: what stands in for a tree the text does not have
    guards: int = 0                        # rows above the core: the conditions a seq begins with, its guard
    otherwise: bool = False                # the last branch of a decision, which no condition guards
    decision: bool = False                 # a select over branches that begin with conditions
    parent: "Block | None" = None
    order: int = 0                         # its place among its parent's children, from 1

    @property
    def top(self) -> tuple[Path, dict]:
        """The node the card stands for in its parent: its first band, else its core."""
        return self.rows[0] if len(self.rows) - 1 - self.guards > 0 else self.rows[-1]

    @property
    def core(self) -> tuple[Path, dict]:
        return self.rows[-1]

    def is_guard(self, path: Path) -> bool:
        return any(p == path for p, _ in self.rows[len(self.rows) - 1 - self.guards:-1])

    @property
    def read_only(self) -> bool:
        return bool(self.via)

    @property
    def ref_known(self) -> bool:
        """A reference that can be shown in place."""
        return self.ref_state in ("text", "engine")

    def walk(self):
        yield self
        for k in self.kids:
            yield from k.walk()


def node_keys(name: str, root: dict) -> dict[tuple, str]:
    """A name for each node of a tree that an edit elsewhere does not
    change: its words and how many nodes of the same words come before it
    in the tree (`tdm:tree tdm_contact#0`). What is opened or folded is
    remembered by it, so it survives an insertion above, a move of
    something else, an undo."""
    out, seen = {}, {}
    stack = [((), root)]
    while stack:
        path, n = stack.pop()
        sig = n.get("text") or n.get("kind", "")
        i = seen.get(sig, 0)
        seen[sig] = i + 1
        out[path] = f"{name}:{sig}#{i}"
        kids = n.get("children", [])
        for j in range(len(kids) - 1, -1, -1):
            stack.append((path + (j,), kids[j]))
    return out


def ref_state(doc: dict, name: str, chain: tuple[str, ...] = ()) -> str:
    """What `tree <name>` refers to: a tree of the text, one the engine
    writes, the way back to a tree it is in (a circle), or nothing."""
    if name in chain:
        return "cycle"
    t = tree(doc, name)
    if t is not None and "root" in t:
        return "text"
    return "engine" if name in ENGINE_TREES else "missing"


def build_blocks(doc: dict, root: str, schema: dict | None, opened: set[str] | None = None,
                 folded: set[str] | None = None, open_all: bool = False, via: tuple[str, ...] = (),
                 chain: tuple[str, ...] = ()) -> Block | None:
    """The blocks of tree `root`, references opened where `opened` names
    them (by block key) or everywhere with `open_all`; `folded` keys keep
    their children hidden. `via` makes the whole read-only (a tree shown
    beside another); `chain`, the trees it is shown inside."""
    opened, folded = opened or set(), folded or set()
    t = tree(doc, root)
    if t is None or "root" not in t:
        return None
    keys: dict[str, dict] = {}
    band_kinds = bands(schema)

    def make(path: Path, node: dict, via: tuple[str, ...], chain: tuple[str, ...]) -> Block:
        if path[0] not in keys:
            keys[path[0]] = node_keys(path[0], tree(doc, path[0])["root"])
        rows = [(path, node)]
        while node.get("kind") in band_kinds and len(node.get("children", [])) == 1:
            path, node = (path[0], path[1] + (0,)), node["children"][0]
            rows.append((path, node))
        key = "/".join(via) + "|" + keys[path[0]][rows[0][0][1]]
        b = Block(key, rows, via)
        if is_ref(node):
            name = node.get("ref", "")
            b.ref, b.ref_state = name, ref_state(doc, name, chain)
            if b.ref_known and (open_all or key in opened):
                b.opened = True
                if b.ref_state == "text":
                    k = make((name, ()), tree(doc, name)["root"], via + (key,), chain + (name,))
                else:
                    k = Block(key + "/note", [(path, node)], via + (key,), note=ENGINE_TREES[name])
                k.parent, k.order = b, 1
                b.kids = [k]
            return b
        kids = node.get("children", [])
        g = guard_count(schema, node)
        b.rows[-1:-1] = [((path[0], path[1] + (i,)), kids[i]) for i in range(g)]   # read first: "if ..., then"
        b.guards = g
        if key in folded and kids[g:]:
            b.folded = sum(count(c) for c in kids[g:])
            return b
        for i, c in enumerate(kids[g:], start=g):
            k = make((path[0], path[1] + (i,)), c, via, chain)
            k.parent, k.order = b, len(b.kids) + 1
            b.kids.append(k)
        if TRIES.get(node.get("kind")) == "first" and any(k.guards for k in b.kids):
            b.decision = True
            last = b.kids[-1] if b.kids else None
            if last is not None and not last.guards:
                last.otherwise = True
        return b

    return make((root, ()), t["root"], via, chain + (root,))


def ref_size(doc: dict, name: str, seen: tuple[str, ...] = ()) -> int:
    """Nodes of a tree with its references opened (as the engine runs it)."""
    t = tree(doc, name)
    if t is None or "root" not in t or name in seen:
        return 0

    def n(node):
        c = 1
        if is_ref(node):
            c = ref_size(doc, node.get("ref", ""), seen + (name,)) or 1
        return c + sum(n(k) for k in node.get("children", []))

    return n(t["root"])


# ---- how a pick is drawn ---------------------------------------------------------

def options(node: dict) -> list[dict]:
    """The options of a pick: in the format, its children that have a factor and a trait."""
    return [o for o in node.get("children", []) if "trait" in o]


def is_roll(pick: dict) -> bool:
    return pick.get("roll", "weighed") not in ("weighed", None)


def is_priority_list(pick: dict) -> bool:
    """A pick used as a priority list: weighed, its options (nearly) all of
    trait `none`, the factors far apart. It is drawn as numbered rows."""
    if is_roll(pick):
        return False
    opts = options(pick)
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
    opts = options(pick)
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
    fs = [float(o.get("factor", 1)) for o in options(pick)]
    lo = min((f for f in fs if f > 0), default=0)
    return bool(fs) and lo > 0 and not is_roll(pick) and max(fs) / lo > 12
