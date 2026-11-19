-- map_sources_test.lua -- what `map add` makes of what was pasted
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit tests/map_sources_test.lua      (from the repository root)

package.path = "catalog/core/?.lua;" .. package.path;

local failures, checks = 0, 0;
local function check(ok, what, detail)
	checks = checks + 1;
	if (ok) then print("  PASS " .. what) else
		failures = failures + 1;
		print("  FAIL " .. what .. (detail and ("  (" .. tostring(detail) .. ")") or ""));
	end
end
local function eq(got, want, what)
	check(got == want, what, string.format("got %s, want %s", tostring(got), tostring(want)));
end

local M = require "map_sources";
local S = M.sources();

print("\n1. aos.party, built in");
for _, input in ipairs({"https://aos.party/view/864", "https://aos.party/view/864/",
                        "https://aos.party/download/864/vxl", "aos.party:864",
                        "  https://aos.party/download/864/txt  "}) do
	local r = M.resolve(input, S);
	check(r and r[1].url == "https://aos.party/download/864/vxl"
		and r[2] and r[2].url == "https://aos.party/download/864/txt" and r[2].optional,
		input .. " -> the map and its metadata", r and r[1].url);
end
eq(M.resolve("aos.party:864", S)[1].source, "aos.party", "and says where from");

print("\n2. other sources");
local extra = {{name = "maps.example", view = "https://maps.example/m/%(id)",
	vxl = "https://maps.example/get/%(id).vxl"}};
local S2, bad = M.sources(extra);
eq(#S2, #M.BUILTIN + 1, "the operator's source joins the built-in ones");
eq(#bad, 0, "and is well formed");
local r = M.resolve("https://maps.example/m/castle-2", S2);
eq(r and r[1].url, "https://maps.example/get/castle-2.vxl", "a page of another source");
eq(r and #r, 1, "with no metadata when it has none");
eq(M.resolve("maps.example:castle-2", S2)[1].url, "https://maps.example/get/castle-2.vxl",
	"name:id for it too");
local _, bad2 = M.sources({{name = "broken", vxl = "https://x/no-id"}});
eq(#bad2, 1, "a source without %(id) in its vxl is refused");
local S3 = M.sources({{name = "aos.party", vxl = "https://mirror.example/%(id).vxl"}});
eq(#S3, #M.BUILTIN, "a source of the same name replaces the built-in");
eq(M.resolve("aos.party:7", S3)[1].url, "https://mirror.example/7.vxl", "and is used");

print("\n3. anything else");
eq(M.resolve("https://example.org/maps/Foo.vxl", S)[1].url, "https://example.org/maps/Foo.vxl",
	"any other URL is fetched as it is");
eq(M.resolve("/tmp/Foo.vxl", S)[1].file, "/tmp/Foo.vxl", "a path is a local file");
check(M.resolve("nowhere:12", S) == nil, "an unknown name:id is refused");
check(M.resolve("", S) == nil, "nothing is refused");

print("\n4. names and contents");
eq(M.disposition_name('HTTP/2 200\r\ncontent-disposition: attachment; filename="Remus.vxl";\r\n'),
	"Remus.vxl", "Content-Disposition, quoted");
eq(M.disposition_name("Content-Disposition: attachment; filename=Foo.txt\r\n"), "Foo.txt", "unquoted");
eq(M.disposition_name("content-type: text/html\r\n"), nil, "none");
eq(M.safe_name("Remus.vxl"), "Remus.vxl", "a plain name");
eq(M.safe_name("../../etc/evil.vxl"), "evil.vxl", "a path keeps only its last part");
eq(M.safe_name("My Map!.vxl"), "My_Map_.vxl", "odd characters become _");
check(M.safe_name(".hidden.vxl") == nil, "a hidden name is refused");
check(M.safe_name("vxl") == nil, "a name without .vxl is refused");
check(M.looks_like_vxl("\0>>\0", M.MIN_VXL), "a map's start, big enough");
check(not M.looks_like_vxl("<!DOCTYPE html>", 3000000), "an HTML page is refused");
check(not M.looks_like_vxl("\0>>\0", 1000), "too small is refused");

print("\n3. hosting.dgd.cx: maps by file name, spaces and all");
local S = M.sources();
local p = M.resolve("hosting.dgd.cx:Normandie", S);
eq(p and p[1].url, "https://hosting.dgd.cx/all_maps/allmaps/Normandie.vxl", "name:id, the map");
eq(p and p[2].url, "https://hosting.dgd.cx/all_maps/allmaps/Normandie.txt", "and its .txt");
p = M.resolve("hosting.dgd.cx:Rocket Island", S);
eq(p and p[1].url, "https://hosting.dgd.cx/all_maps/allmaps/Rocket%20Island.vxl", "a space is URL-encoded");
p = M.resolve("https://hosting.dgd.cx/map-search?map=Rocket%20Island", S);
eq(p and p[1].url, "https://hosting.dgd.cx/all_maps/allmaps/Rocket%20Island.vxl", "its map page, pasted");
p = M.resolve("https://hosting.dgd.cx/all_maps/allmaps/Ha%20Long%20Babel.vxl", S);
eq(p and p[2] and p[2].url, "https://hosting.dgd.cx/all_maps/allmaps/Ha%20Long%20Babel.txt", "its download, pasted: the .txt comes too");
eq(M.safe_name("Rocket%20Island.vxl"), "Rocket_Island.vxl", "an encoded name makes a plain file name");
eq((M.resolve("aos.party:864", S))[1].url, "https://aos.party/download/864/vxl", "aos.party unchanged");

print("\n4. listing a source's maps for a random pick");
local aos, dgd;
for _, src in ipairs(S) do
	if (src.name == "aos.party") then aos = src; elseif (src.name == "hosting.dgd.cx") then dgd = src; end
end
local r = M.list_request(dgd, "ctf");
eq(r and r.method, "POST", "hosting.dgd.cx lists by its search API");
eq(r and r.body, '{"query":"","game_mode":"CTF","page":0}', "ctf maps: its CTF mode");
eq(M.list_request(dgd, "babel").body, '{"query":"babel","game_mode":"","page":0}', "babel maps: by name");
eq(M.list_request(aos, "babel").url, "https://aos.party/?q=babel", "aos.party by its search page");
eq(M.list_request(aos, "parkour"), nil, "a kind a source does not list: nothing to ask");
eq(M.list_request({name = "x", vxl = "https://x/%(id)"}, "ctf"), nil, "a source that cannot list: nothing to ask");
local ids = M.list_ids(dgd, '{"maps":[{"file_name":"Normandie.vxl"},{"file_name":"Rocket Island.vxl"},'
	.. '{"file_name":"Hosting/Babel/maps/x.vxl"},{"file_name":"Normandie.vxl"}]}');
eq(table.concat(ids, "|"), "Normandie|Rocket Island", "its ids, each once, the maps kept elsewhere left out");
ids = M.list_ids(aos, '<a href="/view/864">x</a><a href="/view/12">y</a><a href="/view/864">z</a>');
eq(table.concat(ids, "|"), "864|12", "aos.party's map ids from its page");
eq(#M.list_ids(dgd, nil), 0, "no answer: no ids");

print(string.format("\n%d checks, %d failed", checks, failures));
os.exit(failures > 0 and 1 or 0);
