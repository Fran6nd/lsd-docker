-- lib_settings.lua -- A real settings file, in the format LSd already reads
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- config.lua is code: it decides which modules run, and a stray brace
-- in it stops the server. Settings are not that. They are values, they
-- belong to whoever is running the server rather than to whoever wrote
-- the module, and getting one wrong should be a complaint about a line
-- rather than a dead process.
--
-- So: a plain settings file next to config.lua.
--
--   # Night instead of day. The client draws full darkness.
--   daytime_night = True
--   daytime_resync = 300
--   masterlist_name = 'Fran6nd''s Hallway At Night'
--   ext_policy = {0x33: 'required', 0x32: 'required'}
--
-- THE FORMAT IS LSd's OWN, not a new one. LSd already reads declarative
-- `key = value` files: every AoS map carries a pyspades sidecar .txt,
-- and lib_pyscrape scrapes `name = 'x'`, `fog = (128, 232, 255)` and
-- `spawn_locations_blue = [(x, y, z)]` out of them. That is the format
-- an AoS operator already edits, and its value parsers already exist --
-- parse_str, parse_bool, split_tuple -- so this uses them rather than
-- inventing a second syntax with a second parser to maintain.
--
-- What lib_pyscrape does not have is a walker: its grep() knows a fixed
-- list of map keys and matches each by name. A settings file has keys
-- nobody knew in advance, so the line walker below is the piece this
-- adds. Values go to lib_pyscrape wherever it already has an opinion.
--
-- IT CHANGES NO MODULE. Not one line, anywhere. The whole mechanism is
-- core.lua's getcfg, which fills a global only if it is still nil
-- (core.lua:43-47) -- so applying the file to the globals BEFORE
-- anything loads means every getcfg in the server finds the operator's
-- value already there and leaves it alone. A module declares a setting
-- the way it always did and is configured from the file for free, which
-- is why a script dropped into scripts.local/ needs no wiring at all.
--
-- Which is also why this must load FIRST, before the group_* lines. A
-- value applied after a module has already defaulted its global is a
-- value that does nothing.
--
-- AND IT IS PORTABLE, which the .env is not. LSd's C core reads no
-- environment variables at all -- it takes -c and -p on argv
-- (main.c:1652-1672) -- so instances/<name>.env is an artifact of the
-- docker wrapper, invented by lsdctl and turned back into argv by
-- docker-entrypoint.sh:25. Nothing reads it when LSd runs natively.
-- This file is read by Lua, from the working directory beside
-- config.lua, so `./server -c config.lua` and the container see the
-- same settings.
--
-- IT NEVER WRITES ITSELF. The file is input. New settings are added to
-- it by  ./lsdctl <instance> settings --sync , on the host, when you
-- ask -- the server only ever says what it supports.
--
-- API (globals):
--   getcfg(key, default, doc)    core.lua's, plus an optional third
--        argument: what the setting means, in one line. This is how a
--        module exposes a setting rather than merely having one, and
--        it is what --sync writes into the file as a comment.
--   settings_file                path read, set before loading this
--   settings_loaded()      -> true if a file was found and parsed
--   settings_values()      -> {key = value} as parsed, for --sync
--   settings_doc(key)      -> the doc string a module declared, or nil
local mod = init_mod();
local py = require "lib_pyscrape";

-- Where to look. A plain global rather than a getcfg, because getcfg is
-- the thing being fed: a setting naming the settings file would have to
-- be read out of the file it names.
--
-- The working directory, which is /lsd in the container and wherever
-- you ran it natively -- the same place LSd looks for config.lua when
-- -c says nothing else (main.c:60).
if (settings_file == nil) then
	settings_file = "settings";
end

-- key -> the doc string its module declared. Filled by the getcfg
-- wrapper as modules load, which is after this file has been read --
-- so it describes what CAN be set, while `values` below is what IS.
local docs = {};
-- key -> value, exactly as parsed out of the file
local values = {};
local parsed = false;

--============================== PARSING =============================--

