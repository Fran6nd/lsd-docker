-- lib_map_layout.lua -- A map's moving parts and permissions, in every game
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- A map is its .vxl terrain plus a layout, <map>.editor.json beside it:
-- the components built into it (doors, elevators -- map_layout/door.lua,
-- map_layout/elevator.lua), who may edit which part of it (authorization
-- chunks, map_layout/chunks.lua) and the map-wide policy. The editor
-- gamemode makes layouts; this runs them, in whatever gamemode is
-- playing, which is why every Gamemode requires it.
--
-- What it does all the time:
--
--   * loads the layout on every map load, and draws its components
--   * runs them: each component's tick, at the server's 60 Hz
--   * guards them: a component's blocks cannot be broken one at a time
--     (one lost block would break it), by players or by other scripts'
--     bulk writes, and no player edit lands where a chunk forbids it
--   * spares riders: no fall damage inside an elevator's shaft
--
-- API (the global `map_layout`), for the editor and for gamemodes:
--
--   map_layout.map()                    the current map's name, or nil
--   map_layout.kinds()                  name -> component module
--   map_layout.instances()              id -> placed component
--   map_layout.add(kind, data, opts)    place one: opts.perm, opts.color;
--                                       -> the instance
--   map_layout.release(id)              un-place one, its blocks left as
--                                       terrain (undo); -> the instance
--   map_layout.owner(x, y, z)           id of the component owning a cell
--   map_layout.owned()                  id -> how many cells each owns
--   map_layout.may_edit(pid, x, y, z)   "allow" | "deny" | "break", id
--   map_layout.revert(pid, pos, type)   undo a refused edit on a client
--   map_layout.revert_action(pid, pos, type)   ...of a whole Block Action
--                                       (a spade's three blocks)
--   map_layout.revert_line(pid, a, b)   ...of a whole Block Line
--   map_layout.chunks                   the chunk module
--   map_layout.readonly([on])           the master lock, read or set
--   map_layout.save([force])            write the layout (autosave rules)
--   map_layout.save_as(name)            write <name>.vxl + its layout
--   map_layout.json_path()              where the layout lives
--   map_layout.blocks                   the block API (`we`) itself
local mod = init_mod();

-- Hot-reload correctness: require() caches modules in package.loaded, so
-- without this a /load of lib_map_layout would re-run this file but keep
-- the *old* chunks and component code. Drop the whole namespace first so
-- a reload genuinely reloads every piece.
for m in pairs(package.loaded) do
	if (string.sub(m, 1, 11) == "map_layout.") then
		package.loaded[m] = nil;
	end
end

local J      = require "map_layout.json";
local we     = require "map_layout.blocks";
local areas  = require "map_layout.areas";
local chunks = require "map_layout.chunks";

getcfg("map_layout_dir", "maps",
	"Where each map's <map>.editor.json lives, beside the map.");
getcfg("map_layout_default_perm", "rw",
	"Who may edit blocks outside every chunk: ro, rw, rw:<team>.");
getcfg("map_layout_readonly", false,
	"Master lock: refuse every player block edit.");
getcfg("map_layout_autosave", true,
	"Rewrite the layout on every change.");

local msg = {
	cannot_write     = {en="map_layout: cannot write %(path) (%(err)) -- drop the :ro on the maps mount to persist"},
	bad_json         = {en="map_layout: %(path) is not valid json, ignoring"},
	layout_loaded    = {en="map_layout: loaded %(path)"},
	component_failed = {en="map_layout: component %(name) failed to load: %(err)"},
	vxl_failed       = {en="map_layout: cannot write %(path) (%(err))"},
	broke            = {en="You broke %(kind) #%(id)."},
};

local mapname = nil;
local kinds = {};      -- name -> component module
local insts = {};      -- id -> instance
local nextid = 1;

--=========================== RESERVED VOLUMES =======================--
--
-- A component may reserve cells it does not fill -- an elevator's shaft --
-- and nobody may build into them. They are consulted for every block a
-- player edits, and a block line is dozens of blocks at once -- so they go
-- through the same xy grid the authorization chunks use rather than a
-- scan over every component. Rebuilt whenever the instance set changes.
local reserved_idx = areas.index();

local function reindex_reserved()
	reserved_idx:reset();
	for _, inst in pairs(insts) do
		if (inst.reserved_area ~= nil) then
			reserved_idx:add(inst.reserved_area, inst);
		end
	end
end

-- Does any reserved volume covering this block refuse this player?
-- Every volume covering the block has a say, not just the first found:
-- where two overlap, the stricter one wins, so a permissive component
-- can't open a hole through a protected one.
local function reserved_denies(pid, x, y, z)
	local bucket = reserved_idx:bucket(x, y);
	if (bucket == nil) then
		return false;
	end
	for i = 1, #bucket do
		local inst = bucket[i];
		if (areas.contains(inst.reserved_area, x, y, z)) then
			local p = inst.perm or {mode="ro"};
			if (p.mode ~= "rw" or (p.team ~= nil and get_team(pid) ~= p.team)) then
				return true;
			end
		end
	end
	return false;
end

-- is this point inside any component's reserved volume at all?
local function in_reserved(x, y, z)
	local bucket = reserved_idx:bucket(x, y);
	if (bucket == nil) then
		return false;
	end
	for i = 1, #bucket do
		if (areas.contains(bucket[i].reserved_area, x, y, z)) then
			return true;
		end
	end
	return false;
end

--============================= PERSISTENCE ==========================--

-- Layouts live beside the .vxl as <map>.editor.json. The .editor.
-- infix keeps them clearly ours and out of the way of anything else
-- that might key off <map>.json.
local function json_path(name)
	name = name or mapname;
	if (name == nil) then
		return nil;
	end
	return map_layout_dir .. "/" .. name .. ".editor.json";
end

-- the whole layout as a plain table, ready to encode
local function build_doc()
	local comps = {};
	for _, inst in pairs(insts) do
		local d = kinds[inst.kind].save(inst);
		d.kind = inst.kind;
		d.id = inst.id;
		d.perm = chunks.format_perm(inst.perm or {mode="ro"});
		if (inst.color ~= nil) then
			d.color = {r=inst.color.r, g=inst.color.g, b=inst.color.b};
		end
		table.insert(comps, d);
	end
	table.sort(comps, function(a, b) return a.id < b.id; end);

	return {
		default_perm = chunks.format_perm(chunks.get_default()),
		readonly = map_layout_readonly and true or false,
		chunks = chunks.serialize(),
		components = comps,
	};
end

-- write the layout to an explicit path; returns ok, err
local function write_json(path)
	local f, err = io.open(path, "w");
	if (f == nil) then
		-- maps/ may be mounted read-only; say so plainly rather than
		-- silently dropping the layout
		l10n_log(msg.cannot_write, {path=path, err=tostring(err)});
		return false, err;
	end
	f:write(J.encode(build_doc()), "\n");
	f:close();
	return true;
end

-- force writes even with autosave off: the editor's first write of a new
-- map's layout, and explicit saves
local function save(force)
	local path = json_path();
	if (path == nil or (not map_layout_autosave and not force)) then
		return false;
	end
	return write_json(path);
end

local function clear_all()
	for _, inst in pairs(insts) do
		kinds[inst.kind].destroy(inst, we);
	end
	insts = {};
	we.guarded = {};
	nextid = 1;
	reindex_reserved();
end

local function load_layout()
	clear_all();
	chunks.reset();
	chunks.set_default(chunks.parse_perm(map_layout_default_perm) or {mode="rw"});

	local path = json_path();
	if (path == nil) then
		return;
	end

	local f = io.open(path, "r");
	if (f == nil) then
		return;  -- no layout for this map: perfectly normal
	end
	local body = f:read("*a");
	f:close();

	local ok, doc = pcall(J.decode, body);
	if (not ok or type(doc) ~= "table") then
		l10n_log(msg.bad_json, {path=path});
		return;
	end

	if (doc.default_perm) then
		chunks.set_default(chunks.parse_perm(doc.default_perm) or {mode="rw"});
	end
	if (doc.readonly ~= nil) then
		map_layout_readonly = doc.readonly;
	end
	chunks.deserialize(doc.chunks);

	for _, d in ipairs(doc.components or {}) do
		local k = kinds[d.kind];
		if (k) then
			local inst = k.spawn(d, we);
			inst.id = d.id or nextid;
			inst.kind = d.kind;
			inst.perm = chunks.parse_perm(d.perm) or {mode="ro"};
			inst.color = d.color;
			if (k.reserved) then inst.reserved_area = k.reserved(inst, we); end
			if (inst.id >= nextid) then nextid = inst.id + 1; end
			insts[inst.id] = inst;
			k.render(inst, we);
		end
	end
	reindex_reserved();

	l10n_log(msg.layout_loaded, {path=path});
end

--================================ GUARD =============================--
--
-- Deny order matters: component blocks are absolute, then the master
-- readonly switch, then the chunk the block sits in.
--
-- Components carry the same perm vocabulary as chunks: "ro" is protected
-- from both teams, "rw:<team>" leaves only that team able to touch it,
-- "rw" protects it from nobody. A player who *is* allowed through doesn't
-- chip a hole in it -- one lost block would break the component, so the
-- whole thing comes down instead.
-- Returns "allow", "deny", or "break", <instance id>.
local function may_edit(pid, x, y, z)
	local id = we.guarded[we.key(x, y, z)];
	if (id ~= nil) then
		local inst = insts[id];
		if (inst == nil) then
			return "allow";
		end
		local p = inst.perm or {mode="ro"};
		if (p.mode ~= "rw") then
			return "deny";
		end
		if (p.team ~= nil and get_team(pid) ~= p.team) then
			return "deny";
		end
		return "break", id;
	end

	-- reserved volumes (e.g. an elevator shaft): no block there to break,
	-- but nobody may fill it in either, subject to the same perm as the
	-- component that owns it
	if (reserved_denies(pid, x, y, z)) then
		return "deny";
	end

	if (map_layout_readonly) then
		return "deny";
	end
	if (not chunks.can_write(pid, x, y, z)) then
		return "deny";
	end
	return "allow";
end

-- Hand a component's blocks back to the map instead of taking them down
-- with it.
--
-- A component is made OUT OF somebody's build: placement captures the
-- marked box and render digs those very blocks and re-lays them as ours
-- (see map_layout/stencil.lua). Un-placing one must therefore not delete
-- them -- undoing a misplaced door would otherwise eat the door somebody
-- had just drawn. So the component is first settled back to rest,
-- putting the drawing exactly where it was captured, and then simply
-- forgotten: the blocks stay in the map as ordinary terrain.
--
-- This is deliberately NOT what destroy does. save_as needs the blocks
-- genuinely gone so the .vxl it dumps is pure terrain, and a component
-- broken by a player still comes down; both keep using destroy.
local function release(id)
	local inst = insts[id];
	if (inst == nil) then
		return nil;
	end
	local k = kinds[inst.kind];
	if (k.settle ~= nil) then
		k.settle(inst, we);
	end
	we.disown(id);
	insts[id] = nil;
	reindex_reserved();
	save();
	return inst;
end

-- take a whole component down because one of its blocks was broken
local function break_component(id, by)
	local inst = insts[id];
	if (inst == nil) then
		return;
	end
	kinds[inst.kind].destroy(inst, we);
	insts[id] = nil;
	reindex_reserved();
	if (by ~= nil) then
		l10n_send_chat(by, msg.broke, {kind=inst.kind, id=id});
	end
	save();
end

-- put back what the client already changed locally: a refused destroy
-- has to be rebuilt, a refused build has to be taken away. A bot has no
-- client to put back, and is sent nothing (lib_bot: never a packet to a
-- bot).
local function revert(pid, pos, type)
	if (bot_is_bot ~= nil and bot_is_bot(pid)) then
		return;
	end
	if (type == 0) then
		send_block_action(pid, pos, 1, get_anon_pid());
		return;
	end
	-- this leaves THIS client holding a different colour for the anon pid
	-- than the server does; harmless, because every component build sets
	-- the colour again before it draws (see map_layout/blocks.lua)
	send_set_block_color(pid, get_map_block_color(pos), get_anon_pid());
	send_block_action(pid, pos, 0, get_anon_pid());
end

-- the same for every block a 1- or 3-wide action touched
local function revert_action(pid, pos, type)
	revert(pid, pos, type);
	if (type == 2) then
		revert(pid, {x=pos.x, y=pos.y, z=pos.z-1}, type);
		revert(pid, {x=pos.x, y=pos.y, z=pos.z+1}, type);
	end
end

-- ...and for every block of a line, which only builds
local function revert_line(pid, start, stop)
	for p in iter_block_line(start, stop) do
		revert(pid, p, 0);
	end
end

-- The guard runs in the `late` callchain, not the default one, and that
-- is load-bearing rather than tidiness.
--
-- Vetoing means returning without calling next, which hides the event
-- from every handler further down. Scripts that only *observe* block
-- actions are entitled to see one even when it changes no block: a
-- bullet that hit a protected door was still a bullet. lib_shot_detect
-- takes a block action as proof a gun really fired; starve it and the
-- railgun and grenade shotgun stop once the engine's magazine estimate
-- drifts. Dispatch runs xearly -> early -> std -> late -> impl, so a
-- guard in `late` is the last word before the engine while every std
-- observer above it still runs.
function mod.late.on_block_action(pid, pos, type)
	-- spade-3 takes the block above and below too
	local hit = {pos};
	if (type == 2) then
		hit = {pos, {x=pos.x, y=pos.y, z=pos.z-1}, {x=pos.x, y=pos.y, z=pos.z+1}};
	end
	local broke = nil;
	for _, p in ipairs(hit) do
		local act, id = may_edit(pid, p.x, p.y, p.z);
		if (act == "deny") then
			for _, q in ipairs(hit) do
				revert(pid, q, type);
			end
			return;
		elseif (act == "break") then
			broke = id;
		end
	end
	if (broke ~= nil) then
		break_component(broke, pid);
		return;
	end

	mod.late.next.on_block_action(pid, pos, type);
end

-- ...and the same for a block line, for the same reason.
function mod.late.on_block_line(pid, start, stop)
	local broke = nil;
	for p in iter_block_line(start, stop) do
		local act, id = may_edit(pid, p.x, p.y, p.z);
		if (act == "deny") then
			-- refuse the whole line: a half-drawn line is worse than none
			revert_line(pid, start, stop);
			return;
		elseif (act == "break") then
			broke = id;
		end
	end
	if (broke ~= nil) then
		break_component(broke, pid);
		return;
	end
	mod.late.next.on_block_line(pid, start, stop);
end

-- A cell nothing but a component may write: one it occupies, or a volume
-- it has reserved. `guarded` is our record of what exists -- a foreign
-- write makes that record a lie, and the component silently breaks. That
-- is the whole of what this library keeps, said once to the question
-- every edit answers to (lib_block_filter): not a script's /selrm or
-- /selfill, not a rocket's or a grenade's crater, not a bot's dig. Our
-- own drawing is the server's (server_edit) and is not asked.
local function foreign_blocked(pos)
	return we.guarded[we.key(pos.x, pos.y, pos.z)] ~= nil
	    or in_reserved(pos.x, pos.y, pos.z);
end

function mod.may_edit_block(who, pos, type)
	if (foreign_blocked(pos)) then
		return false;
	end
	local below = mod.next.may_edit_block;
	return below == nil or below(who, pos, type);
end

-- A grenade a player threw that lands on a component: anything short of
-- a fully open one (perm "rw") shrugs it off, an open one is broken
-- whole -- the same as a player's spade on it (above).
function mod.block_action(pos, type, from)
	if (from ~= get_anon_pid() and type ~= 0) then
		local id = we.guarded[we.key(pos.x, pos.y, pos.z)];
		local inst = id and insts[id];
		if (inst ~= nil) then
			local p = inst.perm or {mode="ro"};
			if (p.mode ~= "rw" or p.team ~= nil) then
				return;
			end
			break_component(id, nil);
			return;
		end
	end
	mod.next.block_action(pos, type, from);
end

--================================ EVENTS ============================--

-- strip directory and extension so "maps/hallway.vxl" keys the same
-- file as "hallway"
local function mapkey(name)
	name = string.gsub(name, "^.*/", "");
	name = string.gsub(name, "%.vxl$", "");
	name = string.gsub(name, "%.lua$", "");
	return name;
end

function mod.after.load_map(name)
	mapname = mapkey(name);
	load_layout();
end

-- Loaded onto an already-running map, load_map has long since fired, so
-- recover the current map from the masterlist name (usually the
-- filename; a map shipping .txt metadata may report a display name,
-- which the next real load_map corrects).
if (mapname == nil) then
	local ok, m = pcall(masterlist_get_map);
	if (ok and type(m) == "string" and m ~= "" and m ~= "???") then
		mapname = mapkey(m);
	end
end

-- tick() is called at TICKRATE Hz (60, per src/main.c) and Lua is not
-- told the delta, so it lives here as one constant rather than being
-- hardcoded again inside every component.
local TICK_DT = 1/60;

function mod.after.tick()
	for _, inst in pairs(insts) do
		kinds[inst.kind].tick(inst, we, TICK_DT);
	end
end

-- A rider is teleported, not falling, but neither the engine's velocity
-- nor fall_damage.lua's apex tracking can tell the difference, so a ride
-- can land phantom fall damage. Swallow environment damage (KillTypeFall
-- = 4: fall_damage.lua and water_damage.lua both report it) for anyone
-- standing inside an elevator's shaft.
function mod.damage_player(pid, hp, type, from)
	if (type == 4 and is_alive(pid)) then
		local p = get_position(pid);
		if (in_reserved(p.x, p.y, p.z)) then
			return;
		end
	end
	mod.next.damage_player(pid, hp, type, from);
end

--================================= API ==============================--

local function add(kind, data, opts)
	local k = kinds[kind];
	if (k == nil) then
		error("no component kind " .. tostring(kind), 2);
	end
	opts = opts or {};
	local inst = k.spawn(data, we);
	inst.id = nextid; nextid = nextid + 1;
	inst.kind = kind;
	inst.perm = opts.perm or {mode="ro"};
	inst.color = opts.color;   -- nil keeps the component's own default
	if (k.reserved) then inst.reserved_area = k.reserved(inst, we); end
	insts[inst.id] = inst;
	reindex_reserved();
	k.render(inst, we);
	save();
	return inst;
end

-- Persist the map itself. The components are drawn into the live map,
-- so lift them out first, dump pure terrain to <name>.vxl, put them
-- back, then write <name>.editor.json alongside -- reloading the map
-- restores terrain from the vxl and components from the json.
local function save_as(name)
	local vxlpath = map_layout_dir .. "/" .. name .. ".vxl";

	-- take component blocks out so the vxl is pure terrain (+ the shafts
	-- dug for elevators, which are genuine terrain changes)
	for _, inst in pairs(insts) do
		kinds[inst.kind].destroy(inst, we);
	end

	local ok = true;
	local f, err = io.open(vxlpath .. ".new", "wb");
	if (f == nil) then
		l10n_log(msg.vxl_failed, {path=vxlpath, err=tostring(err)});
		ok = false;
	else
		f:setvbuf("no");
		for dat in dump_vxl() do
			f:write(dat);
		end
		f:close();
		os.rename(vxlpath .. ".new", vxlpath);
	end

	-- put the components back on the live map
	for _, inst in pairs(insts) do
		kinds[inst.kind].render(inst, we);
	end

	return ok and write_json(json_path(name));
end

map_layout = {
	map = function() return mapname; end,
	kinds = function() return kinds; end,
	instances = function() return insts; end,
	add = add,
	release = release,
	owner = function(x, y, z) return we.guarded[we.key(x, y, z)]; end,
	owned = function()
		local n = {};
		for _, id in pairs(we.guarded) do n[id] = (n[id] or 0) + 1; end
		return n;
	end,
	may_edit = may_edit,
	revert = revert,
	revert_action = revert_action,
	revert_line = revert_line,
	chunks = chunks,
	readonly = function(on)
		if (on ~= nil) then
			map_layout_readonly = on and true or false;
			save();
		end
		return map_layout_readonly;
	end,
	save = save,
	save_as = save_as,
	json_path = json_path,
	blocks = we,
};

-- Components self-register by being required. Done at load time rather
-- than from an event so a broken component surfaces immediately, and
-- adding a file to map_layout/ plus a name here is the only step.
for _, name in ipairs({"elevator", "door"}) do
	local ok, k = pcall(require, "map_layout." .. name);
	if (ok and type(k) == "table") then
		kinds[k.name] = k;
	else
		l10n_log(msg.component_failed, {name=name, err=tostring(k)});
	end
end

--============================== LIFECYCLE ===========================--

-- Loaded onto a running map (a hot load): load_map fired long before us,
-- so nothing would restore the saved layout. On a normal boot mapname is
-- still nil here -- the map loads after us -- and load_map does it.
function mod.on_load()
	if (mapname ~= nil) then
		load_layout();
	end
end

-- Leave nothing of ours behind. Components are drawn into the live map
-- and tracked in we.guarded, which does not survive the unload -- so
-- blocks nobody is guarding would sit there pretending to be a door.
-- Hand them back to the map the way an undo does: settled at rest, and
-- plain terrain again.
function mod.on_unload()
	for id in pairs(insts) do
		local inst = insts[id];
		local k = kinds[inst.kind];
		if (k.settle ~= nil) then k.settle(inst, we); end
		we.disown(id);
	end
	insts = {};
	we.guarded = {};
	reindex_reserved();
	map_layout = nil;
end

return mod;
