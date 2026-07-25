-- world_editor.lua -- Placeable map components (elevators, doors) plus
-- a spatial authorization system.
--
-- Editing is a server-wide mode that can only be switched on from the
-- admin console (/worldedit on). While it is on, nobody new may join,
-- so the only people present are whoever was already there to build.
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

getcfg("we_dir", "maps");          -- where <map>.json is read/written
getcfg("we_default_perm", "rw");   -- authorization outside every chunk
getcfg("we_readonly", false);      -- master lock: no player edits at all
getcfg("we_autosave", true);       -- rewrite <map>.json on every change
getcfg("we_fly", true);            -- free flight while edit mode is on
getcfg("we_fly_speed", 16);        -- blocks per second, doubled by sprint
getcfg("we_mark_range", 160);      -- how far a spade/gun mark reaches
getcfg("we_water_level", 63);      -- z a mark lands on when aimed past all blocks

local editing = false;
local mapname = nil;

local kinds = {};      -- name -> component module
local insts = {};      -- id -> instance
local nextid = 1;
local undo = {};       -- stack of instance ids, newest last

local guarded = {};    -- packed block -> instance id (indestructible)
local session = pid_connected_table(nil);  -- in-progress placement per pid

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

-- The anon pid's held colour is server state that every build reads, and
-- set_block_color() broadcasts a packet on every call -- so setting it
-- per layer sent one redundant packet per layer even though components
-- draw hundreds of layers in the same colour. Remember what it holds and
-- only send on a real change.
--
-- The cache is only sound while nothing ELSE moves that colour, and
-- things do. rifle_is_a_rail_gun broadcasts a random red from the anon
-- pid on every shot, and revert() pushes the map's colour at one client
-- -- both via send_set_block_color, which changes what *clients* believe
-- the anon pid holds without touching the server-side value we track.
-- Skipping our colour packet after that drew the block in their stale
-- colour (grey platform, red ring). So the hooks further down drop this
-- cache whenever anyone sets that colour, and hold_color records the new
-- value only after its own call has passed through them.
local heldcolor = nil;

local function forget_color()
	heldcolor = nil;
end

local function hold_color(c)
	if (c == nil) then
		return;
	end
	if (heldcolor ~= nil
	    and heldcolor.r == c.r and heldcolor.g == c.g and heldcolor.b == c.b) then
		return;
	end
	-- set_block_color, not send_set_block_color: block_action/block_line
	-- colour the map from the anon pid's *server-side* held colour, so
	-- only setting it server-side bakes the colour into the stored map
	-- (a bare broadcast left it black for fresh joiners).
	set_block_color(get_anon_pid(), c);
	heldcolor = {r=c.r, g=c.g, b=c.b};
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
end

function we.is_guarded(x, y, z)
	return guarded[key(x, y, z)] ~= nil;
end

-- ------------------------------------------------------------ footprints
--
-- A footprint is a 2d shape in xy that a component extrudes through z:
-- {shape="rect", x1,y1,x2,y2} or {shape="circle", cx,cy,r}. Platforms,
-- pads and columns are all "this shape, at these layers", so the
-- vocabulary lives here rather than in any one component.

function we.foot_bbox(f)
	if (f.shape == "circle") then
		return f.cx-f.r, f.cy-f.r, f.cx+f.r, f.cy+f.r;
	end
	return f.x1, f.y1, f.x2, f.y2;
end

function we.foot_has(f, x, y)
	if (f.shape == "circle") then
		local dx, dy = x-f.cx, y-f.cy;
		return dx*dx + dy*dy <= f.r*f.r;
	end
	return x >= f.x1 and x <= f.x2 and y >= f.y1 and y <= f.y2;
end

-- the footprint as an areas volume spanning z1..z2 (triggers, reserving)
function we.foot_area(f, z1, z2)
	if (f.shape == "circle") then
		return areas.cylinder(f.cx, f.cy, f.r, z1, z2);
	end
	return areas.box(f.x1, f.y1, z1, f.x2, f.y2, z2);
end

