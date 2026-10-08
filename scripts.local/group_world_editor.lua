-- group_world_editor.lua -- Group of everything the map editor needs
-- Copyright (C) 2026 Fran6nd. AGPL-3.0-or-later; see LICENSE.
--
-- Mirrors the stock group_* scripts (group_commands, group_feature,
-- group_deps): one `load "group_world_editor"` in an instance config
-- instead of a list, and the dependency order lives here rather than in
-- every config that wants the editor.
--
-- sel and noclip are deliberately NOT loaded here. world_editor loads
-- them itself when edit mode is switched on and unloads them again
-- after, so a server running the editor does not hand every player bulk
-- terrain tools and free flight for the rest of the round. Listing them
-- here would defeat that.
--
-- Grant the "worldedit" cap to whoever should be able to switch edit
-- mode on -- it is console-gated as well, so this is belt and braces:
--
--   cap_groups = { admin = {"all"}, ... }        -- already covers it
--   cap_groups = { mod = {"guard", "worldedit"} }
--
-- "worldedit_build" is granted automatically, to everyone present, for
-- as long as edit mode is on. It is not meant to be in a cap group.

-- lib_l10n is loaded rather than required so it is a registered module
-- and /lsmod stays honest about what is running, which is how group_deps
-- treats it.
--
-- lib_bulk_destroy is a registered module (upstream 079db5d) that
-- group_deps loads before anything else, and it is its registration that
-- publishes bdestroy_* as globals. So it is required here, not loaded:
-- this states the dependency without load()'s unload-and-reload of a
-- module already running.
require "lib_bulk_destroy"
load "lib_l10n"

load "world_editor"
