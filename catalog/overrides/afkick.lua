-- afkick.lua -- Automatically prune abandoned players
-- upstream: lsd/scripts/afkick.lua fnv1a32 e9afcfe0 (tests/overrides_test.lua)
local mod = init_mod();

local kicked_msg = {
	en="%(name) was kicked: AFK"
}

local warn_msg = {
	en="You will be automatically AFK-kicked in %(time) s"
}

getcfg("afkick_time_kick", 30*60);
getcfg("afkick_time_warn", 29*60);
getcfg("afkick_time_limbo", 2*60);

local afktm = {};
local nextpid = {kick=nil, warn=nil, limbo=nil};

local function bumpnext(timer, pid)
	local next = nextpid[timer] or pid;

	if (afktm[next].timer ~= timer) then
		next = nil;

		for i in piditer(PID_BROADCAST) do
			if (afktm[i].timer == timer) then
				next = i;
				pid = next;
				goto diffpid;
			end
		end

		goto endfunc;
	end

	::diffpid::
	if (next == pid) then
		for i in piditer(PID_BROADCAST) do
			if (afktm[i].timer == timer and afktm[i].tm < afktm[next].tm) then
				next = i;
			end
		end
	end

	::endfunc::
	nextpid[timer] = next;
end

local function bump_timer(pid, timer)
	afktm[pid].timer = timer or "warn";
	bumpnext("warn", pid);
	bumpnext("kick", pid);
	bumpnext("limbo", pid);
end

-- (lsd-docker) A bot is never away from its keyboard: it has no timer
-- ("bot" is none of the three), set once, and its inputs -- hundreds a
-- second in a fleet -- cost nothing here. Before, each one walked every
-- player three times (bumpnext).
local function exempt(pid)
	if (bot_is_bot == nil or not bot_is_bot(pid)) then
		return false;
	end
	if (afktm[pid] == nil or afktm[pid].timer ~= "bot") then
		afktm[pid] = afktm[pid] or {};
		afktm[pid].tm = math.huge;
		bump_timer(pid, "bot");
	end
	return true;
end

local function bump_afktm(pid, timer)
	if (exempt(pid)) then
		return;
	end
	afktm[pid] = afktm[pid] or {};
	afktm[pid].tm = get_time();
	bump_timer(pid, timer or "warn");
end

-- TODO: don't trust ENet disconnect to handle the big tickloop robustly
local function handle_timer(timer, pid)
	if (timer == "warn") then
		bump_timer(pid, "kick");

		if (afkick_time_warn < afkick_time_kick) then
			l10n_send_chat(pid, warn_msg, {time=afkick_time_kick-afkick_time_warn});
			return;
		end
	end

	if (timer ~= "limbo") then
		l10n_send_chat(PID_BROADCAST, kicked_msg, {name=get_name(pid)});
	end

	disconnect(pid, 2);
end

function mod.after.tick()
	local now = get_time();

	for timer, next in pairs(nextpid) do
		local time = _G["afkick_time_"..timer];
		if (next and now >= afktm[next].tm + time) then
			for i in piditer(PID_BROADCAST) do
				if (afktm[i].timer == timer and now >= afktm[i].tm + time) then
					handle_timer(timer, i);
				end
			end
		end
	end
end

function mod.on_load()
	for i in piditer(PID_BROADCAST) do
		bump_afktm(i, is_joined(i) and "warn" or "limbo");
	end
end

-- on_orientation isn't hooked here since SDL2 (non-compat) openspades users on X have their mouse movement stolen

function mod.after.on_successful_connect(pid)
	bump_afktm(pid, "limbo");
end

function mod.after.boot_players_to_limbo()
	for i in piditer(PID_BROADCAST) do
		bump_afktm(i, "limbo");
	end
end

-- TODO: can i pass the same function ptr to all of these?
function mod.after.on_chat(pid)
	bump_afktm(pid);
end

function mod.after.on_reload(pid)
	bump_afktm(pid);
end

function mod.after.on_color_change(pid)
	bump_afktm(pid);
end

function mod.after.on_mouse_input(pid)
	bump_afktm(pid);
end

function mod.before.on_move_input(pid, bitmask)
	-- In some cases betterspades can steal the shift key
	if (bit.band(bit.bxor(get_inputs(pid), bitmask), 127) ~= 0) then
		bump_afktm(pid);
	end
end

function mod.after.on_join(pid)
	bump_afktm(pid);
end

function mod.after.on_switch(pid)
	bump_afktm(pid);
end

function mod.after.on_disconnect(pid)
	bump_timer(pid, afktm[pid].timer);

	-- If pid is the nextpid for any timer *after* bumping them,
	-- that means pid is the only pid for that timer and therefore
	-- we can just set that timer's nextpid to nil.
	for x,y in pairs(nextpid) do
		if (y == pid) then
			nextpid[x] = nil;
		end
	end
end

return mod;
