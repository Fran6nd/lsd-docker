-- world_editor.lua -- Place moving map components and spatial permissions
--
-- Editing is a server-wide mode that can only be switched on from the
-- admin console (/worldedit on). While it is on the server takes itself
-- off the public server lists, so nobody browsing drops into a half-built
-- map -- but the door is not shut: anyone already here stays, and anyone
-- who knows the address can still join to help build. See the listing
-- section below.
--
-- Components live one-per-file in world_editor/ and register themselves
-- here; this file owns the shared machinery they all need:
--
--   * placement flow   -- /place <component> <dir>, then spade clicks
--   * block guard      -- every edit is resolved against world_editor/
--                         chunks.lua, and component blocks are always
--                         read-only (losing one block would break the
--                         component, so they simply cannot be broken)
--   * persistence      -- components and chunks live in <map>.editor.json
--                         next to the map, autoloaded on map load,
--                         rewritten on every change
--   * undo             -- /undo pops the last thing placed
--
-- Nothing the stock scripts already do is reimplemented here. Edit mode
-- switches those on and grants their caps for its duration instead:
--
--   sel.lua     -- selections and bulk fill/paint/remove/copy/move/swizzle,
--                  i.e. all terrain editing. See the sel section below for
--                  why that needs the anon-pid write guard to be safe.
--   noclip.lua  -- free flight, for reaching awkward corners. Flying
--                  through walls suits building better than colliding
--                  with them, and it is somebody else's to maintain.
--
-- Two capabilities gate this script, following the pattern sel.lua sets:
--
--   worldedit       -- turn edit mode on and off, and set map-wide
--                      policy. Console only; give it to admins.
--   worldedit_build -- place, move and remove components. Granted
--                      automatically to everyone present for as long as
--                      edit mode is on, and dropped again after.
--
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
local mod = init_mod();

-- Hot-reload correctness: require() caches modules in package.loaded, so
-- without this a /load of world_editor would re-run this file but keep
-- the *old* areas/chunks/component code. Drop our whole namespace first
-- so a reload genuinely reloads every piece.
for m in pairs(package.loaded) do
	if (string.sub(m, 1, 13) == "world_editor.") then
		package.loaded[m] = nil;
	end
end

local bit    = require("bit");
local areas  = require "world_editor.areas";
local chunks = require "world_editor.chunks";
require "lib_bulk_destroy";   -- bdestroy_block_action / bdestroy_finish
require "lib_l10n";           -- l10n_send_chat / l10n_log

getcfg("world_editor_dir", "maps");          -- where <map>.editor.json lives
getcfg("world_editor_default_perm", "rw");   -- authorization outside every chunk
getcfg("world_editor_readonly", false);      -- master lock: no player edits at all
getcfg("world_editor_autosave", true);       -- rewrite the layout on every change
getcfg("world_editor_mark_range", 160);      -- how far a spade/gun mark reaches
getcfg("world_editor_water_level", 63);      -- z a mark lands on when aimed past all blocks

-- Caps this script gates itself on, and the stock caps it borrows for the
-- duration of edit mode. Named once here so the grant/drop loop and every
-- command agree.
local CAP_ADMIN = "worldedit";
local CAP_BUILD = "worldedit_build";
local BORROWED  = {"sel", "noclip"};

-- Every string this script shows a player or writes to the log, as
-- lib_l10n message tables so translations can be dropped in beside the
-- English without touching code. Stock scripts declare one local per
-- message; there are sixty here, so they are grouped instead -- same
-- tables, one namespace. Interpolation is lib_l10n's %(name).
local msg = {
	-- log
	cannot_write      = {en="world_editor: cannot write %(path) (%(err)) -- drop the :ro on the maps mount to persist"},
	bad_json          = {en="world_editor: %(path) is not valid json, ignoring"},
	layout_loaded     = {en="world_editor: loaded %(path)"},
	borrow_failed     = {en="world_editor: could not load %(name) (%(err))"},
	delist_failed     = {en="world_editor: could not delist (%(err))"},
	relist_failed     = {en="world_editor: could not relist (%(err))"},
	relisted_log      = {en="world_editor: relisted after a reload (edit mode did not survive it)"},
	component_failed  = {en="world_editor: component %(name) failed to load: %(err)"},
	edit_log          = {en="world_editor: edit mode %(state)"},
	vxl_failed        = {en="world_editor: cannot write %(path) (%(err))"},

	-- edit mode
	not_editing       = {en="world_editor: not in edit mode (enable it from the console)."},
	console_only      = {en="world_editor: edit mode can only be toggled from the console."},
	edit_status       = {en="world_editor: edit mode is %(state) (map %(map))%(extra)"},
	delisted_by_edit  = {en=", delisted by edit mode"},
	created_layout    = {en="world_editor: created %(path)"},
	tools_granted     = {en="world_editor: %(names) loaded -- terrain editing and flight for the session."},
	delisted          = {en="world_editor: delisted from the public lists (ip:port still works, so you can invite builders in)"},
	relisted          = {en="world_editor: listed publicly again."},
	edit_enabled      = {en="world_editor: edit mode ENABLED -- the map is being built on."},
	edit_disabled     = {en="world_editor: edit mode disabled."},

	-- placement
	placeable         = {en="world_editor: placeable -- %(names)"},
	place_hint        = {en="  /place <component> for its help, e.g. /place elevator"},
	no_such_component = {en="world_editor: no such component. placeable: %(names)"},
	help_head         = {en="world_editor: %(name) -- %(desc)"},
	help_usage        = {en="  usage: /place %(name) %(usage)"},
	prompt            = {en="world_editor: %(text)"},
	nothing_placing   = {en="world_editor: nothing being placed -- start with /place or /chunk."},
	select_box        = {en="world_editor: pick the two corners of the %(kind) -- aim and click each one."},
	nothing_placing2  = {en="world_editor: nothing being placed -- start with /place, /chunk or /delete."},
	delete_prompt     = {en="world_editor: spade or shoot a block of the component to delete."},
	chunk_prompt_box  = {en="world_editor: spade two opposite corners."},
	chunk_prompt_radial = {en="world_editor: spade the centre, then the edge."},
	mark_at           = {en="world_editor: mark at %(x) %(y) %(z)"},
	mark_outside      = {en="world_editor: that mark is outside the map."},
	nothing_to_mark   = {en="world_editor: nothing to mark there -- aim at ground or water."},
	batch_finished    = {en="world_editor: placement finished on mark %(n) -- %(extra) extra ignored."},
	placed            = {en="world_editor: %(kind) #%(id) placed."},

	-- components
	no_component_here = {en="world_editor: no component on that block -- aim right at one."},
	no_components     = {en="world_editor: no components on this map."},
	broke             = {en="world_editor: broke %(kind) #%(id)."},
	released          = {en="world_editor: %(verb) %(kind) #%(id) -- its blocks stay, back at rest."},
	nothing_to_undo   = {en="world_editor: nothing to undo."},
	component_perm    = {en="world_editor: %(kind) #%(id) is now %(perm)"},
	component_line    = {en="  #%(id) %(kind) at %(x),%(y) %(perm) blocks %(blocks) %(status)"},

	-- chunks and policy
	bad_perm          = {en="world_editor: perm must be ro, rw, or rw:<team>."},
	chunk_created     = {en="world_editor: chunk %(name) (%(perm)) created."},
	not_in_chunk      = {en="world_editor: you are not in a chunk (use /defaultperm for the open map)."},
	chunk_perm        = {en="world_editor: %(name) is now %(perm)"},
	chunk_removed     = {en="world_editor: removed chunk %(name)"},
	chunks_head       = {en="world_editor: default %(perm)%(readonly)"},
	chunks_readonly   = {en=", map READONLY"},
	chunk_line        = {en="  #%(id) %(name) %(shape) %(perm)"},
	default_perm      = {en="world_editor: default is now %(perm)"},
	readonly_set      = {en="world_editor: map readonly %(state)"},

	-- saving
	no_map_name       = {en="world_editor: no map name known -- pass one: /wesavemap <name>."},
	bad_map_name      = {en="world_editor: bad name (no / \\ or leading dot)."},
	saved             = {en="world_editor: saved %(name).vxl + %(name).editor.json in %(dir)/"},
	save_failed       = {en="world_editor: save failed -- see server log (is maps/ writable?)."},
};

