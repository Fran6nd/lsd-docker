-- editor/placement.lua -- Placing components, chunks and deletions by marks
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- A placement is a session per player: /place door left starts one, and
-- marks -- points on the map -- feed it until the component has what it
-- needs, when it is added to the layout (map_layout.add). Marks come from:
--
--   * a selection: sel.lua already owns "point at a box", at any range
--     and without breaking anything, so a placement takes a finished
--     selection as its first two marks, or arms a fresh one and waits;
--   * a spade or gun swing (aim_target), which works on water and on
--     misses too;
--   * /here (the player's own position) and /marks (coordinates).
--
-- Two pseudo-kinds share the flow: "__chunk" makes an authorization
-- chunk from two marks, "__delete" un-places the component owning the
-- marked block.
local P = {};

local areas = require "map_layout.areas";

local msg = {
	prompt         = {en="editor: %(text)"},
	mark_at        = {en="editor: mark at %(x) %(y) %(z)"},
	mark_outside   = {en="editor: that mark is outside the map."},
	nothing_to_mark = {en="editor: nothing to mark there -- aim at ground or water."},
	no_component_here = {en="editor: no component on that block -- aim right at one."},
	deleted        = {en="editor: deleted %(kind) #%(id) -- its blocks stay, back at rest."},
	placed         = {en="editor: %(kind) #%(id) placed."},
	chunk_created  = {en="editor: chunk %(name) (%(perm)) created."},
	mark_again     = {en="editor: mark again."},
};
P.msg = msg;

getcfg("editor_mark_range", 160,
	"How far a spade or gun mark reaches, in blocks.");
getcfg("editor_water_level", 63,
	"The z a mark lands on when aimed past every block.");

-- pid -> the placement in progress
P.session = pid_connected_table(nil);
-- pid -> true while a placement waits for its selection
P.awaiting = {};
-- placed component ids, newest last, for /undo
P.undo = {};

local function forget_undo(id)
	for i = #P.undo, 1, -1 do
		if (P.undo[i] == id) then table.remove(P.undo, i); end
	end
end
P.forget_undo = forget_undo;

-- Where a player is aiming, for marking. Raycast eye-forward to the first
-- solid block, and fall back to the water plane so a shot that destroys
-- nothing still marks something.
--
-- raycast(s, e, false) returns the solid voxel that was hit. (The apidoc
-- has `last` the wrong way round -- demoncore.c cast2() returns the hit
-- voxel for last=false and the cell before it for last=true.) It needs no
-- bounds clamping: cast2 wraps x/y mod 512 and stops going up at z<0.
--
-- Down is the problem. Water columns may be non-solid (budgetvxl.c,
-- "pyspades allows it so we do too"), and phys_solid() reports
-- everything at z>=64 as solid -- so a shot into water falls through the
-- column and "hits" the virtual floor one layer below the map. Two rules:
--
--   * a hit outside the map is not a hit
--   * a hit *under* the water surface loses to the surface itself, so
--     pointing across water marks the water you aimed at, not the seabed
function P.aim_target(pid)
	local s = get_position(pid);
	local o = get_orientation(pid);
	local e = {x=s.x + o.x*editor_mark_range,
	           y=s.y + o.y*editor_mark_range,
	           z=s.z + o.z*editor_mark_range};

	-- where the ray crosses the water plane; z grows downward, so only a
	-- downward look (o.z > 0) can meet it
	local tw = nil;
	if (o.z > 0.001) then
		local t = (editor_water_level - s.z) / o.z;
		if (t > 0 and t <= editor_mark_range) then
			tw = t;
		end
	end

	local vox = raycast(s, e, false);
	if (vox ~= nil and (vox.z < 0 or vox.z > 63)) then
		vox = nil;                       -- fell off the map, not a real block
	end
	if (vox ~= nil and tw ~= nil and vox.z > editor_water_level) then
		vox = nil;                       -- submerged; the surface came first
	end
	if (vox ~= nil) then
		return vox;
	end

	if (tw ~= nil) then
		-- cast2 wraps horizontally, so the plane hit wraps to match
		return {x=math.floor(s.x + o.x*tw) % 512,
		        y=math.floor(s.y + o.y*tw) % 512,
		        z=editor_water_level};
	end
	return nil;
end

-- Feed one mark into the placement in progress. Every mark source funnels
-- through here, so the checks live here once.
function P.apply_mark(pid, pos)
	local s = P.session[pid];
	if (s == nil) then
		return false;
	end

	-- marking by hand answers the question the selection was asked, so
	-- the two never both get to speak
	if (s.from_sel) then
		s.from_sel = nil;
		P.awaiting[pid] = nil;
	end

	if (pos.x < 0 or pos.x > 511 or pos.y < 0 or pos.y > 511
	    or pos.z < 0 or pos.z > 63) then
		l10n_send_chat(pid, msg.mark_outside);
		return true;
	end

	-- delete: the mark names a block; whichever component owns it is
	-- un-placed, its blocks left as terrain
	if (s.kind == "__delete") then
		local id = map_layout.owner(pos.x, pos.y, pos.z);
		if (id == nil) then
			l10n_send_chat(pid, msg.no_component_here);
			return true;   -- keep the session so they can try again
		end
		local inst = map_layout.release(id);
		forget_undo(id);
		P.session[pid] = nil;
		l10n_send_chat(pid, msg.deleted, {kind=inst.kind, id=id});
		return true;
	end

	local k = s.kind == "__chunk" and P.chunk_kind or map_layout.kinds()[s.kind];
	local done, err = k.click(s, pos, map_layout.blocks);
	if (err) then
		l10n_send_chat(pid, err);
		return true;
	end

	if (not done) then
		l10n_send_chat(pid, s.prompt or msg.mark_again);
		return true;
	end

	P.session[pid] = nil;

	if (s.kind == "__chunk") then
		local c = s.made;
		l10n_send_chat(pid, msg.chunk_created,
		               {name=c and c.name or "?", perm=map_layout.chunks.format_perm(s.perm)});
		map_layout.save();
		return true;
	end

	local inst = map_layout.add(s.kind, s.data, {perm=s.perm, color=s.color});
	table.insert(P.undo, inst.id);
	l10n_send_chat(pid, msg.placed, {kind=s.kind, id=inst.id});
	return true;
end

-- Feed a finished selection into the placement as its first two marks,
-- exactly as if they had been marked one at a time, so components keep
-- taking their marks one at a time.
function P.take_selection(pid)
	local s = P.session[pid];
	if (s == nil or not s.from_sel) then
		P.awaiting[pid] = nil;
		return;
	end

	local a, b = sel_corners(pid);
	if (a == nil) then
		return;            -- still being picked
	end

	s.from_sel = nil;
	P.awaiting[pid] = nil;

	l10n_send_chat(pid, msg.mark_at, a);
	P.apply_mark(pid, a);
	if (P.session[pid] ~= nil) then
		l10n_send_chat(pid, msg.mark_at, b);
		P.apply_mark(pid, b);
	end
end

-- Start a placement: the box comes from sel when it is there to ask. A
-- selection already finished is taken as-is -- that is what "place a
-- door on this" means when you have just selected something -- otherwise
-- a fresh one is armed and picked up the moment its second corner lands.
-- Returns whether a selection is being waited on.
function P.begin(pid, s)
	P.session[pid] = s;
	if (s.kind ~= "__delete" and sel_begin ~= nil and sel_corners ~= nil) then
		s.from_sel = true;
		P.awaiting[pid] = true;
		if (sel_corners(pid) == nil or sel_pending(pid)) then
			sel_begin(pid);
			return true;
		end
		P.take_selection(pid);
		return false;
	end
	return false;
end

function P.forget(pid)
	P.session[pid] = nil;
	P.awaiting[pid] = nil;
end

-- chunk placement shares the mark flow with components
P.chunk_kind = {
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

		s.made = map_layout.chunks.add({area=area, perm=s.perm, name=s.name});
		return true;
	end,
};

return P;
