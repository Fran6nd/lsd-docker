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
--   * persistence      -- components and chunks live in <map>.json next
--                         to the map, autoloaded on map load, rewritten
--                         on every change
--   * undo             -- /undo pops the last thing placed
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
local mod = init_mod();

local areas  = require "world_editor.areas";
local chunks = require "world_editor.chunks";

getcfg("we_dir", "maps");          -- where <map>.json is read/written
getcfg("we_default_perm", "rw");   -- authorization outside every chunk
getcfg("we_readonly", false);      -- master lock: no player edits at all
getcfg("we_autosave", true);       -- rewrite <map>.json on every change

local editing = false;
local mapname = nil;

local kinds = {};      -- name -> component module
local insts = {};      -- id -> instance
local nextid = 1;
local undo = {};       -- stack of instance ids, newest last

local guarded = {};    -- packed block -> instance id (indestructible)
local session = pid_connected_table(nil);  -- in-progress placement per pid

local function key(x, y, z)
	return (z*512 + y)*512 + x;
end

-- Colours are optional on every component: "r,g,b" or one of a few
-- names, so /place elevator up ro 0,255,0 just works. nil means the
-- component keeps whatever default it ships with.
local named = {
	red={r=255,g=32,b=32},    green={r=32,g=255,b=32},  blue={r=64,g=96,b=255},
	yellow={r=255,g=224,b=32}, orange={r=255,g=140,b=0}, purple={r=170,g=64,b=255},
	white={r=245,g=245,b=245}, black={r=16,g=16,b=16},   grey={r=170,g=170,b=185},
	gray={r=170,g=170,b=185},  cyan={r=0,g=220,b=220},   pink={r=255,g=120,b=200},
};

local function parse_color(str)
	if (str == nil) then
		return nil, nil;
	end

	local n = named[string.lower(str)];
	if (n ~= nil) then
		return {r=n.r, g=n.g, b=n.b};
	end

	local r, g, b = string.match(str, "^(%d+)%s*,%s*(%d+)%s*,%s*(%d+)$");
	if (r == nil) then
		return nil, "colour must be r,g,b or a name (red, blue, grey, ...)";
	end
	r, g, b = tonumber(r), tonumber(g), tonumber(b);
	if (r > 255 or g > 255 or b > 255) then
		return nil, "colour channels must be 0-255.";
	end
	return {r=r, g=g, b=b};
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

-- Blocks are built the way a client would: point the anon player's
-- held colour at what we want, then build from that pid. block_action
-- (not send_block_action) so the block is real and solid -- players
-- have to stand on a platform and be stopped by a shut door.
function we.set(inst, x, y, z, color)
	if (color ~= nil) then
		send_set_block_color(PID_BROADCAST, color, get_anon_pid());
	end
	block_action({x=x, y=y, z=z}, 0, get_anon_pid());
	guarded[key(x, y, z)] = inst.id;
end

function we.clear(inst, x, y, z)
	block_action({x=x, y=y, z=z}, 1, get_anon_pid());
	guarded[key(x, y, z)] = nil;
end

function we.is_guarded(x, y, z)
	return guarded[key(x, y, z)] ~= nil;
end

-- a filled disc of blocks, the platform shape shared by elevators
function we.disc(inst, cx, cy, z, r, color, on)
	for dy = -r, r do
		for dx = -r, r do
			if (dx*dx + dy*dy <= r*r) then
				local x, y = cx+dx, cy+dy;
				if (x >= 0 and x < 512 and y >= 0 and y < 512 and z >= 0 and z < 64) then
					if (on) then we.set(inst, x, y, z, color);
					else we.clear(inst, x, y, z); end
				end
			end
		end
	end
end

function we.editing()
	return editing;
end

-- components build their trigger volumes from the same shape library
-- the authorization chunks use
we.areas = areas;

-- ------------------------------------------------------------ persistence

local function jsonpath()
	if (mapname == nil) then
		return nil;
	end
	return we_dir.."/"..mapname..".json";
end

local function save()
	local path = jsonpath();
	if (path == nil or not we_autosave) then
		return;
	end

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

	local doc = {
		default_perm = chunks.format_perm(chunks.get_default()),
		readonly = we_readonly and true or false,
		chunks = chunks.serialize(),
		components = comps,
	};

	local f, err = io.open(path, "w");
	if (f == nil) then
		-- maps/ is mounted read-only in the stock compose file; say so
		-- plainly rather than silently dropping the layout
		log("world_editor: cannot write %s (%s) -- drop the :ro on the maps mount to persist", path, tostring(err));
		return;
	end
	f:write(jenc(doc), "\n");
	f:close();
