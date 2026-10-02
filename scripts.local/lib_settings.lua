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
--   settings_values()      -> {key = value} as parsed
--   settings_fields()      -> every declared setting: key, default,
--                             value, source module, doc, and whether
--                             the file sets it
--   settings_template()    -> the whole file, for every setting every
--                             loaded module declares, grouped by
--                             module, with their own descriptions.
--                             Settings the file does not mention come
--                             out commented at their default.
--   settings_reload()      re-read the file and apply it live
--   settings_listen(name, fn) / settings_unlisten(name)
--        fn(changed) after a reload, for a module that has to
--        re-announce what it already told clients
--   settings_doc(key)      -> the doc string a module declared, or nil
local mod = init_mod();
local py = require "lib_pyscrape";

-- Where to look. A plain global rather than a getcfg, because getcfg is
-- the thing being fed: a setting naming the settings file would have to
-- be read out of the file it names.
--
-- Natively: the working directory, the same place LSd looks for
-- config.lua when -c says nothing else (main.c:60).
--
-- In a container: the instances directory is mounted at
-- /lsd/instances -- the directory and not the file, because a
-- single-file bind mount is pinned to that file's inode and every
-- editor that saves by rename would leave the server reading the old
-- one -- so the file is found by name inside it.
--
-- LSD_SETTINGS_FILE is read for that name alone, and this is the one
-- place an environment variable is still right: finding the config is
-- not configuration. It is what -c does for config.lua. Natively there
-- is no such variable and the fallback applies, so the file stays
-- portable; what is in it is never read from the environment.
if (settings_file == nil) then
	local env = os.getenv and os.getenv("LSD_SETTINGS_FILE");

	if (env ~= nil and env ~= "") then
		settings_file = "instances/" .. string.gsub(env, "^.*/", "");
	else
		settings_file = "settings";
	end
end

-- key -> {default=, source=, doc=, set=}. Every setting any loaded
-- module declared, filled by the getcfg wrapper as they load -- so this
-- is what CAN be set, while `values` below is what IS.
--
-- ONE wrapper around getcfg, and that is not tidiness. There used to be
-- two -- this module for the doc string, lib_config for the key and the
-- default -- and the outer one took (key, default) and called the inner
-- with (key, default). So every doc string in the server was silently
-- dropped on the floor. Two wrappers on one function cannot be kept
-- honest; one can.
local fields = {};
-- name -> fn, called after a reload so a module can re-announce
-- whatever it had already told clients.
local listeners = {};
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
		-- an empty item is the trailing comma a one-entry-per-line
		-- layout ends with, which is normal rather than a mistake
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

