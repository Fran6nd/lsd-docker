# The tree editor

A desktop program to write the bots' behaviour trees and try them on
bots at once. It starts a server of its own in Docker, shows the bots
playing on it, checks the tree as you type, applies it to the bots while
they play, and gives you the address to watch them in ZeroSpades.

It is a front end over the server's own tools (`lsdctl bots ...`, see
[bot/TREES.md](../../bot/TREES.md), section 16). It never reads or
writes a tree by itself: checking, formatting and the outline all come
from the engine in the image, so what the editor shows is what a bot
runs.

## Install and run

Docker must be installed and running. Then:

```sh
pipx install "git+https://github.com/Fran6nd/lsd-docker#subdirectory=tools/tree-editor"
lsd-tree-editor
```

From a checkout, without installing:

```sh
pipx run --spec tools/tree-editor lsd-tree-editor
```

or, in an environment that has PySide6: `cd tools/tree-editor && python -m lsd_tree_editor`.

`lsd-tree-editor mine.bt` opens a file; `--launch` starts the server at
once; `--image`, `--gamemode`, `--bots`, `--level`, `--map` fill the
server's fields.

## Using it

- **The trees and the server** (left, two tabs). *Trees*: every tree of
  the text, its size with its references opened, and how many places use
  it; click one to draw it; the right button has what the **Tree** menu
  has for it. *Server*: choose the image, the game, the map, the bots a
  team and their level (10 unless you say), then **Launch the server**.
  **Stop the server** removes it. **Join it**: the address, to copy or to
  open in ZeroSpades.
- **The diagram** (middle), drawn by itself from the tree's structure. In
  both views **order is downwards**: a select's priorities, a seq's
  steps, a pick's options are one under the other, first at the top, as
  in the text, numbered on the line that joins them.
  - **A, Outline** (the main view): each node above what it holds, one
    step in. Depth costs an indent, so a tree stays narrow beside the
    text.
  - **B, Left to right**: each node at the left of what it holds, level
    with the first; a parent's children share a width, so their bars
    compare. Shorter and wider: for a wide screen.

  A card is a node with what holds it stacked above (an option on what it
  does, a decorator on its child); its colour says its kind. An option
  shows its trait, its factor and a bar against its siblings; a pick its
  settings; a pick used as a priority list (trait `none`, factors far
  apart) is a numbered list with no bars. **Decisions read as decisions**:
  a `seq` that begins with `if`/`unless` shows them at its top, marked
  *when*, then what it does; a `select` over such branches says *decide*,
  and its last branch with no condition is marked *otherwise*. Nothing of
  this changes the text.
- **Trees inside trees.** `tree <name>` is a card with **▸ show**: it
  shows that tree in place, read-only, in a dashed frame; **▾ hide** hides
  it. A reference inside it shows the same way, to any depth; one that
  leads back to a tree it is inside says so and does not open. Right
  arrow shows, Left arrow hides; **Edit > Show it here** does the same;
  **Expand all** and **Collapse all** (the bar below, the View menu,
  Ctrl+Shift+Right and Left) do every one. What is shown stays shown
  while the tree is drawn, through edits elsewhere and undo. Click a
  frame's title (or Enter, or double-click the card) to edit that tree
  itself; **Back** returns. An edit there is made wherever it is used,
  and the head of the diagram says in how many places. **The tree beside
  it**: when a tree `<name>_also` exists it is drawn at the right, framed,
  read-only (it is ticked just before `<name>` at every decision); the
  bar's **Beside** button and **View > The tree beside it** hide it.
  `tree items` and `tree extras` are written by the server at run time:
  their card says so, and **▸ what is it** shows what fills them.
- **Moving about**: drag the canvas to pan, Ctrl+wheel or the bar below
  to zoom, **Fit** (F), the **Map**; the knob under a card hides or shows
  what is under it. Hovering a card shows its whole words and comments.
