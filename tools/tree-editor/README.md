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

- **The server** (left): choose the image, the game, the map (a random
  one from the web, or a generated one when there is no network), the
  bots a team and their level, then **Launch the server**. The bots can
  be changed while it runs; that restarts the server, and the program
  says so. **Stop the server** removes it.
- **Join it**: the address, as `aos://...` and as ip:port, for this
  computer and for your network. **Copy** copies it; **Open in
  ZeroSpades** opens it.
- **The text** (middle): one tree text. New, Open, Open from the server
  (the built-in trees and the ones saved on it), Save, **Save as**, Save
  to the server. Tab indents. The text is checked when you stop typing:
  every mistake is underlined and listed under **Problems**; click one
  to go to it. **Format** rewrites the text in the engine's canonical
  form.
- **The outline** (right): the tree as the engine read it. Choosing a
  node selects its line, and the other way round. Numbers the text did
  not write are shown grey, with their default value.
- **The bots** (below): who plays, on which team, what each runs and
  does now. **Apply to all bots** gives the text to every bot that has
  no tree of its own; **Revert** gives them the game's tree back. A text
  that does not compile changes nothing, and the program shows what the
  server answered.

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
`PySide6` and `pytest`; no Docker).

## What comes next

- **Phase 1 (this):** the server, the text editor with checking,
  formatting and the outline, apply to all bots and revert.
- **Phase 2:** editing the tree as a structure: a palette of every node
  and word from the engine's schema, properties with their types and
  defaults; the text is made again by the engine.
- **Phase 3:** choosing bots or a team to apply a tree to, and watching
  one bot think, live, on its tree.

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