local editing = false;
local mapname = nil;

local kinds = {};      -- name -> component module
local insts = {};      -- id -> instance
local nextid = 1;
local undo = {};       -- stack of instance ids, newest last

local guarded = {};    -- packed block -> instance id (indestructible)
local session = pid_connected_table(nil);  -- in-progress placement per pid

-- True only while world_editor itself is writing blocks. Our writes and
-- every other script's writes both arrive as the anon pid, so the guard
-- cannot tell them apart by `from` alone -- this flag is what tells them
-- apart. Anything anon-pid arriving with this false is somebody else
-- (sel.lua's bulk ops, say) and must not touch what we own.
local drawing = false;

-- Reserved volumes are consulted for every block a player edits, and a
-- block line is dozens of blocks at once -- so they go through the same
-- xy grid the authorization chunks use rather than a scan over every
-- component. Rebuilt whenever the instance set changes (rare).
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

-- Deepest layer components may write. z=63 is the client's connectivity
-- Root (GameMapWrapper::Rebuild marks every column's z=63 Root
-- unconditionally), so a create there hits `GetLink ~= Invalid` and
-- asserts the cell is solid -- if anything emptied it first, the client
-- dies on the spot. z=62 is the engine's floor: its 3x-destroy guards
-- `pos.z < 62`, though *single* destroy has no such guard, so a script
-- can empty bedrock that no client expects to move. Stay above both.
local WE_DEEPEST = 61;

local function key(x, y, z)
	return (z*512 + y)*512 + x;
end

-- ------------------------------------------------------------------ json
--
-- No JSON library ships with the server and the data here is simple
-- (arrays, string/number/bool fields), so a small encoder/decoder is
-- cheaper than another native dependency.

local function jesc(s)
	return (string.gsub(s, '[%c"\\]', function(c)
		local map = {['"']='\\"', ['\\']='\\\\', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t'};
		return map[c] or string.format("\\u%04x", string.byte(c));
	end));
end

local function isarray(t)
	local n = 0;
	for _ in pairs(t) do n = n + 1; end
	return n == #t;
end

local function jenc(v, ind)
	ind = ind or "";
	local t = type(v);

	if (t == "nil") then return "null"; end
	if (t == "boolean") then return tostring(v); end
	if (t == "number") then
		if (v == math.floor(v)) then return string.format("%d", v); end
		return string.format("%.6g", v);
	end
	if (t == "string") then return '"'..jesc(v)..'"'; end
	if (t ~= "table") then return "null"; end

	local sub = ind.."  ";
	local out = {};

	if (isarray(v)) then
		if (#v == 0) then return "[]"; end
		for _, x in ipairs(v) do
			table.insert(out, sub..jenc(x, sub));
		end
		return "[\n"..table.concat(out, ",\n").."\n"..ind.."]";
	end

	local ks = {};
	for k in pairs(v) do table.insert(ks, k); end
	table.sort(ks, function(a, b) return tostring(a) < tostring(b); end);
	if (#ks == 0) then return "{}"; end
	for _, k in ipairs(ks) do
		table.insert(out, sub..'"'..jesc(tostring(k))..'": '..jenc(v[k], sub));
	end
	return "{\n"..table.concat(out, ",\n").."\n"..ind.."}";
end

local jparse;
local function jws(s, i)
	local _, j = string.find(s, "^[ \t\r\n]*", i);
	return j + 1;
end

jparse = function(s, i)
	i = jws(s, i);
	local c = string.sub(s, i, i);

	if (c == "{") then
		local o = {};
		i = jws(s, i+1);
		if (string.sub(s, i, i) == "}") then return o, i+1; end
		while (true) do
			local k; k, i = jparse(s, i);
			i = jws(s, i);
			i = i + 1;  -- ':'
			local v; v, i = jparse(s, i);
			o[k] = v;
			i = jws(s, i);
			local d = string.sub(s, i, i);
			i = i + 1;
			if (d == "}") then return o, i; end
		end
	elseif (c == "[") then
		local a = {};
		i = jws(s, i+1);
		if (string.sub(s, i, i) == "]") then return a, i+1; end
		while (true) do
			local v; v, i = jparse(s, i);
			table.insert(a, v);
			i = jws(s, i);
			local d = string.sub(s, i, i);
			i = i + 1;
			if (d == "]") then return a, i; end
		end
	elseif (c == '"') then
		local out = {};
		i = i + 1;
		while (true) do
			local ch = string.sub(s, i, i);
			if (ch == '"') then return table.concat(out), i+1; end
			if (ch == "\\") then
				local e = string.sub(s, i+1, i+1);
				local map = {n="\n", r="\r", t="\t", ['"']='"', ["\\"]="\\", ["/"]="/"};
				table.insert(out, map[e] or e);
				i = i + 2;
			else
				table.insert(out, ch);
				i = i + 1;
			end
		end
	elseif (string.sub(s, i, i+3) == "true") then
		return true, i+4;
	elseif (string.sub(s, i, i+4) == "false") then
		return false, i+5;
	elseif (string.sub(s, i, i+3) == "null") then
		return nil, i+4;
	end

	local num = string.match(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", i);
	if (num) then
		return tonumber(num), i + #num;
	end
	error("bad json at "..i);
end

-- ------------------------------------------------------------- block api
--
-- Components build through these so the framework can keep the guard
-- table in sync; they write real (solid) blocks, because players have
-- to be able to stand on a platform and be stopped by a shut door.

local we = {};

-- Blocks are built the way a client would: point the anon player's held
-- colour at what we want, then build from that pid. Everything is a
-- *real* (solid) block so players stand on platforms and stop at shut
-- doors.
--
-- Everything is a single block_action, one packet per block, both to
-- build and to destroy. The batched forms were tried and both broke
-- zerospades clients:
--
--   * block_line: a BlockLine only fills the *non-solid* cells its
--     cube_line touches and caps at 50, so building over solid/dug
--     cells silently dropped blocks and corrupted connectivity.
--   * lib_bulk_destroy: it defers the floating-block cull to one
--     finish per batch, but the client culls immediately per destroy
--     -- so the client removes a block the server still holds, leaving
--     a stale connectivity link (cell not solid, link still valid).
--
--     The next create on that cell then hits GameMapWrapper::AddBlock's
--     `GetLink(x,y,z) != Invalid` branch. Note what that costs on a
--     *release* client: SPAssert compiles to a no-op under NDEBUG
--     (zerospades Sources/Core/Debug.h), so the assert never fires --
--     AddBlock simply returns early and the block silently never
--     appears. The assert crash is a debug-build symptom; the
--     release-build symptom is a structure with holes in it. Either way
--     the stale link is the bug.
--
-- Per-block block_action keeps the server's cull in lockstep with the
-- client's, so no stale links -- the proven-stable primitive. If block
-- volume ever needs cutting, do it by moving fewer blocks, not by
-- batching packets.

-- Set the colour every build draws in, every single time.
--
-- set_block_color, not send_set_block_color: block_action/block_line
-- colour the map from the anon pid's *server-side* held colour, so only
-- setting it server-side bakes the colour into the stored map (a bare
-- broadcast left it black for fresh joiners).
--
-- This looks like an obvious thing to cache -- it costs a packet per
-- call and components draw many layers in one colour -- but DO NOT. The
-- anon pid's held colour is global state shared with every other script,
-- and two of ours move it constantly through send_set_block_color, which
-- changes what *clients* believe without touching the server-side value
-- a cache would be tracking:
--
--   * rifle_is_a_rail_gun -- a random red per shot, to everyone
--   * shotgun_are_grenade_launchers -- get_map_block_color(pos) at one
--     client, and that is documented as implementation-defined for a
--     non-solid voxel, so pellets hitting air push black
--
-- Caching it drew platform rings red, then whole moving components
-- black, and only while people were shooting -- which is to say never
-- during a build session and always during a game. Hooking the setters
-- to invalidate the cache did not catch every path either. One packet
-- per fill is a few percent against the ~73 block packets an elevator
-- step already sends; correctness is worth more than that.
local function hold_color(c)
	if (c == nil) then
		return;
	end
	set_block_color(get_anon_pid(), c);
end

-- one guaranteed-empty run [rx1..rx2] at (y,z), as block_line packets
-- capped at 50 cells each (the client's cube_line stops at 50)
local function line_run(inst, y, z, rx1, rx2)
	local s = rx1;
	while (s <= rx2) do
		local e = math.min(s + 49, rx2);
		block_line({x=s, y=y, z=z}, {x=e, y=y, z=z}, get_anon_pid());
		for x = s, e do guarded[(z*512 + y)*512 + x] = inst.id; end
		s = e + 1;
	end
end

-- Fill (or clear) a solid box. `keep` is a predicate (x,y,z)->bool for
-- partial layers (the disc); nil means the whole box.
--
-- `line` picks the build path:
--   * line=true  -- coalesce empty cells into block_line rows (few
--     packets). ONLY safe when every target cell is already empty this
--     tick: the client's BlockLine skips cells IT sees as solid and its
--     cube_line caps at 50, so a run must be genuine air. Use it for a
--     platform layer landing on open air, never over a cell dug or
--     cleared in the same tick.
--   * line=false -- one block_action per empty cell. Slower but its
--     create cancels a same-tick destroy on the client, so it is the
--     only safe path where a build overlaps a clear (the piston layer).
-- Either way we never create over a solid cell (no "paint without
-- breaking"). Clears always go through lib_bulk_destroy: same per-block
-- destroy packets, but one floating-block cull per batch, not per block.
function we.fill(inst, x1, y1, z1, x2, y2, z2, color, on, keep, line)
	x1 = math.max(0, x1); y1 = math.max(0, y1); z1 = math.max(0, z1);
	x2 = math.min(511, x2); y2 = math.min(511, y2); z2 = math.min(WE_DEEPEST, z2);
	if (x1 > x2 or y1 > y2 or z1 > z2) then return; end

	drawing = true;
	if (on) then
		hold_color(color);
	end

	for z = z1, z2 do
		for y = y1, y2 do
			-- (z*512+y)*512 is constant across the row; hoisting it keeps
			-- the inner loop to one add
			local base = (z*512 + y)*512;
			-- run of consecutive empty, wanted cells (for line builds)
			local run = nil;
			for x = x1, x2 + 1 do
				local k = base + x;
				local want = x <= x2 and (keep == nil or keep(x, y, z));
				local empty = want and not is_solid({x=x, y=y, z=z});

				if (on) then
					if (line) then
						if (empty) then
							run = run or x;
						else
							if (run ~= nil) then line_run(inst, y, z, run, x-1); run = nil; end
							if (want and guarded[k] ~= nil) then guarded[k] = inst.id; end
						end
					elseif (want) then
						if (empty) then
							block_action({x=x, y=y, z=z}, 0, get_anon_pid());
							guarded[k] = inst.id;
						elseif (guarded[k] ~= nil) then
							guarded[k] = inst.id;   -- already ours; keep it
						end
					end
				elseif (want and guarded[k] ~= nil) then
					bdestroy_block_action({x=x, y=y, z=z}, 1);
					guarded[k] = nil;
				end
			end
		end
	end

	if (not on) then bdestroy_finish(); end
	drawing = false;
end

-- Recolour cells this component already owns, without breaking them.
--
-- block_action type 0 is "Build", and lsd/src/main.c block_action()
-- implements it as an unconditional set_solid() + set_vox_color() -- it
-- never checks whether the cell was already solid. So a build packet
-- aimed at a cell that is already solid is a pure colour change: no
-- destroy, and therefore no destroy-then-create on one cell inside a
-- single tick, which is the pattern that leaves client connectivity
-- stale (see the block api above).
--
-- That matters for anything that MOVES a multicoloured structure. Slide
-- a drawing one block along and most of its cells land where another of
-- its own cells already was -- the block is in the right place but the
-- wrong colour. Without this the only fix would be to destroy and
-- rebuild those cells in the same tick, which is exactly what we cannot
-- do.
--
-- Deliberately restricted to cells in `guarded` under this instance.
-- Painting without breaking is precisely what players are not allowed to
-- do, and this must not become a way around that: it can only ever
-- recolour a block the calling component already put there itself.
function we.paint(inst, x1, y1, z1, x2, y2, z2, color, keep)
	x1 = math.max(0, x1); y1 = math.max(0, y1); z1 = math.max(0, z1);
	x2 = math.min(511, x2); y2 = math.min(511, y2); z2 = math.min(WE_DEEPEST, z2);
	if (x1 > x2 or y1 > y2 or z1 > z2) then return; end

	drawing = true;
	hold_color(color);

	for z = z1, z2 do
		for y = y1, y2 do
			local base = (z*512 + y)*512;
			for x = x1, x2 do
				if (guarded[base + x] == inst.id
				    and (keep == nil or keep(x, y, z))) then
					block_action({x=x, y=y, z=z}, 0, get_anon_pid());
				end
			end
		end
	end

	drawing = false;
end

function we.is_guarded(x, y, z)
	return guarded[key(x, y, z)] ~= nil;
end

-- dig existing map blocks (not component blocks, so untracked in
-- guarded) out of a box, so an elevator's path is clear. Bulk: one
-- floating-block cull for the whole shaft instead of one per block.
function we.dig_box(x1, y1, z1, x2, y2, z2, keep)
	x1 = math.max(0, x1); y1 = math.max(0, y1); z1 = math.max(0, z1);
	x2 = math.min(511, x2); y2 = math.min(511, y2); z2 = math.min(WE_DEEPEST, z2);
	drawing = true;
	for z = z1, z2 do
		for y = y1, y2 do
			for x = x1, x2 do
				if ((keep == nil or keep(x, y, z))
				    and guarded[(z*512 + y)*512 + x] == nil
				    and is_solid({x=x, y=y, z=z})) then
					bdestroy_block_action({x=x, y=y, z=z}, 1);
				end
			end
		end
	end
	bdestroy_finish();
	drawing = false;
end

function we.editing()
	return editing;
end

-- ------------------------------------------------------------- animation
--
-- Every moving component runs the same loop: accumulate time, and once a
-- period has passed advance by exactly one step. One step per period is
-- what keeps motion from arriving as a block storm, so it is worth every
-- component doing it identically rather than each rolling its own.

-- The colour a component draws in: its own if the placer picked one from
-- their palette, else the component's default.
function we.tint(inst, fallback)
	return inst.color or fallback;
end

-- True once per 1/speed seconds, consuming that much of inst[field].
-- Components call it in tick() and step only when it returns true.
function we.due(inst, field, speed, dt)
	local t = (inst[field] or 0) + dt;
	local period = 1 / math.max(speed, 0.1);
	if (t < period) then
		inst[field] = t;
		return false;
	end
	inst[field] = t - period;
	return true;
end

-- components build their trigger volumes from the same shape library
-- the authorization chunks use
we.areas = areas;

-- deepest layer a component may occupy (see WE_DEEPEST above): the
-- engine floor and the client's Root layer are off limits
we.deepest = WE_DEEPEST;

-- ------------------------------------------------------------ persistence

-- Layouts live beside the .vxl as <map>.editor.json. The .editor.
-- infix keeps them clearly ours and out of the way of anything else
-- that might key off <map>.json.
local function jsonpath()
	if (mapname == nil) then
		return nil;
	end
	return world_editor_dir.."/"..mapname..".editor.json";
end

local function file_exists(path)
	local f = io.open(path, "r");
	if (f == nil) then return false; end
	f:close();
	return true;
end

-- the whole editable state as a plain table, ready for jenc
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
		readonly = world_editor_readonly and true or false,
		chunks = chunks.serialize(),
		components = comps,
	};
end

-- write the layout json to an explicit path; returns ok, err
local function write_json(path)
	local f, err = io.open(path, "w");
	if (f == nil) then
		-- maps/ is mounted read-only in the stock compose file; say so
		-- plainly rather than silently dropping the layout
		l10n_log(msg.cannot_write, {path=path, err=tostring(err)});
		return false, err;
	end
	f:write(jenc(build_doc()), "\n");
	f:close();
	return true;
end

-- force lets edit-mode force the very first write even when autosave is
-- off, so a brand-new map still gets its .editor.json
local function save(force)
	local path = jsonpath();
	if (path == nil or (not world_editor_autosave and not force)) then
		return;
	end
	write_json(path);
end

local function clear_all()
	for _, inst in pairs(insts) do
		kinds[inst.kind].destroy(inst, we);
	end
	insts = {};
	guarded = {};
	undo = {};
	nextid = 1;
	reindex_reserved();
end

local function load_layout()
	clear_all();
	chunks.reset();
	chunks.set_default(chunks.parse_perm(world_editor_default_perm) or {mode="rw"});

	local path = jsonpath();
	if (path == nil) then
		return;
	end

	local f = io.open(path, "r");
	if (f == nil) then
		return;  -- no layout for this map: perfectly normal
	end
	local body = f:read("*a");
	f:close();

	local ok, doc = pcall(function() return (jparse(body, 1)); end);
	if (not ok or type(doc) ~= "table") then
		l10n_log(msg.bad_json, {path=path});
		return;
	end

	if (doc.default_perm) then
		chunks.set_default(chunks.parse_perm(doc.default_perm) or {mode="rw"});
	end
	if (doc.readonly ~= nil) then
		world_editor_readonly = doc.readonly;
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

-- --------------------------------------------------------------- guard
--
-- Deny order matters: component blocks are absolute, then the master
-- readonly switch, then the chunk the block sits in.

-- Components carry the same perm vocabulary as chunks: "ro" is
-- protected from both teams, "rw:<team>" leaves only that team able to
-- touch it, "rw" protects it from nobody. A player who *is* allowed
-- through doesn't chip a hole in it -- one lost block would break the
-- component, so the whole thing comes down instead.
-- Returns "allow", "deny", or "break", <instance id>.
local function may_edit(pid, x, y, z)
	local id = guarded[key(x, y, z)];
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

	if (world_editor_readonly) then
		return "deny";
	end
	if (not chunks.can_write(pid, x, y, z)) then
		return "deny";
	end
	return "allow";
end

-- take a whole component down because one of its blocks was broken
-- Hand a component's blocks back to the map instead of taking them down
-- with it.
--
-- A component is made OUT OF somebody's build: placement captures the
-- marked box and render digs those very blocks and re-lays them as ours
-- (see world_editor/stencil.lua). Deleting one must therefore not delete
-- them -- /undo on a misplaced door would otherwise eat the door
-- somebody had just drawn, which is the opposite of an undo.
--
-- So the component is first settled back to rest, putting the drawing
-- exactly where it was captured, and then simply forgotten: the blocks
-- stay in the map as ordinary terrain that anybody may edit again. The
-- settle is a single jump, not an animation -- see each component's
-- settle for why that is still safe to send in one tick.
--
-- This is deliberately NOT what destroy does. /wesavemap needs the blocks
-- genuinely gone so the .vxl it dumps is pure terrain, and a component
-- broken by a player still comes down; both keep using destroy.
local function release_component(inst)
	local k = kinds[inst.kind];
	if (k.settle ~= nil) then
		k.settle(inst, we);
	end
	-- clearing fields of the table being traversed is fine in Lua; it is
	-- adding them that is not
	local id = inst.id;
	for cell, owner in pairs(guarded) do
		if (owner == id) then guarded[cell] = nil; end
	end
end

local function break_component(id, by)
	local inst = insts[id];
	if (inst == nil) then
		return;
	end
	kinds[inst.kind].destroy(inst, we);
	insts[id] = nil;
	reindex_reserved();
	for i = #undo, 1, -1 do
		if (undo[i] == id) then table.remove(undo, i); end
	end
	if (by ~= nil) then
		l10n_send_chat(by, msg.broke, {kind=inst.kind, id=id});
	end
	save();
end

-- put back what the client already changed locally: a refused destroy
-- has to be rebuilt, a refused build has to be taken away
local function revert(pid, pos, type)
	if (type == 0) then
		send_block_action(pid, pos, 1, get_anon_pid());
		return;
	end
	-- this leaves THIS client holding a different colour for the anon pid
	-- than the server does; harmless, because every component build sets
	-- the colour again before it draws (see hold_color)
	send_set_block_color(pid, get_map_block_color(pos), get_anon_pid());
	send_block_action(pid, pos, 0, get_anon_pid());
end

-- Where a player is aiming, for marking. Raycast eye-forward to the first
-- solid block, and fall back to the water plane so a shot that destroys
-- nothing still marks something.
--
-- raycast(s, e, false) returns the solid voxel that was hit. (The apidoc
-- has `last` the wrong way round -- demoncore.c cast2() returns the hit
-- voxel for last=false and the cell before it for last=true.) It needs no
-- bounds clamping: cast2 wraps x/y mod 512 and stops going up at z<0.
--
-- Down is the problem. Water columns are allowed to be non-solid
-- (budgetvxl.c, "pyspades allows it so we do too"), and phys_solid()
-- reports everything at z>=64 as solid -- so a shot into water falls
-- clean through the column and "hits" the virtual floor one layer below
-- the map. Aiming at water used to return that off-map cell, which is
-- why it never reached the water plane below. Two rules fix it:
--
--   * a hit outside the map is not a hit
--   * a hit *under* the water surface loses to the surface itself, so
--     pointing across water marks the water you aimed at, not the seabed
--     beneath it
local function aim_target(pid)
	local s = get_position(pid);
	local o = get_orientation(pid);
	local e = {x=s.x + o.x*world_editor_mark_range,
	           y=s.y + o.y*world_editor_mark_range,
	           z=s.z + o.z*world_editor_mark_range};

	-- where the ray crosses the water plane; z grows downward, so only a
	-- downward look (o.z > 0) can meet it
	local tw = nil;
	if (o.z > 0.001) then
		local t = (world_editor_water_level - s.z) / o.z;
		if (t > 0 and t <= world_editor_mark_range) then
			tw = t;
		end
	end

	local vox = raycast(s, e, false);
	if (vox ~= nil and (vox.z < 0 or vox.z > 63)) then
		vox = nil;                       -- fell off the map, not a real block
	end
	if (vox ~= nil and tw ~= nil and vox.z > world_editor_water_level) then
		vox = nil;                       -- submerged; the surface came first
	end
	if (vox ~= nil) then
		return vox;
	end

	if (tw ~= nil) then
		-- cast2 wraps horizontally, so the plane hit wraps to match
		return {x=math.floor(s.x + o.x*tw) % 512,
		        y=math.floor(s.y + o.y*tw) % 512,
		        z=world_editor_water_level};
	end
	return nil;
end

-- ------------------------------------------------------- selection input
--
-- A component is a box plus a rule, and sel.lua already owns "point at a
-- box" -- since its corners are picked by aiming, at any range and
-- without breaking anything, there is no reason for this script to keep a
-- second way of doing the same job. /place hands the box to sel and waits
-- for it, which makes the editor a layer on top of sel rather than a
-- parallel one.
--
-- Only the marks sel cannot express stay ours: the elevator's altitude
-- and /delete's block are single points, not boxes.
local awaiting = {};   -- pid -> true while a placement is waiting for one

-- Feed a finished selection into the placement as its first two marks,
-- exactly as if they had been marked one at a time, so components keep
-- taking their marks one at a time and none of them had to change.
local function take_selection(pid)
	local s = session[pid];
	if (s == nil or not s.from_sel) then
		awaiting[pid] = nil;
		return;
	end

	local a, b = sel_corners(pid);
	if (a == nil) then
		return;            -- still being picked
	end

	s.from_sel = nil;
	awaiting[pid] = nil;

	l10n_send_chat(pid, msg.mark_at, a);
	apply_mark(pid, a);
	if (session[pid] ~= nil) then
		l10n_send_chat(pid, msg.mark_at, b);
		apply_mark(pid, b);
	end
end

-- Feed one mark into the placement in progress. Marks arrive from a
-- spade/gun swing (aim_target, works on water and misses too), or from
-- /here for spectators who fly rather than spade.
local function apply_mark(pid, pos)
	local s = session[pid];
	if (s == nil) then
		return false;
	end

	-- marking by hand answers the question the selection was asked, so
	-- the two never both get to speak
	if (s.from_sel) then
		s.from_sel = nil;
		awaiting[pid] = nil;
	end

	-- Every mark source funnels through here, so the in-map check lives
	-- here too rather than in each of them.
	if (pos.x < 0 or pos.x > 511 or pos.y < 0 or pos.y > 511
	    or pos.z < 0 or pos.z > 63) then
		l10n_send_chat(pid, msg.mark_outside);
		return true;
	end

	-- delete mode: the mark names a block; whichever component owns it
	-- gets removed. Aim the spade/gun straight at one of its blocks.
	if (s.kind == "__delete") then
		local id = guarded[key(pos.x, pos.y, pos.z)];
		local inst = id and insts[id];
		if (inst == nil) then
			l10n_send_chat(pid, msg.no_component_here);
			return true;   -- keep the session so they can try again
		end
		release_component(inst);
		insts[id] = nil;
		reindex_reserved();
		for i = #undo, 1, -1 do
			if (undo[i] == id) then table.remove(undo, i); end
		end
		session[pid] = nil;
		l10n_send_chat(pid, msg.released, {verb="deleted", kind=inst.kind, id=id});
		save();
		return true;
	end

	local k = kinds[s.kind];
	local done, err = k.click(s, pos, we);
	if (err) then
		l10n_send_chat(pid, err);
		return true;
	end

	if (not done) then
		l10n_send_chat(pid, s.prompt or msg.prompt, {text="mark again."});
		return true;
	end

	if (s.kind == "__chunk") then
		session[pid] = nil;
		local c = s.made;
		l10n_send_chat(pid, msg.chunk_created,
		               {name=c and c.name or "?", perm=chunks.format_perm(s.perm)});
		save();
		return true;
	end

	local inst = k.spawn(s.data, we);
	inst.id = nextid; nextid = nextid + 1;
	inst.kind = s.kind;
	inst.perm = s.perm or {mode="ro"};
	inst.color = s.color;   -- nil keeps the component's own default
	if (k.reserved) then inst.reserved_area = k.reserved(inst, we); end
	insts[inst.id] = inst;
	reindex_reserved();
	k.render(inst, we);
	table.insert(undo, inst.id);
	session[pid] = nil;
	l10n_send_chat(pid, msg.placed, {kind=s.kind, id=inst.id});
	save();
	return true;
end

-- undo whatever the client just did to a block or three, given the
-- action type (build vs a 1- or 3-wide spade/gun destroy)
local function revert_action(pid, pos, type)
	revert(pid, pos, type);
	if (type == 2) then
		revert(pid, {x=pos.x, y=pos.y, z=pos.z-1}, type);
		revert(pid, {x=pos.x, y=pos.y, z=pos.z+1}, type);
	end
end

function mod.on_block_action(pid, pos, type)
	-- while placing, no block action edits anything -- the destroy is
	-- swallowed and the mark comes from the fire input (on_mouse_input),
	-- so it also works on water and on empty misses
	if (session[pid] ~= nil) then
		revert_action(pid, pos, type);
		return;
	end

	-- a gun never destroys blocks in edit mode: fly around armed without
	-- chewing the map
	if (editing and get_tool(pid) == 2) then
		revert_action(pid, pos, type);
		return;
	end

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

	mod.next.on_block_action(pid, pos, type);
end

-- Marking is driven by the fire button so it works with a spade or a
-- gun, whether or not the swing destroys anything. on_mouse_input gives
-- the whole button bitmask on change; bit 1 is primary fire, so mark on
-- the press edge (0 -> 1) while a placement is in progress.
local prevmouse = pid_connected_table(0);
function mod.on_mouse_input(pid, bits)
	local pressed = bit.band(bits, 1) ~= 0 and bit.band(prevmouse[pid], 1) == 0;
	prevmouse[pid] = bits;

	-- A selection being made owns the click. sel picks its corners from
	-- the same button we do, and it is loaded after us so its hook runs
	-- first -- without this, one click would both pick a corner and drop
	-- a placement mark. Placing a component is the thing you can restart
	-- for free, so it is the one that gives way. (sel_pending comes from
	-- sel.lua; it is absent when sel is not loaded, hence the guard.)
	local picking = sel_pending ~= nil and sel_pending(pid);

	if (pressed and editing and not picking and session[pid] ~= nil) then
		local tool = get_tool(pid);
		if (tool == 0 or tool == 2) then   -- spade or gun
			local t = aim_target(pid);
			if (t == nil) then
				l10n_send_chat(pid, msg.nothing_to_mark);
			else
				l10n_send_chat(pid, msg.mark_at, t);
				apply_mark(pid, t);
			end
		end
	end

	mod.next.on_mouse_input(pid, bits);
end

function mod.on_block_line(pid, start, stop)
	local broke = nil;
	for p in iter_block_line(start, stop) do
		local act, id = may_edit(pid, p.x, p.y, p.z);
		if (act == "deny") then
			-- refuse the whole line: a half-drawn line is worse than none
			for q in iter_block_line(start, stop) do
				send_block_action(pid, q, 1, get_anon_pid());
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
	mod.next.on_block_line(pid, start, stop);
end

-- A cell another script must not write: one a component occupies, or a
-- volume a component has reserved. Blocks written by a script bypass
-- may_edit entirely (that only sees player edits), and `guarded` is our
-- record of what exists -- a foreign write makes that record a lie, and
-- the component silently breaks. sel.lua's /selrm and /selfill are
-- exactly this: bulk writes through the anon pid.
local function foreign_blocked(pos)
	return guarded[key(pos.x, pos.y, pos.z)] ~= nil
	    or in_reserved(pos.x, pos.y, pos.z);
end

-- Grenades and other world damage go straight to block_action without
-- passing a player, so they cannot be team-resolved: anything short of
-- a fully open component (perm "rw") shrugs them off. Our own writes
-- come through as the anon pid and must pass -- `drawing` is how we
-- recognise them; any other anon-pid write is another script's.
function mod.block_action(pos, type, from)
	if (from == get_anon_pid()) then
		if (not drawing and foreign_blocked(pos)) then
			return;
		end
	elseif (type ~= 0) then
		local id = guarded[key(pos.x, pos.y, pos.z)];
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

-- lib_bulk_destroy (and so sel.lua's /selrm, /selmv, /selswiz) destroys
-- through block_action_rm, which never reaches block_action above -- so
-- it needs the same guard.
--
-- Hooking it is safe despite the loop it looks like: lblock_action_rm
-- calls f.block_action_rm, and `f` is a static snapshot taken in
-- lua.c:1619 *before* register_luaawk() installs the cX bridges, so the
-- chain terminates in the original C implementation rather than calling
-- the global straight back.
--
-- Returning 0 is the honest "nothing was destroyed" mask -- main.c's
-- block_action_rm returns exactly that for an already-empty cell -- and
-- bdestroy_block_action skips zero masks, so nothing is left queued for
-- a cull that never happened.
function mod.block_action_rm(pos, type, from)
	if (not drawing and from == get_anon_pid() and foreign_blocked(pos)) then
		return 0;
	end
	return mod.next.block_action_rm(pos, type, from);
end

-- ------------------------------------------------------------ listing
--
-- Edit mode takes the server off the public lists rather than shutting
-- the door: a half-built map is not what anyone browsing wants to drop
-- into, but the people already here (and anyone who knows the address)
-- can carry on. Delisting is not access control -- ip:port still works,
-- which is exactly what makes it usable for inviting someone in to help
-- build.
--
-- The stock masterlist script is the switch. Its on_unload disconnects
-- every masterlist peer (lsd/scripts/masterlist.lua), so unloading it
-- really does delist rather than leaving a stale entry behind, and the
-- console's load unloads first, so putting it back is idempotent.
--
-- Only ever put back what we took away: a server deliberately run
-- unlisted (LSD_MASTERLIST=0, so the config never loaded masterlist at
-- all) must not find itself published because someone edited a map.
--
-- That "did we take it away" flag is a GLOBAL, not a local, and
-- deliberately so. A hot `load world_editor` re-runs this file from
-- scratch: `editing` comes back false and every local is new, so a
-- reload in the middle of a build session would strand the server
-- delisted with nothing left that knew to put it back. Globals outlive
-- the reload, so the bottom of this file can spot that and relist.
if (world_editor_delisted == nil) then
	world_editor_delisted = false;
end

local function listing_hide()
	if (world_editor_delisted or package.loaded["masterlist"] == nil) then
		return false;
	end
	local ok, err = pcall(unload, "masterlist");
	if (not ok) then
		l10n_log(msg.delist_failed, {err=tostring(err)});
		return false;
	end
	world_editor_delisted = true;
	return true;
end

local function listing_show()
	if (not world_editor_delisted) then
		return false;
	end
	world_editor_delisted = false;
	local ok, err = pcall(load, "masterlist");
	if (not ok) then
		l10n_log(msg.relist_failed, {err=tostring(err)});
		return false;
	end
	return true;
end

-- ---------------------------------------------------------------- events

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
	-- A fresh map always comes up in play mode, so anything edit mode
	-- switched off has to come back on -- otherwise a map change during a
	-- build session would leave the server quietly unlisted for good.
	if (editing) then
		editing = false;
		listing_show();
	end
	load_layout();
end

-- When world_editor is hot-loaded onto an already-running map, load_map
-- has long since fired, so recover the current map from the masterlist
-- name (usually the filename; a map shipping .txt metadata may report a
-- display name, which the next real load_map corrects).
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
	for pid in pairs(awaiting) do
		take_selection(pid);
	end
	for _, inst in pairs(insts) do
		kinds[inst.kind].tick(inst, we, TICK_DT);
	end
end

-- A rider is teleported, not falling, but neither the engine's velocity
-- nor fall_damage.lua's apex tracking can tell the difference, so a ride
-- can land phantom fall damage. Swallow fall damage (KillTypeFall = 4)
-- for anyone standing inside an elevator's shaft.
-- Kill type 4 is the environment: BOTH stock hazards report it, so this
-- one branch covers both.
--
--   * fall_damage.lua  -- damage_player(i, damage, 4, i) on landing
--   * water_damage.lua -- damage_player(i, damage, 4, i) per second of
--                         wading, on maps whose meta sets water_damage
--
-- If either ever stops using type 4, its suppression here goes silently
-- dead -- check both before trusting this.
function mod.damage_player(pid, hp, type, from)
	if (type == 4 and is_alive(pid)) then
		-- Building means dropping off things constantly, /noclip can be
		-- toggled off mid-air, and a builder wading a lava-water map
		-- would just bleed. Edit mode swallows the environment outright,
		-- with no message: nobody building should think about landing or
		-- about what they are standing in.
		if (editing) then
			return;
		end
		local p = get_position(pid);
		if (in_reserved(p.x, p.y, p.z)) then
			return;
		end
	end
	mod.next.damage_player(pid, hp, type, from);
end

-- Building means getting to awkward corners, so edit mode hands out
-- stock noclip.lua's flight rather than growing its own: /noclip is
-- already a maintained, capability-gated free-flight implementation
-- loaded by group_commands, and one that passes through walls suits
-- building better than one that collides with them. Edit mode simply
-- grants the cap, exactly as it does for sel -- see edit_start below.

function mod.after.on_disconnect(pid)
	session[pid] = nil;
	awaiting[pid] = nil;
end

-- -------------------------------------------------------------- commands

local function need_edit(pid)
	if (not editing) then
		l10n_send_chat(pid, msg.not_editing);
		return false;
	end
	return true;
end

-- --------------------------------------------------------- edit session
--
-- Turning edit mode on is what hands out the tools. Everything a builder
-- needs beyond this script already exists as a stock script, so edit mode
-- loads those and grants their caps rather than growing its own copies:
--
--   sel.lua     -- selections and bulk fill / replace / paint / remove /
--                  copy / move / swizzle: all terrain editing.
--   noclip.lua  -- free flight, for reaching awkward corners.
--
-- Its own commands are gated the same way, on CAP_BUILD, which is
-- likewise granted only while edit mode is on. Before that existed, every
-- command here was open to anybody holding "default_commands" -- which is
-- everybody, by default (see caps.lua) -- and edit mode no longer refuses
-- joins, so a passer-by could /delete somebody's work.
--
-- One thing needs care with sel in particular: its bulk ops write through
-- the anon pid and consult nothing -- not chunks, not
-- world_editor_readonly, not `guarded`. /selrm across an elevator would
-- delete its blocks while we still believed they existed. The
-- block_action / block_action_rm guards above are what make that safe, by
-- refusing any anon-pid write we did not issue.
--
-- A borrowed script is only unloaded again if we were the one who loaded
-- it, so a server that loads sel or noclip itself keeps them.
local borrowed_ours = {};

local function grant_all(pid)
	if (not has_cap(pid, CAP_BUILD)) then grant_cap(pid, CAP_BUILD); end
	for _, cap in ipairs(BORROWED) do
		if (not has_cap(pid, cap)) then grant_cap(pid, cap); end
	end
end

local function edit_start()
	local loaded = {};
	for _, name in ipairs(BORROWED) do
		if (package.loaded[name] == nil) then
			local ok, err = pcall(load, name);
			if (ok) then
				borrowed_ours[name] = true;
			else
				l10n_log(msg.borrow_failed, {name=name, err=tostring(err)});
			end
		end
		if (package.loaded[name] ~= nil) then
			table.insert(loaded, name);
		end
	end

	for i in piditer(PID_BROADCAST) do
		if (is_joined(i)) then grant_all(i); end
	end
	return loaded;
end

local function edit_stop()
	for i in piditer(PID_BROADCAST) do
		if (is_joined(i)) then
			if (has_cap(i, CAP_BUILD)) then drop_cap(i, CAP_BUILD); end
			for _, cap in ipairs(BORROWED) do
				if (has_cap(i, cap)) then drop_cap(i, cap); end
			end
		end
	end
	for name in pairs(borrowed_ours) do
		pcall(unload, name);
	end
	borrowed_ours = {};
end

-- Someone joining mid-session is here to build like everybody else --
-- edit mode stopped refusing joins precisely so builders could be invited
-- in, and they would otherwise arrive without a single usable command.
function mod.after.on_join(pid, team, gun, name)
	if (editing) then
		grant_all(pid);
	end
end

-- Enabling is console-only: fakepid=true lets the console in, and the
-- is_fakepid check keeps in-game players out.
local cmd = {name="worldedit", caps="worldedit", fakepid=true,
             usage="on|off|status", desc="Toggle world edit mode (console only)."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv <= 1);

	if (not is_fakepid(pid)) then
		l10n_send_chat(pid, msg.console_only);
		return;
	end

	local what = string.lower(argv[1] or "status");
	if (what == "status") then
		l10n_send_chat(pid, msg.edit_status, {
			state = editing and "ON" or "off",
			map   = tostring(mapname),
			extra = world_editor_delisted
			        and l10n_get_str_pid(pid, msg.delisted_by_edit, {}) or "",
		});
		return;
	end

	editing = (what == "on");

	-- entering edit mode on a map with no layout yet writes an empty
	-- <map>.editor.json straight away, so there is a file to save into
	-- (and to prove the mount is writable) before anything is placed
	if (editing) then
		local path = jsonpath();
		if (path ~= nil and not file_exists(path)) then
			save(true);
			l10n_send_chat(pid, msg.created_layout, {path=path});
		end
		local tools = edit_start();
		if (#tools > 0) then
			l10n_send_chat(pid, msg.tools_granted, {names=table.concat(tools, " + ")});
		end
		if (listing_hide()) then
			l10n_send_chat(pid, msg.delisted);
		end
	else
		edit_stop();
		if (listing_show()) then
			l10n_send_chat(pid, msg.relisted);
		end
	end

	l10n_send_chat(PID_BROADCAST, editing and msg.edit_enabled or msg.edit_disabled);
	l10n_log(msg.edit_log, {state=editing and "on" or "off"});
end
register_command(cmd, mod);

-- every registered component, minus the internal chunk pseudo-kind
local function component_names()
	local names = {};
	for n in pairs(kinds) do
		if (n ~= "__chunk") then table.insert(names, n); end
	end
	table.sort(names);
	return names;
end

-- print a component's help: its own lines if it provides them, else a
-- usage line built from its fields
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

local cmd = {name={"place", "weplace"}, caps=CAP_BUILD, usage="[component] [args...]",
             desc="Place a component; /place alone lists them, /place <c> shows help."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end

	-- bare /place lists everything placeable and how to get each one's help
	if (#argv == 0) then
		l10n_send_chat(pid, msg.placeable, {names=table.concat(component_names(), ", ")});
		l10n_send_chat(pid, msg.place_hint);
		return;
	end

	local k = kinds[string.lower(argv[1])];
	if (k == nil or k.name == "__chunk") then
		l10n_send_chat(pid, msg.no_such_component,
		               {names=table.concat(component_names(), ", ")});
		return;
	end

	-- gather the component's own args (everything after its name)
	local args = {};
	for i = 2, #argv do args[#args+1] = argv[i]; end

	-- /place <component> with no further args just prints its help
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
	-- colour comes from the placer's own block palette, not an argument
	s.color = get_block_color(pid);
	session[pid] = s;

	-- The box comes from sel when it is there to ask. A selection already
	-- finished is taken as-is -- that is what "place a door on this" means
	-- when you have just selected something -- otherwise a fresh one is
	-- armed and picked up the moment its second corner lands.
	if (sel_begin ~= nil and sel_corners ~= nil) then
		s.from_sel = true;
		awaiting[pid] = true;
		if (sel_corners(pid) == nil or sel_pending(pid)) then
			sel_begin(pid);
			l10n_send_chat(pid, msg.select_box, {kind=k.name});
		end
		return;
	end

	l10n_send_chat(pid, s.prompt or msg.prompt, {text="mark a block to place."});
end
register_command(cmd, mod);

-- Spectators can't spade, and spectating is the natural way to build:
-- you can fly to the exact spot instead of standing on it. /here drops
-- the mark at your own position, so the whole editor works from spec.
local cmd = {name={"here", "mark"}, caps=CAP_BUILD, usage="[x y z]",
             desc="Drop a placement mark where you are (or at x y z)."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end
	cmd_assert(pid, cmd, #argv == 0 or #argv == 3);

	if (session[pid] == nil) then
		l10n_send_chat(pid, msg.nothing_placing);
		return;
	end

	-- commands.lua's helpers validate, report the offending bound and
	-- abort for us, so every command in the server rejects a bad number
	-- the same way
	local pos;
	if (#argv == 3) then
		pos = {x=math.floor(get_arg_num_range("x", pid, cmd, argv[1], 0, 511)),
		       y=math.floor(get_arg_num_range("y", pid, cmd, argv[2], 0, 511)),
		       z=math.floor(get_arg_num_range("z", pid, cmd, argv[3], 0, 63))};
	else
		local p = get_position(pid);
		pos = {x=math.floor(p.x), y=math.floor(p.y), z=math.floor(p.z)};
	end

	l10n_send_chat(pid, msg.mark_at, pos);
	apply_mark(pid, pos);
end
register_command(cmd, mod);

-- Marks by coordinate, in bulk -- the machine-facing way in.
--
-- /here covers a person standing where they want the mark, and the
-- spade covers a person pointing at it. Neither suits a client with a
-- GUI on top: it already knows every corner it wants and should not have
-- to fly a player to each one in turn. This takes a whole component's
-- worth of marks in one message, so a placement can be driven start to
-- finish without any tool ever being swung:
--
--   /place door left
--   /marks 121 264 59 121 266 60
--
-- Coordinates may be fractional. A client working in world space has
-- float positions, and rejecting 34.5 would just make it round for us --
-- so each is floored to the block that contains it, exactly as /here
-- treats its arguments and as the engine maps a position to a voxel.
local cmd = {name="marks", caps=CAP_BUILD, usage="<x y z> [x y z ...]",
             desc="Place one or more placement marks by coordinate."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end
	cmd_assert(pid, cmd, #argv >= 3 and #argv % 3 == 0);

	if (session[pid] == nil) then
		l10n_send_chat(pid, msg.nothing_placing2);
		return;
	end

	-- Parse the whole list before placing any of it. A batch that got
	-- half way and then hit a typo would leave the placement in a state
	-- the caller has no way to reason about, which is exactly what an
	-- automated caller cannot recover from. commands.lua's helpers abort
	-- the command outright on a bad number, which is precisely that.
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
		if (session[pid] == nil) then
			l10n_send_chat(pid, msg.batch_finished, {n=n - 1, extra=#pts - n + 1});
			return;
		end
		l10n_send_chat(pid, msg.mark_at, p);
		apply_mark(pid, p);
	end
end
register_command(cmd, mod);

local cmd = {name="componentperm", caps=CAP_BUILD, usage="ro|rw|rw:<team>",
             desc="Set protection on the nearest component."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end
	cmd_assert(pid, cmd, #argv == 1);

	local perm = chunks.parse_perm(argv[1]);
	if (perm == nil) then
		l10n_send_chat(pid, msg.bad_perm);
		return;
	end

	local p = get_position(pid);
	local best, bestd = nil, nil;
	for _, inst in pairs(insts) do
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
	save();
end
register_command(cmd, mod);

local cmd = {name={"undo", "weundo"}, caps=CAP_BUILD,
             desc="Un-place the most recent component (its blocks stay)."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end

	local id = table.remove(undo);
	if (id == nil or insts[id] == nil) then
		l10n_send_chat(pid, msg.nothing_to_undo);
		return;
	end
	local inst = insts[id];
	release_component(inst);
	insts[id] = nil;
	reindex_reserved();
	l10n_send_chat(pid, msg.released, {verb="removed", kind=inst.kind, id=id});
	save();
end
register_command(cmd, mod);

-- Delete by pointing: start a mark, then spade/shoot a block belonging
-- to the component you want gone.
local cmd = {name={"delete", "wedelete"}, caps=CAP_BUILD,
             desc="Un-place the component whose block you mark (its blocks stay)."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end
	session[pid] = {kind="__delete", prompt=msg.delete_prompt};
	l10n_send_chat(pid, session[pid].prompt);
end
register_command(cmd, mod);

-- Persist the map itself. The components are drawn into the live map, so
-- lift them out first, dump pure terrain to <name>.vxl, put them back,
-- then write <name>.editor.json alongside -- reloading the map restores
-- terrain from the vxl and components from the json.
-- NOT called "savemap": command_savemap.lua already owns that name, and
-- register_command overwrites silently, so whichever loaded last would
-- quietly win. This one lifts the components out first so the .vxl is
-- pure terrain, which the stock one cannot do.
local cmd = {name={"wesavemap", "wesave"}, caps=CAP_BUILD, fakepid=true, usage="[name]",
             desc="Save the map (.vxl) and its components (.editor.json) to maps/."};
function cmd.func(pid, argv)
	if (not is_fakepid(pid) and not need_edit(pid)) then return; end
	cmd_assert(pid, cmd, #argv <= 1);

	local name = argv[1] or mapname;
	if (name == nil) then
		l10n_send_chat(pid, msg.no_map_name);
		return;
	end
	if (string.find(name, "[/\\]") or string.find(name, "^%.")) then
		l10n_send_chat(pid, msg.bad_map_name);
		return;
	end

	local vxlpath = world_editor_dir.."/"..name..".vxl";
	local jsonpath2 = world_editor_dir.."/"..name..".editor.json";

	-- take component blocks out so the vxl is pure terrain (+ the shafts
	-- dug for elevators, which are genuine terrain changes)
	for _, inst in pairs(insts) do
		kinds[inst.kind].destroy(inst, we);
	end

	local ok = true;
	local f, err = io.open(vxlpath..".new", "wb");
	if (f == nil) then
		l10n_log(msg.vxl_failed, {path=vxlpath, err=tostring(err)});
		ok = false;
	else
		f:setvbuf("no");
		for dat in dump_vxl() do
			f:write(dat);
		end
		f:close();
		os.rename(vxlpath..".new", vxlpath);
	end

	-- put the components back on the live map
	for _, inst in pairs(insts) do
		kinds[inst.kind].render(inst, we);
	end

	local jok = write_json(jsonpath2);

	if (ok and jok) then
		l10n_send_chat(pid, msg.saved, {name=name, dir=world_editor_dir});
	else
		l10n_send_chat(pid, msg.save_failed);
	end
end
register_command(cmd, mod);

local cmd = {name="chunk", caps=CAP_BUILD, usage="box|cylinder|sphere|circle|rect <perm> [name]",
             desc="Create an authorization chunk (spade two marks to set its extent)."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end
	cmd_assert(pid, cmd, #argv >= 2);

	local shape = string.lower(argv[1]);
	local perm = chunks.parse_perm(argv[2]);
	if (perm == nil) then
		l10n_send_chat(pid, msg.bad_perm);
		return;
	end

	session[pid] = {kind="__chunk", shape=shape, perm=perm, name=argv[3], pts={},
	                prompt=(shape == "box") and msg.chunk_prompt_box
	                                        or msg.chunk_prompt_radial};
	l10n_send_chat(pid, session[pid].prompt);
end
register_command(cmd, mod);

local cmd = {name="chunkperm", caps=CAP_BUILD, usage="ro|rw|rw:<team>",
             desc="Set the authorization of the chunk you are standing in."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end
	cmd_assert(pid, cmd, #argv == 1);

	local perm = chunks.parse_perm(argv[1]);
	if (perm == nil) then
		l10n_send_chat(pid, msg.bad_perm);
		return;
	end

	local p = get_position(pid);
	local c = chunks.at(math.floor(p.x), math.floor(p.y), math.floor(p.z));
	if (c == nil) then
		l10n_send_chat(pid, msg.not_in_chunk);
		return;
	end
	c.perm = perm;
	l10n_send_chat(pid, msg.chunk_perm, {name=c.name, perm=chunks.format_perm(perm)});
	save();
end
register_command(cmd, mod);

local cmd = {name="chunkrm", caps=CAP_BUILD, desc="Delete the chunk you are standing in."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end

	local p = get_position(pid);
	local c = chunks.at(math.floor(p.x), math.floor(p.y), math.floor(p.z));
	if (c == nil) then
		l10n_send_chat(pid, msg.not_in_chunk);
		return;
	end
	chunks.remove(c.id);
	l10n_send_chat(pid, msg.chunk_removed, {name=c.name});
	save();
end
register_command(cmd, mod);

-- Why a component is or is not doing what you expect. Each kind reports
-- its own live state through an optional status(inst, we), so a door
-- that will not open can be told apart from a door that thinks nobody
-- is near it without guessing from the outside.
local cmd = {name={"components", "comps"}, caps=CAP_BUILD, fakepid=true,
             desc="List placed components and their live state."};
function cmd.func(pid, argv)
	-- how many blocks each instance actually owns. A component whose
	-- state machine runs but whose block count is 0 owns nothing to move:
	-- we.fill refuses to paint over an already-solid cell, so a component
	-- placed onto existing terrain never claims it and then appears dead.
	local owned = {};
	for _, id in pairs(guarded) do
		owned[id] = (owned[id] or 0) + 1;
	end

	local n = 0;
	for _, inst in pairs(insts) do
		n = n + 1;
		local k = kinds[inst.kind];
		l10n_send_chat(pid, msg.component_line, {
			id=inst.id, kind=inst.kind,
			x=tostring(inst.x), y=tostring(inst.y),
			perm=chunks.format_perm(inst.perm or {mode="ro"}),
			blocks=owned[inst.id] or 0,
			status=k.status and k.status(inst, we) or "",
		});
	end
	if (n == 0) then
		l10n_send_chat(pid, msg.no_components);
	end
end
register_command(cmd, mod);

local cmd = {name="chunks", caps=CAP_BUILD, fakepid=true,
             desc="List authorization chunks."};
function cmd.func(pid, argv)
	l10n_send_chat(pid, msg.chunks_head,
	               {perm=chunks.format_perm(chunks.get_default()),
	                readonly=world_editor_readonly
	                         and l10n_get_str_pid(pid, msg.chunks_readonly, {}) or ""});
	for _, c in pairs(chunks.all()) do
		l10n_send_chat(pid, msg.chunk_line,
		               {id=c.id, name=c.name, shape=c.shape, perm=chunks.format_perm(c.perm)});
	end
end
register_command(cmd, mod);

local cmd = {name="defaultperm", caps=CAP_ADMIN, fakepid=true, usage="ro|rw|rw:<team>",
             desc="Authorization for blocks outside every chunk (console only)."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 1);
	if (not is_fakepid(pid)) then
		l10n_send_chat(pid, msg.console_only);
		return;
	end
	local perm = chunks.parse_perm(argv[1]);
	if (perm == nil) then
		l10n_send_chat(pid, msg.bad_perm);
		return;
	end
	chunks.set_default(perm);
	l10n_send_chat(pid, msg.default_perm, {perm=chunks.format_perm(perm)});
	save();
end
register_command(cmd, mod);

local cmd = {name="mapreadonly", caps=CAP_ADMIN, fakepid=true, usage="on|off",
             desc="Master lock: refuse every player block edit (console only)."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 1);
	if (not is_fakepid(pid)) then
		l10n_send_chat(pid, msg.console_only);
		return;
	end
	world_editor_readonly = (string.lower(argv[1]) == "on");
	l10n_send_chat(pid, msg.readonly_set, {state=world_editor_readonly and "ON" or "off"});
	save();
end
register_command(cmd, mod);

-- chunk placement shares the spade flow with components
local chunkkind = {
	name = "__chunk",
	click = function(s, pos)
		table.insert(s.pts, {x=pos.x, y=pos.y, z=pos.z});
		if (#s.pts < 2) then
			return false;
		end

		local a, b = s.pts[1], s.pts[2];
		local area;
		if (s.shape == "box") then
			area = areas.box(a.x, a.y, a.z, b.x, b.y, b.z);
		elseif (s.shape == "rect2d" or s.shape == "rect") then
			area = areas.rect2d(a.x, a.y, b.x, b.y);
		else
			-- radial shapes: first mark is the centre, second the rim
			local r = math.ceil(math.sqrt((b.x-a.x)^2 + (b.y-a.y)^2));
			if (s.shape == "sphere") then
				area = areas.sphere(a.x, a.y, a.z, r);
			elseif (s.shape == "circle" or s.shape == "circle2d") then
				area = areas.circle2d(a.x, a.y, r);
			else
				area = areas.cylinder(a.x, a.y, r, a.z, b.z);
			end
		end

		s.made = chunks.add({area=area, perm=s.perm, name=s.name});
		return true;
	end,
};

-- Components self-register by being required. Done at load time rather
-- than from an event so a broken component surfaces immediately, and
-- adding a file to world_editor/ plus a name here is the only step.
for _, name in ipairs({"elevator", "door"}) do
	local ok, k = pcall(require, "world_editor."..name);
	if (ok and type(k) == "table") then
		kinds[k.name] = k;
	else
		l10n_log(msg.component_failed, {name=name, err=tostring(k)});
	end
end
kinds["__chunk"] = chunkkind;

-- ------------------------------------------------------------ lifecycle
--
-- The module system calls these, so everything that has to happen when
-- this script comes and goes lives here rather than at file scope --
-- which is both where the rest of the server puts it and the only place
-- that runs on an unload.

function mod.on_load()
	-- Hot-load restore: when the script is (re)loaded onto an
	-- already-running map, load_map fired long before us, so nothing
	-- would restore the saved layout. mapname is recovered above and the
	-- components are registered, so load <map>.editor.json now. (On a
	-- normal boot mapname is still nil here -- the map loads after us --
	-- so this is skipped and load_map does it.)
	if (mapname ~= nil) then
		load_layout();
	end

	-- Recover the public listing. `editing` is false in this fresh
	-- incarnation whatever the last one was doing, so if that one had
	-- taken the server off the server lists, edit mode is over and the
	-- listing is owed back. Without this a reload mid-build left the
	-- server unlisted with nothing remembering why.
	if (world_editor_delisted and listing_show()) then
		l10n_log(msg.relisted_log);
	end
end

-- Leave nothing of ours behind.
--
-- Components are drawn into the live map and tracked in `guarded`, which
-- does not survive the unload -- so blocks nobody is guarding any more
-- would sit there pretending to be a door. Hand them back to the map the
-- way /undo does: settled at rest, and plain terrain again.
--
-- Edit mode ends with us, which means dropping the caps we handed out
-- and putting back the borrowed scripts and the public listing.
function mod.on_unload()
	if (editing) then
		editing = false;
		edit_stop();
		listing_show();
	end

	for _, inst in pairs(insts) do
		release_component(inst);
	end
	insts = {};
	guarded = {};
	undo = {};
	reindex_reserved();
end

return mod;
