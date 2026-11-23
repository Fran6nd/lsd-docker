-- map_sources.lua -- Where maps come from, and what was pasted
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- Pure Lua, no server API: lsdctl's `map add` and the setup wizard use
-- it, and the tests drive it directly.
--
-- A SOURCE is a site that publishes maps by id, as aos.party does:
--
--   {name = "aos.party",
--    view = "https://aos.party/view/%(id)",          -- a map's page
--    vxl  = "https://aos.party/download/%(id)/vxl",  -- the map
--    txt  = "https://aos.party/download/%(id)/txt"}  -- its metadata
--
-- aos.party and hosting.dgd.cx are built in -- the second names a map by
-- its file name, not a number, and is where a map is looked for when
-- aos.party is down -- and an operator adds more in the settings, as
-- `map_sources = [{name: ..., view: ..., vxl: ..., txt: ...}]`. `txt`
-- may be left out, for a site without metadata. An id may hold spaces
-- ("Rocket Island"): it is URL-encoded into the address.
--
-- WHAT MAY BE PASTED, and what it becomes (M.resolve):
--
--   https://aos.party/view/864          a source's page   -> vxl + txt
--   https://aos.party/download/864/vxl  a source's map    -> vxl + txt
--   aos.party:864                       name:id           -> vxl + txt
--   https://hosting.dgd.cx/map-search?map=Normandie       -> vxl + txt
--   hosting.dgd.cx:Rocket Island        an id with spaces -> vxl + txt
--   https://example.org/maps/Foo.vxl    any other URL     -> that file
--   /path/to/Foo.vxl                    a local file      -> that file
--
-- LISTING. A source may also say how to list its maps, for a random
-- pick: `list`, a request (url, and method/body for a POST), filled in
-- with %(query) and %(mode) from the kind of game asked for -- "ctf"
-- (ctf, tdm, the bots modes: two bases, a field between) or "babel" --
-- and `ids`, a Lua pattern capturing a map's id from the answer:
--
--   list = {url = "https://aos.party/?q=%(query)",
--           ids = 'href="/view/(%d+)"',
--           kinds = {ctf = {query = ""}, babel = {query = "babel"}}}
--
-- M.list_request(source, kind) builds the request, M.list_ids(source,
-- text) reads the ids out of what came back. No map is named here: the
-- sites say what they have.
--
-- A download's name comes from the server's Content-Disposition when it
-- sends one (aos.party's /download/864/vxl is Remus.vxl), else from the
-- URL; either way it is checked (M.safe_name) before it names a file.
local M = {};

M.BUILTIN = {
	{name = "aos.party",
	 view = "https://aos.party/view/%(id)",
	 vxl = "https://aos.party/download/%(id)/vxl",
	 txt = "https://aos.party/download/%(id)/txt",
	 -- its search page; with no query, its newest maps
	 list = {url = "https://aos.party/?q=%(query)",
	         ids = 'href="/view/(%d+)"',
	         kinds = {ctf = {query = ""}, babel = {query = "babel"}}}},
	{name = "hosting.dgd.cx",
	 view = "https://hosting.dgd.cx/map-search?map=%(id)",
	 vxl = "https://hosting.dgd.cx/all_maps/allmaps/%(id).vxl",
	 txt = "https://hosting.dgd.cx/all_maps/allmaps/%(id).txt",
	 -- its search API, every match in one answer; the maps it keeps
	 -- elsewhere ("Hosting/...") are left out by the pattern
	 list = {url = "https://hosting.dgd.cx/api/search_maps_detailed", method = "POST",
	         content_type = "application/json",
	         body = '{"query":"%(query)","game_mode":"%(mode)","page":0}',
	         ids = '"file_name":"([^"/]+)%.vxl"',
	         kinds = {ctf = {query = "", mode = "CTF"}, babel = {query = "babel", mode = ""}}}},
};

-- The smallest a real .vxl can be: 512x512 columns, each at least a
-- 4-byte span header and one 4-byte colour. A generated flat map is
-- exactly this.
M.MIN_VXL = 512 * 512 * 8;

-- The built-in sources, then the operator's (from map_sources), a later
-- one of the same name replacing an earlier one. Malformed entries are
-- skipped and named in `bad`.
function M.sources(extra)
	local out, by_name, bad = {}, {}, {};
	local function add(s)
		if (type(s) ~= "table" or type(s.name) ~= "string" or s.name == ""
		    or type(s.vxl) ~= "string" or not string.find(s.vxl, "%(id)", 1, true)) then
			bad[#bad+1] = type(s) == "table" and tostring(s.name) or tostring(s);
			return;
		end
		if (by_name[s.name] ~= nil) then
			out[by_name[s.name]] = s;
		else
			out[#out+1] = s;
			by_name[s.name] = #out;
		end
	end
	for _, s in ipairs(M.BUILTIN) do add(s); end
	if (type(extra) == "table") then
		for _, s in ipairs(extra) do add(s); end
	end
	return out, bad;
end

-- %XX escapes undone, and done: an id is kept plain, and encoded only
-- where it goes into an address.
local function unescape(s)
	return (string.gsub(s, "%%(%x%x)", function(h) return string.char(tonumber(h, 16)); end));
end
local function escape(s)
	return (string.gsub(s, "[^%w_.~-]", function(c) return string.format("%%%02X", string.byte(c)); end));
end
M.unescape = unescape;

local function fill(template, id)
	local e = escape(id);
	return (string.gsub(template, "%%%(id%)", function() return e; end));
end

-- What an id may be: letters, digits, dash, underscore, dot -- and a
-- space, written as one or as %20.
local ID = "[%w_. -]+";
local ID_IN_URL = "[%w_.%%-]+";

-- A template as a pattern capturing the id: "%(id)" matches what an id
-- can be, everything else literally.
local function pattern(template)
	local p = string.gsub(template, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0");
	p = string.gsub(p, "%%%%%%%(id%%%)", "(" .. string.gsub(ID_IN_URL, "%%", "%%%%") .. ")");
	return "^" .. p .. "/?$";
end

local function downloads(s, id)
	local out = {{url = fill(s.vxl, id), kind = "vxl", source = s.name}};
	if (type(s.txt) == "string") then
		out[#out+1] = {url = fill(s.txt, id), kind = "txt", source = s.name, optional = true};
	end
	return out;
end

-- What to fetch for what was pasted: a list of {url=, kind=, source=,
-- optional=} or {file=} -- or nil and why.
function M.resolve(input, sources)
	if (type(input) ~= "string" or input == "") then
		return nil, "nothing to add";
	end
	input = string.gsub(input, "^%s+", "");
	input = string.gsub(input, "%s+$", "");

	for _, s in ipairs(sources) do
		-- name:id
		local id = string.match(input, "^" .. string.gsub(s.name, "%p", "%%%0") .. ":(" .. ID .. ")$");
		if (id ~= nil) then
			return downloads(s, id);
		end
		-- the source's own page or download
		for _, key in ipairs({"view", "vxl", "txt"}) do
			if (type(s[key]) == "string") then
				id = string.match(input, pattern(s[key]));
				if (id ~= nil) then
					return downloads(s, unescape(id));
				end
			end
		end
	end

	if (string.match(input, "^https?://")) then
		return {{url = input, kind = "any"}};
	end
	if (string.match(input, "^[%w_.-]+:" .. ID .. "$")) then
		return nil, "no map source called " .. string.match(input, "^([^:]+)");
	end
	return {{file = input}};
end

-- The request listing a source's maps for a kind of game ("ctf",
-- "babel"): {url=, method=, body=, content_type=}, or nil when the
-- source cannot list, or not that kind.
function M.list_request(s, kind)
	local l = type(s) == "table" and s.list;
	local k = type(l) == "table" and type(l.kinds) == "table" and l.kinds[kind];
	if (type(k) ~= "table" or type(l.url) ~= "string" or type(l.ids) ~= "string") then
		return nil;
	end
	local function fill_in(t, enc)
		return (string.gsub(t, "%%%((%w+)%)", function(key)
			local v = tostring(k[key] or "");
			return enc and escape(v) or (string.gsub(v, '["\\]', ""));
		end));
	end
	return {url = fill_in(l.url, true), method = l.method or "GET",
		body = l.body and fill_in(l.body, false), content_type = l.content_type};
end

-- The map ids in a listing's answer, each once, in order.
function M.list_ids(s, text)
	local out, seen = {}, {};
	if (type(text) ~= "string" or type(s.list) ~= "table") then
		return out;
	end
	for id in string.gmatch(text, s.list.ids) do
		id = unescape(id);
		if (not seen[id] and string.match(id, "^" .. ID .. "$")) then
			seen[id] = true;
			out[#out+1] = id;
		end
	end
	return out;
end

-- The filename a Content-Disposition header gives, or nil.
function M.disposition_name(headers)
	if (type(headers) ~= "string") then
		return nil;
	end
	local name;
	for line in string.gmatch(headers, "[^\r\n]+") do
		if (string.match(string.lower(line), "^content%-disposition:")) then
			name = string.match(line, 'filename%*?="([^"]+)"')
				or string.match(line, "filename%*?=([^;%s]+)");
		end
	end
	if (name ~= nil) then
		name = string.gsub(name, "^UTF%-8''", "");
	end
	return name;
end

-- A name fit to be a file in maps/: its last path part, letters, digits,
-- dot, dash and underscore only, ending in .vxl or .txt, not hidden.
-- Returns it, or nil and why.
function M.safe_name(name)
	if (type(name) ~= "string") then
		return nil, "no name";
	end
	name = string.match(unescape(name), "([^/\\]+)$") or "";
	name = string.gsub(name, "[^%w%._-]", "_");
	if (name == "" or string.sub(name, 1, 1) == ".") then
		return nil, "no usable name";
	end
	if (not string.match(name, "%.vxl$") and not string.match(name, "%.txt$")) then
		return nil, string.format("%s is not a .vxl or .txt", name);
	end
	return name;
end

-- Is this the start of a real .vxl, of this size? Refuses an HTML page
-- (an error, a login wall) and anything too small to hold a map.
function M.looks_like_vxl(head, size)
	if (type(size) ~= "number" or size < M.MIN_VXL) then
		return false, string.format("%s bytes is too small for a map", tostring(size));
	end
	local h = string.lower(string.gsub(head or "", "^%s+", ""));
	if (string.sub(h, 1, 1) == "<") then
		return false, "that is a web page, not a map";
	end
	return true;
end

return M;
