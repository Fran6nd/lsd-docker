-- settings_format.lua -- The settings file's syntax, and nothing else
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Pure Lua: no server API, no globals, no I/O. Two programs read the
-- settings file -- the server (config.lua) and the administration
-- tool (lsdctl) -- and two parsers for one file is how they come to
-- disagree about what it says. So there is one, and both require it.
--
-- THE FORMAT is the one LSd already reads out of map sidecars:
--
--   name = 'text'        name = "text with an apostrophe's"
--   flag = True          flag = False
--   number = 300         hex = 0x33
--   tuple = (128, 232, 255)
--   list  = ['a', 'b']
--   map   = {key: value}     # may span lines
--
-- Anything after an unquoted # or ; is a comment.
--
-- API:
--   F.parse(text, warn)   -> {key = value}, {key, ...} in file order.
--                            warn(lineno, message) is called for every
--                            line that could not be read.
--   F.emit(value)         -> the value in this syntax, or nil if it has
--                            none (a function, or nested too deep)
--   F.assignment(key, v)  -> "key = value", one item per line when the
--                            value is a list or a map
--   F.set(text, key, v)   -> text with key set, in place where it
--                            already is, else under `section`, else at
--                            the end
--   F.unset(text, key)    -> text with key's assignment removed
--   F.section(text, name) / F.add_section / F.remove_section
--                            the "# ---- name ----" blocks lsdctl keeps
--                            one script's settings in
local F = {};

--============================== PARSING =============================--

-- \n, \t and friends inside a quoted string, so that a setting whose
-- module wants several lines can be written as one. An unknown escape
-- is kept verbatim, backslash and all: a Windows path should survive
-- being read, and guessing at \d would lose it silently.
local ESCAPES = {
	n = "\n", t = "\t", r = "\r",
	["\\"] = "\\", ['"'] = '"', ["'"] = "'",
};

local function unescape(body)
	return (string.gsub(body, "\\(.)", function(c)
		return ESCAPES[c] or ("\\" .. c);
	end));
end

local function trim(s)
	return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""));
end

