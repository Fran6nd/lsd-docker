-- editor.lua -- The editor gamemode: build a map and its layout
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Building is its own session, not a game: `lsdctl gamemode editor`,
-- build, `/save`, `lsdctl gamemode ctf`. While it runs:
--
--   * the server is off the public server lists -- a half-built map is
--     not what anyone browsing wants to drop into -- but anyone with the
--     address can still join to help build;
--   * every player is a builder: terrain editing (sel.lua), free flight
--     (noclip.lua), any block placement (unrestricted_blocks), no block
--     or grenade shortage (infinite_blocks), no fall or water damage, and
--     a gun that does not chew the map;
--   * the tools are in the pie menu, first: select corners where you
--     aim, fill, remove, paint, place doors and elevators, undo, save
--     (editor/pies.lua);
--   * the layout -- doors, elevators, permission chunks -- is placed with
--     /place and kept by map_layout, which runs it in every gamemode;
--   * time_limit, when installed, is paused: a build does not end.
--
-- It does not use the Edit Mode protocol extension: building works the
-- same for every client, through the base protocol and the tools above.
--
-- Placement itself -- marks, selections, the session per player -- is
-- editor/placement.lua.
local mod = init_mod();

for m in pairs(package.loaded) do
	if (string.sub(m, 1, 7) == "editor.") then
		package.loaded[m] = nil;
	end
end

local bit = require("bit");
local P = require "editor.placement";
local PIES = require "editor.pies";

-- Builders: every player while the editor runs. Map-wide policy (the
-- default permission, the master lock) is an admin's.
local CAP_BUILD = "editor_build";
local CAP_ADMIN = "editor_admin";

getcfg("editor_all_permissions", false,
	"Give every player every permission (the \"all\" cap: kick, ban, Lua) "
		.. "while the editor runs -- for a private build server.");

-- Stock scripts the editor lends for the session, with the cap each is
-- gated on; one already loaded by the server is left as it is.
local BORROWED = {
	{script = "sel", cap = "sel"},
	{script = "noclip", cap = "noclip"},
};
-- Stock scripts paused for the session, put back after if they were on.
local PAUSED = {"time_limit"};

local msg = {
	welcome          = {en="This is the EDITOR: build freely, then /save. /place lists what can be placed."},
	borrow_failed    = {en="editor: could not load %(name) (%(err))"},
	delist_failed    = {en="editor: could not delist (%(err))"},
	relist_failed    = {en="editor: could not relist (%(err))"},
	placeable        = {en="editor: placeable -- %(names)"},
	place_hint       = {en="  /place <component> for its help, e.g. /place elevator"},
	no_such_component = {en="editor: no such component. placeable: %(names)"},
	help_head        = {en="editor: %(name) -- %(desc)"},
	help_usage       = {en="  usage: /place %(name) %(usage)"},
	select_box       = {en="editor: select the box for the %(kind) -- /sel, then aim and click each corner."},
	mark_to_place    = {en="editor: mark a block to place."},
	nothing_placing  = {en="editor: nothing being placed -- start with /place, /chunk or /delete."},
	batch_finished   = {en="editor: placement finished on mark %(n) -- %(extra) extra ignored."},
	delete_prompt    = {en="editor: spade or shoot a block of the component to delete."},
	no_components    = {en="editor: no components on this map."},
	nothing_to_undo  = {en="editor: nothing to undo."},
	undone           = {en="editor: removed %(kind) #%(id) -- its blocks stay, back at rest."},
	component_perm   = {en="editor: %(kind) #%(id) is now %(perm)"},
	component_line   = {en="  #%(id) %(kind) at %(x),%(y) %(perm) blocks %(blocks) %(status)"},
	bad_perm         = {en="editor: perm must be ro, rw, or rw:<team>."},
	chunk_prompt_box = {en="editor: mark two opposite corners."},
	chunk_prompt_radial = {en="editor: mark the centre, then the edge."},
	not_in_chunk     = {en="editor: you are not in a chunk (use /defaultperm for the open map)."},
	chunk_perm       = {en="editor: %(name) is now %(perm)"},
	chunk_removed    = {en="editor: removed chunk %(name)"},
	chunks_head      = {en="editor: default %(perm)"},
	chunks_head_ro   = {en="editor: default %(perm), map read-only"},
	chunk_line       = {en="  #%(id) %(name) %(shape) %(perm)"},
	default_perm     = {en="editor: default is now %(perm)"},
	readonly_on      = {en="editor: map read-only: no player edits it."},
	readonly_off     = {en="editor: map editable again."},
	no_map_name      = {en="editor: no map name known -- pass one: /save <name>."},
	bad_map_name     = {en="editor: bad name (no / \\ or leading dot)."},
	saved            = {en="editor: saved %(name).vxl and %(name).editor.json in %(dir)/"},
	save_failed      = {en="editor: save failed -- see the server log (is maps/ writable?)."},
};

