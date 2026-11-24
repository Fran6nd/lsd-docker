# Decisions made in C: the audit (WORK.md item 4)

The owner's rule: **the tree decides WHAT a bot does; the engine only
decides HOW.** This is every place in `bot/core/` where C still chooses
what a bot does, or carries a number a tree author would want to change,
as read on 2026-11-24 (HEAD 3e0b428). Each line says where it is, what it
decides, which of three kinds it is, and what to do with it:

- **HOW** -- the way a thing the tree asked for is done (how to walk
  there, how to aim, which keys). It stays in C.
- **WHAT** -- a choice of what to do, which belongs in the tree's
  structure (a condition, an option, a separate action).
- **NUMBER** -- a fixed number or a character formula inside a word,
  which belongs in an argument of that word (with the same default), or in
  a setting the server sends when it concerns every bot alike.

"Risk" is what could move if the change is made: L (low: same default,
nothing else moves), M (behaviour or bench numbers move; tests must be
re-read), H (trees must be rewritten together with the code).

## Done in this step (a number becoming an argument, same default)

Each keeps its old number as its default, so every tree in `trees/` and
every bench number is unchanged; `bttree --words` and VOCAB.md show the
new arguments. Test: `skills_test`, "a word's argument where a number
was" (`sniped` against `sniped 30` for a hit from 40 voxels; `retreat 2`
in sight of the man ends after 2 s).

| word | was | now |
|---|---|---|
| `camp` | left the perch after 2 kills | `camp [secs] [kills]`, kills default 2 (secs 0 = by character, as before) |
| `retreat` | gave up after 10 s | `retreat [secs]`, default 10 |
| `sniped` | hit within 3 s from more than 50 | `sniped [voxels] [secs]`, defaults 50 and 3 |
| `outnumbered` (condition and score) | team-mates counted within 20 | `outnumbered [radius]`, default 20 |
| `target_in_cover` | seen under 5 s ago | `target_in_cover [secs]`, default 5 |
| `spotted_new` | within 2 s | `spotted_new [secs]`, default 2 |
| `allies_hurt_near` | a mate under 50 health | `allies_hurt_near <radius> [hp]`, default 50 |
| `carry_home` | shoots only at a man within 14 | `carry_home [voxels]`, default 14 |

## The table

### Being shot at, cover, looking

