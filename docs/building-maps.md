# Building maps

Building is a gamemode of its own: `lsd gamemode editor`. While it runs,
the server is off the public lists (the address still works, to invite
builders), `time_limit` is paused, and every player builds: terrain
tools (`/sel`, `/selfill`, `/selrm`, `/selcpy`, ...), flight (`/noclip`),
any block anywhere, unlimited blocks, no fall damage, and a gun that does
not chew the map.

The tools are in the pie menu, ahead of the usual pies (the editor
installs `pie_menu`):

| pie | when aiming at | wedges |
|---|---|---|
| Select | a block | Corner 1, Corner 2 (where you aim), Fill, Remove, Paint, Deselect |
| Place | a block | Door (up / aside), Lift (up / down), Mark here, Delete |
| Map | anything | Undo, Save, Fly, Components, Chunks, Help |

For a private build server, the editor's setup can give every player
every permission while it runs -- kick, ban, Lua included:
`lsd configure editor`, or `lsd set editor_all_permissions True`.

Select two corners, then Fill or Remove the box -- or Door or Lift, which
take it as theirs; a lift then wants the height it travels to: aim there,
Mark here. Every wedge is a command too, for clients without the pie
menu.

A map's **layout** -- what it holds besides terrain -- is placed here
and runs in every gamemode, kept in `<map>.editor.json` beside the map:

- **doors** that open as a player nears them, **elevators** that carry
  riders: build the shape, then `/place door left` (or `/place elevator
  up`) and select its box; `/place` lists them, `/undo` and `/delete`
  take one back, its blocks left as they are;
- **permission chunks**: `/chunk box rw:1 base` -- who may edit inside;
  `/defaultperm` for the rest of the map, `/mapreadonly on` to lock it.

`/save` writes the map and its layout to `maps/`; then
`lsd gamemode ctf` (or any other) plays it, doors and all. Marks can
also come by coordinate (`/marks x y z ...`), which with `/place` drives
a placement from the console.

Under the hood: `catalog/libs/map_layout/` runs layouts (doors,
elevators, permissions, the layout file), and
`catalog/gamemodes/editor/` is the editing session and its commands.
