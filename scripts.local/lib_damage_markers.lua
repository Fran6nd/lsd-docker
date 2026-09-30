-- lib_damage_markers.lua -- The Damage Markers protocol extension
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Speaks aosprotocol's Damage Markers extension (id 0x20, version 1):
-- when a hit lands, the server tells whoever landed it how much it took
-- off and who took it, so the client can float the number over that
-- player. That is the whole extension -- one server-to-client packet,
-- three fields, no state on either end.
--
-- NO SUB-PACKETS AT ALL, which is rare enough to say out loud:
-- [0x60][player id][hit amount]. There is no client-to-server form and
-- nothing is retained between packets, so there is nothing to clear on
-- a disconnect and nothing to re-send after a map change. Compare
-- lib_teamplay, whose marks are state held per target and which
-- therefore has a Config, a ready hook and a map-load resend; none of
-- that has an equivalent here, and none of it is missing by oversight.
--
-- Nothing in LSd's core knows about any of this. PacketTypeExtensionInfo
-- is declared in protocol.h:804 and the ExtensionID enum lives at :916 --
-- which names 0, 1 and the packetless ones, and nothing near 0x20 --
-- while nothing in funcs_packetrecv.c, funcs_send.c, main.c or lua.c
-- ever touches packet 0x60. So the negotiation is unclaimed, and lib_ext
-- claims it for every extension at once. This module owns packet 0x60
-- and nothing else; load lib_ext before it.
--
-- API (globals):
--   damage_markers_supported(pid)   -> true once ext 0x20 is agreed
--   damage_markers_show(viewer, target, amount) -> true if it went out
--        float `amount` over `target` on `viewer`'s screen. A negative
--        amount is a heal; the client draws it as one.
--
-- WHAT THE NUMBER IS. The spec asks for the damage the server applied,
-- worked out before the health update, so that a hit for 50 on a man
-- with 20 left reads 50 and not 20 -- the shooter is told what they
-- did, not what was left to do it to. That is why this sends the
-- requested amount rather than the difference it measures: the
-- difference is only ever asked *whether* it moved, never by how much.
--
-- Whether it landed is asked separately, because "the damage the server
-- applied" has to mean applied. god.lua swallows a damage_player whole
-- and world_editor.lua does the same while edit mode is on, and a
-- marker for damage that never landed is a lie told to the one player
-- in a position to notice.
--
-- The question is put to set_hp and not to the HP. damage_player is
-- set_hp followed by a kill if that left them at zero (main.c:1329-1334),
-- so the set_hp is the moment the damage exists and the kill is
-- everything that happens next -- and what happens next can be
-- anything, because kill() is the hook a mode respawns out of.
-- hostage.lua puts its hostage straight back on its post and the Fall
-- catches a faller and patches it up, both from inside the kill, and
-- both leave the victim at full health again. Comparing the HP across
-- the whole call would read those as "nothing happened" and eat the
-- marker for the one hit that mattered, the killing one. Watching the
-- set_hp instead asks only whether the damage was applied, which is the
-- question, and answers it before anybody can undo it.
--
-- WHERE IN THE CHAIN. mod.late, which is as close to the implementation
-- as a script gets (callchain_late in core.lua:50, run after every
-- ordinary mod.* hook). Anything that halves damage, caps it or cancels
-- it outright hooks the std chain and therefore runs above this, so the
-- amount that arrives here is the amount that is about to be handed to
-- set_hp -- which is the number the shooter is owed. Hooking higher
-- would report what was asked for rather than what was done. set_hp and
-- set_hp_directional are hooked in the same chain and for the same
-- reason: whatever the std chain does to them has already been done by
-- the time it gets here.
--
-- WHAT THIS DOES NOT DO: anything for clients that don't speak it. A
-- client that does not name ext 0x20 never gets a packet 0x60. There is
-- no fallback and there should not be one -- a floating number over a
-- body is not something a chat line approximates.
local mod = init_mod();

local EXT_ID = 0x20;
local EXT_VERSION = 1;

-- Damage Markers. The packet id is 64 + the extension id, so 0x60.
local PKT = 64 + EXT_ID;

-- The packet length is what names the type of the Hit Amount, so the
-- three encodings are three whole-packet lengths and there is no room
-- to disagree about which one is in use:
--
--   3 bytes  [0x60][pid][UByte]                0 .. 255
--   4 bytes  [0x60][pid][LE int16]        -32768 .. 32767
--   6 bytes  [0x60][pid][LE int32]         the rest
--
-- A client drops any other length, which makes 5 bytes -- a 24-bit
-- anything -- not a shortcut but a dropped packet. Only these three.
local U8_MAX = 255;
local I16_MIN, I16_MAX = -32768, 32767;
local I32_MIN, I32_MAX = -2147483648, 2147483647;

