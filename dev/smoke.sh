#!/bin/sh
# dev/smoke.sh -- build the image, boot a server, administer it
#
# What a user does on day one, end to end: start with an empty volume,
# wait for the server, install a script with a preset, restart, and
# check the server actually loaded it.
set -eu
cd "$(dirname "$0")/.."

IMAGE=${IMAGE:-lsd-docker:smoke}
NAME=lsd-smoke-$$
VOL=lsd-smoke-$$

if [ -z "${SKIP_BUILD:-}" ]; then
	# for this machine's own arch, so nothing runs under emulation
	docker build \
		--build-arg VERSION="$(cat VERSION)" \
		--build-arg LSD_COMMIT="$(git -C lsd rev-parse --short=10 HEAD 2>/dev/null || echo unknown)" \
		-t "$IMAGE" .
fi

cleanup() {
	docker logs "$NAME" >smoke.log 2>&1 || true
	docker rm -f "$NAME" >/dev/null 2>&1 || true
	docker volume rm "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { echo "SMOKE FAIL: $*" >&2; docker logs "$NAME" 2>&1 | tail -60 >&2; exit 1; }

wait_up() {
	i=0
	until docker exec "$NAME" lsdctl status 2>/dev/null | grep -q 'server: *running'; do
		i=$((i + 1)); [ $i -lt 90 ] || fail "server did not come up ($1)"
		sleep 2
	done
}

# Settings first, unlisted: a test server must never show up on the
# public server lists.
docker run --rm -v "$VOL:/data" "$IMAGE" setup --defaults >/dev/null \
	|| fail "setup --defaults"
docker run --rm -v "$VOL:/data" "$IMAGE" set masterlist_enabled False >/dev/null \
	|| fail "set before start"
# policies from when everything came "recommended", and Player Limit's
# old 254 seats, under the question the setup of the time wrote:
# migrated at start to today's defaults (255 seats, Player Limit required)
docker run --rm -i -v "$VOL:/data" --entrypoint sh "$IMAGE" -s <<'EOS' || fail "seed old seats"
set -e
awk '/^# ---- player_limit ----/{print; print "# How many players may the server seat (above 32, an old client may mishandle high player ids)?"; print "player_limit_max = 254"; skip = 1; next}
	skip && /^(#|player_limit_max)/{next}
	{skip = 0; print}' /data/settings > /data/settings.new
mv /data/settings.new /data/settings
EOS
docker run --rm -v "$VOL:/data" "$IMAGE" get player_limit_max | grep -qx 254 || fail "seed: old seats not in the file"
docker run --rm -v "$VOL:/data" "$IMAGE" set ext_policy "{48: 'recommended', 192: 'recommended', 0x20: 'required', 0x33: 'required'}" >/dev/null \
	|| fail "set old policies"
# a server from when daytime and flashlight were two scripts: night now,
# their sections merged, every value kept (and a policy chosen for 0x33
# kept; 0x32 had none)
docker run --rm -i -v "$VOL:/data" --entrypoint sh "$IMAGE" -s <<'EOS' || fail "seed old daytime and flashlight"
set -e
awk '/^# ---- /{skip = ($3 == "night")}
	/^\t"night",$/{print "\t\"daytime\","; print "\t\"flashlight\","; next}
	!skip' /data/settings > /data/settings.new
mv /data/settings.new /data/settings
cat >> /data/settings <<'OLD'

# ---- daytime ----  Daytime and Weather, extension
daytime_night = True

# ---- flashlight ----  Flashlight, extension
flashlight_red = 200
flashlight_reach = 75
OLD
EOS
docker run --rm -v "$VOL:/data" "$IMAGE" get scripts | grep -q '"flashlight"' || fail "seed: flashlight not in the old scripts"
# a setting from before world_editor became map_layout, migrated at start
docker run --rm -v "$VOL:/data" "$IMAGE" set world_editor_door_speed 9 >/dev/null \
	|| fail "set an old setting"
docker run -d --name "$NAME" -v "$VOL:/data" "$IMAGE" >/dev/null
wait_up "first boot"
echo "ok: first boot on default settings"
docker exec "$NAME" lsdctl get map_layout_door_speed | grep -qx 9 \
	|| fail "world_editor_door_speed was not migrated to map_layout_door_speed"
docker exec "$NAME" lsdctl get world_editor_door_speed >/dev/null \
	&& fail "the old world_editor_door_speed is still there"
echo "ok: old world_editor settings migrated"
docker exec "$NAME" lsdctl get player_limit_max | grep -qx 255 || fail "254 seats not migrated to 255"
pol=$(docker exec "$NAME" lsdctl get ext_policy)
echo "$pol" | grep -Eq '48: *"applied"' || fail "teamplay's old recommended not migrated: $pol"
echo "$pol" | grep -Eq '192: *"required"' || fail "player_limit's old recommended not migrated: $pol"
echo "$pol" | grep -Eq '32: *"required"' || fail "a policy set by hand was changed: $pol"
echo "ok: old policies and seats migrated, a chosen policy kept"
scripts=$(docker exec "$NAME" lsdctl get scripts)
echo "$scripts" | grep -q '"night"' || fail "daytime and flashlight did not become night: $scripts"
echo "$scripts" | grep -Eq '"(daytime|flashlight)"' && fail "daytime or flashlight still installed: $scripts"
docker exec "$NAME" lsdctl get flashlight_red | grep -qx 200 || fail "flashlight_red not kept in night's section"
docker exec "$NAME" lsdctl get flashlight_reach | grep -qx 75 || fail "flashlight_reach not kept in night's section"
docker exec "$NAME" lsdctl get daytime_night | grep -qi true || fail "daytime_night not kept in night's section"
docker exec "$NAME" grep -Eq '^# ---- (daytime|flashlight) ----' /data/settings && fail "an old section is still in the file"
echo "$pol" | grep -Eq '51: *"required"' || fail "daytime's chosen policy was changed: $pol"
echo "$pol" | grep -Eq '50: *"applied"' || fail "flashlight (new to the server's policies) has no default: $pol"
docker logs "$NAME" 2>&1 | grep -q 'lib_night' || fail "lib_night not loaded after the migration"
echo "ok: daytime and flashlight migrated to night, values and policies kept"

# maps: where to find them, a map added from a file (the same path a
# download takes after it lands), and something that is not a map refused
docker exec "$NAME" lsdctl map list | grep -q "find maps on aos.party" \
	|| fail "map list does not point at aos.party on a fresh server"
docker exec "$NAME" cp /data/maps/flat.vxl /tmp/Copy.vxl
docker exec "$NAME" lsdctl map add /tmp/Copy.vxl | grep -q "added Copy.vxl" || fail "map add of a file"
docker exec "$NAME" sh -c 'head -c 4096 /data/maps/flat.vxl > /tmp/Tiny.vxl'
docker exec "$NAME" lsdctl map add /tmp/Tiny.vxl >/dev/null 2>&1 && fail "a file too small to be a map was added"
# random maps: one now, and the whole rotation shuffled
docker exec "$NAME" lsdctl map load random | grep -Eq "loading (flat|Copy)" || fail "map load random"
docker exec "$NAME" lsdctl set map_random True --now >/dev/null || fail "set map_random"
sleep 3
wait_up "after map_random"
docker exec "$NAME" lsdctl exec 'exec log("SHUF|" .. tostring(map_queue_shuffle) .. "|")' | grep -q "SHUF|true|" \
	|| fail "map_random does not shuffle the rotation"
docker exec "$NAME" lsdctl set map_random False --no-restart >/dev/null
docker exec "$NAME" lsdctl map rm Copy >/dev/null || fail "map rm"
echo "ok: map list points at aos.party; map add takes a map and refuses a non-map; random maps"

docker exec "$NAME" lsdctl status
docker exec "$NAME" lsdctl available >/dev/null
docker exec "$NAME" lsdctl install night --preset disco --policy required --yes --now \
	|| fail "install"
sleep 3
wait_up "after install"
docker logs "$NAME" 2>&1 | grep -q 'lib_night' || fail "lib_night not loaded"
docker exec "$NAME" lsdctl get flashlight_colors | grep -q random || fail "preset not written"
echo "ok: install with a preset, server restarted and loaded it"

# every effect, both kinds: catalog/effects/<kind>/<id>/ is one level
# deeper than the other categories, and the player effects all load on
# lib_player_effect
docker exec "$NAME" lsdctl install railgun grenade_shotgun pinning_smg the_fall --yes --now \
	|| fail "install effects"
sleep 3
wait_up "after effects"
for m in lib_player_effect rifle_is_a_rail_gun shotgun_are_grenade_launchers \
         smg_is_incapacitating the_fall; do
	docker logs "$NAME" 2>&1 | grep -q "$m" || fail "$m not loaded"
done
echo "ok: player and world effects load"

# the triggered effects: medkit (upstream's, now a player effect under the
# same id and commands), area_heal and area_hurt
docker exec "$NAME" lsdctl install medkit area_heal area_hurt --yes --now >/dev/null \
	|| fail "install triggered effects"
sleep 3
wait_up "after triggered effects"
fx=$(docker exec "$NAME" lsdctl exec 'exec log("FX|" .. tostring(PlayerEffect.get("area_heal") ~= nil) .. "|" .. tostring(PlayerEffect.get("area_hurt") ~= nil) .. "|" .. tostring(commands.m and commands.m.desc) .. "|" .. tostring(PlayerEffect.get("medkit"):trigger(MAX_PLAYERS - 1)) .. "|")')
echo "$fx" | grep -q "FX|true|true|Use a medkit.|nil|" || fail "triggered effects: $fx"
echo "ok: medkit, area_heal and area_hurt load; a trigger for nobody does nothing"

# the editor gamemode: place a door from the console by coordinates (a
# one-block-thick panel in open air), save the map with its layout, and
# find the layout running again once a game mode loads that map
docker exec "$NAME" lsdctl gamemode editor --yes --now >/dev/null || fail "gamemode editor"
sleep 3
wait_up "after gamemode editor"
docker logs "$NAME" 2>&1 | grep -q "gamemode editor" || fail "the editor is not running"
# one console connection for both: a placement belongs to its session,
# and every lsdctl exec is a session of its own
docker exec "$NAME" sh -c 'printf "place door left\nmarks 256 256 10 256 258 12\n" \
	| socat -t 2 - UNIX-CONNECT:/data/rw/console.sock' >/dev/null
placed=$(docker exec "$NAME" lsdctl exec 'exec local n = 0; for _ in pairs(map_layout.instances()) do n = n + 1 end; log("PLACED|" .. n .. "|")')
echo "$placed" | grep -q "PLACED|1|" || fail "door not placed from the console: $placed"
docker exec "$NAME" lsdctl exec 'save smoketest' >/dev/null
docker exec "$NAME" test -s /data/maps/smoketest.vxl || fail "save wrote no .vxl"
docker exec "$NAME" grep -q '"kind": "door"' /data/maps/smoketest.editor.json \
	|| fail "save wrote no layout with the door"
echo "ok: the editor places a door and saves the map with its layout"
# its tools are in the pie menu, first; time_limit is paused while it runs
# (an empty slot can run no command, so the build skips that check)
pies=$(docker exec "$NAME" lsdctl exec 'exec local h = pie_menu_hide_unavailable; pie_menu_hide_unavailable = false; local b = pie_menu_build(MAX_PLAYERS - 1) or ""; pie_menu_hide_unavailable = h; log("PIES|" .. tostring(b:find("/sel1 %b", 1, true) ~= nil) .. "|" .. tostring(b:find("/place door left", 1, true) ~= nil) .. "|" .. tostring(b:find("/selfill", 1, true) < (b:find("/ratio", 1, true) or 1e9)) .. "|" .. tostring(package.loaded.time_limit == nil) .. "|")')
echo "$pies" | grep -q "PIES|true|true|true|true|" || fail "editor pies or time_limit: $pies"
echo "ok: the editor's tools are in the pie menu, first; time_limit is paused"

docker exec "$NAME" lsdctl gamemode ctf --yes --now >/dev/null || fail "back to ctf"
sleep 3
wait_up "after leaving the editor"
docker exec "$NAME" lsdctl map load smoketest >/dev/null || fail "map load smoketest"
sleep 2
running=$(docker exec "$NAME" lsdctl exec 'exec local n = 0; for _ in pairs(map_layout.instances()) do n = n + 1 end; log("RUNNING|" .. n .. "|" .. tostring(commands.place == nil) .. "|")')
echo "$running" | grep -q "RUNNING|1|true|" || fail "the layout does not run in ctf, or the editor stayed: $running"
docker exec "$NAME" rm -f /data/maps/smoketest.vxl /data/maps/smoketest.editor.json
echo "ok: ctf runs the saved map's door; the editor's commands are gone"


# translations: a script's locales/fr.po, installed by the entrypoint as
# scripts/locales/fr/<id>.po, is what the server answers in French with
fr=$(docker exec "$NAME" lsdctl exec 'exec log("L10N|" .. l10n_get_str_lang("fr_ca", {en = "warning: here rifles are railguns."}) .. "|" .. l10n_get_str_lang("fr", {en = "Language set to %(lang)."}, {lang = "fr"}) .. "|")')
echo "$fr" | grep -q "L10N|attention : ici, les fusils sont des railguns.|Langue réglée sur fr.|" \
	|| fail "French from the scripts' catalogs: $fr"
echo "ok: translations from per-script catalogs"

# settings text: the stock tips and motd are language maps, translated
fr=$(docker exec "$NAME" lsdctl exec 'exec log("L10N2|" .. l10n_get_str_lang("fr", tips[1]) .. "|" .. l10n_get_str_lang("fr", motd[1], {server = "S"}) .. "|")')
echo "$fr" | grep -q "L10N2|Tape /kill pour mourir.|Bienvenue sur S, propulsé par \[LSd\].|" \
	|| fail "French settings text: $fr"
echo "ok: settings text translated"

# upstream LSd's own text: a message and a command's description
fr=$(docker exec "$NAME" lsdctl exec 'exec log("L10N3|" .. l10n_get_str_lang("fr", {en = "Unknown command"}) .. "|" .. l10n_get_str_lang("fr", {en = "Print the server\x27s version.", ctx = "command"}) .. "|")')
echo "$fr" | grep -q "L10N3|Commande inconnue|Afficher la version du serveur.|" \
	|| fail "French for upstream LSd: $fr"
echo "ok: upstream LSd's text translated"

# the gate: translations for the current ZeroSpades only
gate=$(docker exec "$NAME" lsdctl exec 'exec log("GATE|%s|%s|", tostring(l10n_client_matches("Linux | ZeroSpades 0.0.9 abc (x86_64)")), tostring(l10n_client_matches("Linux | OpenSpades 0.1.5 (x86_64)")))')
echo "$gate" | grep -q "GATE|true|false|" || fail "the ZeroSpades gate: $gate"
echo "ok: translations gated to the current ZeroSpades"

# every language translates everything: all are offered, and used
langs=$(docker exec "$NAME" lsdctl exec 'exec log("LANGS|" .. table.concat(l10n_languages(), ",") .. "|" .. l10n_get_str_lang("es", {en = "Unknown command"}) .. "|" .. l10n_get_str_lang("zh", {en = "Unknown command"}) .. "|" .. l10n_get_str_lang("ru", {en = "Unknown command"}) .. "|")')
echo "$langs" | grep -q "LANGS|en,es,fr,ru,zh|" || fail "languages offered: $langs"
echo "$langs" | grep "LANGS|" | grep -q "|Unknown command|" && fail "a language falls back to English: $langs"
echo "ok: Spanish, Chinese and Russian are offered and used"

# the pie menu: commands put themselves in it (votekick, /lang), in the
# player's language, through the scripts' own translations
docker exec "$NAME" lsdctl install pie_menu --yes --now >/dev/null || fail "install pie_menu"
sleep 3
wait_up "after pie_menu"
# (slot 0 has no client to pass the ZeroSpades gate, so it is opened
# for this one build and closed again)
pie=$(docker exec "$NAME" lsdctl exec 'exec local g = l10n_client_ok; l10n_client_ok = function() return true end; l10n_set_lang(0, "fr"); local b = pie_menu_build(0) or ""; log("PIE|%s|%s|%s|", tostring(b:find("/votekick %p", 1, true) ~= nil), tostring(b:find("Voter l\x27exclusion", 1, true) ~= nil), tostring(b:find("/lang", 1, true) ~= nil)); l10n_set_lang(0, nil); l10n_client_ok = g')
echo "$pie" | grep -q "PIE|true|true|true|" || fail "pie menu registrations: $pie"
echo "ok: commands register into the pie menu, translated"
# the gamemode's callouts: their pie first, its wedges /callout
co=$(docker exec "$NAME" lsdctl exec 'exec local h = pie_menu_hide_unavailable; pie_menu_hide_unavailable = false; local b = pie_menu_build(MAX_PLAYERS - 1) or ""; pie_menu_hide_unavailable = h; log("CO|" .. tostring(commands.callout ~= nil) .. "|" .. tostring(b:find("/callout enemy", 1, true) ~= nil) .. "|" .. tostring((b:find("/callout", 1, true) or 1e9) < (b:find("Thanks!", 1, true) or 0)) .. "|")')
echo "$co" | grep -q "CO|true|true|true|" || fail "ctf callouts: $co"
echo "ok: ctf has its callouts pie, first"
# and its pings in the Mark pie, for a client with Teamplay only
pg=$(docker exec "$NAME" lsdctl exec 'exec local h = pie_menu_hide_unavailable; pie_menu_hide_unavailable = false; local t = teamplay_supported; local id = MAX_PLAYERS - 1; teamplay_supported = function() return true end; local b = pie_menu_build(id) or ""; teamplay_supported = function() return false end; local n = pie_menu_build(id) or ""; teamplay_supported = t; pie_menu_hide_unavailable = h; log("PG|" .. tostring(b:find("/pingmark %h Intel here", 1, true) ~= nil) .. "|" .. tostring(n:find("/pingmark", 1, true) ~= nil) .. "|")')
echo "$pg" | grep -q "PG|true|false|" || fail "ctf pings: $pg"
echo "ok: ctf pings are in the Mark pie, for Teamplay clients only"
# rewards live in the inventory: an item held shows as a counted wedge
iv=$(docker exec "$NAME" lsdctl exec 'exec local id = MAX_PLAYERS - 1; inventory_give(id, "rocket", 2); local h = pie_menu_hide_unavailable; pie_menu_hide_unavailable = false; local b = pie_menu_build(id) or ""; pie_menu_hide_unavailable = h; inventory_set(id, "rocket", 0); log("IV|" .. tostring(commands.inv ~= nil and commands.reward ~= nil) .. "|" .. tostring(b:find("/inv rocket %h", 1, true) ~= nil) .. "|" .. tostring(b:find("Rocket x2", 1, true) ~= nil) .. "|" .. tostring(b:find("/inv medkit", 1, true) ~= nil) .. "|")')
echo "$iv" | grep -q "IV|true|true|true|false|" || fail "inventory: $iv"
echo "ok: a reward held is a counted wedge of the Inventory pie; none held, none shown"

docker exec "$NAME" lsdctl gamemode hostage --yes --now || fail "gamemode"
sleep 3
wait_up "after gamemode"
docker logs "$NAME" 2>&1 | grep -q 'gamemode hostage' || fail "hostage not running"
echo "ok: gamemode switch"

docker exec "$NAME" lsdctl set masterlist_name "'smoke test'" || fail "set"
docker exec "$NAME" lsdctl remove night --yes --now || fail "remove"
sleep 3
wait_up "after remove"
echo "ok: set, remove"

# a script of the operator's own, on the data volume: installed like any
# other, translated by its own locales/, and still there after the
# container is recreated from the image -- which is what an update does
docker exec -i "$NAME" sh -c 'mkdir -p /data/catalog/tools/hello/locales &&
	cat > /data/catalog/tools/hello/script.lua &&
	printf "%s\n" \
		"local mod = init_mod();" \
		"local cmd = {name = \"hello\", desc = \"Say hello.\"};" \
		"function cmd.func(pid)" \
		"	l10n_send_chat(pid, {en = \"Hello, %(name)!\"}, {name = get_name(pid)});" \
		"end" \
		"register_command(cmd, mod);" \
		"return mod;" > /data/catalog/tools/hello/hello.lua &&
	printf "%s\n" \
		"msgid \"\"" "msgstr \"\"" \
		"\"Content-Type: text/plain; charset=UTF-8\\n\"" \
		"\"Plural-Forms: nplurals=2; plural=(n > 1);\\n\"" "" \
		"msgid \"Hello, %(name)!\"" "msgstr \"Bonjour, %(name) !\"" \
		> /data/catalog/tools/hello/locales/fr.po' \
	<<'MANIFEST' || fail "write a local script"
return Tool {title = "Hello", summary = "Says hello.", module = "hello"}
MANIFEST
docker exec "$NAME" lsdctl available tools | grep -q "hello .*(yours)" || fail "local script not listed as yours"
docker exec "$NAME" lsdctl install hello --yes --now >/dev/null || fail "install local script"
sleep 3
wait_up "after local script"
local_ok() {
	out=$(docker exec "$NAME" lsdctl exec 'exec log("HELLO|" .. tostring(commands.hello ~= nil) .. "|" .. l10n_get_str_lang("fr", {en = "Hello, %(name)!"}, {name = "Al"}) .. "|")')
	echo "$out" | grep -q "HELLO|true|Bonjour, Al !|"
}
local_ok || fail "local script not loaded, or not translated"
echo "ok: a local script loads, with its translations"

docker rm -f "$NAME" >/dev/null
docker run -d --name "$NAME" -v "$VOL:/data" "$IMAGE" >/dev/null
wait_up "after recreating the container"
local_ok || fail "local script lost when the container was recreated"
docker exec "$NAME" lsdctl info hello | grep -q "yours: updates keep it" || fail "lsdctl info"
echo "ok: it survives the container being recreated, as on update"

# lsdctl local: the operator's scripts, and whether each is running
docker exec "$NAME" sh -c 'echo "return nil" > /data/scripts/extra.lua'
mine=$(docker exec "$NAME" lsdctl local)
echo "$mine" | grep -q "hello .* running" || fail "lsdctl local: hello not running: $mine"
echo "$mine" | grep -q "extra.lua .*not running" || fail "lsdctl local: loose module: $mine"
docker exec "$NAME" rm /data/scripts/extra.lua
echo "ok: lsdctl local lists the operator's scripts and what runs"

# the update check: the registry answers, and a newer version reaches
# status and the admins' notice
check=$(docker exec "$NAME" lsdctl update-check) || fail "update-check: $check"
echo "$check" | grep -Eq "up to date|is available|development build" || fail "update-check said: $check"
# Nothing is newer than a build that is not a release, and CI builds
# ci-<sha>: status compares with the version it runs, so its line is
# checked on a release build (the release workflow's smoke test) only.
# The notice reads the running version from the file, so it is told one.
docker exec "$NAME" sh -c 'printf "running 2000.1.1.1\nlatest 2999.1.1.1\nchecked now\n" > /data/rw/update-check'
running_v=$(docker exec "$NAME" cat /lsd/VERSION)
case $running_v in
[0-9]*.[0-9]*.[0-9]*.[0-9]*)
	docker exec "$NAME" lsdctl status | grep -q "update: *2999.1.1.1 available" || fail "status does not show the update" ;;
*)
	echo "skip: status's update line (a $running_v build is not a release)" ;;
