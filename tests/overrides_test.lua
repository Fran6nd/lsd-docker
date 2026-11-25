-- overrides_test.lua -- an override never drifts from upstream unseen
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
--   luajit tests/overrides_test.lua      (from the repository root)
--
-- catalog/overrides/<file>.lua is upstream's lsd/scripts/<file>.lua,
-- patched, and copied over it at every start (image/entrypoint.sh). A
-- copy says nothing when upstream's file changes under it: the fix
-- upstream made is silently undone. So each override names, in a line
--
--   -- upstream: lsd/scripts/<file>.lua fnv1a32 <8 hex digits>
--
-- the upstream file it was made from, by a checksum of its bytes, and
-- this test fails the moment lsd/scripts/<file>.lua is not that file any
-- more (dev/bump-lsd.sh runs it). Then: re-apply the patch onto the new
-- upstream (git -C lsd diff OLD..NEW -- scripts/<file>.lua), and write
-- the new checksum this test prints into the line.
local bit = require("bit");

local failures, checks = 0, 0;
local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then print("  PASS " .. what) else
		failures = failures + 1;
		print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or ""));
	end
end

-- FNV-1a, 32 bits, over the file's bytes. The prime is 2^24 + 0x193,
-- multiplied in two parts so no product passes a double's 53 bits.
local function fnv1a32(data)
	local h = 0x811c9dc5;
	for i = 1, #data do
		h = bit.bxor(h, data:byte(i)) % 0x100000000;
		h = bit.tobit((h * 0x193) % 0x100000000 + bit.lshift(h, 24) % 0x100000000);
	end
	return bit.tohex(h);
end
assert(fnv1a32("a") == "e40c292c" and fnv1a32("foobar") == "bf9cf968", "fnv1a32 itself");

local function slurp(path)
	local fh = io.open(path, "rb");
	if (fh == nil) then return nil; end
	local s = fh:read("*a");
	fh:close();
	return s;
end

local files = {};
for f in io.popen("ls catalog/overrides/*.lua"):lines() do files[#files + 1] = f; end
check(#files > 0, "there are overrides");

for _, path in ipairs(files) do
	local name = path:match("([^/]+)$");
	local own = slurp(path);
	local up = slurp("lsd/scripts/" .. name);
	local named, sum = own:match("%-%- upstream: (lsd/scripts/%S+) fnv1a32 (%x+)");
	if (up == nil) then
		check(named == nil, name .. ": no upstream file, and it names none", named);
	else
		check(named == "lsd/scripts/" .. name, name .. ": names the upstream file it was made from",
			"add: -- upstream: lsd/scripts/" .. name .. " fnv1a32 " .. fnv1a32(up));
		if (named ~= nil) then
			check(sum == fnv1a32(up), name .. ": upstream's file is still the one it was made from",
				"upstream is now fnv1a32 " .. fnv1a32(up) .. ": re-apply the patch, then write that");
		end
	end
end

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures == 0 and 0 or 1);