-- The footprint shrunk by n blocks on every side, or nil when nothing is
-- left (an elevator's piston column is its platform inset).
function we.foot_inset(f, n)
	n = n or 1;
	if (f.shape == "circle") then
		if (f.r - n < 1) then return nil; end
		return {shape="circle", cx=f.cx, cy=f.cy, r=f.r-n};
	end
	local x1, y1, x2, y2 = f.x1+n, f.y1+n, f.x2-n, f.y2-n;
	if (x1 > x2 or y1 > y2) then return nil; end
	return {shape="rect", x1=x1, y1=y1, x2=x2, y2=y2};
end

-- Half the footprint's smallest span -- how much room an inset has to
-- eat into before the shape disappears.
function we.foot_half(f)
	if (f.shape == "circle") then
		return f.r;
	end
	return math.min(f.x2 - f.x1, f.y2 - f.y1) / 2;
end

-- Draw (or clear) one z layer of a footprint. `except` is an optional
-- second footprint to leave alone, which turns the call into a ring --
-- the single most valuable primitive here, because a shape sliding
-- inside a slightly smaller one only ever changes the ring between them.
-- Touching just that ring is the difference between rewriting a whole
-- platform every step and writing its outline.
function we.layer(inst, f, z, color, on, except)
	local x1, y1, x2, y2 = we.foot_bbox(f);
	we.fill(inst, x1, y1, z, x2, y2, z, color, on, function(x, y)
		return we.foot_has(f, x, y)
		   and (except == nil or not we.foot_has(except, x, y));
	end);
end

-- dig existing map blocks (not component blocks, so untracked in
-- guarded) out of a box, so an elevator's path is clear. Bulk: one
-- floating-block cull for the whole shaft instead of one per block.
function we.dig_box(x1, y1, z1, x2, y2, z2, keep)
	x1 = math.max(0, x1); y1 = math.max(0, y1); z1 = math.max(0, z1);
	x2 = math.min(511, x2); y2 = math.min(511, y2); z2 = math.min(WE_DEEPEST, z2);
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
	return we_dir.."/"..mapname..".editor.json";
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
		readonly = we_readonly and true or false,
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
		log("world_editor: cannot write %s (%s) -- drop the :ro on the maps mount to persist", path, tostring(err));
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
	if (path == nil or (not we_autosave and not force)) then
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
	forget_color();   -- a fresh map resets the anon pid's held colour
end

local function load_layout()
	clear_all();
	chunks.reset();
	chunks.set_default(chunks.parse_perm(we_default_perm) or {mode="rw"});

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
		log("world_editor: %s is not valid json, ignoring", path);
		return;
	end

	if (doc.default_perm) then
		chunks.set_default(chunks.parse_perm(doc.default_perm) or {mode="rw"});
	end
	if (doc.readonly ~= nil) then
		we_readonly = doc.readonly;
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

	log("world_editor: loaded %s", path);
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

	if (we_readonly) then
		return "deny";
	end
	if (not chunks.can_write(pid, x, y, z)) then
		return "deny";
	end
	return "allow";
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
	for i = #undo, 1, -1 do
		if (undo[i] == id) then table.remove(undo, i); end
	end
	if (by ~= nil) then
		server_msg(by, string.format("world_editor: broke %s #%d.", inst.kind, id));
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
	-- than the server does; the send_set_block_color hook drops the colour
	-- cache for us, so the next component build resyncs them
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
	local e = {x=s.x + o.x*we_mark_range,
	           y=s.y + o.y*we_mark_range,
	           z=s.z + o.z*we_mark_range};

	-- where the ray crosses the water plane; z grows downward, so only a
	-- downward look (o.z > 0) can meet it
	local tw = nil;
	if (o.z > 0.001) then
		local t = (we_water_level - s.z) / o.z;
		if (t > 0 and t <= we_mark_range) then
			tw = t;
		end
	end

	local vox = raycast(s, e, false);
	if (vox ~= nil and (vox.z < 0 or vox.z > 63)) then
		vox = nil;                       -- fell off the map, not a real block
	end
	if (vox ~= nil and tw ~= nil and vox.z > we_water_level) then
		vox = nil;                       -- submerged; the surface came first
	end
	if (vox ~= nil) then
		return vox;
	end

	if (tw ~= nil) then
		-- cast2 wraps horizontally, so the plane hit wraps to match
		return {x=math.floor(s.x + o.x*tw) % 512,
		        y=math.floor(s.y + o.y*tw) % 512,
		        z=we_water_level};
	end
	return nil;
end

-- Feed one mark into the placement in progress. Marks arrive from a
-- spade/gun swing (aim_target, works on water and misses too), or from
-- /here for spectators who fly rather than spade.
local function apply_mark(pid, pos)
	local s = session[pid];
	if (s == nil) then
		return false;
	end

	-- Every mark source funnels through here, so the in-map check lives
	-- here too rather than in each of them.
	if (pos.x < 0 or pos.x > 511 or pos.y < 0 or pos.y > 511
	    or pos.z < 0 or pos.z > 63) then
		server_msg(pid, "world_editor: that mark is outside the map.");
		return true;
	end

	-- delete mode: the mark names a block; whichever component owns it
	-- gets removed. Aim the spade/gun straight at one of its blocks.
	if (s.kind == "__delete") then
		local id = guarded[key(pos.x, pos.y, pos.z)];
		local inst = id and insts[id];
		if (inst == nil) then
			server_msg(pid, "world_editor: no component on that block -- aim right at one.");
			return true;   -- keep the session so they can try again
		end
		kinds[inst.kind].destroy(inst, we);
		insts[id] = nil;
		reindex_reserved();
		for i = #undo, 1, -1 do
			if (undo[i] == id) then table.remove(undo, i); end
		end
		session[pid] = nil;
		server_msg(pid, string.format("world_editor: deleted %s #%d.", inst.kind, id));
		save();
		return true;
	end

	local k = kinds[s.kind];
	local done, err = k.click(s, pos, we);
	if (err) then
		server_msg(pid, "world_editor: "..err);
		return true;
	end

	if (not done) then
		server_msg(pid, "world_editor: "..(s.prompt or "mark again."));
		return true;
	end

	if (s.kind == "__chunk") then
		session[pid] = nil;
		local c = s.made;
		server_msg(pid, string.format("world_editor: chunk %s (%s) created.",
		                              c and c.name or "?", chunks.format_perm(s.perm)));
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
	server_msg(pid, string.format("world_editor: %s #%d placed.", s.kind, inst.id));
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

	if (pressed and editing and session[pid] ~= nil) then
		local tool = get_tool(pid);
		if (tool == 0 or tool == 2) then   -- spade or gun
			local t = aim_target(pid);
			if (t == nil) then
				server_msg(pid, "world_editor: nothing to mark there -- aim at ground or water.");
			else
				server_msg(pid, string.format("world_editor: mark at %d %d %d", t.x, t.y, t.z));
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

-- Anyone moving the anon pid's held colour invalidates our cache of it,
-- ourselves included. Two callers make this mandatory rather than
-- defensive: rifle_is_a_rail_gun broadcasts a random red from the anon
-- pid on every shot, and shotgun_are_grenade_launchers pushes the map
-- colour at a single client. Both use send_set_block_color, so the
-- server-side value we track never moves while every client's copy does
-- -- and a build whose colour packet we skipped then rendered in their
-- colour, not ours.
function mod.set_block_color(pid, color)
	if (pid == get_anon_pid()) then
		forget_color();
	end
	mod.next.set_block_color(pid, color);
end

function mod.send_set_block_color(pid, color, from)
	if (from == get_anon_pid()) then
		forget_color();
	end
	mod.next.send_set_block_color(pid, color, from);
end

-- Grenades and other world damage go straight to block_action without
-- passing a player, so they cannot be team-resolved: anything short of
-- a fully open component (perm "rw") shrugs them off. Our own writes
-- come through as the anon pid and must pass.
function mod.block_action(pos, type, from)
	if (type ~= 0 and from ~= get_anon_pid()) then
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
	editing = false;   -- a fresh map always comes up in play mode
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

function mod.on_join(pid, team, gun, name)
	if (editing) then
		server_msg(pid, "This server is in world-edit mode; try again shortly.");
		disconnect(pid, 3);
		return;
	end
	mod.next.on_join(pid, team, gun, name);
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
-- can land phantom fall damage. Swallow fall damage (KillTypeFall = 4)
-- for anyone standing inside an elevator's shaft.
function mod.damage_player(pid, hp, type, from)
	if (type == 4 and is_alive(pid)) then
		-- Building means dropping off things constantly, and /fly can be
		-- toggled off mid-air. Edit mode swallows fall damage outright,
		-- with no message: a builder should never think about landing.
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

-- ------------------------------------------------------------------ flight
--
-- Building means getting to awkward corners, so edit mode gives
-- everyone free flight. Input bits are Forward 1, Backward 2, Left 4,
-- Right 8, Jump 16, Crouch 32, Sneak 64, Sprint 128.
--
-- Vertical is sneak (up) and crouch (down). Jump is deliberately NOT
-- read, for two independent reasons: the engine strips that bit while
-- the player is airborne (on_move_input), so it only fires the instant
-- you leave the ground; and set_jump() below calls send_move_input(),
-- which sets the very same bit -- reading it would make the anti-jitter
-- nudge look like held input and fly you upward forever on its own.

local jumpctr = pid_connected_table(0);
local walking = pid_connected_table(false);  -- players who turned flight off

local function flying(pid)
	return editing and we_fly and is_alive(pid) and not walking[pid];
end

local function right_of(v)
	local len = math.sqrt(v.x*v.x + v.y*v.y);
	if (len == 0) then
		return {x=0, y=0, z=0};
	end
	return {x=-v.y/len, y=v.x/len, z=0};
end

-- is_solid PANICs above z=63 and treats z<0 as undefined; clamp both.
-- Below the world floor reads as solid so you can't fly out the bottom,
-- above the sky as empty.
local function solid_at(x, y, z)
	if (z < 0) then return false; end
	if (z > 63) then return true; end
	return is_solid({x=x, y=y, z=z});
end

-- A player is ~3 blocks tall with pos.z at the head (feet ride at
-- pos.z+2.25, per demoncore's crouch maths). This is true when moving
-- the head to hz at column x,y would bury any of those cells in solid.
local function body_in_solid(x, y, hz)
	local ix, iy, iz = math.floor(x), math.floor(y), math.floor(hz);
	return solid_at(ix, iy, iz)
	    or solid_at(ix, iy, iz+1)
	    or solid_at(ix, iy, iz+2);
end

function mod.tick_player_physics(pid, delta)
	if (not flying(pid)) then
		mod.next.tick_player_physics(pid, delta);
		return;
	end

	local pos = get_position(pid);
	local ori = get_orientation(pid);
	local inp = get_inputs(pid);
	local rt  = right_of(ori);

	local speed = delta * we_fly_speed;
	if (bit.band(inp, 128) ~= 0) then
		speed = speed * 2;
	end

	local fwd    = (bit.band(inp, 1) ~= 0 and 1 or 0) - (bit.band(inp, 2) ~= 0 and 1 or 0);
	local strafe = (bit.band(inp, 8) ~= 0 and 1 or 0) - (bit.band(inp, 4) ~= 0 and 1 or 0);
	-- sneak rises, crouch sinks; z grows downward, so rising subtracts
	local up     = (bit.band(inp, 64) ~= 0 and 1 or 0)
	             - (bit.band(inp, 32) ~= 0 and 1 or 0);

	local nx = (pos.x + (ori.x*fwd + rt.x*strafe) * speed) % 512;
	local ny = (pos.y + (ori.y*fwd + rt.y*strafe) * speed) % 512;
	local nz = pos.z + ori.z*fwd*speed - up*speed;
	if (nz < 0) then nz = 0; end
	if (nz > 63) then nz = 63; end

	-- Collide instead of clipping: resolve each axis on its own so a
	-- blocked direction stops while the others keep going -- you slide
	-- along a wall and settle onto the floor rather than sinking through
	-- it. Steps are a fraction of a block, so stopping short of solid
	-- reads as landing.
	local x, y, z = pos.x, pos.y, pos.z;
	if (not body_in_solid(nx, y, z)) then x = nx; end
	if (not body_in_solid(x, ny, z)) then y = ny; end
	if (not body_in_solid(x, y, nz)) then z = nz; end

	set_position(pid, {x=x, y=y, z=z});

	-- the client keeps trying to fall; nudging jump keeps its view from
	-- settling into a drop and jittering against us
	jumpctr[pid] = jumpctr[pid] + delta;
	if (jumpctr[pid] >= 0.5) then
		set_jump(pid);
		jumpctr[pid] = jumpctr[pid] - 0.5;
	end
end

-- while we are driving the position, the client's own idea of where it
-- is would fight us every packet
function mod.on_position(pid, pos)
	if (flying(pid)) then
		return;
	end
	mod.next.on_position(pid, pos);
end

function mod.after.on_disconnect(pid)
	session[pid] = nil;
end

-- -------------------------------------------------------------- commands

local function need_edit(pid)
	if (not editing) then
		server_msg(pid, "world_editor: not in edit mode (enable it from the console).");
		return false;
	end
	return true;
end

-- Flight is on by default in edit mode; /fly drops you into normal
-- physics so you can walk and jump, and toggles back. Per-player, so
-- one builder walking around doesn't ground everyone.
local cmd = {name="fly", desc="Toggle your flight in edit mode (walk/jump when off)."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end
	if (not we_fly) then
		server_msg(pid, "world_editor: flight is disabled here (we_fly).");
		return;
	end
	walking[pid] = not walking[pid];
	if (walking[pid]) then
		server_msg(pid, "world_editor: flight OFF -- walk and jump normally. /fly to fly again.");
	else
		server_msg(pid, "world_editor: flight ON -- sneak to rise, crouch to sink, sprint to speed up.");
	end
end
register_command(cmd, mod);

-- Enabling is console-only: fakepid=true lets the console in, and the
-- is_fakepid check keeps in-game players out.
local cmd = {name="worldedit", caps="worldedit", fakepid=true,
             usage="on|off|status", desc="Toggle world edit mode (console only)."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv <= 1);

	if (not is_fakepid(pid)) then
		server_msg(pid, "world_editor: edit mode can only be toggled from the console.");
		return;
	end

	local what = string.lower(argv[1] or "status");
	if (what == "status") then
		server_msg(pid, "world_editor: edit mode is "..(editing and "ON" or "off")
		                .." (map "..tostring(mapname)..")");
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
			server_msg(pid, "world_editor: created "..path);
		end
	end

	for i in piditer(PID_BROADCAST) do
		if (is_joined(i)) then
			server_msg(i, "world_editor: edit mode "..(editing and "ENABLED -- no new players may join." or "disabled."));
		end
	end
	log("world_editor: edit mode %s", editing and "on" or "off");
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
			server_msg(pid, line);
		end
		return;
	end
	server_msg(pid, string.format("world_editor: %s -- %s", k.name, k.desc or ""));
	if (k.usage) then
		server_msg(pid, "  usage: /place "..k.name.." "..k.usage);
	end
end

local cmd = {name="place", usage="[component] [args...]",
             desc="Place a component; /place alone lists them, /place <c> shows help."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end

	-- bare /place lists everything placeable and how to get each one's help
	if (#argv == 0) then
		server_msg(pid, "world_editor: placeable -- "..table.concat(component_names(), ", "));
		server_msg(pid, "  /place <component> for its help, e.g. /place elevator");
		return;
	end

	local k = kinds[string.lower(argv[1])];
	if (k == nil or k.name == "__chunk") then
		server_msg(pid, "world_editor: no such component. placeable: "
		                ..table.concat(component_names(), ", "));
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
		if (err) then server_msg(pid, "world_editor: "..err); end
		show_help(pid, k);
		return;
	end

	s.kind = k.name;
	s.perm = s.perm or {mode="ro"};   -- components default to fully protected
	-- colour comes from the placer's own block palette, not an argument
	s.color = get_block_color(pid);
	session[pid] = s;
	server_msg(pid, "world_editor: "..(s.prompt or "mark a block to place."));
end
register_command(cmd, mod);

-- Spectators can't spade, and spectating is the natural way to build:
-- you can fly to the exact spot instead of standing on it. /here drops
-- the mark at your own position, so the whole editor works from spec.
local cmd = {name={"here", "mark"}, usage="[x y z]",
             desc="Drop a placement mark where you are (or at x y z)."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end
	cmd_assert(pid, cmd, #argv == 0 or #argv == 3);

	if (session[pid] == nil) then
		server_msg(pid, "world_editor: nothing being placed -- start with /place or /chunk.");
		return;
	end

	local pos;
	if (#argv == 3) then
		local x, y, z = tonumber(argv[1]), tonumber(argv[2]), tonumber(argv[3]);
		if (x == nil or y == nil or z == nil) then
			server_msg(pid, "world_editor: x y z must be numbers.");
			return;
		end
		pos = {x=math.floor(x), y=math.floor(y), z=math.floor(z)};
	else
		local p = get_position(pid);
		pos = {x=math.floor(p.x), y=math.floor(p.y), z=math.floor(p.z)};
	end

	if (pos.x < 0 or pos.x > 511 or pos.y < 0 or pos.y > 511
	    or pos.z < 0 or pos.z > 63) then
		server_msg(pid, "world_editor: that is outside the map.");
		return;
	end

	server_msg(pid, string.format("world_editor: mark at %d %d %d", pos.x, pos.y, pos.z));
	apply_mark(pid, pos);
end
register_command(cmd, mod);

local cmd = {name="componentperm", usage="ro|rw|rw:<team>",
             desc="Set protection on the nearest component."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end
	cmd_assert(pid, cmd, #argv == 1);

	local perm = chunks.parse_perm(argv[1]);
	if (perm == nil) then
		server_msg(pid, "world_editor: perm must be ro, rw, or rw:<team>.");
		return;
	end

	local p = get_position(pid);
	local best, bestd = nil, nil;
	for _, inst in pairs(insts) do
		local d = (inst.x-p.x)^2 + (inst.y-p.y)^2;
		if (bestd == nil or d < bestd) then best, bestd = inst, d; end
	end
	if (best == nil) then
		server_msg(pid, "world_editor: no components on this map.");
		return;
	end

	best.perm = perm;
	server_msg(pid, string.format("world_editor: %s #%d is now %s",
	                              best.kind, best.id, chunks.format_perm(perm)));
	save();
end
register_command(cmd, mod);

local cmd = {name="undo", desc="Remove the most recently placed component."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end

	local id = table.remove(undo);
	if (id == nil or insts[id] == nil) then
		server_msg(pid, "world_editor: nothing to undo.");
		return;
	end
	kinds[insts[id].kind].destroy(insts[id], we);
	insts[id] = nil;
	reindex_reserved();
	server_msg(pid, string.format("world_editor: removed #%d.", id));
	save();
end
register_command(cmd, mod);

-- Delete by pointing: start a mark, then spade/shoot a block belonging
-- to the component you want gone.
local cmd = {name="delete", desc="Delete the component whose block you mark."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end
	session[pid] = {kind="__delete",
	                prompt="spade or shoot a block of the component to delete."};
	server_msg(pid, "world_editor: "..session[pid].prompt);
end
register_command(cmd, mod);

-- Persist the map itself. The components are drawn into the live map, so
-- lift them out first, dump pure terrain to <name>.vxl, put them back,
-- then write <name>.editor.json alongside -- reloading the map restores
-- terrain from the vxl and components from the json.
local cmd = {name="savemap", fakepid=true, usage="[name]",
             desc="Save the map (.vxl) and its components (.editor.json) to maps/."};
function cmd.func(pid, argv)
	if (not is_fakepid(pid) and not need_edit(pid)) then return; end
	cmd_assert(pid, cmd, #argv <= 1);

	local name = argv[1] or mapname;
	if (name == nil) then
		server_msg(pid, "world_editor: no map name known -- pass one: /savemap <name>.");
		return;
	end
	if (string.find(name, "[/\\]") or string.find(name, "^%.")) then
		server_msg(pid, "world_editor: bad name (no / \\ or leading dot).");
		return;
	end

	local vxlpath = we_dir.."/"..name..".vxl";
	local jsonpath2 = we_dir.."/"..name..".editor.json";

	-- take component blocks out so the vxl is pure terrain (+ the shafts
	-- dug for elevators, which are genuine terrain changes)
	for _, inst in pairs(insts) do
		kinds[inst.kind].destroy(inst, we);
	end

	local ok = true;
	local f, err = io.open(vxlpath..".new", "wb");
	if (f == nil) then
		log("world_editor: cannot write %s (%s)", vxlpath, tostring(err));
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
		server_msg(pid, string.format("world_editor: saved %s.vxl + %s.editor.json in %s/",
		                              name, name, we_dir));
	else
		server_msg(pid, "world_editor: save failed -- see server log (is maps/ writable?).");
	end
end
register_command(cmd, mod);

local cmd = {name="chunk", usage="box|cylinder|sphere|circle|rect <perm> [name]",
             desc="Create an authorization chunk (spade two marks to set its extent)."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end
	cmd_assert(pid, cmd, #argv >= 2);

	local shape = string.lower(argv[1]);
	local perm = chunks.parse_perm(argv[2]);
	if (perm == nil) then
		server_msg(pid, "world_editor: perm must be ro, rw, or rw:<team>.");
		return;
	end

	session[pid] = {kind="__chunk", shape=shape, perm=perm, name=argv[3], pts={},
	                prompt=(shape == "box") and "spade two opposite corners."
	                                        or "spade the centre, then the edge."};
	server_msg(pid, "world_editor: "..session[pid].prompt);
end
register_command(cmd, mod);

local cmd = {name="chunkperm", usage="ro|rw|rw:<team>",
             desc="Set the authorization of the chunk you are standing in."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end
	cmd_assert(pid, cmd, #argv == 1);

	local perm = chunks.parse_perm(argv[1]);
	if (perm == nil) then
		server_msg(pid, "world_editor: perm must be ro, rw, or rw:<team>.");
		return;
	end

	local p = get_position(pid);
	local c = chunks.at(math.floor(p.x), math.floor(p.y), math.floor(p.z));
	if (c == nil) then
		server_msg(pid, "world_editor: you are not in a chunk (use /defaultperm for open map).");
		return;
	end
	c.perm = perm;
	server_msg(pid, string.format("world_editor: %s is now %s", c.name, chunks.format_perm(perm)));
	save();
end
register_command(cmd, mod);

local cmd = {name="chunkrm", desc="Delete the chunk you are standing in."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end

	local p = get_position(pid);
	local c = chunks.at(math.floor(p.x), math.floor(p.y), math.floor(p.z));
	if (c == nil) then
		server_msg(pid, "world_editor: you are not in a chunk.");
		return;
	end
	chunks.remove(c.id);
	server_msg(pid, "world_editor: removed chunk "..c.name);
	save();
end
register_command(cmd, mod);

local cmd = {name="chunks", fakepid=true, desc="List authorization chunks."};
function cmd.func(pid, argv)
	server_msg(pid, "world_editor: default "..chunks.format_perm(chunks.get_default())
	                ..(we_readonly and ", map READONLY" or ""));
	for _, c in pairs(chunks.all()) do
		server_msg(pid, string.format("  #%d %s %s %s", c.id, c.name, c.shape,
		                              chunks.format_perm(c.perm)));
	end
end
register_command(cmd, mod);

local cmd = {name="defaultperm", fakepid=true, usage="ro|rw|rw:<team>",
             desc="Authorization for blocks outside every chunk."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 1);
	local perm = chunks.parse_perm(argv[1]);
	if (perm == nil) then
		server_msg(pid, "world_editor: perm must be ro, rw, or rw:<team>.");
		return;
	end
	chunks.set_default(perm);
	server_msg(pid, "world_editor: default is now "..chunks.format_perm(perm));
	save();
end
register_command(cmd, mod);

local cmd = {name="mapreadonly", fakepid=true, usage="on|off",
             desc="Master lock: refuse every player block edit."};
function cmd.func(pid, argv)
	cmd_assert(pid, cmd, #argv == 1);
	we_readonly = (string.lower(argv[1]) == "on");
	server_msg(pid, "world_editor: map readonly "..(we_readonly and "ON" or "off"));
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
		log("world_editor: component %s failed to load: %s", name, tostring(k));
	end
end
kinds["__chunk"] = chunkkind;

-- Hot-load restore: when the script is (re)loaded onto an already-running
-- map, load_map fired long before us, so nothing would restore the saved
-- layout. Now that mapname is recovered and the components are
-- registered, load <map>.editor.json here. (On a normal boot mapname is
-- still nil at this point -- the map loads after us -- so this is skipped
-- and load_map does the load.)
if (mapname ~= nil) then
	load_layout();
end

return mod;
