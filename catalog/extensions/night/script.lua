-- Night: the Daytime and Weather and Flashlight protocol extensions,
-- and how the bots behave in the dark -- one file, lib_night, because
-- by night the flashlight is the only light there is.
--
-- An entry takes ONE preset, so night's are the combinations that mean
-- something: whether it is day or night, and the beam. The flashlight's
-- own looks (night vision, disco) come at night, where a light matters.
local DEFAULT_BEAM = {
	flashlight_visibility = "all",
	flashlight_colors = "fixed",
	flashlight_red = 255, flashlight_green = 179, flashlight_blue = 128,
	flashlight_reach = 60, flashlight_cone = 90,
};

local function preset(name, summary, night, beam)
	local values = {daytime_night = night};
	for k, v in pairs(beam) do values[k] = v; end
	return {name = name, summary = summary, values = values};
end

return Extension {
	title = "Night",
	summary = "Day or night, and server-controlled flashlights: the F key, beam shape and colour.",
	module = "lib_night",
	exts = {
		-- by day it changes nothing; by night a client without it sees a
		-- black fog instead of real darkness, and is told so
		{id = 0x33, title = "Daytime and Weather",
			policy = function(v) return v.daytime_night == true and "recommended" or "applied"; end},
		-- a client without it has no light, and needs none by day
		{id = 0x32, title = "Flashlight", policy = "applied"},
	},
	presets = {
		preset("day", "ordinary daylight, OpenSpades' warm white beam seen by everybody",
			false, DEFAULT_BEAM),
		preset("night", "full darkness: only flashlights light the world, the default beam",
			true, DEFAULT_BEAM),
		preset("night_vision",
			"night, with a green beam only its carrier sees: nobody spots your light", true, {
				flashlight_visibility = "self",
				flashlight_colors = "fixed",
				flashlight_red = 40, flashlight_green = 255, flashlight_blue = 64,
				flashlight_reach = 70, flashlight_cone = 100,
			}),
		preset("disco", "night, every player's beam a random colour, changing as they play", true, {
			flashlight_visibility = "all",
			flashlight_colors = "random",
			flashlight_reach = 60, flashlight_cone = 90,
		}),
	},
	questions = {
		{key = "flashlight_blast", type = "boolean", default = false,
			ask = "Make nearby grenade blasts shake beams into a flicker?"},
	},
}
