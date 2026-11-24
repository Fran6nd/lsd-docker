# Writing a behaviour tree, step by step

The bots of this server decide what to do with a *behaviour tree*: a
short text. The files beside this one (`tdm.bt`, `ctf.bt`, `parkour.bt`,
`default.bt`) are the trees that ship. This page takes you from nothing
to a tree of your own running on a server, one step at a time; each step
ends with something to run and what you should see.

It is a tutorial. The reference -- every keyword's exact meaning, every
format -- is [`../TREES.md`](../TREES.md), and the words a tree may use
are [`../VOCAB.md`](../VOCAB.md). A desktop editor that checks a tree as you type and tries it on bots at once is in [`tools/tree-editor`](../../tools/tree-editor/README.md).

**The tool** is `bttree`. On a server it is already there:
`docker exec lsd bttree ...`. From a checkout, build it once with `make
-C bot tools`; it is then `bot/build/bin/bttree`. Below it is written
`bttree`.

Every tree on this page is compiled by `make -C bot test`, and every
output shown was produced by the command above it.

## 1. Look at a tree

```sh
bttree --plain bot/trees/default.bt
```

```
default
`- select
   |- pick every=1.5 sticky=0.3 noise=0.15
   |  |- option none grenade_near x100  # a grenade at its feet: run
   |  |  `- do evade
   |  |- option none harmful_water x60  # wading in water that hurts: out, first
   |  |  `- do leave_water
   |  |- option none has_order x30  # the server said so
   |  |  `- do obey
   |  |- option caution under_fire x1.5  # shot at: to cover, and fight from it
   |  |  `- tree default_cover
   |  |     `- seq
   |  |        |- do crouch  # the flinch, facing the shot
   |  |        `- do take_cover
   |  |- option aggression enemy_visible x1.2  # fight him
   |  |  `- do fight
   ...
```

One node a line; a node's children are under it. The leaves ask
something (`if ...`) or do something (`do ...`); what is above them says
in what order. Read it from the top: that is what a bot does, twenty
times a second. (`--plain` is for copying; in a terminal, leave it out
for colours.)

## 2. The smallest tree that does something

Save this as `mine.bt`:

```bt
tree mine:
do seek
```

`seek` is an action: go and find the enemy. Check the file:

```sh
bttree --check mine.bt
```

```
ok: 1 file(s)
```

A tree is compiled before it is run, by the same compiler the server
uses, and a mistake is said with its line. Three mistakes at once:

```
tree mine:
select
	do go_to enemy_bas
	do fight him
	wait
```

```
$ bttree --check mine.bt
mine.bt: line 3: go_to: no place called enemy_bas
mine.bt: line 4: fight takes no argument
mine.bt: line 5: 'wait' takes one number of seconds
```

What words there are, and what each takes: `bttree --words`, or
[VOCAB.md](../VOCAB.md). Children are indented with a tab (or two
spaces, or four -- one kind for the whole file).

## 3. Make it choose

**A priority list.** `select` tries its children in order and stops at
the first that does not fail; `seq` does its children in order as long
as each succeeds.

```bt
tree mine:
select
	seq                                       # a grenade at its feet: run
		if grenade_near
		do evade
	seq                                       # somebody in sight: fight him
		if enemy_visible
		do fight
	do seek                                   # nothing else: go and find them
```

That works, and every bot does the same. It also has a flaw: `select`
and `seq` *remember where they were*. A bot that is in `seek` stays in
it; it does not look at `if enemy_visible` again until `seek` ends --
and `seek` never ends.

**A weighed choice** is what looks again, and what makes bots differ:

```bt
tree mine:
select
	pick every=2
		option aggression enemy_visible       # somebody in sight: fight him
			do fight
		option caution under_fire x1.5        # being shot at: to cover
			do take_cover
	do seek                                   # nothing of that: go and find them
```

Every 2 seconds the `pick` works out what each option is worth *to this
bot, now*, and does the best:

```
worth = score  x  the bot's weight for the trait  x  factor  x  a little luck
```

- `enemy_visible` and `under_fire` are **scores**: 0 to 1, how much the
  situation calls for the option. At 0 the option is out.