- **Editing in the diagram**: choose a node (click, or the arrows: Up and
  Down go through the rows in reading order, the same in both views),
  change it in **Properties**: every field its kind has, from the
  engine's schema -- the word, each argument with its type, its choices
  and its default (a place: the engine's, or `@name`, a place a server
  script sets), a pick's way of rolling and its settings (those it does
  not have with that roll are not shown), an option's trait and factor
  (with a slider), the comments; on a tree's root, what the tree is for.
  An argument left empty before one that is given is written with its
  default, or refused with the reason. **Alt+Up / Alt+Down** move a node
  earlier or later among its siblings (order is priority), or drag it
  onto a blue line, under the same parent or another. The right button
  and the **Edit** menu: insert before, after or as a child from a
  palette of what may go there, with a search over the words and what
  they do. A new node is complete before it is put in: a seq, a select,
  a decorator asks what it holds; a pick asks its first option, and the
  option what it does. **If ... then ... otherwise ...** (first in the
  palette) puts a decision in one step: a condition, what to do if it
  holds, what to do otherwise; the condition is then chosen, its number
  in Properties. **If ... then ... otherwise it** (Ctrl+Alt+I) puts a
  condition before the node chosen. Wrap in a decorator and remove one;
  cut, copy, paste, delete; make a part a tree of its own; copy a
  referenced tree in place. **Undo** and **Redo**. Every change is made
  on the structure, written back as text **by the engine** and checked by
  it: one it refuses changes nothing, and the diagram says why.
- **The trees of the text** (the **Tree** menu, and the right button on
  the list): **New tree** (a name, then the node it begins with), **Rename**
  (every `tree <name>` follows, and its `_also`), **Duplicate**,
  **Delete** (refused while another tree uses it, saying which), **Add
  the tree beside it** (`_also`), and **Make it the tree the bots run**: a
  text given to bots runs its **first** tree (with its `_also`), and the
  diagram's head says which tree that is. **File > New from the game's
  tree** starts an untitled copy of a tree the server has (a game's, or
  one saved to it), to rename and change.
- **The text** (right, always shown): what is kept, and what a bot runs.
  New, Open, Open from the server, Save, Save as, Save to the server.
  The text is checked when you stop typing: every mistake is underlined
  and listed under **Problems**. While it does not compile the diagram
  shows the last tree that did, marked so, and cannot be edited.
  Choosing a node in the diagram, the text or the **Outline** chooses it
  in the other two.
- **Who chooses what** (beside Properties): the engine rolls a crowd of
  bots -- of every kind, or of one kind -- and ticks the tree drawn once
  for each, in a situation you set with a slider for each word the tree
  asks about; it shows what they end up doing, in all and by kind of bot,
  and for a chosen pick how often each option was taken. It runs again
  after every change.
- **The bots** (below): who plays, on which team, what each runs and
  does now. **Apply to all bots** gives the text to every bot that has
  no tree of its own; **Apply to selected** to the bots chosen in the
  table, **Apply to them** to a team or a kind of bot, each as its own
  tree; **Revert selected** and **Revert all** give the game's tree
  back. A text that does not compile changes nothing, and the program
  shows what the server answered.

Nothing of the language is written into the program: the kinds of node,
their children, their words and arguments come from the engine's schema
(`lsdctl bots schema`), so a kind or a word the engine gains is offered,
drawn and edited as it comes. A few facts the schema does not give yet
are said in one place, `model.py`: the trees the engine writes (`items`,
`extras`), the `_also` suffix, the `@` of a script's place, which pick
settings a roll leaves out, and how `seq` and `select` try their
children (for drawing decisions).

A tree applied this way lasts until the server stops. To keep it, save
it (Save as, for a file of yours; Save to the server, for the server's
`/data/trees`).

## The safety rules

The owner's words: *"the app never touch a docker it did not create.
when exit, it kills the dev docker instance. can create only one."*

**It never touches a Docker container it did not create.**

- One module (`lsd_tree_editor/docker.py`) runs the docker command, and
  nothing else does.