-- Everything before an unquoted # or ;, which is the comment. Walked a
-- character at a time rather than matched, because the obvious
-- `gsub("%s*[#;].*$", "")` cuts inside strings too: a server named
-- "Server #1" becomes an unterminated quote, and a per-entry comment
-- in a multi-line value is not stripped at all unless this is applied
-- to every line of it.
local function strip_comment(line)
	local out, quote = {}, nil;

	for i = 1, #line do
		local c = string.sub(line, i, i);

		if (quote ~= nil) then
			if (c == quote) then
				quote = nil;
			end
			out[#out+1] = c;
		elseif (c == '"' or c == "'") then
			quote = c;
			out[#out+1] = c;
		elseif (c == "#" or c == ";") then
			break;
		else
			out[#out+1] = c;
		end
	end

	return (string.gsub(table.concat(out), "%s+$", ""));
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

		-- Comments come off every line, inside an open value as well as
		-- outside one -- a multi-line ext_policy naming each extension
		-- in a trailing comment is the whole point of it being
		-- multi-line.
		local stripped = strip_comment(line);

		if (key ~= nil) then
			acc = acc .. " " .. stripped;
			depth = depth + depth_of(stripped);

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

-- Where the call came from, as the script that made it.
--
-- Level 3 counting from here: 1 is this function, 2 is the getcfg
-- wrapper below, 3 is the module that called it. And NOT through
-- pcall -- a pcall puts its own frame in between, every level shifts by
-- one, and the answer comes back as this file instead of the caller's.
-- getinfo returns nil for a level that does not exist rather than
-- failing, so there is nothing to catch.
local function caller_source()
	local info = debug and debug.getinfo and debug.getinfo(3, "S");

	if (info == nil or info.source == nil) then
		return "?";
	end

	-- "@./scripts/lib_daytime.lua" -> "lib_daytime"
	local src = string.gsub(info.source, "^@", "");
	return (string.gsub(string.gsub(src, "^.*/", ""), "%.lua$", ""));
end

-- core.lua's getcfg, wrapped. The fill is still its -- these are its
-- semantics and a copy of them here would be a second place for them to
-- drift -- and everything else is bookkeeping.
local core_getcfg = getcfg;

function getcfg(key, default, doc)
	if (type(key) == "string") then
		-- Only true before the fill below runs: a global that is
		-- already non-nil was set by the settings file or by config.lua,
		-- because nothing else sets one this early. That one bit is the
		-- difference between "you chose this" and "this is the default".
		local already = _G[key] ~= nil;
		local was = fields[key];

		fields[key] = {
			default = default,
			source = caller_source(),
			doc = type(doc) == "string" and doc
				or (was ~= nil and was.doc or nil),
			-- a key declared twice keeps the first reading, taken
			-- before any default could have filled it
			set = was ~= nil and was.set or already,
		};
	end

	return core_getcfg(key, default);
end

--============================= TEMPLATE =============================--

-- A value as this file's own syntax, which is the inverse of the parser
-- above: whatever the template emits must read back as the same value.
local function emit(v, depth)
	depth = depth or 0;
	local t = type(v);

	if (t == "boolean") then return v and "True" or "False"; end
	if (t == "number") then return tostring(v); end
	if (t == "nil") then return "None"; end

	if (t == "string") then
		-- double quotes unless the text has one, so an apostrophe in a
		-- server name needs no escaping -- which is as well, since this
		-- format has no escapes
		if (string.find(v, '"') == nil) then
			return '"' .. v .. '"';
		end
		return "'" .. string.gsub(v, "'", "") .. "'";
	end

	if (t == "table" and depth < 2) then
		local arr = {};
		for _,x in ipairs(v) do
			arr[#arr+1] = emit(x, depth+1);
		end

		-- r/g/b is a tuple, which is how a fog reads in a map sidecar
		if (#arr == 0 and v.r and v.g and v.b) then
			return string.format("(%d, %d, %d)", v.r, v.g, v.b);
		end

		local keys = {};
		for k in pairs(v) do
			if (type(k) ~= "number" or k < 1 or k > #arr or k % 1 ~= 0) then
				keys[#keys+1] = k;
			end
		end

		if (#keys == 0) then
			return "[" .. table.concat(arr, ", ") .. "]";
		end

		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b);
		end);

		local pairs_out = {};
		for _,k in ipairs(keys) do
			pairs_out[#pairs_out+1] = emit(k, depth+1) .. ": "
				.. emit(v[k], depth+1);
		end

		return "{" .. table.concat(pairs_out, ", ") .. "}";
	end

	-- a function, or something nested deeper than this format goes.
	-- Named rather than emitted, so the template says why it is absent.
	return nil;
end

-- The whole file, for every setting every loaded module declared,
-- grouped by the module that declared it.
--
-- This is the point of watching getcfg at all: drop a script into
-- scripts.local/, start the server, and its settings are here with its
-- own descriptions, without the script registering anything or anyone
-- editing a list. A setting already in the file keeps its current
-- value; one that is not is written commented out, at its default, so
-- uncommenting is the whole act of setting it.
--
-- Returned as a list of lines, because the console carries lines.
function settings_template()
	local by_source, sources = {}, {};

	for key,f in pairs(fields) do
		local src = f.source or "?";

		if (by_source[src] == nil) then
			by_source[src] = {};
			sources[#sources+1] = src;
		end

		by_source[src][#by_source[src]+1] = key;
	end

	table.sort(sources);

	local out = {};
	local function add(fmt, ...)
		out[#out+1] = select("#", ...) > 0 and string.format(fmt, ...)
			or fmt;
	end

	for _,src in ipairs(sources) do
		local keys = by_source[src];
		table.sort(keys);

		add("");
		add("# ---- %s ----", src);

		for _,key in ipairs(keys) do
			local f = fields[key];
			local v = _G[key];
			if (v == nil) then v = f.default; end

			local text = emit(v);

			add("");
			if (f.doc ~= nil) then
				add("# %s", f.doc);
			end

			if (text == nil) then
				add("# %s is a %s: it has no form in this file and stays"
					.. " in config.lua.", key, type(v));
			elseif (values[key] ~= nil) then
				add("%s = %s", key, text);
			else
				add("# %s = %s", key, text);
			end
		end
	end

	return out;
end

--============================== RELOAD ==============================--

-- Re-read the file and apply it, without restarting.
--
-- WHAT THIS CAN AND CANNOT DO, because the difference matters. A
-- setting read every time it is used -- daytime_night, ext_policy,
-- flashlight_reach -- changes behaviour the moment this returns. One
-- consumed once, while its module was loading, does not: masterlist_name
-- was already handed to the masterlist, and `gamemode` already decided
-- which module to load. Those need that module reloaded, or a restart.
--
-- So this reports what changed rather than claiming to have applied it,
-- and modules that have already told clients something re-announce it
-- through a listener.
function settings_reload()
	local f = io.open(settings_file, "r");

	if (f == nil) then
		log("lib_settings: no %s to reload", settings_file);
		return 0;
	end

	local text = f:read("*a");
	f:close();

	local fresh = parse(text);
	local changed = {};

	-- Compared as text, not with ~=. A table parsed afresh is a new
	-- table, so identity says every table-valued setting changed on
	-- every reload -- ext_policy would be reported every time and the
	-- report would be worthless.
	local function same(a, b)
		if (type(a) == "table" or type(b) == "table") then
			return emit(a) == emit(b);
		end
		return a == b;
	end

	-- changed or newly set
	for k,v in pairs(fresh) do
		if (not same(values[k], v)) then
			changed[#changed+1] = k;
		end
		_G[k] = v;
	end

	-- removed from the file: back to the default its module declared,
	-- which is what the file no longer mentioning it has to mean
	for k in pairs(values) do
		if (fresh[k] == nil) then
			changed[#changed+1] = k;
			_G[k] = fields[k] ~= nil and fields[k].default or nil;
		end
	end

	values = fresh;
	parsed = true;

	table.sort(changed);
	log("lib_settings: reloaded %s, %d changed%s", settings_file,
		#changed,
		#changed > 0 and ": " .. table.concat(changed, ", ") or "");

	for name,fn in pairs(listeners) do
		local ok, err = pcall(fn, changed);

		if (not ok) then
			listeners[name] = nil;
			log("lib_settings: %s crashed on reload, dropped: %s",
				name, tostring(err));
		end
	end

	return #changed;
end

-- Called as fn(changed) after a reload, `changed` being the list of
-- keys. For a module that has already told clients something and needs
-- to say it again -- lib_daytime's Sky, lib_ext_policy's offered list.
function settings_listen(name, fn)
	if (type(name) ~= "string" or type(fn) ~= "function") then
		error("settings_listen: name and fn required", 2);
	end
	listeners[name] = fn;
end

function settings_unlisten(name)
	listeners[name] = nil;
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
	return fields[key] ~= nil and fields[key].doc or nil;
end

-- Every declared setting, sorted. The shape lib_config used to return,
-- because lsdctl's `config` subcommand reads it.
function settings_fields()
	local keys = {};

	for k in pairs(fields) do
		keys[#keys+1] = k;
	end
	table.sort(keys);

	local out = {};
	for _,k in ipairs(keys) do
		local f = fields[k];

		out[#out+1] = {
			key = k,
			default = f.default,
			value = _G[k],
			source = f.source,
			doc = f.doc,
			set = values[k] ~= nil or f.set,
		};
	end

	return out;
end

-- lib_config's names, kept so that `lsdctl <instance> config` and
-- anything else built on them keeps working now that this module is the
-- single getcfg observer. It is the same registry either way.
config_fields = settings_fields;

-- Logged for lsdctl to read back over the console, the same way
-- config_dump is: one line per declared setting, with whether this file
-- sets it and what its module says it is for. --sync turns the ones
-- marked `unset` into commented lines in the file.
-- Logged for lsdctl to read back over the console. One line per
-- setting, with a stable prefix so it can be grepped out of whatever
-- else the server is saying.
function settings_dump(pattern, opts)
	opts = opts or {};

	local shown = 0;

	for _,f in ipairs(settings_fields()) do
		local hit = pattern == nil or pattern == ""
			or string.find(f.key, pattern) ~= nil
			or string.find(f.source, pattern) ~= nil;

		if (hit and not (opts.new_only and f.set)) then
			shown = shown + 1;
			log("CFG| %-28s %-20s %-8s %s", f.key, f.source,
				f.set and "set" or "default",
				tostring(emit(f.value) or type(f.value)));
		end
	end

	log("CFG-END %d shown, %d declared, %d in %s", shown,
		#settings_fields(),
		(function() local n = 0 for _ in pairs(values) do n = n + 1 end
			return n end)(), settings_file);
end

config_dump = settings_dump;

-- The template, line by line, for lsdctl to write out.
function settings_dump_template()
	for _,line in ipairs(settings_template()) do
		log("TPL|%s", line);
	end

	log("TPL-END %d declared", #settings_fields());
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
	"settings_fields", "settings_template", "settings_reload",
	"settings_listen", "settings_unlisten",
	"settings_dump", "settings_dump_template",
	-- lib_config's names, which this module now answers for
	"config_fields", "config_dump",
};

function mod.on_unload()
	getcfg = core_getcfg;

	for _,name in ipairs(EXPORTS) do
		_G[name] = nil;
	end
end

return mod;