- `aggression` and `caution` are **traits**: each bot has its own weight
  for each, around 1, rolled when it is made. A pusher's aggression is
  about 1.9, a camper's 0.5.
- `x1.5` is your thumb on the scale.

With an enemy in sight (score 1) and rounds coming in (`under_fire` 0.7),
a camper (aggression 0.5, caution 1.8) weighs fight 1 x 0.5 = 0.5 and
cover 0.7 x 1.8 x 1.5 = 1.9: it takes cover. A pusher (1.9 and 0.6)
weighs 1.9 against 0.6: it fights.

**A weight is not a probability.** The pick takes the option with the
highest worth, every time; it does not draw lots. One bot in one
situation chooses the same thing again and again. The variety comes
from the bots being different.

## 4. See who does what, before running it

```sh
bttree --plain --split mine.bt enemy_visible=1 under_fire=0.7
```

```
700 bots, level 5, tree (the first)
   all soldier  camper  pusher flanker support  sapper   scout
 54.1%     47%    100%      1%     29%     83%     64%     55%  pick:caution > take_cover
 45.9%     53%      0%     99%     71%     17%     36%     45%  pick:aggression > fight
```

You state the situation (`word=value`; what you do not give is 0), 700
bots of every kind are rolled, each is asked once, and what each ended
up doing is counted -- in all, and by kind. Those percentages are
*shares of the crowd*: 54 % of bots are of a character that takes cover
here, and each of them would do so again.

Add `--why` to see the sum behind a row:

```
why: pick every=2  (mine.bt line 3; 700 bots came to it)
  chose   score  weight  factor   worth
  45.9%    1.00    1.00       1    1.00  aggression enemy_visible  -> do fight
  54.1%    0.70    1.04     1.5    1.08  caution under_fire  -> do take_cover
```

Change `x1.5` to `x1` and run it again: that loop -- state a situation,
split, move a number -- is how a tree is tuned.

## 5. Run it on a server

Your trees live in the `trees/` folder of the server's data volume. A
file there is read when the server starts and again **at every map
change**; a tree named like a built-in one (`tdm`) replaces it, any
other name is added. (The outputs below are from a server playing tdm
with three bots a side and the tree of step 6 as `mine.bt`.)

```sh
docker exec -i lsd lsdctl bots save mine < mine.bt
```

```
saved /data/trees/mine.bt (mine, mine_duty, mine_also): the bot engine reads it at the next map load
```

That checked the text and wrote `/data/trees/mine.bt` (`docker cp
mine.bt lsd:/data/trees/` does the same without the check). The engine
has not read the file yet -- it will at the next map -- so to try the
tree *now*, give it the text. No restart, nobody disconnected:

```sh
docker exec -i lsd lsdctl bots apply - --all < mine.bt
```

```
  #0   Bot322           now runs mine
  #1   Bot264           now runs mine
  #2   Bot410           now runs mine
  #3   Bot403           now runs mine
  #4   Bot662           now runs mine
  #5   Bot111           now runs mine
the world's tree: mine (a bot given one of its own keeps it: --each reaches every bot)
```

(`--all` is the tree of the world; `--bot <name>`, `--team 2`,
`--archetype camper` give it to some bots only. A text that does not
compile is refused with every mistake, and nothing changes.) See what
they are doing:

```sh
docker exec lsd lsdctl bots list
```

```
  id  name             team  kind     level health  tree                 doing
   0  Bot322              1  soldier      5    100  mine                 pick:none > fight
   1  Bot264              1  sapper       3      6  mine                 pick:none > fight
   2  Bot410              1  support      3     42  mine                 pick:none > fight
   3  Bot403              2  flanker      3    100  mine                 pick:none > fight
   4  Bot662              2  camper       4      1  mine                 pick:none > take_cover
   5  Bot111              2  scout        5    100  mine                 pick:curiosity > investigate
the world runs: mine
```

**Watch one think**:

```sh
docker exec -it lsd lsdctl bots watch
```