-- Hook damage_player/damage_player_directional and send a marker for
-- every hit that lands. Off leaves the wire silent and the API below
-- working, for a server that would rather decide each marker itself.
getcfg("damage_markers_auto", true);
-- Whether damage a player did to themselves gets a marker: their own
-- grenade, a fall (fall_damage.lua calls damage_player(i, dmg, 4, i)),
-- drowning. The dealer and the taker are the same man, so the number
-- floats over a body he is standing inside and generally cannot see.
-- Harmless either way; on, because a number that appears when you hit
-- the ground is information, and one that never appears is a client
-- that looks broken.
getcfg("damage_markers_self", true);
-- Log every marker sent and every reason one wasn't. Noisy; off unless
-- you are asking why a client is showing nothing.
getcfg("damage_markers_debug", false);
-- (Which clients are new enough to be told about extensions at all is
-- lib_ext's ext_min_major/minor/patch, since it is one announcement for
-- every extension and cannot be per-module.)

-- Whether this client and this server have both named ext 0x20 at
-- version 1. lib_ext holds the agreement -- one table for every
-- extension, keyed by the pid it belongs to and dropped when that pid
-- does -- so there is nothing to keep here beyond asking it.
local function negotiated(pid)
	return ext_supported ~= nil and ext_supported(pid, EXT_ID) ~= nil;
end

--============================== BYTES ===============================--

-- Toward zero, which is what the server itself did with the number.
-- damage_player takes a Lua number and binds it to a C int
-- (luaawk.h:1959), and that conversion truncates rather than rounds --
-- so the shotgun's 4096/d2 falling out at 12.9 removes 12 HP, and a
-- marker reading 13 would be off by one against the health bar the
-- victim watched move. Same operation, same answer.
local function toward_zero(v)
	if (v >= 0) then
		return math.floor(v);
	end
	return math.ceil(v);
end

-- Little-endian two's complement out of arithmetic rather than out of
-- the FFI. LuaJIT is 5.1, so there is no string.pack (it arrived in
-- 5.3), and the obvious alternative -- write an int16_t and hand back
-- its bytes -- is only little-endian because x86 is. The modulo does it
-- in one line and says so on every host, which for two bytes is worth
-- more than the cast.
local function put_le(n, bytes)
	local out = {};

	n = n % (2^(8*bytes));
	for i = 1, bytes do
		out[i] = string.char(n % 256);
		n = math.floor(n / 256);
	end

	return table.concat(out);
end

-- The Hit Amount, in the narrowest of the three encodings that holds
-- it. Narrowest because the length *is* the type: there is no field
-- saying which one this is, so picking the smallest that fits is not an
-- optimisation, it is the only way the value and the type agree.
--
-- Note the unsigned byte comes first and covers 0..255 only. A -1 does
-- not fit it -- it is a heal, and a heal has to reach the client as a
-- signed short at least, or 255 points of healing is what gets drawn.
local function put_amount(n)
	if (n >= 0 and n <= U8_MAX) then
		return string.char(n);
	end
	if (n >= I16_MIN and n <= I16_MAX) then
		return put_le(n, 2);
	end
	return put_le(n, 4);
end

--=============================== API ================================--

function damage_markers_supported(pid)
	return negotiated(pid);
end

-- Float `amount` over `target` on `viewer`'s screen. Returns false
-- without sending anything for a viewer that has not negotiated the
-- extension, which is what makes this safe to call over bots and over
-- clients that never heard of it.
function damage_markers_show(viewer, target, amount)
	if (not negotiated(viewer)) then
		return false;
	end

	-- the Player ID is one byte, so a target outside a byte has no
	-- spelling in this packet at all. Fake pids run to 255 (check_nplid,
	-- lua.c:71-76) and fit; anything else is a caller's mistake and is
	-- refused rather than wrapped into a number naming somebody else.
	target = tonumber(target);
	if (target == nil or target ~= target
	    or target < 0 or target > 255 or target % 1 ~= 0) then
		return false;
	end

	amount = tonumber(amount);
	if (amount == nil or amount ~= amount) then
		return false; -- nil or NaN
	end

	-- infinities and anything past an int32 are clamped rather than
	-- refused: the amount is a quantity and the packet's widest field is
	-- an int32, so the honest thing to say about 1e9 of damage is the
	-- largest number that field can hold. Refusing would drop the
	-- marker for the one hit most worth a number over it.
	amount = toward_zero(amount);
	amount = math.max(I32_MIN, math.min(I32_MAX, amount));

	send_packet(viewer, string.char(PKT, target) .. put_amount(amount));

	if (damage_markers_debug) then
		log("lib_damage_markers: #%d told #%d took %d", viewer, target,
			amount);
	end

	return true;
end

--============================ THE HOOKS =============================--

-- The pid whose damage is in flight, and whether the set_hp that
-- applies it has happened yet. Two plain locals rather than a stack:
-- each damage_player saves what it found, sets its own, and puts the
-- old pair back, so a damage dealt from inside a kill hook nests
-- without either call seeing the other's answer -- and an error
-- unwinding past the restore leaves values the next damage_player
-- overwrites on the way in, rather than a stack that never rebalances.
local in_flight = nil;
local applied = false;