--=============================== LISTING ============================--
--
-- The stock masterlist script is the switch. Its on_unload disconnects
-- every masterlist peer, so unloading it really delists rather than
-- leaving a stale entry, and the console's load unloads first, so
-- putting it back is idempotent. Only ever put back what we took away:
-- a server run unlisted must not find itself published because someone
-- edited a map.
--
-- That flag is a GLOBAL, not a local: a hot reload re-runs this file
-- with every local new, and the next incarnation must still know to put
-- the listing back.
if (editor_delisted == nil) then
	editor_delisted = false;
end

local function listing_hide()
	if (editor_delisted or package.loaded["masterlist"] == nil) then
		return;
	end
	local ok, err = pcall(unload, "masterlist");
	if (not ok) then
		l10n_log(msg.delist_failed, {err=tostring(err)});
		return;
	end
	editor_delisted = true;
end

local function listing_show()
	if (not editor_delisted) then
		return;
	end
	editor_delisted = false;
	local ok, err = pcall(load, "masterlist");
	if (not ok) then
		l10n_log(msg.relist_failed, {err=tostring(err)});
	end
end

--=============================== BUILDERS ===========================--

local borrowed_ours = {};
local paused_ours = {};

local function borrow()
	for _, name in ipairs(PAUSED) do
		if (package.loaded[name] ~= nil and pcall(unload, name)) then
			paused_ours[name] = true;
		end
	end
	for _, b in ipairs(BORROWED) do
		if (package.loaded[b.script] == nil) then
			local ok, err = pcall(load, b.script);
			if (ok) then
				borrowed_ours[b.script] = true;
			else
				l10n_log(msg.borrow_failed, {name=b.script, err=tostring(err)});
			end
		end
	end
end

local function give_back()
	for name in pairs(borrowed_ours) do
		pcall(unload, name);
	end
	borrowed_ours = {};
	for name in pairs(paused_ours) do
		pcall(load, name);
	end
	paused_ours = {};
end

local function make_builder(pid)
	if (editor_all_permissions == true and not has_cap(pid, "all")) then
		grant_cap(pid, "all");
	end
	if (not has_cap(pid, CAP_BUILD)) then grant_cap(pid, CAP_BUILD); end
	-- unrestricted_blocks lets through what this cap names
	if (unrestricted_blocks_cap ~= nil and not has_cap(pid, unrestricted_blocks_cap)) then
		grant_cap(pid, unrestricted_blocks_cap);
	end
	for _, b in ipairs(BORROWED) do
		if (not has_cap(pid, b.cap)) then grant_cap(pid, b.cap); end
	end
	-- The pie menu hides the wedges of commands a player may not run, and
	-- may have been built before these were granted: send it again.
	if (pie_menu_refresh ~= nil) then
		pie_menu_refresh(pid);
	end
end

-- A builder from the moment they connect, as caps.lua grants "default"
-- -- before the client agrees to the pie menu, so the first menu it is
-- sent already has the editor's tools.
function mod.after.on_successful_connect(pid)
	make_builder(pid);
end

function mod.after.on_join(pid, team, gun, name)
	make_builder(pid);
	l10n_send_chat(pid, msg.welcome);
end