- What the program makes is named `lsd-tree-editor-<random>` and
  labelled `org.lsd-docker.tree-editor=1`, with the run's session id and
  the program's process id.
- Every command that acts on a container or a volume (exec, logs,
  inspect, rm, volume rm) goes through one function. It refuses unless
  the target is the one this run created **and** Docker says it carries
  this run's session label. No field, argument or file gives the program
  a container's name.
- The docker verbs it can run are a fixed list. There is no stop of
  another container, no prune, no image removal. An image is downloaded
  only after you said yes.
- It uses a free port from 32888, not 32887, so a server you run
  yourself keeps its port.

**When it exits, it removes its server.** Closing the window, Quit,
Ctrl-C, `kill`, a closed terminal: the window says "Stopping the
server..." and stays until the container and its volume are removed
(`docker rm -f`, `docker volume rm`), or tells you what could not be
removed and the command to do it by hand.

If the program is killed outright (`kill -9`, a crash, a power cut),
two things clean up:

- A watcher inside the container stops the server when the program has
  not been heard from for about half a minute (the program touches a
  file in the container every 3 seconds). The container was started
  with `--rm`, so Docker removes it as it stops.
- The next time the program starts, it removes what carries its label
  and belongs to a run that is no longer alive: the volume the killed
  run left, and the container if it is still there.

**Only one.** A second Launch is refused while a server exists. A second
copy of the program is refused when it starts: the first holds a lock
file (`~/Library/Application Support/lsd-tree-editor/lock` on macOS,
`~/.local/state/lsd-tree-editor/lock` on Linux). A lock left by a
program that is gone is taken over.

`tests/` proves each rule against a stand-in for the docker command that
records every call: `python -m pytest` in this directory (needs
`PySide6` and `pytest`; no Docker). The tests of the edits build the
engine's `bttree` for this computer from `bot/` (a C compiler is
needed; without one they are skipped) and check every edit made text by
it against the texts kept in `tests/fixtures/edits`; the shipped trees
(`bot/trees/*.bt`) are drawn and their layout checked. `LSD_BOT_DIR`
names another `bot/` to build from and read the shipped trees of (a copy
that does not change while the tests run); `LSD_BTTREE`, a `bttree`
built already.

## What comes next

- **Phase 1:** the server, the text editor with checking, formatting
  and the outline, apply to all bots and revert.
- **Phase 2 (this):** the diagram (outline and left to right), editing
  the tree as a structure through the engine, trees inside trees shown in
  place, decisions, applying to some bots, who chooses what.
- Watching one bot think, live, on the diagram: not now (the owner's
  choice); `lsdctl bots watch` does it in a terminal.

## Troubleshooting

- **"Docker is not running."** Start Docker Desktop (or the docker
  service). The text cannot be checked until then: the checker is in the
  image.
- **"The image ... is too old."** The image has no `lsdctl bots`
  commands. Choose a newer one in the Image field. An image built from
  this repository (`docker build -t lsd-docker:demo .`, or
  `dev/demo-new.sh`) has them, and `lsd-docker:demo` is offered in the
  list when it is on your computer.
- **The port.** The program takes the first free UDP port from 32888 and
  shows it. If friends on your network cannot join, your firewall may be
  closing that port.
- **"Nothing on this computer opens aos:// links."** ZeroSpades does not
  register the `aos://` scheme everywhere. Use **Choose client...** to
  point at the ZeroSpades program (the `.app` on macOS): the editor then
  starts it with the address. Or copy the address and paste it into
  ZeroSpades.
- **"The tree editor is already running."** Only one may run. If none
  is, the lock file is stale and the next start takes it over by itself.
- **Something was left behind.** `docker ps -a --filter
  label=org.lsd-docker.tree-editor=1` and `docker volume ls --filter
  label=org.lsd-docker.tree-editor=1` list everything the program ever
  made that is still there. Starting the program again removes it.

GPL-3.0-or-later. Copyright (C) 2026 Fran6nd.
