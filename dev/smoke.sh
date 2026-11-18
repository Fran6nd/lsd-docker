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
docker run -d --name "$NAME" -v "$VOL:/data" "$IMAGE" >/dev/null
wait_up "first boot"
echo "ok: first boot on default settings"

docker exec "$NAME" lsdctl status
docker exec "$NAME" lsdctl available >/dev/null
docker exec "$NAME" lsdctl install flashlight --preset disco --policy required --yes --now \
	|| fail "install"
sleep 3
wait_up "after install"
docker logs "$NAME" 2>&1 | grep -q 'lib_flashlight' || fail "lib_flashlight not loaded"
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

# machine-translated drafts (fuzzy) are installed but never shown
draft=$(docker exec "$NAME" lsdctl exec 'exec log("DRAFT|" .. l10n_get_str_lang("es", {en = "Vote kicked"}) .. "|" .. table.concat(l10n_languages(), ",") .. "|")')
echo "$draft" | grep -q "DRAFT|Vote kicked|en,fr|" || fail "drafts must stay unused: $draft"
echo "ok: unreviewed drafts are not shown"

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

docker exec "$NAME" lsdctl gamemode hostage --yes --now || fail "gamemode"
sleep 3
wait_up "after gamemode"
docker logs "$NAME" 2>&1 | grep -q 'gamemode hostage' || fail "hostage not running"
echo "ok: gamemode switch"

docker exec "$NAME" lsdctl set masterlist_name "'smoke test'" || fail "set"
docker exec "$NAME" lsdctl remove flashlight --yes --now || fail "remove"
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
docker exec "$NAME" sh -c 'printf "running %s\nlatest 2999.1.1.1\nchecked now\n" "$(cat /lsd/VERSION)" > /data/rw/update-check'
docker exec "$NAME" lsdctl status | grep -q "update: *2999.1.1.1 available" || fail "status does not show the update"
note=$(docker exec "$NAME" lsdctl exec 'exec log("NOTE|" .. tostring(update_notice()) .. "|")')
echo "$note" | grep -q "NOTE|lsd-docker 2999.1.1.1 is available" || fail "notice: $note"
docker exec "$NAME" rm /data/rw/update-check
echo "ok: update check, status and the admins' notice"

if docker logs "$NAME" 2>&1 | grep -E 'failed to load|is installed but not in the catalog|stack traceback'; then
	fail "errors in the server log"
fi
if docker logs "$NAME" 2>&1 | grep -q 'Connected to masterlist'; then
	fail "the test server announced itself to a public server list"
fi
echo "SMOKE OK"