end

local function clear_all()
	for _, inst in pairs(insts) do
		kinds[inst.kind].destroy(inst, we);
	end
	insts = {};
	guarded = {};
	undo = {};
	nextid = 1;
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
			if (inst.id >= nextid) then nextid = inst.id + 1; end
			insts[inst.id] = inst;
			k.render(inst, we);
		end
	end

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
	send_set_block_color(pid, get_map_block_color(pos), get_anon_pid());
	send_block_action(pid, pos, 0, get_anon_pid());
end

function mod.on_block_action(pid, pos, type)
	-- a spade click while placing is a pick, not an edit
	local s = session[pid];
	if (s ~= nil and type ~= 0) then
		-- a mark is always "spade one block"; put it straight back, and
		-- put back the neighbours too if they used the 3-block spade
		revert(pid, pos, type);
		if (type == 2) then
			revert(pid, {x=pos.x, y=pos.y, z=pos.z-1}, type);
			revert(pid, {x=pos.x, y=pos.y, z=pos.z+1}, type);
		end
		local k = kinds[s.kind];
		local done, err = k.click(s, pos, we);
		if (err) then
			server_msg(pid, "world_editor: "..err);
			return;
		end
		if (done) then
			local inst = k.spawn(s.data, we);
			inst.id = nextid; nextid = nextid + 1;
			inst.kind = s.kind;
			inst.perm = s.perm or {mode="ro"};
			inst.color = s.color;   -- nil keeps the component's own default
			insts[inst.id] = inst;
			k.render(inst, we);
			table.insert(undo, inst.id);
			session[pid] = nil;
			server_msg(pid, string.format("world_editor: %s #%d placed.", s.kind, inst.id));
			save();
		else
			server_msg(pid, "world_editor: "..(s.prompt or "click again."));
		end
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

function mod.after.load_map(name)
	mapname = name;
	editing = false;   -- a fresh map always comes up in play mode
	load_layout();
end

function mod.on_join(pid, team, gun, name)
	if (editing) then
		server_msg(pid, "This server is in world-edit mode; try again shortly.");
		disconnect(pid, 3);
		return;
	end
	mod.next.on_join(pid, team, gun, name);
end

function mod.after.tick()
	for _, inst in pairs(insts) do
		kinds[inst.kind].tick(inst, we);
	end
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
	for i in piditer(PID_BROADCAST) do
		if (is_joined(i)) then
			server_msg(i, "world_editor: edit mode "..(editing and "ENABLED -- no new players may join." or "disabled."));
		end
	end
	log("world_editor: edit mode %s", editing and "on" or "off");
end
register_command(cmd, mod);

local cmd = {name="place", usage="<component> [direction] [perm] [colour]",
             desc="Place a component (perm: ro/rw/rw:<team>; colour: r,g,b or a name)."};
function cmd.func(pid, argv)
	if (not need_edit(pid)) then return; end
	cmd_assert(pid, cmd, #argv >= 1);

	local k = kinds[string.lower(argv[1])];
	if (k == nil) then
		local names = {};
		for n in pairs(kinds) do
			if (n ~= "__chunk") then table.insert(names, n); end
		end
		table.sort(names);
		server_msg(pid, "world_editor: unknown component. have: "..table.concat(names, ", "));
		return;
	end

	-- default is protected from both teams: a component nobody can chip
	local perm = {mode="ro"};
	if (argv[3] ~= nil) then
		perm = chunks.parse_perm(argv[3]);
		if (perm == nil) then
			server_msg(pid, "world_editor: perm must be ro, rw, or rw:<team>.");
			return;
		end
	end

	local color, cerr = parse_color(argv[4]);
	if (cerr ~= nil) then
		server_msg(pid, "world_editor: "..cerr);
		return;
	end

	local s, err = k.start(pid, argv[2]);
	if (s == nil) then
		server_msg(pid, "world_editor: "..err);
		return;
	end
	s.kind = k.name;
	s.perm = perm;
	s.color = color;
	session[pid] = s;
	server_msg(pid, "world_editor: "..(s.prompt or "spade a block to place."));
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
	server_msg(pid, string.format("world_editor: removed #%d.", id));
	save();
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

return mod;