function mod.after.on_disconnect(pid)
	P.forget(pid);
end

--================================ RULES =============================--

-- Building means dropping off things constantly, /noclip can be toggled
-- off mid-air, and a builder wading a lava-water map would just bleed:
-- the environment (KillTypeFall = 4, which fall_damage.lua and
-- water_damage.lua both report) is swallowed outright.
function mod.damage_player(pid, hp, type, from)
	if (type == 4) then
		return;
	end
	mod.next.damage_player(pid, hp, type, from);
end

-- While placing, no block action edits anything -- the destroy is
-- swallowed and the mark comes from the fire input (on_mouse_input), so
-- it also works on water and on empty misses. And a gun never destroys
-- blocks here: fly around armed without chewing the map. Not for a
-- spectator, whose tool is whatever spawn_player left (the gun) and who
-- builds through the pie menu's tools. Both run before map_layout's
-- guard (this loads later, so its late hook is asked first).
function mod.late.on_block_action(pid, pos, type)
	if (P.session[pid] ~= nil
	    or (get_tool(pid) == 2 and is_alive(pid))) then
		map_layout.revert_action(pid, pos, type);
		return;
	end
	mod.late.next.on_block_action(pid, pos, type);
end

-- Marks are driven by the fire button so they work with a spade or a
-- gun, whether or not the swing destroys anything: bit 1 is primary
-- fire, marked on the press edge while a placement is in progress.
local prevmouse = pid_connected_table(0);

function mod.on_mouse_input(pid, bits)
	local pressed = bit.band(bits, 1) ~= 0 and bit.band(prevmouse[pid], 1) == 0;
	prevmouse[pid] = bits;

	-- A selection being made owns the click: sel picks its corners from
	-- the same button. And a placement waiting on a selection must not
	-- take the click that lands the second corner as one of its own.
	local s = P.session[pid];
	local picking = (sel_pending ~= nil and sel_pending(pid))
		or (s ~= nil and s.from_sel);

	if (pressed and not picking and s ~= nil) then
		local tool = get_tool(pid);
		if (tool == 0 or tool == 2) then   -- spade or gun
			local t = P.aim_target(pid);
			if (t == nil) then
				l10n_send_chat(pid, P.msg.nothing_to_mark);
			else
				l10n_send_chat(pid, P.msg.mark_at, t);
				P.apply_mark(pid, t);
			end
		end
	end

	mod.next.on_mouse_input(pid, bits);
end

-- The tools go in the pie menu whenever there is one: added on load,
-- and again if pie_menu comes after us (a hot load) or comes back.
local pies_in = false;

local function add_pies()
	if (pie_menu_add ~= nil and not pies_in) then
		pie_menu_add("editor", PIES, 10);
		pies_in = true;
	elseif (pie_menu_add == nil) then
		pies_in = false;
	end
end

function mod.after.tick()
	for pid in pairs(P.awaiting) do
		P.take_selection(pid);
	end
	add_pies();
end

--============================== COMMANDS ============================--

-- every placeable component, by name
local function component_names()
	local names = {};
	for n in pairs(map_layout.kinds()) do table.insert(names, n); end
	table.sort(names);
	return names;
end

-- a component's help: its own lines if it provides them, else a usage
-- line built from its fields
local function show_help(pid, k)
	if (type(k.help) == "table") then
		for _, line in ipairs(k.help) do
			l10n_send_chat(pid, line);
		end
		return;
	end
	l10n_send_chat(pid, msg.help_head, {name=k.name, desc=k.desc or ""});
	if (k.usage) then
		l10n_send_chat(pid, msg.help_usage, {name=k.name, usage=k.usage});
	end
end

-- Open to the console too: with /marks, a placement can be driven by
-- coordinates alone.
local cmd = {name="place", caps=CAP_BUILD, fakepid=true, usage="[component] [args...]",
             desc="Place a component; /place alone lists them, /place <c> shows help."};