```
Bot322  #0, team 1: a soldier, level 5, health 100, alive
route 0/380 SPRINT; sees 0, suspicious
weights: aggression 1.07 caution 0.78 objective 0.64 teamwork 0.93 builder 1.15 marksman 1.05 flank 0.91 stealth 1.15 curiosity 0.65 greed 1.21

mine (its tree)  pick:none > pick:aggression > seek
   0 > `- select
   1 >    |- pick every=1 sticky=0.2 noise=0  [chose 0.1 s ago, again in 0.9 s]
   2      |  |- option none grenade_near x100  score 0  (+1)
   4      |  |- option none under_fire x10  score 0  (+1)
   6      |  |- option none enemy_visible x5  score 0  (+1)
   8      |  |- option curiosity search x2  0.40 x 0.65 x 2 x 1.00 x 1.00 = 0.522  (+1)
  10 >    |  `- option none always  1.00 x 1.00 x 1 x 1.00 x 1.00 = 1.000  <- held
  11 >    |     `- pick every=20 sticky=1.5 noise=0.3  [chose 0.1 s ago, again in 19.9 s]
  12      |        |- option flank flank_open x0.9  1.00 x 0.91 x 0.9 x 0.82 x 1.00 = 0.668  (+1)
  14      |        |- option teamwork mate_near 40 x0.5  0.77 x 0.93 x 0.5 x 0.72 x 1.00 = 0.256  (+2)
  17 >    |        `- option aggression always x0.9  1.00 x 1.07 x 0.9 x 0.95 x 1.00 = 0.924  <- held
  18 >    |           `- do seek
  19      `- limit 1  (+1)

mine_also (ticked beside, at every decision)
  29   `- seq  (+65)
  id   an option: score x weight x factor x luck x sticky = worth   (+N): nodes not shown; --full shows all
```

(Shown with `--once --plain`, which prints one frame; without them it
redraws live, with colours, until Ctrl-C.) The lines marked `>` are
where the bot is. Each option its pick weighed shows `score x weight x
factor x luck x sticky = worth`: this soldier heard something (`search`
0.40) but its curiosity is 0.65, so 0.52 loses to the duty's 1.0; in the
duty, going straight (0.92) beat going round (0.67).

**To make it last**, name the tree in the setting; it is the engine's
after the next map change (a restart forgets a tree that was only
applied):

```sh
docker exec lsd lsdctl set engine_bots_tree "'mine'"
docker exec lsd lsdctl map load flat          # any map change: the engine reads /data/trees again
docker logs lsd 2>&1 | grep botd: | tail -4
```

```
botd: trees loaded: 4 files from /opt/botd/trees
botd: user trees loaded from /data/trees: mine.bt (mine mine_duty mine_also)
botd: engine: map 3 loaded
botd: map loaded: botlink-map-2.vxl, 2097152 bytes, 2 ms
```

A file that does not compile is said there instead (`botd: tree error:
/data/trees/mine.bt: line 12: no action called figth (skipped)`) and the
built-in trees stay. A name the engine has not read yet is refused
rather than guessed at:

```
$ docker exec lsd lsdctl bots apply mine --all
lsdctl: the bot engine has not read the tree mine yet (it reads /data/trees at the next map load): change the map, or give it the text now: lsdctl bots apply --file /data/trees/mine.bt ...
```

Three more settings lean the whole crowd without touching a tree:
`engine_bots_archetypes` (`camper:2,pusher:1`: the mix of characters),
`engine_bots_traits` (`aggression:1.5`: every bot's weights scaled) and
`engine_bots_edit` (`dig`, `build` or `all`: what a bot's route may do
to the map; empty: it only walks and jumps). `lsdctl bots revert --all`
gives the world its gamemode's tree back, `--each` every bot.

## 6. The shape of a real tree

Reactions on top, a duty underneath, a last resort that never stands.
This is `tdm.bt`'s shape, small:

```bt
# mine.bt -- reactions on top, a duty underneath, a last resort that never stands
tree mine:
select
	pick every=1 sticky=0.2 noise=0
		option none grenade_near x100         # a grenade at its feet: run
			do evade
		option none under_fire x10            # being shot at: to cover, and fight from it
			do take_cover
		option none enemy_visible x5          # somebody in sight: fight him
			do fight
		option curiosity search x2            # a noise, a man lost from sight: go and look
			do investigate
		option none always                    # nothing of that: its duty
			tree mine_duty
	limit 1
		do seek                               # the net: never stand