esac
note=$(docker exec "$NAME" lsdctl exec 'exec log("NOTE|" .. tostring(update_notice()) .. "|")')
echo "$note" | grep -q "NOTE|lsd-docker 2999.1.1.1 is available" || fail "notice: $note"
docker exec "$NAME" rm /data/rw/update-check
echo "ok: update check, status and the admins' notice"

# play: a casual game on a throwaway container. Offline here: a map that
# cannot be had leaves the generated one. Nobody joins, so with play_wait
# cut to a second it ends by itself -- and Docker takes the container
# and its volume with it.
PLAY=lsd-play-$$
docker run --rm -d --name "$PLAY" "$IMAGE" play tdm nowhere:1 >/dev/null || fail "start play"
i=0
until docker exec "$PLAY" lsdctl status 2>/dev/null | grep -q 'server: *running'; do
	i=$((i + 1)); [ $i -lt 60 ] || { docker logs "$PLAY" | tail -20 >&2; fail "play did not come up"; }
	sleep 2
done
docker logs "$PLAY" 2>&1 | grep -q "playing a generated one" || fail "play did not fall back to a generated map"
pv=$(docker inspect -f '{{range .Mounts}}{{.Name}}{{end}}' "$PLAY")
state=$(docker exec "$PLAY" lsdctl exec 'exec log("PLAY|" .. tostring(play_mode) .. "|" .. tostring(masterlist_enabled) .. "|")')
echo "$state" | grep -q "PLAY|true|false|" || fail "play mode: $state"
# tdm, the default game: ctf underneath, its rider loaded, nothing broken
tdm=$(docker exec "$PLAY" lsdctl exec 'exec log("TDM|" .. tostring(package.loaded.tdm ~= nil) .. "|" .. tostring(tdm_kills) .. "|")')
echo "$tdm" | grep -q "TDM|true|50|" || fail "tdm not loaded: $tdm"
if docker logs "$PLAY" 2>&1 | grep -E 'failed to load|stack traceback'; then
	fail "errors in the play server's log"
fi
# the server ends at once on this, taking the exec with it
docker exec "$PLAY" lsdctl exec 'exec play_wait = 1' >/dev/null 2>&1 || true
i=0
while docker container inspect "$PLAY" >/dev/null 2>&1; do
	i=$((i + 1)); [ $i -lt 30 ] || { docker rm -f "$PLAY" >/dev/null; fail "play did not end by itself"; }
	sleep 1
done
[ -n "$pv" ] && docker volume inspect "$pv" >/dev/null 2>&1 && fail "play left its volume behind"
echo "ok: play runs tdm unlisted and ends by itself, leaving nothing behind"

if docker logs "$NAME" 2>&1 | grep -E 'failed to load|is installed but not in the catalog|stack traceback'; then
	fail "errors in the server log"
fi
if docker logs "$NAME" 2>&1 | grep -q 'Connected to masterlist'; then
	fail "the test server announced itself to a public server list"
fi
echo "SMOKE OK"
