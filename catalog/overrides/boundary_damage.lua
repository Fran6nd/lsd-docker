-- boundary_damage.lua -- Punish players who step too far out of line
-- upstream: lsd/scripts/boundary_damage.lua fnv1a32 22637705 (tests/overrides_test.lua)
--
-- lsd-docker's copy of upstream's (catalog/overrides/README): a map's
-- boundary_damage written over several lines -- "'boundary_damage' :"
-- with the { on the next one, as plenty of maps on the web have it --
-- came out of get_ext as an empty string (it takes the rest of that line
-- only), so every edge was nil, and the tick hook compared positions
-- with nil every tick: the error ended each tick there, and every
-- script's tick chained after this one -- bots, blasts, effects --
-- stopped with it. So the block is read whole, wherever it is, and a
-- boundary missing any edge or the damage is no boundary at all.
local mod = init_mod();
local damage_timer = pid_spawn_table(nil);

local function in_range(pid, tbl)
	local pos = get_position(pid);

	return
		pos.x >= tbl.left  and
		pos.x <= tbl.right and
		pos.y >= tbl.top   and
		pos.y <= tbl.bottom;
end

function mod.after.pyscrape_ext(scrape, text, meta)
	local str = scrape.get_ext(text, "boundary_damage");

	if (str == nil) then
		return;
	end

	-- the { ... } block, over as many lines as it takes
	if (not string.find(str, "%d")) then
		str = string.match(text, "[\"']boundary_damage[\"']%s*:%s*(%b{})") or str;
	end

	-- TODO: maybe rewrite this to use lpeg if you don't hate yourself
	--       . . . just make sure it still parses that handful of broken
	--       maps i remember some time ago

	meta.boundary_damage = {
		left   = tonumber(str:match("['\"]left['\"].-:.-(%d+)")),
		right  = tonumber(str:match("['\"]right['\"].-:.-(%d+)")),
		top    = tonumber(str:match("['\"]top['\"].-:.-(%d+)")),
		bottom = tonumber(str:match("['\"]bottom['\"].-:.-(%d+)")),
		damage = tonumber(str:match("['\"]damage['\"].-:.-(%d+)"))
	};

	local b = meta.boundary_damage;
	if (b.left == nil or b.right == nil or b.top == nil or b.bottom == nil or b.damage == nil) then
		log("boundary_damage: the map's boundary_damage is incomplete; none on this map");
		meta.boundary_damage = nil;
	end
end

function mod.after.tick()
	local tbl = get_map_meta().boundary_damage;
	if (tbl == nil) then
		return;
	end

	local now = get_time();

	for i in piditer(PID_BROADCAST) do
	if (
		is_alive(i) and
		(damage_timer[i] == nil or now >= damage_timer[i])
	) then
		if (not in_range(i, tbl)) then
			local basetime = damage_timer[i] or now;
			damage_timer[i] = basetime + 1;

			damage_player(i, tbl.damage, 4, i);
		else
			damage_timer[i] = nil;
		end
	end
	end
end

return mod;
