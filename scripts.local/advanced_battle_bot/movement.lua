-- advanced_battle_bot/movement.lua -- reactive navigation, in the
-- spirit of bot_standard's try_unstick + the original's spadeing/digy.
-- A bot walks straight at its destination; when it stops making
-- progress it escalates: a real jump (clears a 1-block step), then
-- spades straight through whatever is still in the way (any taller
-- wall). In water it holds jump to swim up to the shore. No teleport
-- tricks -- those caused the "little hop then rocket up" jump.
-- (The original's BOT_junkai_route waypoint patrol needs map-authored
-- route graphs and is not ported; this local handling works anywhere.)
require "lib_bulk_destroy"; -- bdestroy_* for the dig

local M = {};
local floor, sqrt = math.floor, math.sqrt;

local STUCK_CHECK = 0.5;  -- seconds between progress checks
local STUCK_MOVE = 0.7;   -- blocks of progress that count as moving
local JUMP_GRACE = 0.6;   -- let a jump land before escalating to digging

-- spade the wall ahead from head to feet
local function dig(pid, p)
	local o = get_orientation(pid);
	local h = sqrt(o.x*o.x + o.y*o.y);
	if (h < 0.001) then return; end
	local fx, fy = floor(p.x + o.x/h), floor(p.y + o.y/h);
	local iz = floor(p.z);
	for _, z in ipairs({iz-1, iz, iz+1, iz+2}) do
		if (z >= 0 and z < 62 and is_solid({x=fx, y=fy, z=z})) then
			bdestroy_block_action({x=fx, y=fy, z=z}, 1);
		end
	end
	bdestroy_finish();
end

function M.navigate(pid, d, dest, now, dt)
	bot_look_horizontal(pid, dest);

	local p = get_position(pid);
	local ix, iy, iz = floor(p.x), floor(p.y), floor(p.z);
	-- z is down: iz+2/iz+3 catch the floor below the feet
	local grounded = is_solid({x=ix, y=iy, z=iz+2}) or is_solid({x=ix, y=iy, z=iz+3});

	local jump, crouch = false, false;

	-- in water / off a ledge: hold jump to swim/scramble upward
	if (not grounded and not is_airborne(pid)) then
		jump = true;
	end

	-- progress check
	d.jump_grace = math.max(0, (d.jump_grace or 0) - dt);
	d.stuck_t = (d.stuck_t or 0) + dt;
	if (d.stuck_t >= STUCK_CHECK) then
		d.stuck_t = 0;
		local o = d.pos_check or p;
		d.moved = sqrt((p.x-o.x)^2 + (p.y-o.y)^2) >= STUCK_MOVE;
		d.pos_check = p;
		if (d.moved) then
			d.jumped = false;
			d.jump_grace = 0;
		end
	end

	-- stuck on the ground: jump once (a step), then dig (a wall)
	if (not d.moved and grounded and d.jump_grace <= 0) then
		if (not d.jumped) then
			d.jumped = true;
			d.jump_grace = JUMP_GRACE;
			jump = true;
		else
			d.jumped = false;
			if (now - (d.digtime or 0) > 0.4) then
				d.digtime = now;
				dig(pid, p);
			end
		end
	end

	-- crouch at the apex of a climb-jump: pulling the legs up is what
	-- lets an AoS jump clear a full 2 blocks instead of only ~1.5
	if (d.jump_grace > 0 and is_airborne(pid)) then
		crouch = true;
	end

	bot_walk(pid, {forward=true, sprint = not crouch, jump=jump, crouch=crouch});
end

return M;