-- A scalar: a string quoted either way, Python's True/False/None, a
-- number in decimal or hex, and a bare word left as a string so that
-- `level = required` means what it looks like.
local function parse_scalar(raw, complain)
	raw = trim(raw);

	if (raw == "") then
		return nil;
	end

	-- Matched to the CLOSING quote of the same kind as the opening one,
	-- so "Fran6nd's Hallway At Night" is not cut at its apostrophe.
	local q = string.sub(raw, 1, 1);

	if (q == '"' or q == "'") then
		local body = string.match(raw, "^" .. q .. "(.*)" .. q .. "$");

		if (body ~= nil and #raw >= 2) then
			return unescape(body);
		end

		-- SAY so: silence here is the worst failure this file has,
		-- because the key simply goes missing and its default applies.
		complain("unterminated quote, setting ignored: " .. raw);
		return nil;
	end

	-- 0 and "off" are TRUTHY in Lua, so without naming them here
	-- `masterlist_enabled = 0` would switch the listing ON.
	local lower = string.lower(raw);

	if (lower == "true" or lower == "yes" or lower == "on") then
		return true;
	end
	if (lower == "false" or lower == "no" or lower == "off"
	    or raw == "0") then
		return false;
	end
	if (raw == "None" or raw == "nil") then
		return nil;
	end

	-- every extension id in this tree is written in hex
	local hex = string.match(raw, "^0[xX](%x+)$");
	if (hex) then
		return tonumber(hex, 16);
	end

	local n = tonumber(raw);
	if (n ~= nil) then
		return n;
	end

	return raw;
end

-- Split a list or mapping body on the commas that separate items, and
-- not the ones inside a quoted string or a nested bracket. A motd line
-- with a comma in it is one item.
local function split_items(body)
	local out, buf = {}, {};
	local quote, depth, skip = nil, 0, false;

	for i = 1, #body do
		local c = string.sub(body, i, i);

		if (skip) then
			skip = false;
			buf[#buf+1] = c;
		elseif (quote ~= nil) then
			if (c == "\\") then skip = true;
			elseif (c == quote) then quote = nil; end
			buf[#buf+1] = c;
		elseif (c == "'" or c == '"') then
			quote = c;
			buf[#buf+1] = c;
		elseif (c == "{" or c == "[" or c == "(") then
			depth = depth + 1;
			buf[#buf+1] = c;
		elseif (c == "}" or c == "]" or c == ")") then
			depth = depth - 1;
			buf[#buf+1] = c;
		elseif (c == "," and depth == 0) then
			out[#out+1] = table.concat(buf);
			buf = {};
		else
			buf[#buf+1] = c;
		end
	end

	out[#out+1] = table.concat(buf);

	-- Drop the empty item a trailing comma leaves, which a
	-- one-entry-per-line layout always ends with.
	local items = {};
	for _, item in ipairs(out) do
		item = trim(item);
		if (item ~= "") then
			items[#items+1] = item;
		end
	end

	return items;
end

local parse_value;

local function parse_map(body, complain)
	local out = {};

	for _, item in ipairs(split_items(body)) do
		local k, v = string.match(item, "^(.-)%s*:%s*(.*)$");

		if (k ~= nil) then
			local key = parse_scalar(k, complain);
			if (key ~= nil) then
				out[key] = parse_value(v, complain);
			end
		end
	end

	return out;
end

local function parse_list(body, complain)
	local out = {};

	for _, item in ipairs(split_items(body)) do
		out[#out+1] = parse_value(item, complain);
	end

	return out;
end

-- Named r, g, b when it is three long: that is the one tuple this tree
-- uses, and a fog here then reads like a fog in a map sidecar.
local function parse_tuple(body, complain)
	local out = {};

	for _, item in ipairs(split_items(body)) do
		out[#out+1] = parse_scalar(item, complain);
	end

	if (#out == 3) then
		return {r = out[1], g = out[2], b = out[3]};
	end

	return out;
end

parse_value = function(raw, complain)
	raw = trim(raw);

	local body = string.match(raw, "^{(.*)}$");
	if (body) then return parse_map(body, complain); end

	body = string.match(raw, "^%[(.*)%]$");
	if (body) then return parse_list(body, complain); end

	body = string.match(raw, "^%((.*)%)$");
	if (body) then return parse_tuple(body, complain); end

	return parse_scalar(raw, complain);
end

-- Everything before an unquoted # or ;. Walked a character at a time,
-- because a pattern would cut inside strings too: a server named
-- "Server #1" would become an unterminated quote.
local function strip_comment(line)
	local out, quote, skip = {}, nil, false;

	for i = 1, #line do
		local c = string.sub(line, i, i);

		if (skip) then
			skip = false;
			out[#out+1] = c;
		elseif (quote ~= nil) then
			if (c == "\\") then
				skip = true;
			elseif (c == quote) then
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

-- How many brackets a line leaves open, ignoring the ones in strings.
local function depth_of(s)
	local d, quote, skip = 0, nil, false;

	for i = 1, #s do
		local c = string.sub(s, i, i);

		if (skip) then
			skip = false;
		elseif (quote ~= nil) then
			if (c == "\\") then skip = true;
			elseif (c == quote) then quote = nil; end
		elseif (c == '"' or c == "'") then
			quote = c;
		elseif (c == "{" or c == "[" or c == "(") then
			d = d + 1;
		elseif (c == "}" or c == "]" or c == ")") then
			d = d - 1;
		end
	end

	return d;
end

local function lines_of(text)
	local out = {};

	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		out[#out+1] = line;
	end

	-- the split above yields one empty trailing line for a text that
	-- already ends in a newline
	if (out[#out] == "") then
		out[#out] = nil;
	end

	return out;
end

-- Every `key = value` in the text, as the line range it occupies. A
-- value may span lines while a bracket is open. This is the one walker:
-- parse() reads values off it and set()/unset() edit by it, so what is
-- parsed and what is rewritten can never be two different ideas of
-- where an assignment ends.
--
-- on_junk(lineno, line) is called for a line that is neither blank, a
-- comment nor an assignment.
local function spans(lines, on_junk)
	local out = {};
	local cur = nil;

	for i, line in ipairs(lines) do
		local stripped = strip_comment(line);

		if (cur ~= nil) then
			cur.raw = cur.raw .. " " .. stripped;
			cur.depth = cur.depth + depth_of(stripped);

			if (cur.depth <= 0) then
				cur.last = i;
				out[#out+1] = cur;
				cur = nil;
			end
		elseif (not string.match(stripped, "^%s*$")) then
			local k, v = string.match(stripped,
				"^%s*([%a_][%w_]*)%s*=%s*(.*)$");

			if (k == nil) then
				if (on_junk) then on_junk(i, line); end
			else
				local d = depth_of(v);

				if (d > 0) then
					cur = {key = k, first = i, raw = v, depth = d};
				else
					out[#out+1] = {key = k, first = i, last = i, raw = v};
				end
			end
		end
	end

	return out, cur;
end

function F.parse(text, warn)
	warn = warn or function() end;

	local values, order = {}, {};
	local found, unclosed = spans(lines_of(text), function(i, line)
		warn(i, "ignored, not a `key = value`: " .. trim(line));
	end);

	for _, s in ipairs(found) do
		if (values[s.key] == nil) then
			order[#order+1] = s.key;
		end

		values[s.key] = parse_value(s.raw, function(msg)
			warn(s.first, msg);
		end);
	end

	if (unclosed ~= nil) then
		warn(unclosed.first, string.format(
			"unclosed value for %q at end of file", unclosed.key));
	end

	return values, order;
end

--============================== EMITTING ============================--

local function emit_string(v)
	-- double quotes, with the three characters that would end or bend
	-- the string escaped -- the inverse of unescape above
	return '"' .. string.gsub(v, '[\\"\n\t]', {
		["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\t"] = "\\t",
	}) .. '"';
end

local function is_rgb(v)
	return #v == 0 and type(v.r) == "number" and type(v.g) == "number"
		and type(v.b) == "number";
end

-- A table's list part and its other keys, the latter sorted so the same
-- table always emits the same text.
local function split_table(v)
	local keys = {};

	for k in pairs(v) do
		if (type(k) ~= "number" or k < 1 or k > #v or k % 1 ~= 0) then
			keys[#keys+1] = k;
		end
	end

	table.sort(keys, function(a, b)
		if (type(a) == type(b)) then return a < b; end
		return tostring(a) < tostring(b);
	end);

	return keys;
end

function F.emit(v, depth)
	depth = depth or 0;
	local t = type(v);

	if (t == "boolean") then return v and "True" or "False"; end
	if (t == "number") then return tostring(v); end
	if (t == "nil") then return "None"; end
	if (t == "string") then return emit_string(v); end

	if (t == "table" and depth < 3) then
		if (is_rgb(v)) then
			return string.format("(%d, %d, %d)", v.r, v.g, v.b);
		end

		local keys = split_table(v);
		local out = {};

		if (#keys == 0) then
			for _, x in ipairs(v) do
				out[#out+1] = F.emit(x, depth + 1);
				if (out[#out] == nil) then return nil; end
			end
			return "[" .. table.concat(out, ", ") .. "]";
		end

		for _, k in ipairs(keys) do
			local kt, vt = F.emit(k, depth + 1), F.emit(v[k], depth + 1);
			if (kt == nil or vt == nil) then return nil; end
			out[#out+1] = kt .. ": " .. vt;
		end

		return "{" .. table.concat(out, ", ") .. "}";
	end

	return nil;
end

-- "key = value", laid out one entry per line when the value is a
-- non-empty list or map: that is how a motd and an ext_policy are read
-- and edited, and a trailing comma on every line makes adding one a
-- one-line diff.
--
-- notes[k] is an optional trailing comment for map entry k.
function F.assignment(key, v, notes)
	local text = F.emit(v);

	if (text == nil) then
		return nil;
	end

	if (type(v) ~= "table" or is_rgb(v) or next(v) == nil) then
		return key .. " = " .. text;
	end

	local keys = split_table(v);
	local out = {};

	if (#keys == 0) then
		out[1] = key .. " = [";
		for _, x in ipairs(v) do
			out[#out+1] = "\t" .. F.emit(x, 1) .. ",";
		end
		out[#out+1] = "]";
	else
		out[1] = key .. " = {";
		for _, k in ipairs(keys) do
			local line = "\t" .. F.emit(k, 1) .. ": " .. F.emit(v[k], 1) .. ",";
			if (notes ~= nil and notes[k] ~= nil) then
				line = line .. "   # " .. notes[k];
			end
			out[#out+1] = line;
		end
		out[#out+1] = "}";
	end

	return table.concat(out, "\n");
end

--============================== EDITING =============================--

local function header(name)
	return "# ---- " .. name .. " ----";
end

local function header_name(line)
	return string.match(line, "^# %-%-%-%- (%S+)");
end

-- Every edit goes out through here: one blank line before each section
-- header, never two blank lines running, none at the end. So however
-- sections come and go, the file stays laid out the same way.
local function join(lines)
	local out = {};

	for _, l in ipairs(lines) do
		local blank = string.match(l, "^%s*$") ~= nil;

		if (blank) then
			if (#out > 0 and out[#out] ~= "") then out[#out+1] = ""; end
		else
			if (header_name(l) ~= nil and #out > 0 and out[#out] ~= "") then
				out[#out+1] = "";
			end
			out[#out+1] = l;
		end
	end

	while (#out > 0 and out[#out] == "") do out[#out] = nil; end

	return table.concat(out, "\n") .. "\n";
end

local function splice(lines, first, last, new)
	local out = {};

	for i = 1, first - 1 do out[#out+1] = lines[i]; end
	for _, l in ipairs(new) do out[#out+1] = l; end
	for i = last + 1, #lines do out[#out+1] = lines[i]; end

	return out;
end

-- The line range of a section: its header through the line before the
-- next header (or the end), without the blank lines that trail it.
local function section_range(lines, name)
	local first;

	for i, line in ipairs(lines) do
		local n = header_name(line);

		if (first == nil) then
			if (n == name) then first = i; end
		elseif (n ~= nil) then
			return first, i - 1;
		end
	end

	if (first ~= nil) then
		return first, #lines;
	end
end

function F.section(text, name)
	local lines = lines_of(text);
	local first, last = section_range(lines, name);

	if (first == nil) then
		return nil;
	end

	local out = {};
	for i = first, last do out[#out+1] = lines[i]; end
	return join(out);
end

-- Append a section: a header carrying `title`, then `body` lines.
function F.add_section(text, name, title, body)
	local lines = lines_of(text);

	while (#lines > 0 and lines[#lines] == "") do
		lines[#lines] = nil;
	end

	if (#lines > 0) then lines[#lines+1] = ""; end
	lines[#lines+1] = header(name)
		.. (title and title ~= "" and ("  " .. title) or "");
	for _, l in ipairs(body or {}) do lines[#lines+1] = l; end

	return join(lines);
end

function F.remove_section(text, name)
	local lines = lines_of(text);
	local first, last = section_range(lines, name);

	if (first == nil) then
		return text;
	end

	-- and the blank line that separated it from the one before
	if (first > 1 and lines[first - 1] == "") then
		first = first - 1;
	end

	return join(splice(lines, first, last, {}));
end

-- A commented-out assignment, "# key = value", which is how a setting
-- left at its default is written: uncommenting is the act of setting it.
local function commented_line(lines, key, from, to)
	for i = from or 1, to or #lines do
		if (string.match(lines[i], "^#%s*" .. key .. "%s*=")) then
			return i;
		end
	end
end

-- Set key. In order of preference: where it is already assigned; over
-- its commented-out default; at the end of opts.section; at the end of
-- the file. Returns the new text.
function F.set(text, key, value, opts)
	opts = opts or {};

	local assignment = F.assignment(key, value, opts.notes);
	if (assignment == nil) then
		return nil, "a " .. type(value) .. " has no form in a settings file";
	end

	local new = lines_of(assignment);
	local lines = lines_of(text);

	for _, s in ipairs(spans(lines)) do
		if (s.key == key) then
			return join(splice(lines, s.first, s.last, new));
		end
	end

	local at = commented_line(lines, key);
	if (at ~= nil) then
		return join(splice(lines, at, at, new));
	end

	if (opts.doc ~= nil) then
		table.insert(new, 1, "# " .. opts.doc);
	end

	if (opts.section ~= nil) then
		local first, last = section_range(lines, opts.section);

		if (first ~= nil) then
			while (last > first and lines[last] == "") do
				last = last - 1;
			end
			table.insert(new, 1, "");
			return join(splice(lines, last + 1, last, new));
		end
	end

	-- Not in a section: with the server's own settings, which are the
	-- ones above the first section. Appending at the very end would put
	-- it inside whichever script's section happens to be last.
	table.insert(new, 1, "");
	for i, line in ipairs(lines) do
		if (header_name(line) ~= nil) then
			new[#new+1] = "";
			return join(splice(lines, i, i - 1, new));
		end
	end

	return join(splice(lines, #lines + 1, #lines, new));
end

-- Remove key's assignment, leaving `default` behind as a commented line
-- when one is given, so the file still says the setting exists.
function F.unset(text, key, default)
	local lines = lines_of(text);

	for _, s in ipairs(spans(lines)) do
		if (s.key == key) then
			local new = {};

			if (default ~= nil) then
				local a = F.assignment(key, default);
				if (a ~= nil) then
					for _, l in ipairs(lines_of(a)) do
						new[#new+1] = "# " .. l;
					end
				end
			end

			return join(splice(lines, s.first, s.last, new)), true;
		end
	end

	return text, false;
end

return F;
