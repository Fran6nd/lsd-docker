-- link_ffi_test.lua: the header as LuaJIT reads it. Run from the repo root:
--   luajit bot/tests/link_ffi_test.lua
-- (after `make -C bot test`, which builds libbotlink.so and link_test)
local ffi = require("ffi")

local checks, failed = 0, 0
local function check(c, what)
	checks = checks + 1
	if not c then failed = failed + 1; print("FAIL " .. what) end
end

local function slurp(p)
	local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close(); return s
end

local src = slurp("bot/link/botlink.h"):gsub("[^\n]*", function(l)
	if l:match("^%s*#") then return "" end
end)
ffi.cdef(src)

local lib = ffi.load("bot/build/libbotlink.so")
check(lib.bl_layout_ok() == 1, "bl_layout_ok")

-- sizes: what the C compiler says, printed by link_test
local p = assert(io.popen("bot/build/tests/link_test --sizes"))
for line in p:lines() do
	local name, n = line:match("^(%S+) (%d+)$")
	check(ffi.sizeof(name) == tonumber(n), name .. ": ffi " .. ffi.sizeof(name) .. " vs C " .. n)
end
p:close()
check(ffi.sizeof("bl_file") == 542880, "bl_file size")

local path = os.tmpname()
local f = lib.bl_create(path)
check(f ~= nil, "bl_create")
check(f.header.magic == 0x4B4E4C42, "magic")

local e = lib.bl_attach(path)
check(e ~= nil, "bl_attach")

-- a world through the seqlock
lib.bl_world_begin(f)
f.world.tick = 77
f.world.players[5].hp = 99
lib.bl_world_end(f)
local w = ffi.new("bl_world")
check(lib.bl_world_read(e, w, 10) == 1, "world read")
check(w.tick == 77 and w.players[5].hp == 99, "world content")

-- an event out, an action back
local ping = ffi.new("bl_ev_ping")
ping.pos.x, ping.pos.y, ping.pos.z = 1.5, 2.5, 3.5
ffi.copy(ping.reason, "over there")
check(lib.bl_push(f.events, 8, 3, ping, ffi.sizeof(ping)) == 1, "push")
local buf = ffi.new("uint8_t[?]", 1024)
local n = lib.bl_pop(e.events, buf)
check(n == 4 + ffi.sizeof("bl_ev_ping"), "pop size")
local rec = ffi.cast("bl_record *", buf)
check(rec.size == n and rec.type == 8 and rec.pid == 3, "record header")
local got = ffi.cast("bl_ev_ping *", buf + 4)
check(got.pos.x == 1.5 and got.pos.z == 3.5 and ffi.string(got.reason) == "over there", "payload")
check(lib.bl_pop(e.events, buf) == 0, "ring empty")

local blk = ffi.new("bl_ac_block", { x = -3, y = 4, z = 50, action = lib.BL_B_DESTROY })
check(lib.bl_push(e.actions, lib.BL_AC_BLOCK, 12, blk, ffi.sizeof(blk)) == 1, "push action")
n = lib.bl_pop(f.actions, buf)
local b2 = ffi.cast("bl_ac_block *", buf + 4)
check(n == 12 and b2.x == -3 and b2.z == 50, "action back")

lib.bl_close(e); lib.bl_close(f)
os.remove(path)
print(string.format("%d checks, %d failed", checks, failed))
os.exit(failed == 0 and 0 or 1)
