-- map_layout/blocks.lua -- How components write the map
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Components build through this table -- the `we` every component
-- callback is handed -- so the record of which cells they own, `guarded`,
-- stays true. They write real (solid) blocks, because players have to be
-- able to stand on a platform and be stopped by a shut door.
--
-- State, read by lib_map_layout's guards:
--   we.guarded   packed cell -> owning instance id (indestructible)
--   we.drawing   true only while a component is writing. Our writes and
--                every other script's both arrive as the anon pid, so
--                the guard cannot tell them apart by `from` alone; this
--                is what tells them apart.
--
-- Blocks are built the way a client would: point the anon player's held
-- colour at what we want, then build from that pid.
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
--     `GetLink(x,y,z) != Invalid` branch. On a *release* client SPAssert
--     compiles to a no-op under NDEBUG (zerospades Sources/Core/Debug.h),
--     so AddBlock simply returns early and the block silently never
--     appears: a structure with holes in it. The stale link is the bug.
--
-- Per-block block_action keeps the server's cull in lockstep with the
-- client's, so no stale links -- the proven-stable primitive. If block
-- volume ever needs cutting, do it by moving fewer blocks, not by
-- batching packets.
require "lib_bulk_destroy";   -- bdestroy_block_action / bdestroy_finish

local we = {guarded = {}, drawing = false};

-- Deepest layer components may write. z=63 is the client's connectivity
-- Root (GameMapWrapper::Rebuild marks every column's z=63 Root
-- unconditionally), so a create there hits `GetLink ~= Invalid` and
-- asserts the cell is solid -- if anything emptied it first, the client
-- dies on the spot. z=62 is the engine's floor: its 3x-destroy guards
-- `pos.z < 62`, though *single* destroy has no such guard, so a script
-- can empty bedrock that no client expects to move. Stay above both.
we.deepest = 61;

function we.key(x, y, z)
	return (z*512 + y)*512 + x;
end

-- Set the colour every build draws in, every single time.
--
-- set_block_color, not send_set_block_color: block_action/block_line
-- colour the map from the anon pid's *server-side* held colour, so only
-- setting it server-side bakes the colour into the stored map (a bare
-- broadcast left it black for fresh joiners).
--
-- This looks like an obvious thing to cache -- DO NOT. The anon pid's
-- held colour is global state shared with every other script, and two
-- of ours move it constantly through send_set_block_color, which changes
-- what *clients* believe without touching the server-side value a cache
-- would be tracking: the railgun (a random red per shot) and the grenade
-- shotgun (get_map_block_color of a pellet's cell, black for air).
-- Caching it drew platform rings red, then whole moving components
-- black, and only while people were shooting -- never during a build
-- session, always during a game. One packet per fill is a few percent
-- against the ~73 block packets an elevator step already sends.
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
		for x = s, e do we.guarded[(z*512 + y)*512 + x] = inst.id; end
		s = e + 1;
	end
end

local function clamp(x1, y1, z1, x2, y2, z2)
	return math.max(0, x1), math.max(0, y1), math.max(0, z1),
		math.min(511, x2), math.min(511, y2), math.min(we.deepest, z2);
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
	x1, y1, z1, x2, y2, z2 = clamp(x1, y1, z1, x2, y2, z2);
	if (x1 > x2 or y1 > y2 or z1 > z2) then return; end
	local guarded = we.guarded;

	we.drawing = true;
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
	we.drawing = false;
end

-- Recolour cells this component already owns, without breaking them.
--
-- block_action type 0 is "Build", and lsd/src/main.c block_action()
-- implements it as an unconditional set_solid() + set_vox_color() -- it
-- never checks whether the cell was already solid. So a build packet
-- aimed at a cell that is already solid is a pure colour change: no
-- destroy, and therefore no destroy-then-create on one cell inside a
-- single tick, which is the pattern that leaves client connectivity
-- stale (see above).
--
-- That matters for anything that MOVES a multicoloured structure: slide
-- a drawing one block along and most of its cells land where another of
-- its own cells already was -- the right place, the wrong colour.
--
-- Deliberately restricted to cells in `guarded` under this instance.
-- Painting without breaking is precisely what players are not allowed to
-- do, and this must not become a way around that: it can only ever
-- recolour a block the calling component already put there itself.
function we.paint(inst, x1, y1, z1, x2, y2, z2, color, keep)
	x1, y1, z1, x2, y2, z2 = clamp(x1, y1, z1, x2, y2, z2);
	if (x1 > x2 or y1 > y2 or z1 > z2) then return; end
	local guarded = we.guarded;

	we.drawing = true;
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

	we.drawing = false;
end

function we.is_guarded(x, y, z)
	return we.guarded[we.key(x, y, z)] ~= nil;
end

-- dig existing map blocks (not component blocks, so untracked in
-- guarded) out of a box, so an elevator's path is clear. Bulk: one
-- floating-block cull for the whole shaft instead of one per block.
function we.dig_box(x1, y1, z1, x2, y2, z2, keep)
	x1, y1, z1, x2, y2, z2 = clamp(x1, y1, z1, x2, y2, z2);
	local guarded = we.guarded;
	we.drawing = true;
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
	we.drawing = false;
end

-- Forget every cell an instance owns, leaving the blocks in the map.
function we.disown(id)
	for cell, owner in pairs(we.guarded) do
		if (owner == id) then we.guarded[cell] = nil; end
	end
end

--============================== ANIMATION ===========================--
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
we.areas = require "map_layout.areas";

return we;