-- A scalar, in the syntaxes lib_pyscrape's sidecars already use.
-- Strings quoted either way, Python's True/False/None, numbers in
-- decimal or hex, and a bare word left as a string so that
-- `level = required` means what it looks like.
local function parse_scalar(raw)
	raw = string.gsub(raw, "^%s+", "");
	raw = string.gsub(raw, "%s+$", "");

	if (raw == "") then
		return nil;
	end

	-- A quoted string, matched to the CLOSING quote of the same kind as
	-- the opening one -- deliberately not lib_pyscrape's parse_str,
	-- which matches "[\"'] ([^\"']*) [\"']" and so stops at whichever
	-- quote comes first. That turns "Fran6nd's Hallway At Night" into
	-- "Fran6nd", which is exactly the sort of value a server name is.
	-- Its own TODO admits it does not handle escapes; a settings file
	-- has to, so this is the one place the formats part company.
	local q = string.sub(raw, 1, 1);

	if (q == '"' or q == "'") then
		local body = string.match(raw, "^" .. q .. "(.*)" .. q .. "$");

		if (body ~= nil) then
			return body;
		end

		-- an unterminated quote: say so rather than guessing where it
		-- was meant to end
		return nil;
	end

	if (raw == "True" or raw == "true") then return true; end
	if (raw == "False" or raw == "false") then return false; end
	if (raw == "None" or raw == "nil") then return nil; end

	-- 0x33 as well as 51, because every extension id in this tree is
	-- written in hex and a settings file that forced decimal would be
	-- asking the operator to convert what the config comments gave them
	local hex = string.match(raw, "^0[xX](%x+)$");
	if (hex) then
		return tonumber(hex, 16);
	end

	local n = tonumber(raw);
	if (n ~= nil) then
		return n;
	end

	-- a bare word, which is a string
	return raw;
end

-- A braced mapping: {0x33: 'required', 0x32: 'required'}. Colons rather
-- than equals, which is the shape lib_pyscrape's get_ext already reads
-- out of a sidecar's JSON-ish blocks.
local function parse_map(body)
	local out = {};

	for item in string.gmatch(body .. ",", "%s*([^,]-)%s*,") do
		if (item ~= "") then
			local k, v = string.match(item, "^(.-)%s*:%s*(.*)$");

			if (k ~= nil) then
				local key = parse_scalar(k);
				if (key ~= nil) then
					out[key] = parse_scalar(v);
				end
			end
		end
	end

	return out;
end