# What a bot does with nothing on its hands -- by its character, for a good while.
tree mine_duty:
pick every=20 sticky=1.5 noise=0.3
	option flank flank_open x0.9              # the sly: round to their base, from behind
		do flank
	option teamwork mate_near 40 x0.5         # the team-minded: with a team-mate
		limit 20
			do follow mate
	option aggression always x0.9             # everybody, more or less: straight at them
		do seek

# Beside the above, at every decision.
tree mine_also:
seq
	always
		tree extras                           # what the server's scripts add (night and lamps)
	always
		tree items                            # whatever it holds, used as each item says
```

- **The top pick is a priority list everybody obeys**: the trait `none`
  (the same for every bot), factors far apart (x100, x10, x5), no luck
  (`noise=0`), looked at again every second. A grenade beats a firefight
  beats an enemy beats a noise.
- **The duty is where characters differ**: real traits, chosen for 20
  seconds at a time, and `sticky=1.5` so a bot does not drop a plan for
  one about as good.
- **`option none always`** at the end of a pick can always be chosen:
  without it, a pick whose scores are all 0 fails.
- **`limit 1` / `do seek`** under the pick is the net: whatever happened
  above, a bot goes somewhere.
- A file may hold several trees; `tree mine_duty` as a node means "that
  tree, here".

With nothing known, and then with a way round open and a team-mate near:

```
$ bttree --plain --split mine.bt
700 bots, level 5, tree (the first)
   all soldier  camper  pusher flanker support  sapper   scout
100.0%    100%    100%    100%    100%    100%    100%    100%  pick:none > pick:aggression > seek
asked and not given (so 0): grenade_near, under_fire, enemy_visible, search, flank_open, mate_near 40

$ bttree --plain --split mine.bt flank_open=1 "mate_near 40=0.8"
700 bots, level 5, tree (the first)
   all soldier  camper  pusher flanker support  sapper   scout
 49.6%     48%     46%      3%     85%     24%     53%     80%  pick:none > pick:flank > flank
 43.0%     52%     42%     97%     15%     34%     45%     20%  pick:none > pick:aggression > seek
  7.4%      0%     12%      0%      0%     41%      2%      0%  pick:none > pick:teamwork > follow
asked and not given (so 0): grenade_near, under_fire, enemy_visible, search
```

Read the last line every time: it is every word the tree asked about
that you left at 0.

## 7. Roles that last

A weighed pick chooses again and again. For a bot to *be* something --
a camper, a guard -- in every life, a pick can instead **draw a role
once and keep it**:

```bt
tree mine_duty:
pick roll=once
	option marksman gun_is rifle x0.5         # a third of the rifles camp...
		tree camper
	option marksman gun_is smg x0.2           # ...a sixth of the smgs; a shotgun never
		tree camper
	option none always                        # everybody else
		do seek

tree camper:
pick every=3 sticky=0.5 noise=0
	option none vantage x10                   # a perch it can have: up, and wait
		seq
			do take_high_ground
			do camp
	option none always                        # none free just now: go and find them, and look again
		do seek
```

Here, and in `roll=each` (a lottery drawn again at every choice, for variety inside one bot: TREES.md section 6), worth IS a chance: with `roll=once` an option is
drawn with a probability in proportion to `score x weight x factor`, the
same for a given bot in every life and on every map. The scores under it
must be *facts about the bot* (its gun, what it holds, `always`), not
the situation of the moment.

```
$ bttree --plain --split --n 7000 mine_role.bt "gun_is rifle=1" vantage=1
7000 bots, level 5, tree (the first)
   all soldier  camper  pusher flanker support  sapper   scout
 67.7%     66%     53%     72%     68%     71%     73%     70%  pick:none > seek
 32.3%     34%     47%     28%     32%     29%     27%     30%  pick:marksman > pick:none > take_high_ground