-- The first set_hp on the pid whose damage is in flight IS that damage:
-- it is the only one the C damage_player performs, and it performs it
-- before the kill. Clearing in_flight here is what keeps the rest out
-- -- the restock a respawn does, a mode healing the man back up -- so
-- the answer stays about the damage and not about the aftermath.
--
-- And it is the value about to be set against the value still there,
-- read here because here is the last place the old one exists. That
-- catches the two ways a damage_player does nothing without being
-- cancelled: a hit for zero, and a hit on a man already at zero, which
-- asks for -50 and gets the clamp (main.c:1302-1303) rather than a
-- change. Neither is worth a number over a body.
local function note(pid, hp)
	if (in_flight ~= pid) then
		return;
	end

	in_flight = nil;

	hp = toward_zero(hp);
	if (hp < 0) then
		hp = 0;
	end

	-- get_hp goes through check_plid (lua.c:60-65), which raises rather
	-- than returns on a pid past MAX_PLAYERS -- and a raise here would
	-- take the whole damage down with it. Nothing the core damages is
	-- out of range, so this is the guard for a caller that surprises us,
	-- and its answer is the safe one: no marker.
	applied = pid >= 0 and pid < MAX_PLAYERS and hp ~= get_hp(pid);
end

function mod.late.set_hp(pid, hp)
	note(pid, hp);
	mod.late.next.set_hp(pid, hp);
end

function mod.late.set_hp_directional(pid, hp, pos)
	note(pid, hp);
	mod.late.next.set_hp_directional(pid, hp, pos);
end

-- `hp` and not the change note() measured is what goes out: see the
-- header. The measurement answers whether, the request answers how much.
local function landed(target, hp, damager, hit)
	if (not damage_markers_auto) then
		return;
	end

	if (not hit) then
		if (damage_markers_debug) then
			log("lib_damage_markers: #%d -> #%d for %s applied nothing,"
				.. " no marker", damager, target, tostring(hp));
		end
		return;
	end

	if (damager == target and not damage_markers_self) then
		return;
	end

	damage_markers_show(damager, target, hp);
end

function mod.late.damage_player(pid, hp, type, damager)
	local outer_pid, outer_applied = in_flight, applied;
	in_flight, applied = pid, false;

	mod.late.next.damage_player(pid, hp, type, damager);

	local hit = applied;
	in_flight, applied = outer_pid, outer_applied;

	landed(pid, hp, damager, hit);
end

function mod.late.damage_player_directional(pid, hp, pos, type, damager)
	local outer_pid, outer_applied = in_flight, applied;
	in_flight, applied = pid, false;

	mod.late.next.damage_player_directional(pid, hp, pos, type, damager);

	local hit = applied;
	in_flight, applied = outer_pid, outer_applied;

	landed(pid, hp, damager, hit);
end

--============================= INTAKE ===============================--
-- There is no client-to-server form, so nothing may arrive on packet
-- 0x60 and anything that does is swallowed. Claimed rather than left
-- alone because the core would otherwise log every one as "Unknown
-- packet ID" crap (funcs_packetrecv.c:484) -- the id is this module's,
-- and the answer to a client sending on it is silence, not a log line
-- per packet. Returning 0 hands it to on_sane_packet, whose switch has
-- no default case, so it is dropped there having been dealt with here.
function mod.on_any_packet(pid, data)
	if (string.byte(data, 1) == PKT) then
		return 0;
	end

	return mod.next.on_any_packet(pid, data);
end

--============================ LIFECYCLE =============================--

-- Registering is also what re-announces. Whatever a client agreed with
-- the last copy of this module is not something the new copy has any
-- record of, and the client will not repeat itself -- so lib_ext sends
-- the list again to everybody connected, and their replies re-establish
-- the agreement.
--
-- No ready callback: there is nothing this extension has to say to a
-- client that has just negotiated. The first packet it ever sends is
-- the first hit somebody lands.
function mod.on_load()
	if (ext_register == nil) then
		error("lib_damage_markers needs lib_ext loaded first "
			.."(config.lua loads it, or: lsdctl <instance> load lib_ext "
			.."lib_damage_markers)", 0);
	end

	ext_register("lib_damage_markers", EXT_ID, EXT_VERSION, nil);
end

-- Everything this module put in the global table, taken back out again.
--
-- Unloading a module does not undo its globals -- the functions keep
-- working, closed over the state of a module nothing is calling any
-- more -- and consumers ask "is damage_markers_show nil?" to find out
-- whether the extension is available at all. Left behind, those names
-- answer yes forever and the guard is dead code.
--
-- The list is exhaustive on purpose: a name added to the API above and
-- forgotten here outlives its own module, and goes on answering for it.
local EXPORTS = {
	"damage_markers_supported",
	"damage_markers_show",
};

function mod.on_unload()
	if (ext_unregister ~= nil) then
		ext_unregister(EXT_ID);
	end

	for _,name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
