-- map_layout/json.lua -- The layout file's JSON, both ways
-- Copyright (C) 2026 Fran6nd. GPL-3.0-or-later; see LICENSE.
--
-- No JSON library ships with the server and the data here is simple
-- (arrays, string/number/bool fields), so a small encoder/decoder is
-- cheaper than another native dependency.
--
--   J.encode(v)    -> text, indented, keys sorted (stable diffs)
--   J.decode(text) -> value; raises on malformed input
local J = {};

local function jesc(s)
	return (string.gsub(s, '[%c"\\]', function(c)
		local map = {['"']='\\"', ['\\']='\\\\', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t'};
		return map[c] or string.format("\\u%04x", string.byte(c));
	end));
end

local function isarray(t)
	local n = 0;
	for _ in pairs(t) do n = n + 1; end
	return n == #t;
end

local function enc(v, ind)
	ind = ind or "";
	local t = type(v);

	if (t == "nil") then return "null"; end
	if (t == "boolean") then return tostring(v); end
	if (t == "number") then
		if (v == math.floor(v)) then return string.format("%d", v); end
		return string.format("%.6g", v);
	end
	if (t == "string") then return '"'..jesc(v)..'"'; end
	if (t ~= "table") then return "null"; end

	local sub = ind.."  ";
	local out = {};

	if (isarray(v)) then
		if (#v == 0) then return "[]"; end
		for _, x in ipairs(v) do
			table.insert(out, sub..enc(x, sub));
		end
		return "[\n"..table.concat(out, ",\n").."\n"..ind.."]";
	end

	local ks = {};
	for k in pairs(v) do table.insert(ks, k); end
	table.sort(ks, function(a, b) return tostring(a) < tostring(b); end);
	if (#ks == 0) then return "{}"; end
	for _, k in ipairs(ks) do
		table.insert(out, sub..'"'..jesc(tostring(k))..'": '..enc(v[k], sub));
	end
	return "{\n"..table.concat(out, ",\n").."\n"..ind.."}";
end

local function ws(s, i)
	local _, j = string.find(s, "^[ \t\r\n]*", i);
	return j + 1;
end

local parse;
parse = function(s, i)
	i = ws(s, i);
	local c = string.sub(s, i, i);

	if (c == "{") then
		local o = {};
		i = ws(s, i+1);
		if (string.sub(s, i, i) == "}") then return o, i+1; end
		while (true) do
			local k; k, i = parse(s, i);
			i = ws(s, i);
			i = i + 1;  -- ':'
			local v; v, i = parse(s, i);
			o[k] = v;
			i = ws(s, i);
			local d = string.sub(s, i, i);
			i = i + 1;
			if (d == "}") then return o, i; end
		end
	elseif (c == "[") then
		local a = {};
		i = ws(s, i+1);
		if (string.sub(s, i, i) == "]") then return a, i+1; end
		while (true) do
			local v; v, i = parse(s, i);
			table.insert(a, v);
			i = ws(s, i);
			local d = string.sub(s, i, i);
			i = i + 1;
			if (d == "]") then return a, i; end
		end
	elseif (c == '"') then
		local out = {};
		i = i + 1;
		while (true) do
			local ch = string.sub(s, i, i);
			if (ch == "") then error("unfinished string"); end
			if (ch == '"') then return table.concat(out), i+1; end
			if (ch == "\\") then
				local e = string.sub(s, i+1, i+1);
				local map = {n="\n", r="\r", t="\t", ['"']='"', ["\\"]="\\", ["/"]="/"};
				table.insert(out, map[e] or e);
				i = i + 2;
			else
				table.insert(out, ch);
				i = i + 1;
			end
		end
	elseif (string.sub(s, i, i+3) == "true") then
		return true, i+4;
	elseif (string.sub(s, i, i+4) == "false") then
		return false, i+5;
	elseif (string.sub(s, i, i+3) == "null") then
		return nil, i+4;
	end

	local num = string.match(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", i);
	if (num) then
		return tonumber(num), i + #num;
	end
	error("bad json at "..i);
end

function J.encode(v)
	return enc(v);
end

function J.decode(text)
	return (parse(text, 1));
end

return J;