asked and not given (so 0): gun_is smg
```

(Saved as `mine_role.bt`; `--n 7000` because a lottery needs a larger
crowd than a weighed choice to show its shares to the percent.) A third
of the rifles camp, nearly half of those with a camper's character. This
is how `tdm.bt` has its campers. It gives *shares* of a crowd. When
a game needs **exactly one** boss, a role with its own place to spawn or
its own team, the gamemode's script gives those bots a tree of their own
instead:

```lua
botlink_add{team = 2, name = "Warden", tree = BOSS_TREE_TEXT,
	at = {x = 256, y = 256, z = 40}, once = true};
```

([TREES.md, section 12](../TREES.md#12-writing-your-own): a boss and a
villager, whole.)

## 8. The side tree, items and extras

A bot runs one tree, and the one called `<name>_also` beside it at every
decision: that is where things done *in passing* go (a callout, a lamp),
because the main tree is busy in whatever is RUNNING. Two trees are
written by the engine and only referred to: `tree items` (each inventory
item's own rule: a medkit when hurt) and `tree extras` (what server
scripts add: flashlights at night). A tree that does not say `tree
items` has bots that never use what they hold.

## 9. What a server script can add

A gamemode or any catalog script shapes the bots from Lua: a tree for
the world or for one bot, a fragment beside every tree, an item's rule,
settings, orders. And three things for what the engine has no word for:

```lua
botlink_set("fact.alarm", 1);                        -- a FACT the trees can read
botlink_set("place.church", "286.5 268.5 30");       -- a PLACE of the script's naming
botlink_on("ring_bell", function(pid, words)         -- a WORD a tree says back
	log("bot %d rings the bell", pid);
end);
```

```bt
tree guard:
pick every=1 noise=0
	option none fact alarm x10                # the alarm: to the church, ring, and stay
		seq
			do go_to @church 3
			always
				cooldown 600                  # once
					do tell ring_bell church
			do hold @church 60
	option none always                        # the day: its post in the village
		do hold @village 30
```

`fact <name>` is a condition and a score; a script's place is written
`@name` wherever a place goes; `do tell <name>` calls the script's
function. Everything a script can do, each with an example:
[TREES.md, "What a server script can do"](../TREES.md#13-what-a-server-script-can-do).

## 10. Tune it, then prove it

1. State the situations that matter (nothing known; an enemy far; shot
   at; hurt; the objective taken) and `--split` each. Change one number.
   Split them all again: a factor that fixes one usually moves another.
2. `bttree --trace --as camper --secs 5 mine.bt enemy_visible=1` shows
   ONE bot, node by node, over a few seconds -- for `sticky`, timers,
   and anything a single tick does not show.
3. On a server: `lsdctl bots watch <bot>` for why a bot does what it
   does, `lsdctl bots apply` to try a change on the spot.
4. For the trees that ship: `make -C bot test` (scenarios on a simulated
   server pin what teams do), and the bench, which measures a change:

   ```sh
   make -C bot build/tests/bench
   bot/build/tests/bench arena12 > before.txt     # change the tree...
   bot/build/tests/bench arena12 > after.txt ; diff before.txt after.txt
   ```

   ```
   arena12 think_mean_us 26.7 us
   arena12 think_worst_us 1062 us
   arena12 no_key_pct 22.2 %
   arena12 longest_idle_s 4.1 s
   arena12 plans 550
   arena12 kills 35
   arena12 stuck 0
   arena12 goals_dropped 0
   ```

   One line a metric (some of them shown); all but the two `think_`
   lines are the same on every run of the same trees, so a difference
   is your change.

## 11. Where to go next

| you want | read |
|---|---|
| every keyword, exactly: what it answers, its defaults | [TREES.md](../TREES.md) sections 4 to 9 |
| the worth formula, `every`, `sticky`, `noise`, `roll=`, with worked numbers | TREES.md section 6 |
| what words there are, and what each takes | [VOCAB.md](../VOCAB.md), `bttree --words` |
| how a text is compiled, when a tree is ticked, what it costs | TREES.md section 10 |
| characters: traits, archetypes, how weights are rolled | TREES.md section 11 |
| a boss, a villager; trees from a gamemode's Lua | TREES.md section 12 |
| facts, places, `tell`, items, extras, settings, orders from Lua | TREES.md section 13 |
| watching a bot think; trying a tree live | TREES.md section 15 |
| JSON for a tool or an editor; the `lsdctl bots` operations | TREES.md sections 16 and 17 |
