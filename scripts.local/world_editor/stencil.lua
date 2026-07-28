-- world_editor/stencil.lua -- Capture an existing build as a component
--
-- Components that MOVE a piece of the map -- the door, the elevator --
-- do not draw a shape of their own. Whatever is already built inside the
-- marked box is the component: every solid cell with the colour it
-- already has, every empty cell left empty. This is the part they share,
-- so the packing is written and got right once.
--
-- The drawing lives in <map>.editor.json rather than in the map itself,
-- because /wesavemap takes every component down before dumping the .vxl --
-- the terrain on disk has a component-shaped hole in it and this is the
-- only record of what used to be there.
--
-- It is packed small enough to sit comfortably in that json: a palette of
-- the distinct colours, plus one run-length string over the box in
-- z,y,x order, each run written "<count>*<palette index>" with index 0
-- meaning empty. A few hundred cells in a handful of colours comes to a
-- couple of hundred bytes.
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
local S = {};

-- Read a box off the live map: which cells are solid, and what colour
-- each solid one carries. This has to run BEFORE the component digs the
-- box, because digging is exactly what turns that terrain into blocks
-- the component owns.
--
-- get_map_block_color reads colorData straight (lsd/src/lua.c
-- get_map_block_color), so it means nothing for a cell that is not
-- solid -- hence reading it only behind is_solid.
--
-- Returns nil for a box with nothing in it, which is the caller's cue to
-- fall back to a plain solid shape of its own.
function S.capture(x1, y1, z1, x2, y2, z2)
	local pal, index, runs = {}, {}, {};
	local prev, count, solid = nil, 0, 0;

	for z = z1, z2 do
		for y = y1, y2 do
			for x = x1, x2 do
				local idx = 0;
				if (is_solid({x=x, y=y, z=z})) then
					local c = get_map_block_color({x=x, y=y, z=z});
					local hex = string.format("%02x%02x%02x", c.r, c.g, c.b);
					idx = index[hex];
					if (idx == nil) then
						table.insert(pal, hex);
						idx = #pal;
						index[hex] = idx;
					end
					solid = solid + 1;
				end

				if (idx == prev) then
					count = count + 1;
				else
					if (prev ~= nil) then
						table.insert(runs, count.."*"..prev);
					end
					prev, count = idx, 1;
				end
			end
		end
	end
	if (prev ~= nil) then
		table.insert(runs, count.."*"..prev);
	end

	if (solid == 0) then
		return nil;
	end
	return pal, table.concat(runs, ",");
end

-- the saved palette (rrggbb strings) as colour tables, or nil if it is
-- not one
function S.decode_pal(pal)
	if (type(pal) ~= "table") then
		return nil;
	end
	local out = {};
	for i, s in ipairs(pal) do
		if (type(s) ~= "string" or string.len(s) ~= 6) then
			return nil;
		end
		local r = tonumber(string.sub(s, 1, 2), 16);
		local g = tonumber(string.sub(s, 3, 4), 16);
		local b = tonumber(string.sub(s, 5, 6), 16);
		if (r == nil or g == nil or b == nil) then
			return nil;
		end
		out[i] = {r=r, g=g, b=b};
	end
	return out;
end

-- Walk a packed drawing, calling fn(x, y, z, cidx) for each solid cell.
-- `box` is anything with x1,y1,z1,x2,y2,z2 -- an instance will do.
--
-- Returns the number of solid cells, or nil plus a reason when the runs
-- do not describe this box. A caller that gets nil must fall back to a
-- plain shape: half-applying a stencil that does not fit would put the
-- drawing down misaligned, which is worse than not having it.
function S.each(box, npal, cells, fn)
	local w = box.x2 - box.x1 + 1;
	local h = box.y2 - box.y1 + 1;
	local plane = w * h;
	local total = plane * (box.z2 - box.z1 + 1);

	local i, n = 0, 0;

	for count, idx in string.gmatch(cells, "(%d+)%*(%d+)") do
		count, idx = tonumber(count), tonumber(idx);
		if (i + count > total) then
			return nil, "more cells than the box holds";
		end

		if (idx ~= 0) then
			if (idx > npal) then
				return nil, "a run names colour "..idx..", which is not in the palette";
			end
			for c = i, i + count - 1 do
				-- capture walked z, then y, then x; unwind that
				fn(box.x1 + (c % w),
				   box.y1 + (math.floor(c / w) % h),
				   box.z1 + math.floor(c / plane),
				   idx);
				n = n + 1;
			end
		end
		i = i + count;
	end

	if (i ~= total) then
		return nil, string.format("%d cells for a box of %d", i, total);
	end
	return n;
end

return S;
