-- dev/live/probe.lua -- what dev/live-babel.sh measures inside the server
--
-- Loaded into a running server with `lsdctl exec 'exec dofile(...)'`
-- (the harness copies it in); loading it again changes nothing. It only
-- counts and reads: no setting, no player, no block is touched.
--
--   live_report()           "LIVE t=<s> blocks <t1> <t2> captures <c1> <c2>"
--                           blocks: voxels placed by each team (a block
--                           line counts its voxels) since the probe was
--                           loaded; captures: each team's intel captures
--   live_positions()        "POS <pid>:<team>:<x>:<y>:<z> ..." for every
--                           living player (the eye, as get_position says)
--   live_ground(x, y)       "GROUND <x> <y> <z>": the top of the ground in a
--                           column (the solid run down to the map's bottom)
--   live_climb(x, y, z, r)  "CLIMB yes|no <steps>": whether a body can walk
--                           from the ground to stand on voxel (x, y, z) --
--                           its own search, not the bot engine's: floors
--                           (a solid voxel with three of air over it) joined
--                           side by side, at most one voxel up or two down
--                           from one to the next on the way up, within r
--                           columns of it, never higher than it (so not by
--                           some other way down from a platform it touches);
--                           "the ground" is a floor that is its column's
--                           ground (ground_at). steps: the floors on the
--                           shortest such way.

if (LIVE_PROBE ~= nil) then return; end

local probe = init_mod();
probe.name = "live_probe";
LIVE_PROBE = probe;

local since = get_time();
local blocks, captures = {0, 0}, {0, 0};

local function team_of(pid)
	local t = pid ~= nil and get_team(pid) or nil;
	return (t == 1 or t == 2) and t or nil;
end

function probe.after.on_block_action(pid, pos, type)
	local t = team_of(pid);
	if (t ~= nil and type == 0) then blocks[t] = blocks[t] + 1; end
end

function probe.after.on_block_line(pid, s, e)
	local t = team_of(pid);
	if (t ~= nil) then
		local n = math.max(math.abs(e.x - s.x), math.abs(e.y - s.y), math.abs(e.z - s.z)) + 1;
		blocks[t] = blocks[t] + n;
	end
end

function probe.after.capture_intel(pid)
	local t = team_of(pid);
	if (t ~= nil) then captures[t] = captures[t] + 1; end
end

register(probe);

function live_report()
	log("LIVE t=%d blocks %d %d captures %d %d", get_time() - since,
		blocks[1], blocks[2], captures[1], captures[2]);
end

function live_positions()
	local out = {};
	for i in piditer(PID_BROADCAST) do
		if (is_alive(i)) then
			local p = get_position(i);
			out[#out + 1] = string.format("%d:%d:%.1f:%.1f:%.1f", i, get_team(i), p.x, p.y, p.z);
		end
	end
	log("POS %s", table.concat(out, " "));
end

local function solid(x, y, z)
	if (x < 0 or y < 0 or x > 511 or y > 511 or z > 63) then return true; end
	if (z < 0) then return false; end
	return is_solid({x = x, y = y, z = z});
end

local function ground_at(x, y)
	local z = 62;
	if (not solid(x, y, 62)) then return 63; end
	while (z > 0 and solid(x, y, z - 1)) do z = z - 1; end
	return z;
end

function live_ground(x, y)
	log("GROUND %d %d %d", x, y, ground_at(x, y));
end

local function floor_ok(x, y, z)
	return solid(x, y, z) and not solid(x, y, z - 1) and not solid(x, y, z - 2) and not solid(x, y, z - 3);
end

function live_climb(x, y, z, r)
	r = r or 64;
	if (not floor_ok(x, y, z)) then log("CLIMB no 0 (nowhere to stand on it)"); return; end
	local key = function(a, b, c) return (c * 512 + b) * 512 + a; end
	local seen, queue, head = {[key(x, y, z)] = 0}, {{x, y, z}}, 1;
	local S = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
	while (head <= #queue) do
		local p = queue[head]; head = head + 1;
		local d = seen[key(p[1], p[2], p[3])];
		if (p[3] >= ground_at(p[1], p[2])) then
			log("CLIMB yes %d", d);
			return;
		end
		for _, s in ipairs(S) do
			local nx, ny = p[1] + s[1], p[2] + s[2];
			if (math.abs(nx - x) <= r and math.abs(ny - y) <= r) then
				-- walking the way back down from the spot: the floor before
				-- this one on the way up is at most one voxel lower (a body
				-- climbs one), or up to two higher (a drop)
				for nz = p[3] - 2, p[3] + 1 do
					local k = key(nx, ny, nz);
					if (seen[k] == nil and nz >= z and floor_ok(nx, ny, nz)) then
						seen[k] = d + 1;
						queue[#queue + 1] = {nx, ny, nz};
					end
				end
			end
		end
	end
	log("CLIMB no %d (no way down to the ground within %d)", #queue, r);
end
