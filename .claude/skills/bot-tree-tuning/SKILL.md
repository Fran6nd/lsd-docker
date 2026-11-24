---
name: bot-tree-tuning
description: Design or tune a bot behaviour tree (bot/trees/*.bt, an item's or a script's tree fragment) - who does what, how often, by which kind of bot. Use when asked to make bots more/less aggressive, defensive, objective-minded, to rebalance a gamemode's choices, to write a tree for a new gamemode, or when "too many bots do X".
---

# Designing and tuning a behaviour tree

A tree says what CAN be done and what bears on it; each bot's character
(ten traits, rolled per bot from its archetype) says what THAT bot would
rather. Tuning is moving numbers in the text, never code. Grammar:
`bot/core/bt.h`. Words: `bttree --words` (the truth) and
`bot/core/vocab.h` (the prose). For a new word, skill or setting, use the
`bot-behaviour` skill instead.

## The tool

```sh
make -C bot tools                    # builds bot/build/bin/bttree
B=bot/build/bin/bttree
```

| Question | Command |
|---|---|
| What does the tree look like, sub-trees opened? | `$B bot/trees/tdm.bt` (`--tree NAME` for one, `--plain` for a pipe) |
| Does it compile, with today's words? | `$B --check bot/trees/*.bt` (also the last step of `make -C bot test`) |
| What words are there? | `$B --words` (`\| grep '^score'`) |
| How does a kind of bot weigh each option? | `$B --as camper bot/trees/tdm.bt` |
| **In this situation, who does what?** | `$B --split ...` (below) |

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
  need their bounds moved, deliberately.
- live: the `demo-server` skill to put it on the demo, `bot-live-debug`
  to see what bots are doing (the engine's "stuck" lines print each
  bot's `pick:... > action` path, the same text as --split's rows).
- A tree can be tried on a running server without a rebuild:
  `botlink_set("tree", <text>)` from `lsdctl exec`.