| # | where | what it decides | kind | proposed move | risk |
|---|---|---|---|---|---|
| 1 | skill_cover.c `bc_cover_query` (HIDE) | which cover to take when shot at: the cheapest of every cell within 12 walked steps, in ANY direction, including behind the bot; the price favours near cells and only mildly penalises getting nearer the threat | WHAT (where it may look for cover) + HOW (pricing) | STEP B: an argument to `take_cover` (`in_view`: only cells within the head's field of view and near), and a condition `cover_in_view` so the under-fire trees can say "cover in view: take it facing him; else face him". The pricing stays C. | M |
| 2 | skill_cover.c `bc_do_take_cover` TC_GO | the way to cover is walked as a route, so the body turns to the route and the head follows the follower: it turns its back on the shooter | HOW (wrong today) | STEP B: walk to cover with the head kept on the threat (strafe/back toward it), the keys remapped as for a fight | M |
| 3 | skill_cover.c `tc_arrive` | how long it stays in cover: 6 x caution - 3 x aggression + 2 s (0.8 to 14), and how often it peeks | NUMBER (time) + HOW (peek) | `take_cover [secs]` with "by character" as the default, as `camp` has; the peek rhythm stays C | L |
| 4 | skill_cover.c `bc_do_take_cover` TC_GO | shooting on the way to cover only for a bot with aggression over 1.3 | WHAT hidden behind a trait threshold | an argument (`take_cover ... firing`) or a select in the tree on `enemy_visible`; the default as today | L |
| 5 | skill_cover.c `bc_do_take_cover` TC_HOLD | seen in its cover for 1 s: looks for another, three times, then gives back to the tree | HOW (cover that is no cover) | keep | -- |
| 6 | skill_cover.c `bounds` | `fall_back_by_cover` ends when out of sight 1.5 s with no round for 3 s, or after 25 s; `advance_by_cover` fails after 90 s; the pause at each cover is 0.3 + 1.2 x caution - 0.5 x aggression s | NUMBER | `fall_back_by_cover [place] [secs]`, `advance_by_cover ... [secs]`; pauses stay by character (HOW) | L |
| 7 | skill_misc.c `bc_do_retreat` + skill_move.c `bc_find_cover` | retreat runs to the cheapest of 64 points on four rings, any direction, "back turned"; with none, 18 voxels straight away | HOW for an action the tree chose explicitly; the ring search is a second, older cover finder | keep `retreat` as the explicit "run away" word; make `bc_find_cover` use the cover query (one cover finder, not two); place `cover` likewise | M |
| 8 | skill_cover.c `bc_do_crouch` | the flinch lasts 0.25 + 0.35 x caution s (0.3 to 1), once per burst | HOW (has an argument already) | keep | -- |
| 9 | skill_look.c `bc_look_travel`, `choose`, `interval` | where the head is while travelling: a glance every 2.2 to 5.5 s / character (x 0.45 when alert), lasting reaction + 0.45 to 1 s, at a searched place (weight 3), an opening beside the route (2) or over a shoulder (0.35, 0.9 when alert); measured 33% of the time off the heading | HOW, but a policy the owner wants changed | STEP B: heading first, short glances as the exception; the rate and the share become settings (`gaze.every`, `gaze.back`), so a mode can make its bots more watchful without C | M |
| 10 | skill_tactics.c `bc_do_camp` | the sweep while camping (40 degrees either side, 9 s a sweep, a look at a noise every 6 s) | HOW | keep | -- |
| 11 | skill_misc.c `watch`, skill_objective.c guard, skill_squad.c station | the sweep when holding, guarding, standing by a leader; crouched when caution > 1.2 / 1.0 / 1.1 | HOW (by character) | keep; the three crouch thresholds could be one rule | L |

### What to do with nobody in sight

| # | where | what it decides | kind | proposed move | risk |
|---|---|---|---|---|---|
| 12 | skill_tactics.c `bc_do_seek` | an ITINERARY: the enemy's base, then where the team last met him (if under 60 s and 20 from the base), then back to halfway between the bases, and round; three failures in a row: roam 20 s | WHAT | a place `middle` (between the bases) added to the places; then `seek` can be written in a tree as a select of `go_to enemy_base`, `go_to hot`, `go_to middle` -- and `seek` kept as the shipped net that does the same. The tree version first in default.bt, measured against the bench before changing tdm/ctf | M |
| 13 | skill_tactics.c `bc_do_flank` | too near (< 30): fail, rest 15 s; no ground: rest 30 s; done: rest 30 s; failed: rest 40 s; a leg gives up after 90 s; the side by cover and the bot's own leaning | NUMBER (rests) + HOW (side) | the rests after success become an argument (`flank [place] [rest]`); the rests after a failure stay (they say "no way", which is HOW); `flank_open`'s 45 voxels an argument | L |
| 14 | skill_tactics.c `bc_rumour`, `bc_do_hunt_noise` | which rumour: freshness x (0.6 + 0.4 x aggression) - distance x (0.3 + 0.5 x caution); lifetimes 30 s (noise, sighting) and 60 s (the team's meeting); not one within 10 or just visited (30 s); failed: rest 10 s | NUMBER + a ranking by character | keep the ranking (it is what "the freshest rumour for this bot" means); lifetimes as settings (`rumour.secs`, `hot.secs`) | L |
| 15 | skill_tactics.c `perch_look`, `bc_perch_pick` | what a perch is (3 above the ground round it, 3 of 5 rays clear for 48, a quarter to nine tenths of the way to the enemy's base), and which one a bot takes (75 voxels from the enemy for a rifle, 45 otherwise) | NUMBER | settings `perch.height`, `perch.view`, and `take_high_ground [distance]`; also STEP C: a perch is taken only if there is a way DOWN, unless the tree says it means to camp there | M |
| 16 | skill_tactics.c `bc_do_camp` | ends when shot at, after 2 kills (now an argument), or patience (20 + 30 x caution x marksman, 25 to 120 s); then 6 s before a perch again | NUMBER, done in part | "when shot at" as an option (`camp ... stay`), the 6 s as an argument | L |
| 17 | vocab.c `s_vantage`, `s_mate_near`, `s_rumour`, `flank_open`, `nade_worth` | a score is forced to 0 while the matching action is resting (camp, follow, hunt, flank, grenade cooldowns) | WHAT hidden in C: a per-skill cooldown gates a choice | keep the coupling (bt.h says a score must be 0 when the action cannot be done), but the rest times become the actions' arguments (rows 13, 16, 19, 21) so that a tree author sees and sets them; the tree's own `cooldown` node remains the way to add more | L |
| 18 | skill_misc.c `bc_do_roam`, skill_move.c `bc_roam_goal` | where a roam goes: near the team's last meeting (24 round), else between the bases (45), else anywhere; least visited of 8; not within 40 of its own base; a new one after 20 to 40 s | HOW of the word roam | keep | -- |
| 19 | skill_misc.c `bc_do_follow` (mate) | follow the nearest team-mate who is not following; give up after 4 + 4 x teamwork s with him standing still, then 20 s rest; look again every 12 s | NUMBER | `follow mate [patience]`, the 20 s rest an argument | L |
| 20 | skill_misc.c `bc_do_investigate`, `look_round` | three looks of 0.7 to 1.3 s, then the place is forgotten | HOW | keep | -- |

### Fighting

| # | where | what it decides | kind | proposed move | risk |
|---|---|---|---|---|---|
| 21 | skill_fight.c `bc_fight_select` | WHOM it fights: the nearest in sight; switches only after 1.2 s and to one at half the distance; whoever shot it first; its leader's target over all | WHAT in part (who), run before every tree tick | an argument `fight [who]` (`nearest`, `shooter`, `leader`...) with today's rule as the default; the hysteresis stays C | M |
| 22 | skill_fight.c `bc_do_fight`, `strafe`, `bc_hold_range` | close in to the holding range (gun reach x level, shaped by marksman, caution, aggression), then strafe; 8% of men are met with the spade; crouch and jump in bouts | HOW (aosbot's mechanics) | keep. The tree already chooses "stand and shoot" (`hold self 4` on `standoff`) and "close by cover" (`advance_by_cover enemy`) as separate options | -- |
| 23 | skill_fight.c `bc_fire_at_will`, called by every moving skill | shoots its target if it is in sight and within reach -- in go_to, seek, flank, roam, guard, escort, hold, follow; not in retreat or fall_back; in take_cover only for the bold (row 4); in carry_home only within 14 (now an argument) | WHAT, documented word by word | keep as the default; where a tree may want the opposite it is an argument (rows 4, carry_home). A general `quiet` flag on every moving word would be heavier than the need | L |
| 24 | skill_fight.c `bc_fight_trigger`, `bc_reload_act` | bursts and gaps by gun, a mate in the line, reload when the magazine is under 10 to 50% by level and nothing is in sight | HOW | keep; `do reload` already lets a tree reload on purpose | -- |
| 25 | skill_grenade.c `bc_grenade_target` (the condition `grenade_worth`) | what is worth a grenade: two men within 5.5, one in sight 14 or more away, a place a man was lost in the last 5 s; 8 to 32 away | NUMBER (three criteria in one word) | arguments `grenade_worth [group] [far] [lost_secs]` with today's numbers; or three conditions (`enemies_grouped` exists already) so a tree can weigh each | L |
| 26 | skill_grenade.c `bc_do_throw`, `bc_grenade_threat` | vetoes (no arc, would hurt itself 25, would do under 22 + 35 x skill), sloppiness and rest by level, the flight from a grenade | HOW | keep | -- |
| 27 | vocab.c `losing`, `pressed`, `standoff`, `hurt_in_fight` | the fight's summary numbers: 45 / 30 health, "0 for 6 s after a retreat" | NUMBER + a hidden link to retreat | arguments for the thresholds; the 6 s after a retreat as an argument (`pressed [rest]`), so it is visible that a retreat silences them | L |

### Squads, pings, items

| # | where | what it decides | kind | proposed move | risk |
|---|---|---|---|---|---|
| 28 | skill_squad.c `bc_leaders_think` | WHO leads: one for every 5 (setting), by lot, a bot weighing 0.5 + 0.4 x aggression + 0.3 x objective - 0.3 x caution, a person 2 (setting); a term of 2 to 6 minutes; out after two deaths in a minute or a goal dropped as stuck | WHAT, made by the engine for the whole team | keep the draw in C (it is the team's, not one bot's tree) but its numbers as settings (`leaders.term`, and the weights as a trait list like `traits=`); whether a bot behaves as a leader is the tree's already (`is_leader`) | L |
| 29 | skill_squad.c `bc_leader_of` | WHO follows: never with teamwork under 0.75; the nearest leader with fewer than 4 | WHAT hidden behind a trait threshold, on top of the tree's own `option teamwork has_leader` | a setting `leaders.size` (4) and `leaders.min_teamwork` (0.75), later 0 by default so the tree's weighing alone decides; measure squad_test and the bench | M |
| 30 | skill_squad.c `bc_follow_leader` | WHEN they leave him: standing for 10 + 15 x teamwork s and not fighting; then 30 s on their own | NUMBER | `follow leader [patience]` (by character as default) | L |
| 31 | skill_squad.c `bc_squad_target` | a follower takes its leader's target within 40 | WHAT (whom), inside the fight's choice | goes with row 21 (`fight leader`) | M |
| 32 | engine.c `ev_ping` | WHO answers a ping: the 2 nearest (setting) within 40 (setting) with teamwork 0.7 or more, keenness dividing distance; the answerer is jolted | WHAT (who), at the event | the 0.7 a setting `ping_teamwork`; the answering itself is already the tree's (`ping_called`) | L |
| 33 | skill_misc.c `bc_do_ping` | WHETHER to say it: fails half the time at teamwork 1 (`rand > 0.5 x teamwork`), and rests 10 / teamwork s (4 to 30) | WHAT in the word | the dice and the rest move to the tree (`chance`, `cooldown`, a pick weighted by teamwork); the word keeps only "the team knows already" and the server's one-a-second. Changes every tree's callouts: do it together | M |
| 34 | skill_misc.c `bc_do_use` | rests after a use: 4 / greed s for that item, 1.5 / greed for any | NUMBER by character | `use <item> [place] [guide] [rest]`; greed stays the default | L |
| 35 | engine.c `with_generated` (items tree) | the items tree is a SELECT of every item's fragment, in name order | WHAT (order), deliberate and documented | keep (a pick would block the second item behind the first) | -- |

### Objectives

| # | where | what it decides | kind | proposed move | risk |
|---|---|---|---|---|---|
| 36 | skill_objective.c `bc_do_fetch` | on the intel and not given it after 4 s: fail (step off) | HOW | keep | -- |
| 37 | skill_objective.c `bc_do_carry_home` | the route keeps 18 from the nearest three enemies within 70; through them if no way round | HOW | keep | -- |
| 38 | skill_objective.c `bc_do_escort`, `bc_do_intercept`, `bc_do_guard` | stations (6 ahead and 3 aside; the point of his way home it reaches first; a spot 4 to 8 off on the enemy's side) | HOW | keep; guard's spot by cover/height is open (BRAIN-STATUS (g) 10) | -- |
| 39 | skill_objective.c `bc_objective_world` | an intel changing state jolts every bot | WHAT (what makes them think again) | goes with row 41 | -- |

### The engine's own choices (the net, thinking again)

| # | where | what it decides | kind | proposed move | risk |
|---|---|---|---|---|---|
| 40 | engine.c `watchdog` | the ladder: 1.5 s pushing -> a jump and a new plan with the failed move priced; 1.5 s more -> a step back, a sidestep with a jump; 1.5 s more -> OUT; 8 s in a 4-voxel circle -> OUT | HOW (unsticking a body) | keep | -- |
| 41 | engine.c `decide`, `bc_engine_event`, `bc_objective_world` | THE JOLT, what makes every pick choose again at once: engaged (a man in sight) for the first time, a grenade that threatens, a hit with nobody in sight or the first round of a burst, a round passing close, a mate killed within 12, a ping given to it, an order, an intel changing state, a goal dropped as stuck | WHAT (when to think again), for every tree alike | a tree-side declaration: the top pick says what wakes it (`pick every=1 wake=under_fire,enemy_visible,objective`), the engine only raises the named events. Needs bt.h (BRAIN-STATUS (h) 1-2: "re-choose this pick only"). Behind steps B-F | H |
| 42 | engine.c `stuck_out`, `pick_elsewhere` | after OUT: 4 s walking straight to somewhere else, away from what it pushed at, BEFORE the tree is ticked again; the seek itinerary skips a leg; the bot leads nobody for 60 s | WHAT (4 s the tree does not decide) | keep the goal failing and the team's memory (HOW); turn "somewhere else" into a condition `just_stuck [secs]` and an action `step_away`, the shipped trees putting it at the top. Low priority: it is the last net | M |
| 43 | engine.c `decide` (SHUT IN), skill_move.c | three searches with no way in 20 s: no route asked for 15 s, and the engine makes the bot PACE and look about, overriding the tree's move | WHAT (what a stranded bot does) | STEP C: a condition `shut_in` (or `stranded`) for the trees, which choose: hold and watch, shoot from there, camp; the pacing stays only as the fallback of a tree that says nothing. This is exactly the owner's "asking for routes or pacing an edge" | M |
| 44 | skill_tactics.c `bc_unreach_*`, skill_move.c (5 s, 20 s, 30 s) | a goal with no way is remembered by the team (30 s, within 5 of the goal and 24 of the start), the bot's own given-up goals (20 s), a search that failed (5 s) | HOW (a fact cached so the flood is not run 40 times) | keep; the times as settings if a mode wants them | -- |
| 45 | skill_move.c (edits) | twice refused: no editing for a minute | HOW | keep | -- |
| 46 | skill_tactics.c `bc_do_leave_water` | nearest dry inland floor within 48; three banks tried then 20 s | HOW | keep | -- |
| 47 | engine.c `act` | a lamp is never lit by day | a rule of the engine's (night is a script's) | keep | -- |
| 48 | senses.c `bc_senses_*` | what counts as being shot at (hurt, a round within 2.5, a mate killed within 12), alertness (engaged for 1.5 s after the last sight, suspicious after a noise) | NUMBER (perception) | settings beside `sight`, `fov`, `memory` (`fire.near`, `fire.mate`); low priority | L |
| 49 | engine.c, skill_tactics.c `bc_enemy_area` | "where the enemy is" is the team's last meeting for 60 s, else his base | NUMBER | setting `hot.secs` (with row 14) | L |
| 50 | persona.c tables | the kinds of bot: trait centres and spreads | data in C | STEP E (item 5): a file beside the trees | M |

## Proposed, in priority order

1. **Cover in view, facing the threat** (rows 1, 2, 7, 9): step B. The
   owner's complaint, and the largest WHAT still in C on the fight's
   path: where to look for cover. The tree gains `cover_in_view` and
   `take_cover in_view`; the skill keeps the head on the threat while it
   moves.
2. **Stranded bots** (rows 43, 15): step C. A condition the tree reads
   instead of the engine's pacing; a perch with no way down not taken
   unless the tree means to camp there.
3. **Rest times and thresholds as arguments** (rows 3, 4, 6, 13, 16, 19,
   25, 27, 30, 34): one sitting, all L, the same pattern as the moves
   above; each with a check that the default reads as before.
4. **`seek` as tree structure** (row 12): add the place `middle`, write
   the itinerary in default.bt with go_to, bench it against `seek`.
5. **Who fights whom** (rows 21, 31): `fight [who]`, default as today.
6. **Leaders' and pings' hidden trait gates** (rows 29, 32, 33): settings
   first (same numbers), then remove the gates in favour of the trees'
   weights once squad_test and the bench say it reads the same.
7. **The jolt as a tree declaration** (rows 39, 41) and **stuck as a
   condition** (row 42): needs bt.h's "re-choose this pick" first.
8. **Perception and memory numbers as settings** (rows 14, 48, 49).

What is NOT proposed: aim, physics, the route planner and follower, the
unsticking ladder, the edit cadence, the grenade's arc and vetoes, the
stations of escort/guard/intercept, the gun table. Those are HOW, ported
from aosbot with their tests.