function cmd.func(pid, argv)
	if (#argv == 0) then
		l10n_send_chat(pid, msg.placeable, {names=table.concat(component_names(), ", ")});
		l10n_send_chat(pid, msg.place_hint);
		return;
	end

	local k = map_layout.kinds()[string.lower(argv[1])];
	if (k == nil) then
		l10n_send_chat(pid, msg.no_such_component,
		               {names=table.concat(component_names(), ", ")});
		return;
	end

	local args = {};
	for i = 2, #argv do args[#args+1] = argv[i]; end
	if (#args == 0) then
		show_help(pid, k);
		return;
	end

	local s, err = k.start(pid, args);
	if (s == nil) then
		if (err) then l10n_send_chat(pid, err); end
		show_help(pid, k);
		return;
	end

	s.kind = k.name;
	s.perm = s.perm or {mode="ro"};   -- components default to fully protected
	-- colour comes from the placer's own block palette, not an argument;
	-- the console has none, and gets the component's default
	if (not is_fakepid(pid)) then
		s.color = get_block_color(pid);
	end

	if (P.begin(pid, s)) then
		l10n_send_chat(pid, msg.select_box, {kind=k.name});
	elseif (P.session[pid] ~= nil and not s.from_sel) then
		l10n_send_chat(pid, s.prompt or msg.mark_to_place);
	end
end
register_command(cmd, mod);

-- Spectators can't spade, and spectating is the natural way to build:
-- you fly to the exact spot. /here drops the mark at your own position.
local cmd = {name={"here", "mark"}, caps=CAP_BUILD, usage="[x y z]",
             desc="Drop a placement mark where you are (or at x y z)."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 0 or #argv == 3);

	if (P.session[pid] == nil) then
		l10n_send_chat(pid, msg.nothing_placing);
		return;
	end

	local pos;
	if (#argv == 3) then
		pos = {x=math.floor(get_arg_num_range("x", pid, cmd, argv[1], 0, 511)),
		       y=math.floor(get_arg_num_range("y", pid, cmd, argv[2], 0, 511)),
		       z=math.floor(get_arg_num_range("z", pid, cmd, argv[3], 0, 63))};
	else
		local p = get_position(pid);
		pos = {x=math.floor(p.x), y=math.floor(p.y), z=math.floor(p.z)};
	end

	l10n_send_chat(pid, P.msg.mark_at, pos);
	P.apply_mark(pid, pos);
end
register_command(cmd, mod);

-- Marks by coordinate, in bulk -- the machine-facing way in: a client
-- with a GUI already knows every corner it wants. Coordinates may be
-- fractional, floored to the block that contains them, as the engine
-- maps a position to a voxel. The whole list is parsed before any of it
-- is placed: a batch that failed half way would leave the placement in a
-- state its caller could not reason about.
local cmd = {name="marks", caps=CAP_BUILD, fakepid=true, usage="<x y z> [x y z ...]",
             desc="Place one or more placement marks by coordinate."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv >= 3 and #argv % 3 == 0);

	if (P.session[pid] == nil) then
		l10n_send_chat(pid, msg.nothing_placing);
		return;
	end

	local pts = {};
	for i = 1, #argv, 3 do
		pts[#pts+1] = {
			x=math.floor(get_arg_num_range("x", pid, cmd, argv[i],   0, 511)),
			y=math.floor(get_arg_num_range("y", pid, cmd, argv[i+1], 0, 511)),
			z=math.floor(get_arg_num_range("z", pid, cmd, argv[i+2], 0, 63)),
		};
	end

	for n, p in ipairs(pts) do
		-- a component takes itself out of the session on its last mark
		if (P.session[pid] == nil) then
			l10n_send_chat(pid, msg.batch_finished, {n=n - 1, extra=#pts - n + 1});
			return;
		end
		l10n_send_chat(pid, P.msg.mark_at, p);
		P.apply_mark(pid, p);
	end
end
register_command(cmd, mod);

local cmd = {name="undo", caps=CAP_BUILD,
             desc="Un-place the most recent component (its blocks stay)."};
function cmd.func(pid, argv)
	local id = table.remove(P.undo);
	local inst = id and map_layout.release(id);
	if (inst == nil) then
		l10n_send_chat(pid, msg.nothing_to_undo);
		return;
	end
	l10n_send_chat(pid, msg.undone, {kind=inst.kind, id=id});
end
register_command(cmd, mod);

local cmd = {name="delete", caps=CAP_BUILD,
             desc="Un-place the component whose block you mark (its blocks stay)."};
function cmd.func(pid, argv)
	P.begin(pid, {kind="__delete", prompt=msg.delete_prompt});
	l10n_send_chat(pid, msg.delete_prompt);
end
register_command(cmd, mod);

local cmd = {name="componentperm", caps=CAP_BUILD, usage="ro|rw|rw:<team>",
             desc="Set protection on the nearest component."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 1);

	local chunks = map_layout.chunks;
	local perm = chunks.parse_perm(argv[1]);
	if (perm == nil) then
		l10n_send_chat(pid, msg.bad_perm);
		return;
	end

	local p = get_position(pid);
	local best, bestd = nil, nil;
	for _, inst in pairs(map_layout.instances()) do
		local d = (inst.x-p.x)^2 + (inst.y-p.y)^2;
		if (bestd == nil or d < bestd) then best, bestd = inst, d; end
	end
	if (best == nil) then
		l10n_send_chat(pid, msg.no_components);
		return;
	end

	best.perm = perm;
	l10n_send_chat(pid, msg.component_perm,
	               {kind=best.kind, id=best.id, perm=chunks.format_perm(perm)});
	map_layout.save();
end
register_command(cmd, mod);

-- Why a component is or is not doing what you expect: each kind reports
-- its live state through an optional status(inst, we), and the block
-- count says whether it owns anything to move at all (a component placed
-- onto existing terrain never claims it, and appears dead).
local cmd = {name={"components", "comps"}, caps=CAP_BUILD, fakepid=true,
             desc="List placed components and their live state."};
function cmd.func(pid, argv)
	local owned = map_layout.owned();
	local kinds = map_layout.kinds();
	local n = 0;
	for _, inst in pairs(map_layout.instances()) do
		n = n + 1;
		local k = kinds[inst.kind];
		l10n_send_chat(pid, msg.component_line, {
			id=inst.id, kind=inst.kind,
			x=tostring(inst.x), y=tostring(inst.y),
			perm=map_layout.chunks.format_perm(inst.perm or {mode="ro"}),
			blocks=owned[inst.id] or 0,
			status=k.status and k.status(inst, map_layout.blocks) or "",
		});
	end
	if (n == 0) then
		l10n_send_chat(pid, msg.no_components);
	end
end
register_command(cmd, mod);

-- Save the map: its terrain (.vxl, components lifted out) and its
-- layout (.editor.json). NOT "savemap": command_savemap.lua owns that,
-- and cannot lift the components out.
local cmd = {name={"save", "wesave"}, caps=CAP_BUILD, fakepid=true, usage="[name]",
             desc="Save the map (.vxl) and its layout (.editor.json) to maps/."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv <= 1);

	local name = argv[1] or map_layout.map();
	if (name == nil) then
		l10n_send_chat(pid, msg.no_map_name);
		return;
	end
	if (string.find(name, "[/\\]") or string.find(name, "^%.")) then
		l10n_send_chat(pid, msg.bad_map_name);
		return;
	end

	if (map_layout.save_as(name)) then
		l10n_send_chat(pid, msg.saved, {name=name, dir=map_layout_dir});
	else
		l10n_send_chat(pid, msg.save_failed);
	end
end
register_command(cmd, mod);

--=============================== CHUNKS =============================--

local cmd = {name="chunk", caps=CAP_BUILD, usage="box|cylinder|sphere|circle|rect <perm> [name]",
             desc="Create an authorization chunk from two marks."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv >= 2);

	local shape = string.lower(argv[1]);
	local perm = map_layout.chunks.parse_perm(argv[2]);
	if (perm == nil) then
		l10n_send_chat(pid, msg.bad_perm);
		return;
	end

	local prompt = (shape == "box") and msg.chunk_prompt_box or msg.chunk_prompt_radial;
	P.begin(pid, {kind="__chunk", shape=shape, perm=perm, name=argv[3], pts={},
	              prompt=prompt});
	if (P.session[pid] ~= nil and not P.session[pid].from_sel) then
		l10n_send_chat(pid, prompt);
	end
end
register_command(cmd, mod);

local function chunk_here(pid)
	local p = get_position(pid);
	return map_layout.chunks.at(math.floor(p.x), math.floor(p.y), math.floor(p.z));
end

local cmd = {name="chunkperm", caps=CAP_BUILD, usage="ro|rw|rw:<team>",
             desc="Set the authorization of the chunk you are standing in."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 1);

	local chunks = map_layout.chunks;
	local perm = chunks.parse_perm(argv[1]);
	if (perm == nil) then
		l10n_send_chat(pid, msg.bad_perm);
		return;
	end
	local c = chunk_here(pid);
	if (c == nil) then
		l10n_send_chat(pid, msg.not_in_chunk);
		return;
	end
	c.perm = perm;
	l10n_send_chat(pid, msg.chunk_perm, {name=c.name, perm=chunks.format_perm(perm)});
	map_layout.save();
end
register_command(cmd, mod);

local cmd = {name="chunkrm", caps=CAP_BUILD, desc="Delete the chunk you are standing in."};
function cmd.func(pid, argv)
	local c = chunk_here(pid);
	if (c == nil) then
		l10n_send_chat(pid, msg.not_in_chunk);
		return;
	end
	map_layout.chunks.remove(c.id);
	l10n_send_chat(pid, msg.chunk_removed, {name=c.name});
	map_layout.save();
end
register_command(cmd, mod);

local cmd = {name="chunks", caps=CAP_BUILD, fakepid=true,
             desc="List authorization chunks."};
function cmd.func(pid, argv)
	local chunks = map_layout.chunks;
	l10n_send_chat(pid, map_layout.readonly() and msg.chunks_head_ro or msg.chunks_head,
	               {perm=chunks.format_perm(chunks.get_default())});
	for _, c in pairs(chunks.all()) do
		l10n_send_chat(pid, msg.chunk_line,
		               {id=c.id, name=c.name, shape=c.shape, perm=chunks.format_perm(c.perm)});
	end
end
register_command(cmd, mod);

local cmd = {name="defaultperm", caps=CAP_ADMIN, fakepid=true, usage="ro|rw|rw:<team>",
             desc="Who may edit blocks outside every chunk."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 1);
	local chunks = map_layout.chunks;
	local perm = chunks.parse_perm(argv[1]);
	if (perm == nil) then
		l10n_send_chat(pid, msg.bad_perm);
		return;
	end
	chunks.set_default(perm);
	l10n_send_chat(pid, msg.default_perm, {perm=chunks.format_perm(perm)});
	map_layout.save();
end
register_command(cmd, mod);

local cmd = {name="mapreadonly", caps=CAP_ADMIN, fakepid=true, usage="on|off",
             desc="Master lock: refuse every player block edit."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 1);
	local on = string.lower(argv[1]) == "on";
	map_layout.readonly(on);
	l10n_send_chat(pid, on and msg.readonly_on or msg.readonly_off);
end
register_command(cmd, mod);

--============================== LIFECYCLE ===========================--

function mod.on_load()
	if (map_layout == nil) then
		error("the editor needs lib_map_layout loaded first "
			.. "(every gamemode pulls it in: lsdctl gamemode editor)", 0);
	end

	listing_hide();
	borrow();

	-- first, before the default layout's pies (PIE_MENU_BASE_ORDER)
	add_pies();

	-- a hot load: whoever is already here builds too
	for i in piditer(PID_BROADCAST) do
		if (is_joined(i)) then make_builder(i); end
	end
end

function mod.on_unload()
	for i in piditer(PID_BROADCAST) do
		P.forget(i);
	end
	if (pie_menu_remove ~= nil) then
		pie_menu_remove("editor");
	end
	pies_in = false;
	give_back();
	listing_show();
end

return mod;
