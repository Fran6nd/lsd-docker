---
name: bot-tree-tuning
description: Design or tune a bot behaviour tree (bot/trees/*.bt, an item's or a script's tree fragment) - who does what, how often, by which kind of bot. Use when asked to make bots more/less aggressive, defensive, objective-minded, to rebalance a gamemode's choices, to write a tree for a new gamemode, or when "too many bots do X".
---

# Designing and tuning a behaviour tree

A tree says what CAN be done and what bears on it; each bot's character
(ten traits, rolled per bot from its archetype) says what THAT bot would
rather. Tuning is moving numbers in the text, never code. Never written
a tree? `bot/trees/README.md` is the tutorial, step by step. The reference
is `bot/TREES.md` (every keyword's exact answers and defaults, the worth
formula with a worked example, `_also` / `items` / `extras`, how a tree
is compiled and run, giving one bot a tree of its own); `bot/core/bt.h`
is the same in short. Words: `bot/VOCAB.md`, which is `bttree --words
--md` (the truth), and `bot/core/vocab.h` (the prose). For a new word,
skill or setting, use the `bot-behaviour` skill instead.

## The tool

```sh
make -C bot tools                    # builds bot/build/bin/bttree
B=bot/build/bin/bttree
```

| Question | Command |
|---|---|
| What does the tree look like, sub-trees opened? | `$B bot/trees/tdm.bt` (`--tree NAME` for one, `--plain` for a pipe) |
| Does it compile, with today's words? | `$B --check bot/trees/*.bt` (also in `make -C bot test`): EVERY mistake, each with its line -- wrong words and wrong arguments (a word for a number, a place there is none of) |
| What words are there? | `$B --words` (`\| grep '^score'`); `bot/VOCAB.md` is the same as a page |
| How does a kind of bot weigh each option? | `$B --as camper bot/trees/tdm.bt` |
| **In this situation, who does what?** | `$B --split ...` (below) |
| **...and why?** | `$B --split --why ...`: each pick's options with their mean score, weight, worth, and who chose them |
| What does ONE bot hold, node by node? | `$B --trace --as camper --secs 4 FILE word=value...` (below) |
| Is the text in the house form? | `$B --format FILE` writes it canonical (tabs, comments in one column), which is how the shipped trees are written |
| Are the examples of the docs still right? | `$B --doc bot/TREES.md bot/trees/README.md` (part of `make -C bot test`) |

## --split: the tuning loop

```sh
$B --split --tree tdm_search bot/trees/tdm.bt rumour=0.6 flank_open=1 "vantage rifle=1"
```

rolls 700 bots (`--n`), of every kind (`--mix "camper:2,pusher"`, the same
text as the `engine_bots` spread setting; `--level 5`), ticks the tree once
for each with the engine's real `bt_tick`, and prints what each ended up
doing, in all and by kind:

```
   all soldier  camper  pusher flanker support  sapper   scout
 56.1%     83%    100%     15%     17%     80%     66%     36%  pick:marksman > take_high_ground
 17.7%      7%      0%      0%     75%      3%     18%     15%  pick:flank > flank
asked and not given (so 0): ping_called, vantage smg, has_leader, ...
```

The SITUATION is yours to state, as `word=value`:
- a **score** is 0 to 1 (read its line in `--words` for what 1 means);
  a **condition** 0 or 1; anything not given is 0 (`always` is 1);
- `"word arg=value"` sets it for those arguments only (`"enemy_far 70=0.8"`);
  plain `word=` covers every use of it;
- an **action** is `run` by default (it is what the bot is then doing, and
  the row's name); give `crouch=ok` for one that ends at once so the tree
  goes on past it, `=fail` to see the fallback;
- read the **"asked and not given"** line every time: it is every word the
  tree consulted that you left at 0. A situation is only honest when each
  of those is 0 on purpose. "given but never asked" is a typo or a branch
  that was not reached.

Loop: state the situation -> `--split` -> change a factor (`x1.4`), a
`sticky=`, a `noise=`, the trait of an option -> `--split` again. Run
several situations per change (nothing known / enemy far / shot at / hurt
/ objective taken): a factor that fixes one usually moves another.

When a row surprises, add `--why`. Under the rows it prints, for every
pick a bot came to (with its file and line), one line an option:

```
why: pick every=3  (first.bt line 7; 700 bots came to it)
  chose   score  weight  factor   worth
  32.9%    0.60    1.00     1.2    0.72  aggression enemy_near  -> do fight
  67.1%    0.60    1.04     1.5    0.93  caution hurt  -> do retreat
   0.0%    0.00    1.09       1    0.00  curiosity search (0: cannot be chosen)  -> do investigate
```

`weight` and `worth` are means over the bots that weighed it (worth
includes luck). It says which of the three is too strong -- the score you
stated, the factor, or the crowd's weights -- before you move a number.

## --trace: one bot, node by node

```sh
$B --trace --as soldier --seed 3 --secs 4 first.bt enemy_near=0.6 hurt=0.6
```

One rolled bot (`--as`, `--seed`, `--level`) in the stated situation,
ticked for `--secs` (ten ticks a second; default one tick), then its tree
drawn as the engine holds it: references opened, each node with its id,
`>` on the RUNNING path, a pick's time to its next choice, and for every
option `score x weight x factor x luck x sticky = worth` with the one
held. Use it for what `--split` cannot show: `sticky` (it only counts
once an option is held: give `--secs` longer than the pick's `every`),
timers (`wait`, `limit`, `cooldown`), and a `seq` that resumes. `--json`
gives the same as data.

## What the numbers mean

An option's worth = `score x the bot's trait weight x factor x luck`.
- **factor** (`xF`): the designer's thumb. Options under a `none` trait are
  the same for every bot: use `none` with big factors (x100, x60, x30...)
  for a priority list everybody obeys, a real trait where characters
  should differ.
- **trait weights** run 0.2 to 3; an archetype's strong trait is about 1.8,
  its weak one about 0.5 (`--as <archetype>` shows them). So x1.5 on a
  trait option is already a lot between two archetypes.
- **noise** (pick): luck of +-that fraction; 0 for a priority list, 0.15 to
  0.35 where bots should not all agree. **sticky**: how much the current
  choice is favoured when chosen again (stops flip-flop). **every**: how
  often it is chosen again; long (20 s) for a plan, short (1 s) for
  reactions.
- **A weight is not a probability.** A pick takes the option with the
  highest worth; one bot in one situation chooses the same nearly every
  time, and the percentages `--split` prints are shares of a crowd of
  different characters, not odds for one bot.
- **Variety inside one bot** is `pick roll=each [every=<secs>]`: a
  lottery drawn AGAIN at every choice (first tick, every `every`, when
  the child ends), in proportion to `score x weight x factor`, from the
  bot's own dice -- worths 0.9 / 0.9 / 1.2 are 30 / 30 / 40 % of its
  choices. `sticky` and `noise` are refused. Use it only where every
  option is acceptable (idle behaviour, which way to patrol), NEVER for a
  priority list of reactions: an option worth a tenth of another still
  wins one choice in eleven. `--split` shows one draw per bot, so its
  shares approximate the odds. (TREES.md section 6.)
- **A role that lasts** is `pick roll=once` (or `roll=life`): there the
  option is DRAWN, with a chance in proportion to `score x weight x
  factor`, once for each bot and kept (TREES.md section 6). Its scores
  must be facts about the bot (`gun_is`, `has_item`, `always`), not the
  moment. `tdm.bt`'s campers are the example (`tree tdm_duty`): tune the
  two factors with `$B --split --tree tdm_duty bot/trees/tdm.bt "gun_is
  rifle=1" vantage=1` (then `smg`, then `shotgun`); `--split` gives each
  rolled bot its own identity, so the rows are the real shares. For an
  exact count of a role, or one with its own spawn, use a tree per bot
  from the gamemode instead.
- An option with score 0 is never taken; if all are 0 the pick fails:
  end a pick with `option none always x0.1` and a sane fallback.

## Shape of a good tree (see bot/trees/tdm.bt, ctf.bt)

1. Top: `pick every=1 noise=0` of `none` options, by falling factor --
   grenade, harmful water, the game's must-do (carrying the intel), an
   order, under fire, enemy in sight, something to search, then `always`
   -> the gamemode's duty tree.
2. The duty tree: a slow `pick` (every=20, sticky 1.5, noise 0.3) that
   splits the team by character. Aim for a spread, checked with --split:
   no row over about 60% in the nothing-known situation unless meant.
3. Last resort always goes somewhere useful (`seek`), never stands.
4. `<name>_also`: things done beside (extras, items, callouts), actions
   that end at once.

## After the numbers

`--split` knows the tree, not the world: it cannot tell whether a score
is ever above 0 on a real map (a perch found, a rumour heard). Then:
- `make -C bot test` -- the scenarios (`bot/tests/behaviour_test.c`,
  `ctf_test.c`, `squad_test.c`) pin splits and outcomes; a retune may
  need their bounds moved, deliberately. It also compiles every tree
  shown in `bot/TREES.md`, sends the shipped trees to JSON and back, and
  fails if `bot/VOCAB.md` is not today's vocabulary (`make -C bot doc`
  rewrites it).
- live: the `demo-server` skill to put it on the demo, `bot-live-debug`
  to see what bots are doing (the engine's "stuck" lines print each
  bot's `pick:... > action` path, the same text as --split's rows).
- **On a running server** (TREES.md sections 14 and 16): `lsdctl bots
  list` and `lsdctl bots watch <bot>` show what each bot is doing and,
  option by option, why (the same numbers as `--trace`, live);
  `lsdctl bots apply - --bot <bot> < file.bt` (or `--team`,
  `--archetype`, `--each`, `--all`) gives a tree to bots that are
  playing, `revert` takes it back, `save <name>` keeps it as an
  operator's tree. A text that does not compile is refused with every
  mistake.
- A tree can also be tried from the server's Lua:
  `botlink_set("tree", <text>)` from `lsdctl exec`, or -- an operator's
  way -- a file `<name>.bt` in the data volume's `trees/` (read again at
  each map load; a tree named like a built-in one replaces it) and the
  setting `engine_bots_tree`. `engine_bots_archetypes` and
  `engine_bots_traits` lean the crowd without touching a tree. One bot
  with its own tree (a boss): `botlink_add{tree=<text>, at=, once=true}`,
  changed in play with `botlink_set("tree", <text>, pid)` -- TREES.md,
  sections 12 and 13. A text sent from Lua is compiled alone: it cannot
  refer to the built-in files' trees.
- When a mode needs something the trees cannot ask or do, look at the
  bridge before asking for a C word: a fact (`if fact alarm`), a place
  of the script's (`@church`), a word back (`do tell ring_bell`) --
  TREES.md section 13, items 8 to 10. `--split` takes `"fact alarm=1"`.
