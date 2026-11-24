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
  it; click one to draw it, the right button renames it (every `tree
  <name>` follows). *Server*: choose the image, the game, the map, the
  bots a team and their level, then **Launch the server**. **Stop the
  server** removes it. **Join it**: the address, to copy or to open in
  ZeroSpades.
- **The diagram** (middle): the tree drawn by itself from its structure,
  top-down (**A**, the main view) or left to right (**B**). A card is a
  node with what holds it stacked above (an option on what it does, a
  decorator on its child); its colour says its kind, an option shows its
  trait, its factor and a bar against its siblings; a pick shows its
  settings, a pick that rolls its shares. A pick used as a priority list
  (options of trait `none`, factors far apart) is a numbered list with
  no bars. In A, a node of many children stacks them in a numbered
  column, so a pick of 13 options is not 3,800 px wide; its options'
  own children start folded (the knob opens them). `tree <name>` is a
  box: **open** shows that tree in place, in a dashed frame, read-only;
  click the frame's title (or double-click the box) to edit that tree
  itself, **Back** returns. An edit there changes it wherever it is
  used, and the diagram says in how many places. Drag to pan,
  Ctrl+wheel or the bar below to zoom, **Fit**, the map to move.
  Hovering a card shows its whole words and comments.
- **Editing in the diagram**: choose a node (click, or the arrows),
  change its words in **Properties** (each argument with its type, its
  choices and its default, from the engine's schema; a factor with a
  slider; the comments). Alt+arrows move a node among its siblings (order
  is priority; the numbers follow), or drag it onto a blue line, under
  the same parent or another. The right button (and the Edit menu):
  insert before, after or as a child from a palette of what may go
  there, with a search over the words and what they do; wrap in a
  decorator, remove one; cut, copy, paste, delete; make a part a tree of
  its own; copy a referenced tree in place. **Undo** and **Redo**.
  Every change is made on the structure, written back as text **by the
  engine** and checked by it: one it refuses changes nothing and the
  diagram says why.
- **The text** (right, always shown): what is kept, and what a bot runs.
  New, Open, Open from the server, Save, Save as, Save to the server.
  The text is checked when you stop typing: every mistake is underlined
  and listed under **Problems**. While it does not compile the diagram
  shows the last tree that did, marked so, and cannot be edited.
  Choosing a node in the diagram, the text or the **Outline** chooses it
  in the other two.
- **Who chooses what** (beside Properties): the engine rolls a crowd of
  bots and ticks the tree drawn once for each, in a situation you set
  with a slider for each word the tree asks about; it shows what they
  end up doing, in all and by kind of bot, and for a chosen pick how
  often each option was taken. It runs again after every change.
- **The bots** (below): who plays, on which team, what each runs and
  does now. **Apply to all bots** gives the text to every bot that has
  no tree of its own; **Apply to selected** to the bots chosen in the
  table, **Apply to them** to a team or a kind of bot, each as its own
  tree; **Revert selected** and **Revert all** give the game's tree
  back. A text that does not compile changes nothing, and the program
  shows what the server answered.

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
it against the texts kept in `tests/fixtures/edits`.

## What comes next

- **Phase 1:** the server, the text editor with checking, formatting
  and the outline, apply to all bots and revert.
- **Phase 2 (this):** the diagram (A and B), editing the tree as a
  structure through the engine, applying to some bots, who chooses what.
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