-- A bracketed list: ['66.135.15.57', 'master.buildandshoot.com'].
local function parse_list(body)
	local out = {};

	for item in string.gmatch(body .. ",", "%s*([^,]-)%s*,") do
		if (item ~= "") then
			out[#out+1] = parse_scalar(item);
		end
	end

	return out;
end

-- A parenthesised tuple: (128, 232, 255). Named r, g, b when it is
-- three long, because that is the one tuple this tree uses and
-- lib_pyscrape's getfog already reads it that way for maps -- so a fog
-- in a settings file and a fog in a map sidecar look alike.
local function parse_tuple(body)
	local out = {};

	for item in py.split_tuple("(" .. body .. ")") do
		out[#out+1] = parse_scalar(item);
	end

	if (#out == 3) then
		return {r = out[1], g = out[2], b = out[3]};
	end

	return out;
end

local function parse_value(raw)
	raw = string.gsub(string.gsub(raw, "^%s+", ""), "%s+$", "");

	local body = string.match(raw, "^{(.*)}$");
	if (body) then return parse_map(body); end

	body = string.match(raw, "^%[(.*)%]$");
	if (body) then return parse_list(body); end

	body = string.match(raw, "^%((.*)%)$");
	if (body) then return parse_tuple(body); end

	return parse_scalar(raw);
end

-- The walker lib_pyscrape has no equivalent of: every `key = value`
-- line, whatever the key, because a settings file's keys are not known
-- in advance the way a map sidecar's are.
--
-- A value may span lines while a bracket is open, so that a long
-- ext_policy can be laid out one entry per line. Complaints name the
-- line number and are warnings rather than errors: one unreadable
-- setting should cost that setting, not the server.
local function parse(text)
	local out = {};
	local lineno = 0;
	local key, acc, depth = nil, nil, 0;

	local function depth_of(s)
		local d = 0;
		for c in string.gmatch(s, "[%{%[%(%}%]%)]") do
			if (c == "{" or c == "[" or c == "(") then
				d = d + 1;
			else
				d = d - 1;
			end
		end
		return d;
	end

	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		lineno = lineno + 1;

		-- comments and blank lines, outside an open value
		local stripped = key == nil
			and string.gsub(line, "%s*[#;].*$", "") or line;

		if (key ~= nil) then
			acc = acc .. " " .. line;
			depth = depth + depth_of(line);

			if (depth <= 0) then
				out[key] = parse_value(acc);
				key, acc, depth = nil, nil, 0;
			end
		elseif (string.match(stripped, "^%s*$")) then
			-- nothing
		else
			local k, v = string.match(stripped, "^%s*([%a_][%w_]*)%s*=%s*(.*)$");

			if (k == nil) then
				log("lib_settings: %s:%d ignored, not a `key = value`: %s",
					settings_file, lineno,
					(string.gsub(line, "^%s+", "")));
			else
				local d = depth_of(v);

				if (d > 0) then
					key, acc, depth = k, v, d;
				else
					out[k] = parse_value(v);
				end
			end
		end
	end

	if (key ~= nil) then
		log("lib_settings: %s: unclosed value for %q at end of file",
			settings_file, key);
	end

	return out;
end

--============================= APPLYING =============================--

-- Straight into the globals, which is the whole trick: core.lua's
-- getcfg fills a global only when it is nil, so a value already sitting
-- there when a module loads is a value that module keeps. Nothing has
-- to be told about this file, and nothing is.
local function apply(vals)
	local n = 0;

	for k,v in pairs(vals) do
		_G[k] = v;
		n = n + 1;
	end

	return n;
end

--============================== GETCFG ==============================--

-- core.lua's getcfg, wrapped for the third argument and nothing else.
-- The fill is still its: these are its semantics and a copy of them
-- here would be a second place for them to drift.
local core_getcfg = getcfg;

function getcfg(key, default, doc)
	if (type(key) == "string" and type(doc) == "string") then
		docs[key] = doc;
	end

	return core_getcfg(key, default);
end

--=============================== API ================================--

function settings_loaded()
	return parsed;
end

function settings_values()
	local out = {};

	for k,v in pairs(values) do
		out[k] = v;
	end

	return out;
end

function settings_doc(key)
	return docs[key];
end

-- Logged for lsdctl to read back over the console, the same way
-- config_dump is: one line per declared setting, with whether this file
-- sets it and what its module says it is for. --sync turns the ones
-- marked `unset` into commented lines in the file.
function settings_dump()
	local keys = {};

	for k in pairs(docs) do
		keys[#keys+1] = k;
	end
	table.sort(keys);

	for _,k in ipairs(keys) do
		log("SET| %s\t%s\t%s", k,
			values[k] ~= nil and "file" or "unset",
			docs[k]);
	end

	log("SET-END %d documented, %d in %s", #keys,
		(function() local n = 0 for _ in pairs(values) do n = n + 1 end
			return n end)(), settings_file);
end

--============================ LIFECYCLE =============================--

-- Read and applied at load, not at a tick: everything that reads a
-- setting does so while it is loading, which is after this and before
-- the first tick.
function mod.on_load()
	local f = io.open(settings_file, "r");

	if (f == nil) then
		log("lib_settings: no %s, every setting is its module's default",
			settings_file);
		return;
	end

	local text = f:read("*a");
	f:close();

	values = parse(text);
	parsed = true;

	local n = apply(values);
	log("lib_settings: %s applied, %d setting(s)", settings_file, n);
end

local EXPORTS = {
	"settings_loaded", "settings_values", "settings_doc",
	"settings_dump",
};

function mod.on_unload()
	getcfg = core_getcfg;

	for _,name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
