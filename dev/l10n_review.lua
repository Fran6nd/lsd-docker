-- dev/l10n_review.lua -- review a language's translations in bulk
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
--   luajit dev/l10n_review.lua todo <lang> > todo.lua
--        every entry of every locales/<lang>.po not yet in use (empty,
--        or fuzzy: a machine draft), as a Lua list to fill in:
--          {file = "...", ctx = nil, en = "...", draft = "...", str = nil},
--   luajit dev/l10n_review.lua apply <lang> done.lua
--        writes each entry's `str` into its file as reviewed: fuzzy
--        cleared, the machine-translation mark dropped. An entry whose
--        %(placeholders) differ from the English is refused, and said.
--
-- For a reviewer working on many entries at once -- a person in a text
-- editor, or a script -- rather than one at a time in Poedit. The .po
-- files stay written by l10n_po, as dev/l10n.lua writes them.
package.path = "catalog/core/?.lua;" .. package.path;
local P = require "l10n_po";

local MARKS = {
	["# machine-translated (LibreTranslate)"] = true,
};

local function read(p)
	local f = assert(io.open(p));
	local s = f:read("*a");
	f:close();
	return s;
end

local function files(lang)
	local out = {};
	for f in io.popen("find catalog -path '*/locales/" .. lang .. ".po' | sort"):lines() do
		out[#out+1] = f;
	end
	return out;
end

local function in_use(e)
	return not e.fuzzy and ((e.str ~= nil and e.str ~= "") or #e.forms > 0);
end

local function same_placeholders(a, b)
	return table.concat(P.placeholders(a), ",") == table.concat(P.placeholders(b), ",");
end

local mode, lang, input = arg[1], P.norm_lang(arg[2] or ""), arg[3];

if (mode == "todo" and lang) then
	print("return {");
	for _, path in ipairs(files(lang)) do
		for _, e in ipairs(P.parse(read(path)).list) do
			if (not in_use(e) and e.plural == nil) then
				print(string.format("\t{file = %q, ctx = %s, en = %q, draft = %s, str = nil},",
					path, e.ctx and string.format("%q", e.ctx) or "nil", e.msgid,
					(e.str and e.str ~= "") and string.format("%q", e.str) or "nil"));
			end
		end
	end
	print("}");
	os.exit(0);
end

if (mode == "apply" and lang and input) then
	local list = dofile(input);
	local by_file = {};
	for _, t in ipairs(list) do
		if (t.str ~= nil and t.str ~= "") then
			by_file[t.file] = by_file[t.file] or {};
			by_file[t.file][P.key(t.ctx, t.en)] = t.str;
		end
	end

	local done, refused = 0, {};
	for path, want in pairs(by_file) do
		if (not string.find(path, "/locales/" .. lang .. "%.po$")) then
			error(path .. " is not a " .. lang .. ".po", 0);
		end
		local cat = P.parse(read(path));
		for _, e in ipairs(cat.list) do
			local s = want[P.key(e.ctx, e.msgid)];
			if (s ~= nil) then
				if (not same_placeholders(e.msgid, s)) then
					refused[#refused+1] = path .. ": " .. e.msgid .. "  ->  " .. s;
				else
					e.str, e.fuzzy = s, false;
					local c = {};
					for _, x in ipairs(e.comments or {}) do
						if (not MARKS[x] and not string.find(x, "^# from .*: review$")) then
							c[#c+1] = x;
						end
					end
					e.comments = c;
					done = done + 1;
				end
			end
		end
		local w = assert(io.open(path, "w"));
		w:write(P.write(cat.header, cat.list));
		w:close();
	end

	print(string.format("%s: %d entr%s reviewed", lang, done, done == 1 and "y" or "ies"));
	if (#refused > 0) then
		print(#refused .. " refused (placeholders differ from the English):");
		for _, r in ipairs(refused) do print("  " .. r); end
		os.exit(1);
	end
	os.exit(0);
end

io.stderr:write("usage: luajit dev/l10n_review.lua todo <lang>\n"
	.. "       luajit dev/l10n_review.lua apply <lang> <file.lua>\n");
os.exit(2);
