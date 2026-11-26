# Behaviour trees

What a bot does is decided by a tree: a short text that says what can be
done and what bears on it. This page is the **reference**: every
keyword, what it answers, its defaults; how a text is compiled and run;
what a server script can do; and the formats a tool is built on.

- **New to this? Start with the tutorial**: [trees/README.md](trees/README.md)
  -- from an empty file to a tree of your own running on a server, step
  by step.
- The words a tree may use (conditions, scores, actions, traits, places):
  [VOCAB.md](VOCAB.md), generated from the engine.
- The tool used all through: `bttree`. Build it with `make -C bot tools`
  (it is then `bot/build/bin/bttree`); in the image it is on the path:
  `docker exec <server> bttree /opt/botd/trees/tdm.bt`.
- The trees that ship: [`trees/`](trees).

Every tree shown in a block on this page and in the tutorial is compiled
by `make -C bot test` (`bttree --doc`), with the engine's own compiler
and words.

Contents: [what a tree is](#1-what-a-tree-is-and-why) ·
[a first tree](#2-a-first-tree) · [the text](#3-the-text) ·
[the three answers](#4-the-three-answers) ·
[every node](#5-every-node) · [pick, in full](#6-pick-in-full) ·
[when actions are stopped](#7-when-an-action-is-stopped) ·
[time](#8-time) · [several trees](#9-several-trees-in-a-text) ·
[compiled and used](#10-how-trees-are-compiled-and-used) ·
[characters](#11-characters-traits-archetypes-weights) ·
[writing your own](#12-writing-your-own) ·
[what a server script can do](#13-what-a-server-script-can-do) ·
[tuning](#14-tuning) ·
[debugging, live](#15-debugging-watching-a-bot-think) ·
[for tool authors](#16-for-tool-authors) ·
[the editor's backend](#17-the-editors-backend-operations-and-their-json) ·
[review](#18-review-what-an-editor-and-a-debugger-need) ·
[limits](#19-limits)

## 1. What a tree is, and why

Three ideas, one on top of the other.

**A behaviour tree.** A tree of nodes, read from the top at every
decision. The leaves ask something (`if enemy_visible`) or do something
(`do fight`); the nodes above them say in what order and under what
condition. It is text, one node a line, so it can be read, compared and
changed without touching the engine.

**Weighed choices.** A plain behaviour tree is a list of rules: the first
that holds wins, and every bot obeys it alike. Here a tree may also say
"these are the things that could be done now, and this is how much the
situation calls for each" -- a `pick` -- and the best is done.

**A character per bot.** How much an option is worth is multiplied by
the bot's own weight for a *trait* (aggression, caution, teamwork...),
rolled once when the bot is made. So the tree says what CAN be done and
what bears on it; the character says what THIS bot would rather. Ten bots
thinking with one tree are not ten of the same bot: one pushes where
another holds.

The tree is shared by every bot that runs it and never changes while
they play. What each bot keeps is where in it it is, and its character.

## 2. A first tree

```bt
tree first:
select
	seq                                       # hurt and out of the fight: get well
		if health_below 30
		unless enemy_visible
		do retreat
	pick every=3
		option aggression enemy_near x1.2     # an enemy close: fight him
			do fight
		option caution hurt x1.5              # hurt: get out of it
			do retreat
		option curiosity search               # a noise, a man lost from sight: go and look
			do investigate
	do seek                                   # nothing else to do: go and find them
```

Read from the top: the `select` is a priority list; its first child, a
`seq`, is "under 30 health with no enemy in sight: retreat"; the `pick`
weighs three options, differently for each bot, and chooses again every
3 seconds ([section 6](#6-pick-in-full) does the sum for this tree);
`do seek` is what is left when nothing else applies. The tutorial builds
such a tree from nothing and shows the tool at each step:
[trees/README.md](trees/README.md).

## 3. The text

- **One node a line.** A node's children are the lines under it, indented
  one step more.
- **Indentation** is a tab, or two spaces, or four spaces a step:
  whichever the text's first indented line uses, and the same all
  through. A mix of tabs and spaces, a line that is off the step, or a
  line indented two steps deeper than the one above is a mistake, and the
  compiler says which line.
- **Words** on a line are separated by spaces or tabs; at most 16 words a
  line. There are no quotes: a word cannot hold a space or a `#`.
- **Comments** start at `#` and run to the end of the line. A line may be
  only a comment, or empty. Comments are kept by everything that reads a
  tree for you (the tool, an editor): they are not lost by a round trip.
- **A tree begins** with `tree <name>:` at no indent, and holds exactly
  one root node: the first node after the header, at whatever indent (the
  trees that ship write it at none). Everything else is under that root.
- **A text with no header** is one tree, named `main`. That is how a
  fragment -- an item's rule, a script's addition -- is written.
- **Names** of trees are letters, digits, `_`, `-` and `.`, at most 31
  characters.

```bt
# A file may hold several trees. This comment belongs to the tree below.
tree sentry:
select
    seq
        if enemy_visible
        do fight
    do hold self 10      # four spaces a step here: the whole text must be so

tree sentry_also:
always
    tree extras
```

The same text in its canonical form -- a tab a step, the comments on a
node's line in one column -- is what `bttree --format FILE` writes.

## 4. The three answers

Each time a node is ticked it answers one of three things:

| answer | meaning |
|---|---|
| **SUCCESS** | done, and it went well |
| **FAILURE** | not done, or it cannot be done |
| **RUNNING** | not finished: tick me again |

A tree is ticked about twenty times a second for each bot. An action
that takes time (walk there, fight him) answers RUNNING tick after tick,
then SUCCESS or FAILURE; the nodes above it pass RUNNING up, and resume
where they were at the next tick.

## 5. Every node

Fourteen keywords. Composites have any number of children, decorators
exactly one, leaves none.

| keyword | children | written |
|---|---|---|
| [`seq`](#seq) | 1 or more | `seq` |
| [`select`](#select) | 1 or more | `select` |
| [`pick`](#pick-and-option) | 1 or more, all `option` | `pick [every=<secs>] [sticky=<x>] [noise=<x>]`, or `pick roll=once`, `pick roll=life`, `pick roll=each [every=<secs>]` |
| [`option`](#pick-and-option) | 1 | `option <trait> <score> [score's arguments] [x<factor>]` |
| [`if`](#if-and-unless) | none | `if <condition> [arguments]` |
| [`unless`](#if-and-unless) | none | `unless <condition> [arguments]` |
| [`do`](#do) | none | `do <action> [arguments]` |
| [`wait`](#wait) | none | `wait <secs>` |
| [`invert`](#invert-always-never) | 1 | `invert` |
| [`always`](#invert-always-never) | 1 | `always` |
| [`never`](#invert-always-never) | 1 | `never` |
| [`cooldown`](#cooldown) | 1 | `cooldown <secs>` |
| [`limit`](#limit) | 1 | `limit <secs>` |
| [`tree`](#tree) | none | `tree <name>` |

### seq

Its children in order, as long as each succeeds: "do this, then this".

- A child answers FAILURE: `seq` answers FAILURE at once; the children
  after it are not ticked.
- A child answers RUNNING: `seq` answers RUNNING, and **the next tick
  resumes at that child**: the ones before it are not asked again.
- All have answered SUCCESS: SUCCESS.

```bt
seq
	if has_grenade
	if enemies_grouped 2 8
	do throw_grenade group
```

Because it resumes, a condition at the top of a `seq` is a condition to
*begin*, not one that is watched: once `do throw_grenade` is RUNNING, the
two `if`s are not looked at again. To have something re-examined, put it
under a `pick` (below).

### select

Its children in order, until one does not fail: "the first rule that
holds" -- a priority list.

- A child answers SUCCESS: `select` answers SUCCESS at once.
- A child answers RUNNING: RUNNING, and the next tick resumes at that
  child, exactly as `seq` does.
- A child answers FAILURE: on to the next. All failed: FAILURE.

```bt
select
	seq
		if ammo_out
		do retreat
	seq
		if enemy_visible
		do fight
	do seek
```

Because it resumes, a `select` does not notice that a higher rule has
become true while a lower one is RUNNING: here a bot that is seeking will
not see `if enemy_visible` until `seek` ends. That is deliberate (it is
predictable and cheap), and it is why the top of every tree that ships
is a `pick`: re-deciding is `pick`'s job.

### pick and option

A weighed choice. `pick` has only `option` children; each option has one
child, the thing to do.

```bt
pick every=2 sticky=0.25 noise=0.1
	option aggression enemy_visible x1.2
		do fight
	option caution under_fire x1.5
		do take_cover
	option none always x0.3
		do seek
```

- When it must choose, `pick` works out what each option is **worth** to
  this bot, now, and ticks the child of the best one.
- It answers what that child answers. When the child ends (SUCCESS or
  FAILURE) the choice is over: the next tick chooses afresh.
- While the child is RUNNING, `pick` goes on ticking it without asking,
  until `every` seconds have passed since the choice; then it chooses
  again. If another option now wins, the one left is
  [stopped](#7-when-an-action-is-stopped) and the new one begins.
- An option whose score is 0 (or less) cannot be chosen. If no option has
  a score above 0, `pick` answers FAILURE.

An option is `option <trait> <score> [arguments of the score] [x<factor>]`:

- `<trait>`: whose character weighs it -- one of the
  [traits](VOCAB.md#traits). `none` weighs the same for every bot.
- `<score>`: what bears on it -- one of the [scores](VOCAB.md#scores), a
  number from 0 to 1 read off the situation, with its arguments if it
  takes any (`enemy_near 40`).
- `x<factor>`: the designer's thumb on the scale. Default `x1`. It is
  the last word, an `x` and a number of 0 or more (`x1.5`, `x100`).

All the numbers, their defaults, and the sum: [section 6](#6-pick-in-full).

### if and unless

A condition of the [vocabulary](VOCAB.md#conditions), with its arguments.

- `if`: SUCCESS if the condition holds, FAILURE if not.
- `unless`: the other way round.

Never RUNNING. They are for the top of a `seq`.

```bt
seq
	if health_below 50
	unless enemy_within 10
	do take_cover
```

### do

An action of the [vocabulary](VOCAB.md#actions), with its arguments: the
only node that makes the bot do anything.

- RUNNING while the action goes on (it is called again at each tick).
- SUCCESS or FAILURE when it ends. Each action's line in VOCAB.md says
  which it answers and when: `go_to` succeeds there and fails with no
  way; `roam` is always RUNNING; `lamp on` succeeds at once.

```bt
do go_to enemy_base 6
```

An action that is RUNNING when its branch stops being ticked is told so,
once: [section 7](#7-when-an-action-is-stopped).

### wait

`wait <secs>`: RUNNING for that long, then SUCCESS. The time runs from
the first tick that reaches it. While it waits the bot does nothing of
its own: no key is held.

```bt
seq
	do look_around
	wait 1.5
	do reload
```

### invert, always, never

One child each; they change its answer and nothing else. RUNNING is
passed up unchanged by all three.

| | child SUCCESS | child FAILURE |
|---|---|---|
| `invert` | FAILURE | SUCCESS |
| `always` | SUCCESS | SUCCESS |
| `never` | FAILURE | FAILURE |

`always` is how a `seq` goes on whatever came of one step; `never`
makes a `select` go on after doing something.

```bt
seq
	always
		do ping enemy Enemy
	do fight
```

### cooldown

`cooldown <secs>`, one child: "not more often than this".

- It ticks its child and answers what the child answers.
- When the child ends (SUCCESS or FAILURE), the cooldown begins: for
  `<secs>` after that, `cooldown` answers FAILURE without asking the
  child.
- A child that is abandoned while RUNNING does not start the cooldown.
  A cooldown that is running is kept even if the branch round it is
  abandoned (it is the one timer that is).

```bt
cooldown 20
	do ping enemy Enemy
```

### limit

`limit <secs>`, one child: "not longer than this".

- It ticks its child and answers what the child answers...
- ...unless the child is still RUNNING `<secs>` after `limit` was first
  reached: then the child is [stopped](#7-when-an-action-is-stopped) and
  `limit` answers FAILURE.

```bt
limit 12
	do investigate
```

`limit 1` over a last resort (`limit 1` / `do seek`, as the shipped
trees end) makes a branch that never holds on for more than a second, so
the node above it is asked again.

### tree

`tree <name>`: another tree of the same text (or of the trees loaded with
it), as if it were written here. [Section 9](#9-several-trees-in-a-text).

## 6. pick, in full

```
pick [every=<secs>] [sticky=<x>] [noise=<x>]
    option <trait> <score> [arguments] [x<factor>]
        <one child>
```

| setting | default | allowed | what it is |
|---|---|---|---|
| `every` | 2 | 0 or more | seconds between two choices while the chosen option is RUNNING. `every=0`: chosen again at every tick |
| `sticky` | 0.25 | 0 or more | the option being done is worth this much MORE, as a fraction of its own worth: with 0.25 it counts for 1.25 times what it would. Stops a bot flipping between two things about as good |
| `noise` | 0.1 | 0 to 1 | luck: each option's worth is multiplied by a draw between 1 - noise and 1 + noise, from the bot's own dice, each time the pick chooses. `noise=0`: no luck, the same bot in the same situation always chooses the same |
| `x<factor>` (option) | 1 | 0 or more | multiplies that option's worth |

Each setting is written `name=value` with no space, in any order, after
`pick`; one that is not written has its default.

### What an option is worth

```
worth = score  x  the bot's weight for <trait>  x  factor  x  luck  [x (1 + sticky) if it is the one being done]
```

- **score**: the named score, asked of the situation as this bot
  perceives it; 0 to 1. At 0 or less the option is out, whatever the
  rest.
- **weight**: the bot's own weight for the trait, 0.2 to 3, about 1 for a
  trait its kind does not care about. `none` is always 1.
- **factor**: the option's `x<factor>`.
- **luck**: `1 + noise x (a draw from -1 to 1)`.
- **sticky**: only for the option the pick is holding at the moment it
  chooses again.

The option worth most is chosen. Ties go to the one written first.

### A weight is not a probability

Nothing above is a chance. A pick does not draw among its options in
proportion to their worth: it takes **the one with the highest worth**,
every time. An option of worth 1.2 beside one of worth 1.0 is not chosen
"55 % of the time": it is chosen, and the other is not.

- **One bot, one situation: the same choice, nearly always.** The only
  thing that varies it is `noise`, and noise moves each worth by at most
  that fraction (10 % by default). Two options within that of each other
  can change places from one choice to the next; two that are further
  apart never do.
- **The spread you see is across the crowd, not inside a bot.** Each bot
  has its own trait weights, so the same situation has a different
  winner for different bots. When `--split` says "33 % fight, 67 %
  retreat", it means a third of the bots are of a character that fights
  there, and each of them would fight there again -- not that every bot
  has one chance in three.
- A trait weight of 2 does not make an option twice as likely: it makes
  it worth twice as much, which is decisive against a rival worth 1.5
  times as much and indifferent against one worth 5 times as much.

If what you want is one bot that really varies:

- raise `noise` (up to 1): options within that fraction of each other
  then change places often. It is still not a lottery in proportion to
  worth -- an option worth a third of the best never wins, whatever the
  noise below 0.5;
- or use the condition `chance <probability>`, which is a real draw from
  the bot's own dice each time it is asked: `if chance 0.2` at the top
  of a `seq` lets a fifth of the tries through.

The one place where worth IS a chance is a pick that rolls, below: a role
drawn once, or a lottery drawn at every choice.

### Why this and not a lottery

Because a bot that decides by lot looks like it has no reasons. With the
highest worth, a bot does what its character makes of the situation and
goes on doing it while the situation holds; the variety of a team comes
from its members being different people.

### A worked example

The pick of [the first tree](#2-a-first-tree), with defaults written out:

```bt
pick every=3 sticky=0.25 noise=0.1
	option aggression enemy_near x1.2
		do fight
	option caution hurt x1.5
		do retreat
	option curiosity search
		do investigate
```

The situation: an enemy in sight 24 voxels away, so `enemy_near` is 0.6
(1 at arm's length, 0 at 60); the bot has 40 health left, so `hurt` is
0.6; nothing to search, so `search` is 0 and the third option is out.

| the bot | aggression | caution | fight = 0.6 x aggression x 1.2 | retreat = 0.6 x caution x 1.5 | does |
|---|---|---|---|---|---|
| a typical pusher | 1.90 | 0.59 | **1.37** | 0.53 | fights |
| a typical camper | 0.51 | 1.79 | 0.37 | **1.61** | retreats |
| a typical soldier | 1.00 | 1.00 | 0.72 | **0.90** | retreats, mostly |

Luck moves each by up to 10 %: the pusher's fight is between 1.23 and
1.50, his retreat between 0.48 and 0.58 -- he fights whatever the dice
say. The soldier's fight is between 0.65 and 0.79, his retreat between
0.81 and 0.99: he retreats.

Now suppose the soldier was already fighting when the pick chooses
again. Fight is the option held, so it counts 1.25 times: 0.72 x 1.25 =
0.90, the same as retreat. It is a toss-up, decided by luck: about half
the soldiers stay in the fight they began. With `sticky=0.5`, fight is
worth 1.08 and nearly all of them finish it. That is what sticky is for.

And no two soldiers are quite alike: their weights are rolled around 1,
so some have aggression 1.14 and caution 0.92, and fight. `bttree
--split` counts it over a crowd, and `--why` shows the sum
([section 14](#14-tuning)):

```
$ bttree --split --why first.bt enemy_near=0.6 hurt=0.6
700 bots, level 5, tree (the first)
   all soldier  camper  pusher flanker support  sapper   scout
 67.1%     80%    100%      0%     37%     94%     83%     79%  pick:caution > retreat
 32.9%     20%      0%    100%     63%      6%     17%     21%  pick:aggression > fight

why: pick every=3  (first.bt line 7; 700 bots came to it)
  chose   score  weight  factor   worth
  32.9%    0.60    1.00     1.2    0.72  aggression enemy_near  -> do fight
  67.1%    0.60    1.04     1.5    0.93  caution hurt  -> do retreat
   0.0%    0.00    1.09       1    0.00  curiosity search (0: cannot be chosen)  -> do investigate
```

### A role, drawn and kept: `pick roll=once`, `pick roll=life`

Sometimes a lottery is exactly what is wanted: one villager in twelve is
a killer, one bot in six is a camper -- and stays one.

```bt
tree village:
pick roll=once
	option none always                        # 1 in 12: the boss -- it keeps its post
		do hold self 99
	option none always x10                    # 10 in 12: a villager
		tree villager
	option none always                        # 1 in 12: the killer
		do seek

tree villager:
pick every=2
	option caution under_fire x10
		do take_cover
	option none always
		do look_around
```

A pick with `roll=` does not take the best option. It **draws** one,
each with a chance in proportion to its worth -- `score x the bot's
weight for the trait x factor`, no luck, no sticky -- and then **keeps
it**: that option's child is ticked every time, whatever it answers, and
the pick answers what the child does. Here the worths are 1, 10 and 1,
so the chances are 1, 10 and 1 in 12:

```
$ bttree --split --n 12000 village.bt
12000 bots, level 5, tree (the first)
   all soldier  camper  pusher flanker support  sapper   scout
 83.5%     83%     84%     83%     83%     85%     83%     84%  pick:none > pick:none > look_around
  8.4%      8%      8%     10%      8%      8%      9%      8%  pick:none > hold
  8.2%      8%      9%      8%      8%      8%      8%      8%  pick:none > seek
asked and not given (so 0): under_fire
```

- **`roll=once`**: the draw is the bot's **for good**. It is made from
  the bot's identity (its seed, which the server gives it) and from
  which pick this is (its tree's name, and its place among that tree's
  picks) -- nothing is stored, so it is the same in every life, on every
  map, after the trees are compiled again, in a replay.
- **`roll=life`**: drawn anew, from the bot's dice, each time it comes to
  life; kept until it dies.
- A role is kept through everything that makes other picks choose again:
  being startled, a pick above it going elsewhere and coming back.
- **The role does not move when its child ends.** If the child answers
  FAILURE, the pick answers FAILURE and ticks the same child again next
  time: what the bot does *instead* is said by the node above (a
  `select`), or inside the role's own tree.
- An option whose score is 0 **at the draw** is not drawn; with none
  above 0 the pick fails, and tries again at the next tick.
- `every`, `sticky` and `noise` mean nothing here and may not be
  written with `roll=`: the compiler refuses them.

**Under `roll=`, a score should be a FACT ABOUT THE BOT, not the
situation of the moment**: `always`, `gun_is rifle`, `has_item medkit`,
`is_leader`. The draw is fixed, but which option it lands on is worked
out from the worths at the first tick of each life -- so `option
marksman gun_is rifle` makes campers of rifles only, and a bot whose gun
changed is drawn again among what its new gun allows. A score like
`enemy_near` would make the role depend on where an enemy stood when the
bot was born, which is nobody's intent. The trait is a fact too: `option
marksman ...` gives a bot with twice the marksman's weight twice the
share.

**The shipped example** is `tdm.bt`'s campers: `tree tdm_duty` draws,
once for each bot, between a camper's tree (`option marksman gun_is
rifle x0.5`, `option marksman gun_is smg x0.2`) and the ordinary search
(`option none always`). About one bot in six is a camper -- 31 % of the
rifles, 16 % of the smgs, no shotgun; 45 % and 27 % among bots of the
camper's character -- and it is one in every life. A camper still
fights, takes cover and looks into a noise as anybody (those are above
its role in the tree); with nothing else on its hands it goes up to a
perch and waits, and when it is shot off it, to another. While no perch
is free it searches as the others do and looks again every few seconds.

**When separate trees are the better tool.** `roll=` gives *shares* of a
crowd: about one in twelve, never exactly two. When the game needs an
exact number (one boss), a role with its own place to spawn, its own
team, its own number of lives, or a role the script must be able to name
and change, give those bots their own tree from the gamemode instead:
`botlink_add{team=, tree=, at=, once=}`
([section 12](#one-bot-with-a-role-a-boss-a-villager)). `roll=` is for
characters within one team that plays one game.

`ctf.bt` has no such role: what a bot should do there turns on where the
two intels are, which is a situation and changes; its weighed
`ctf_duty`, chosen again whenever an intel changes hands, is the right
tool for that.

### A lottery at every choice: `pick roll=each`

`roll=once` and `roll=life` draw a role and keep it. `roll=each` draws
**again every time the pick chooses**: the first tick, every `every`
seconds (default 2, as for a plain pick), and whenever the chosen
option's child ends. Each time, one option is drawn with a chance in
proportion to its worth -- `score x the bot's weight for the trait x
factor`, no luck, no sticky -- from **the bot's own dice** (not its
identity: the same bot does not draw the same twice), and ticked until
the next choice.

```bt
pick roll=each every=8
	option flank always x0.9              # worth 0.9
		do flank
	option none always x0.9               # worth 0.9
		do seek
	option marksman always x1.2           # worth 1.2 for a bot of weight 1
		do hold self 10
```

With worths 0.9, 0.9 and 1.2 the same bot, in the same situation, flanks
30 % of the times it chooses, seeks 30 % and holds 40 %. (A plain pick
would take the 1.2 every time.)

- `every` is meaningful and may be written. `sticky` and `noise` mean
  nothing -- there is no best to favour, and the lottery is the luck --
  and the compiler refuses them.
- The draw may land on the option already held: that option then
  **simply goes on**; it is not stopped and started again. The option
  being left is [stopped](#7-when-an-action-is-stopped) once, as for a
  plain pick.
- An option whose score is 0 at the choice is never drawn. With none
  above 0 the pick fails, draws nothing, and asks again at the next tick.
- A jolt (`bt_restart`) or a `bt_reset` makes it choose, and so draw,
  again at the next tick, and stops what it was doing -- exactly what a
  plain pick does there. Nothing is kept: there is no role.
- Scores here are the situation of the moment, as for a plain pick; the
  draw is made with them as they are at the choice.
- `--split` runs one tick for each bot of the crowd, so it shows **one
  draw each**: the crowd's shares approximate the odds of a single bot's
  choice, within the noise of the crowd's size. `--trace` and the live
  snapshot show each option's share and which one the last draw took.

**It must never be used for a priority list of reactions.** An option
worth a tenth of another still wins one choice in eleven: a bot that
sometimes takes a walk while a grenade is at its feet. Use it only where
**every option is acceptable at any moment** -- idle behaviour, which
way to patrol, which of several harmless things to do while waiting.
Anything that must win when it applies belongs in a plain pick (factors
as ranks) or in a `select` above.

The three ways of choosing, side by side:

| | `pick` (best worth wins) | `roll=once` / `roll=life` | `roll=each` |
|---|---|---|---|
| chooses by | the highest worth, with luck and sticky | a draw in proportion to worth | a draw in proportion to worth |
| chosen again | every `every` s, and when the child ends | never in the life (once: never at all) | every `every` s, and when the child ends |
| the same bot in the same situation, next time | the same option, nearly always | the same option: it is its role | any option, in proportion to worth |
| a weak option (a tenth of the best) | never wins | wins in its share of the crowd -- and keeps winning for that bot | wins its share of the choices of every bot |
| scores should be | the situation | facts about the bot | the situation, if every option is acceptable |
| use it for | reactions, priorities, plans | characters, roles | variety within one bot: idle behaviour, which way to patrol |

### Three ways a pick is used

**A priority list everybody obeys**, looked at again every second: the
trait `none`, falling factors, `noise=0`. The factor is the rank; a score
that is 0 when its thing does not apply takes the option out.

```bt
pick every=1 sticky=0.2 noise=0
	option none grenade_near x100         # a grenade at its feet: run
		do evade
	option none has_order x30             # the server said so
		do obey
	option none enemy_visible x5          # somebody in sight
		do fight
	option none always                    # nothing of that: the game
		do seek
```

Unlike a `select`, it is asked again every `every` seconds, so a grenade
landing interrupts a fight within a second.

**A split of the team by character**, chosen for a good while: real
traits, a long `every`, a high `sticky`, some `noise`.

```bt
pick every=20 sticky=1.5 noise=0.3
	option objective their_intel_home     # the keen on the game: go and take it
		do fetch
	option caution unwatched own_intel 20 # the careful: keep ours
		do guard own_intel 40
	option flank flank_open x0.8          # the sly: round the side
		do flank
	option none always x0.2               # everybody, a little: go and find them
		do seek
```

**A last option that can always be chosen** -- `option none always` with
a small factor -- so that the pick does not fail when nothing else
applies. Where a pick may fail, put something under it in a `select`.

Give every option a score that is 0 when its action cannot be done. A
pick ticks its one best option and answers with it: an option that wins
and then fails at once is chosen again at the next tick, and the bot
stands.

## 7. When an action is stopped

An action that is RUNNING holds things: a route, a key pressed, a claim
on a perch. When its branch stops being ticked **the action is told so,
once** (its `stop`), so it can let go; and everything remembered under
that branch -- where each `seq` and `select` was, each `wait`, each
`limit` -- is forgotten, so the branch starts from its top if it is
chosen again. This happens when:

- a `pick` chooses another option (or finds none to choose);
- a `limit` runs out;
- the bot's tree is entered afresh: it died, the map changed, its tree
  was replaced, or something startled it (a first enemy in sight, a hit
  from nowhere, a grenade noticed -- the engine then has every pick
  choose NOW rather than at its next `every`).

An action that itself answered SUCCESS or FAILURE is not told to stop: it
is over. A `cooldown` that has begun is kept through all but the last
case.

## 8. Time

Every bot has its own clock, advanced at each tick by the time since its
last one. `wait`, `limit`, `cooldown` and `pick`'s `every` all read it,
so a timer is right even in a branch that was not ticked meanwhile.

- A timer starts at the first tick that reaches its node: `wait 1`,
  ticked every half second, answers RUNNING, RUNNING, SUCCESS.
- `limit` asks its child first and then looks at the time.
- `cooldown` starts when its child answers SUCCESS or FAILURE.

## 9. Several trees in a text

A text may hold any number of trees, each begun by `tree <name>:`. A name
may be defined once.

### References: `tree <name>`

`tree <name>` as a node stands for that tree, **as if it were written
there**. The tree may be defined before or after, in the same file or in
another file loaded with it. A tree used in two places is two copies:
each has its own memory. A tree may not lead back to itself.

```bt
tree patrol:
select
	seq
		if enemy_visible
		tree engage
	do roam

tree engage:
seq
	always
		do ping enemy Enemy
	do fight
```

### `<name>_also`: what is done beside

A bot runs ONE tree, by name (say `tdm`): what it is doing. If a tree
called `<name>_also` (`tdm_also`) exists with it, it is ticked just
before the main one at every decision. That is where things done BESIDE
go -- a lamp, a ping, an item -- because `seq` and `select` remember
where they were and would not come back to them while a fight is
RUNNING. Keep an `_also` tree to actions that end at once.

```bt
tree guard_duty:
pick every=1 noise=0
	option none enemy_visible x5
		do fight
	option none always
		do guard own_base 30

tree guard_duty_also:
seq
	always
		tree extras       # what the server's scripts add (night and lamps, if it has them)
	always
		tree items        # whatever it holds, used as each item says
```

### `tree items` and `tree extras`: written by the engine

Two trees are always there to be referred to, and are never written in a
file:

- **`items`**: one rule for each inventory item, brought by whoever
  defined the item (a medkit when hurt, a missile at an enemy under open
  sky). The engine writes them as a `select` of `seq`s, each beginning
  with `if has_item <name>`. It fails at once for a bot with nothing to
  use.
- **`extras`**: what the server's scripts add to every bot that is not
  an item -- night and flashlights first of all. Each fragment is ticked
  at every decision, whatever the others answer.

A tree that wants its bots to use what they hold and to follow the
server's scripts says so in its `_also` part, as above. A tree that does
not, has bots that ignore both. `bttree` draws the two as "(filled in at
run time)".

## 10. How trees are compiled and used

### From text to forest

```
text ──lines──▶ words ──nodes──▶ trees as written ──references opened──▶ forest
                                 (the SOURCE)                          (what is RUN)
```

1. **Lines.** The text is cut at each newline. What follows a `#` is the
   line's comment; a line with nothing else is kept for the node that
   comes next (so comments survive).
2. **Words.** The line's indentation is counted and checked against the
   text's step; the rest is cut into words at spaces and tabs.
3. **Nodes.** The first word is the keyword; the others are checked for
   that keyword: numbers are numbers, a `pick` has only known settings,
   and every leaf **name is looked up in the vocabulary** -- a condition
   after `if`, an action after `do`, a trait and a score after `option`.
   A name nobody registered is a mistake. So are **arguments the word
   does not take**: each word says what it takes ([VOCAB.md](VOCAB.md)),
   and one too many or too few, a word where a number goes, a number out
   of its range, a place there is none of, a word that is not one of
   those allowed are refused -- `line 5: go_to: no place called
   nowhere`. The node is placed under the
   last node one step less indented, and the shape is checked: a leaf
   takes no children, a decorator exactly one, an `option` sits directly
   under a `pick` and a `pick` has only options.
4. **Trees as written** -- the *source*: every tree, each node with its
   words, its line and column, and its comments. This is what an editor
   reads and writes.
5. **References opened.** Each `tree <name>` is looked up among all the
   trees of the text and replaced by a copy of that tree. A name with no
   tree, or a circle of references, is a mistake.
6. **The forest**: one flat array of nodes for all the trees, each node
   with the C function its name stands for. One block of memory, never
   changed after.

The engine says the first mistake, where and what: `line 12: no action
called figth`. `bttree --check` says **every** mistake of a text at once
(each with its line and, for a tool, its column): a line whose words are
wrong keeps its place, so what is under it is still read; what merely
follows from a line that had to be dropped is not said twice.
A text that does not compile changes nothing: the trees running stay.
The same holds for what arrives while the server runs: an item's or a
script's fragment with a wrong word or a wrong argument is said in the
log with its line and left out, and a tree sent whole is refused.

### One forest, one state a bot

The forest is **shared and immutable**: every bot running those trees
reads the same one. What a bot owns is a *state*: one small slot for
each node of the forest (16 bytes), holding what that node remembers --
which child a `seq` was at, which option a `pick` holds and since when,
whether a `do` is RUNNING, when a `wait` began -- and the bot's clock.
It is allocated once, when the bot is given the forest; nothing is
allocated while it thinks.

### The tick

About twenty times a second for each bot (not all at the same instant),
the engine:

1. refreshes what the bot perceives;
2. if something startled it, forgets where it was in the tree
   ([section 7](#7-when-an-action-is-stopped));
3. ticks `<name>_also`, if there is one;
4. ticks the main tree `<name>`, from its root.

A tick walks down from the root: a `seq` or a `select` goes straight to
the child it was waiting on; a `pick` goes straight to the option it
holds unless it is time to choose; a leaf calls its C function. So most
ticks touch one path of the tree, a handful of nodes, and call one
action. The actions state what the bot wishes (go there, look there,
fire); the layers below (routes, aim, the body) carry it out between
decisions.

### Which tree a bot runs

In order: the bot's own tree (given to that one bot); else the world's
(`tree=<name>`, which the server sets to the gamemode's name, or what
the operator chose); else `default`. The name is looked for in the bot's
own text first, then in a text the server sent for everybody, then in
the trees loaded from files, then in the engine's built-in last resort
(fight what is in sight, else roam). A name with no tree anywhere is
said in the log and `default` is run.

When any tree text changes, the trees are compiled again together with
the `items` and `extras` the engine writes, each bot is moved to the new
forest with a clean state, and whatever action was RUNNING is stopped
once.

### Cost

A tick of the two trees of a bot, with leaves that cost nothing,
measures about 40 nanoseconds on a laptop; with every pick choosing at
every tick, about 55. In the engine the tree is not what costs: the
leaves are (a score that looks for a perch, an action that follows a
route), and they are budgeted on their own. A whole think of a bot --
senses, tree, movement -- is about 0.1 ms. Compiling is done when a text
arrives, never in a tick; the four shipped files (some 270 node lines,
some 520 nodes once the references are opened) compile in under a tenth of a millisecond.

## 11. Characters: traits, archetypes, weights

A bot's character is ten **traits**, each a weight around 1:

| trait | a high weight means |
|---|---|
| `aggression` | take the fight, close the distance |
| `caution` | cover, retreat when hurt, keep range |
| `objective` | the intel, the point, the tower -- the game |
| `teamwork` | answer pings, escort, stay with the others |
| `builder` | dig and build rather than walk round |
| `marksman` | fight from far, hold an angle |
| `flank` | go round rather than through |
| `stealth` | sneak, lamp out, do not be heard |
| `curiosity` | go and look: noises, last-seen places |
| `greed` | use what it holds: items, grenades |

and `none`, which is 1 for everybody.

**How the weights are rolled.** When a bot is made it is first given an
**archetype** -- soldier, camper, pusher, flanker, support, sapper,
scout -- drawn by the mix the server set (all equal when unset). Each
trait is then drawn around that archetype's centre for it, with a spread
of 0.25 to 0.4, and kept within 0.2 and 3. A pusher's aggression is
about 1.9 and his caution about 0.6, but no two pushers are alike -- one
in five or so of each kind does something else than its kind. The roll
comes from the bot's own seed: the same seed is the same character. The
centre and spread of each archetype for each trait are the table in
[VOCAB.md](VOCAB.md#archetypes).

**The kinds are data.** That table is the file `trees/archetypes.txt`,
beside the shipped trees, a line a kind:

```
camper   aggression=0.5/0.30 caution=1.8/0.40 ... -- careful and a marksman: ...
```

(`<trait>=<centre>/<spread>`; a trait not named is drawn round 1 with a
spread of 0.25; `#` starts a comment; after `--`, its one line.) The
engine has the same numbers built in. **Your own:** an `archetypes.txt`
in the trees directory of the data volume (`/data/trees/`) is read after
the shipped one, at start and at each map: a kind of the same name is
replaced by yours, a new name is one kind more, and `engine_bots_
archetypes` may then name it (`medic:2,camper:1`). A script may send a
table too, `botlink_set("archetype_table", text)`, read over the files'.
A fault in a file or a text is said in botd's log, and the kinds stay as
they were; so does a table that leaves out a kind the mix names. `bttree
--split --mix`, `--as` and `--schema` read the `archetypes.txt` beside
the trees they are given, or the ones named with `--archetypes FILE`.

Three things lean the whole crowd, all settings the server sends
([section 12](#12-writing-your-own)):

- `archetypes=camper:2,pusher:1` -- the mix characters are drawn from;
- `traits=aggression:2,caution:0.5` -- every bot's weight for those
  traits multiplied, on top of its own roll, still within 0.2 to 3. The
  bots keep their differences; the lot leans. It can be set for one bot
  too, and the two multiply;
- the tree's own factors, which weigh an option for everybody.

**Level** (1 to 10) is apart from character: how WELL the bot does what
its tree and character choose, never WHAT it chooses. Everything below
moves together with the level, because a weak player is not only a worse
shot: they also react later, hear less and move worse.

| What the level sets | Level 1 | Level 5 | Level 10 | Where |
|---|---|---|---|---|
| aim cone (how far the aim wanders) | 14 deg | 6.2 deg | 1.8 deg | `core/aim.c` LEVELS |
| turn speed | 90 deg/s | 175 deg/s | 320 deg/s | `core/aim.c` |
| delay before acting on a new target | 0.50 s | 0.30 s | 0.14 s | `core/aim.c` |
| where on the body the aim lands (0 centre, 1 spread) | 1.00 | 0.90 | 0.38 | `core/aim.c` |
| lead on a moving man (0 exact, 1 like a person) | 1.00 | 0.88 | 0.30 | `core/aim.c` |
| sensing where a hit came from | 0.95 s, 40 deg off | | 0.15 s, 4 deg off | `core/aim.c`, `core/senses.c` |
| hearing a shot / a dig or build / a step / a blast | 14 / 6 / 4 / 24 blocks | | 34 / 14 / 8 / 48 blocks | `core/senses.c` bc_hear_range |
| aggression: opens fire from this share of the gun's range | 0.20: 80 % | 0.52: 87 % | 0.95: 97 % | `core/skill_fight.c` LEVELS |
| dodging, crouching, sprinting, reloading, digging, grenades | 0.05 to 0.30 | 0.35 to 0.58 | 0.66 to 0.95 | `core/skill_fight.c` |

Each table is the one place to tune it, monotonic in every column (a
test checks it). The level leaves alone: the tree and the role (a level
1 sniper is a sniper), the character's traits, and the body (speed,
jump, health are a player's). Operators choose levels with
`engine_bots_level` (the centre, 10 by default) and
`engine_bots_level_spread` (how far each bot may fall from it, either
way: 0 by default, so every bot is level 10); a script gives one bot its level
with `botlink_add{level = n}`.

A tree may gate a branch on the level -- what only the able should try:
`if level_at_least 8` (a condition), or lean a pick with the score
`level` (0 at level 1, 1 at level 10):

```bt
tree sniper_or_not:
select
	seq
		if level_at_least 8                   # a long shot is for a good shot
		do take_high_ground
	do advance_by_cover enemy_base 45
```

## 12. Writing your own

Whoever you are, the loop is the same: write the text, `bttree --check`
it, look at it (`bttree FILE`), try the situations that matter with
`--split` ([section 14](#14-tuning)), then give it to the bots. The
tutorial does it from an empty file: [trees/README.md](trees/README.md).

### As an operator: a file, and four settings

The steps, with what each prints, are the tutorial's
([trees/README.md, step 5](trees/README.md#5-run-it-on-a-server)). The
facts:

- A file `<name>.bt` in the **`trees/` directory of the data volume**
  (`/data/trees/` in the container) is read with the built-in trees when
  the server starts and **again at each map load**: edit the file,
  change the map, and the bots have the new tree -- no restart.
- User trees are loaded after the built-in ones. **A tree with the name
  of a built-in one replaces it** (your own `tdm`); any other name is
  added, to be chosen by name.
- A file that does not compile is said in botd's log -- `tree error:
  /data/trees/mine.bt: line 12: no action called figth (skipped)` -- and
  left out; the built-in trees stay.
- `lsdctl bots save <name>` writes such a file from a text it has
  checked; `lsdctl bots apply` gives a tree to bots that are playing
  ([section 17](#17-the-editors-backend-operations-and-their-json)).

How the engine's bots play is said with four settings of the
`engine_bots` script (`catalog/bots/engine_bots`), each empty by default
and applied live, within a second of being set:

| setting | example | what it does |
|---|---|---|
| `engine_bots_tree` | `mine` | the tree the bots run, by name: a built-in one or yours. Empty: the gamemode's |
| `engine_bots_archetypes` | `camper:2,pusher:1` | the mix of characters. Empty: every kind, equally |
| `engine_bots_traits` | `aggression:2,caution:0.5` | every bot's trait weights multiplied. Empty: as rolled |
| `engine_bots_edit` | `dig`, `build`, `all` | what a bot's route may do to the map. Empty: nothing, it only walks and jumps |

A tree of your own for a mode that already has one is easiest begun as a
copy: `docker exec lsd lsdctl bots tree tdm > mine.bt` gives one tree,
`docker exec lsd cat /opt/botd/trees/tdm.bt > mine.bt` the whole file;
rename its trees (`tdm` to `mine`, `tdm_also` to `mine_also`, and so on
down the file), and change it.

### As a gamemode author

A gamemode's Lua sends the tree, for every bot or for one, and much
else: [section 13](#13-what-a-server-script-can-do).

### One bot with a role: a boss, a villager

A gamemode can give ONE bot a tree of its own -- a guard, a courier, a
boss -- and change it while it plays:

```lua
local pid = botlink_add{team = 2, name = "Warden", level = 9,
	tree = BOSS,                          -- its own tree: a name, or the text
	at = {x = 256, y = 256, z = 40},      -- where it spawns (or a function(pid) -> position)
	once = true};                         -- one life: when it dies it leaves the server
```

- `tree`: the tree this one bot runs instead of the world's. A text is
  compiled and kept for that bot alone, and freed with it.
- `at`: where it spawns, asked at every spawn; without it the bot spawns
  where the gamemode puts a player.
- `once`: when it dies it is removed.
- `botlink_set("tree", name_or_text, pid)` changes its tree at any time
  (what it was doing is stopped, once). A text replaces the bot's own; a
  name is a tree of the world's (a built-in one, the operator's, one the
  gamemode sent for everybody) and drops the bot's own text; an empty
  value gives it back the world's tree.
- `botlink_set("traits", "aggression:3", pid)` leans that one bot's
  character.

**The boss.** It keeps to its lair, goes for anybody it sees, never
backs off, and throws grenades at groups. Its lair is a place the
script gives it as an order (`do obey` goes there and holds).

```bt
tree boss:
pick every=1 sticky=0.5 noise=0
	option none grenade_near x100         # even a boss steps off a grenade
		do evade
	option greed grenade_worth x8         # a knot of them, or one far off: a grenade
		do throw_grenade
	option aggression enemy_visible x5    # anybody in sight: at him
		do fight
	option none under_fire x3             # shot from somewhere it cannot see: go and look
		do investigate
	option none has_order                 # nothing: back to the lair, and watch
		do obey
	option none always x0.1
		do look_around
```

**The boss, enraged**, for when the script decides it is time (half its
health gone, the last door open): it leaves the lair and hunts.

```bt
tree boss_enraged:
pick every=0.5 sticky=0 noise=0
	option none grenade_worth x8
		do throw_grenade
	option none enemy_visible x5
		do fight
	option none rumour x2                 # no one in sight: to where they were last heard
		do hunt_noise
	option none always
		do seek
```

**The villager.** It stands about near home, goes to look at a noise if
it is curious, keeps with the others, and runs for cover from a stranger
or a shot.

```bt
tree villager:
pick every=2 sticky=0.3 noise=0.2
	option none grenade_near x100
		do evade
	option caution under_fire x10         # shot at: run for cover
		do take_cover
	option caution enemy_near 30 x4       # a stranger close: back off, toward home
		do fall_back_by_cover own_base
	option curiosity search x0.5          # a noise: the curious go and look
		do investigate
	option teamwork alone 30 x0.6         # lonely: back to the others
		do follow mate
	option none always x0.3               # the day's work
		tree villager_idle

tree villager_idle:
seq
	do hold self 6                        # stand a while, looking about
	do look_around
	limit 15                              # then a walk, not a long one
		do roam
```

Put together, in a gamemode's script:

```lua
local BOSS = read_file("boss.bt");            -- each of the three texts above, as it is
local BOSS_ENRAGED = read_file("boss_enraged.bt");
local VILLAGER = read_file("villager.bt");
local LAIR = {x = 256, y = 256, z = 40};

local boss = botlink_add{team = 2, name = "Warden", level = 9, tree = BOSS, at = LAIR, once = true};
botlink_set("traits", "aggression:3,caution:0.2,greed:2", boss);
botlink_order(boss, {order = "hold", pos = LAIR});      -- `has_order`, and what `do obey` does

for i = 1, 6 do
	local v = botlink_add{team = 1, name = "Villager", level = 2, tree = VILLAGER,
		at = function() return village_spot(); end};
	botlink_set("traits", "caution:2,aggression:0.3", v);
end

-- later, when the script decides it is time: the same bot, another tree
local function enrage()
	botlink_set("tree", BOSS_ENRAGED, boss);  -- the text: the first tree in it is the one run
	botlink_order(boss, {order = "none"});    -- and no lair to keep to
end
```

A mode that does this for real: the hostages of
`catalog/gamemodes/hostage/hostage.lua` (THE ENGINE'S MIND there). The
script keeps the game's rules -- who leads a hostage, when it is home --
and tells its tree (an order to follow, `fact rescue`, `fact home`, `fact
lost`); the tree decides what it does with that: follows, runs the last
steps home and `tell`s it, cowers under fire. With no engine beating it
is the lib_bot hostage it always was.

(`read_file`, `village_spot` and when `enrage` is called are the
script's own; the `botlink_*` calls are lib_botlink's, documented at the
top of `catalog/libs/botlink/lib_botlink.lua`. Trees that several bots
share by NAME -- every villager running `villager` -- can instead be put
in the text the gamemode sends for everybody, after its main tree, and
named: `botlink_add{..., tree = "villager"}`.)

What a tree cannot do: it chooses among the engine's actions, and some
of them shoot on their own (`go_to` shoots what it meets, `take_cover`
peeks to fire: each action's line in VOCAB.md says). A villager that
must never fire is the server's business -- it is the authority on what
a player may do -- not the tree's. And a bot goes to *places the engine
has a name for* ([VOCAB.md](VOCAB.md#places)): a point of your own is
given as an order, as the lair is here.

## 13. What a server script can do

Everything a catalog Lua script -- a gamemode, an extension, an item --
can do to shape the bots, today. The functions are lib_botlink's
(`catalog/libs/botlink/lib_botlink.lua`, whose head comment lists them);
they do nothing when the link is not there, so a script may call them
unconditionally once it has checked `botlink_set ~= nil`. What is said
is kept by the server and sent again to a bot engine that starts late or
comes back.

Nothing in the engine knows a gamemode, an item or a script by name: a
script gives it trees made of the neutral words, settings, and -- for
what there is no word for -- names of its own choosing (8 to 10).

### 1. A tree for the world

```lua
function mod.on_load()
	if (botlink_set == nil) then return; end
	botlink_set("tree", "ctf");            -- a tree the engine has, by name
	botlink_set("tree", SIEGE);            -- or the text of trees: the first in it is the one run
end
```

```bt
tree siege:
pick every=1 noise=0
	option none grenade_near x100
		do evade
	option none enemy_visible x5
		do fight
	option none always
		do go_to enemy_base 8
tree siege_also:
always
	tree items
```

The text is compiled on its own, with the `items` and `extras` the
engine writes: it may refer to those two and to its own trees, **not to
the trees of the built-in files** (copy what you need of them into the
text). If it does not compile, the engine says so with the line and the
bots keep the tree they had. A text may be up to 60000 bytes: one longer
than a record of the link (about 1000 bytes) is sent in pieces and put
together by the engine, which takes it only if every piece came -- a
tree is never run cut short (`botlink_set` answers false, and says so in
the log, for one that is too long). With no call at all, lib_botlink
names the tree after the gamemode (`tdm`, `ctf`...), and a mode with no
tree of that name gets `default`.
*Tested: `bot/tests/engine_test.c` (the trees, a tree longer than a
record), `tests/botlink_test.lua` section 10b.*

### 2. A tree for one bot, changed while it plays

```lua
local pid = botlink_add{team = 2, name = "Warden", level = 9,
	tree = BOSS, at = {x = 256, y = 256, z = 40}, once = true};
botlink_set("tree", BOSS_ENRAGED, pid);    -- later: another, for that bot
botlink_set("tree", "", pid);              -- or the world's tree again
```

The whole of it, with a boss and a villager:
[section 12](#one-bot-with-a-role-a-boss-a-villager).
*Tested: `engine_test.c` ("a tree for one bot, replaced in play"),
`botlink_test.lua` section 10b.*

### 3. A fragment every bot runs beside its tree

For a script that changes how every bot behaves without being an item:
the night and its flashlights are the model
(`catalog/extensions/night/lib_night.lua`, BOT_TREE).

```lua
botlink_set("extra.night.tree", LAMP);     -- added to every bot's `tree extras`
botlink_set("extra.night.tree", "");       -- taken back
```

```bt
pick noise=0
	option none night_vision x10    # it sees in the dark: stay dark
		do lamp off
	option stealth night            # the stealthy stay dark and listen
		do lamp off
	option none night x1.2          # anybody else, at night: light up
		do lamp on
```

The fragment is a text with no header. The engine puts each script's
fragment into `tree extras`, each ticked at every decision whatever the
others answer; a tree runs them where it says `tree extras` (its
`_also` part). Keep a fragment to actions that end at once. One that
does not compile is said in the log, with the line in ITS text, and left
out; the rest stand.
*Tested: `engine_test.c` (the night scenarios), `tests/night_test.lua`.*

### 4. An item that says when a bot should use it

```lua
inventory_define("medkit", {label = {en = "Medkit"}, command = "reward medkit",
	bot = {tree = "seq\n\tif health_below 50\n\tdo use medkit self", guide = 0}});
```

```bt
seq
	if health_below 50
	do use medkit self
```

`tree`: a fragment, tried by any bot that holds the item wherever its
tree says `tree items` (the engine puts `if has_item <key>` in front of
it). `guide`: seconds the bot keeps its aim on the target after using it
(a guided missile). The rewards menu (`rewards_menu`,
`catalog/tools/rewards`) takes the short form, a list of lines that is
made a `seq`: `bot = {"if health_below 50", "do use medkit self"}`.
`do use <item> [place]` makes the bot run the item's command, as a
player would.
*Tested: `engine_test.c` ("items: each brings its own decision"),
`botlink_test.lua` section 9b, `tests/rewards_test.lua`.*

### 5. Settings

`botlink_set(key, value [, pid])`: for every bot, or -- for the keys
marked * -- for one. The list is `bot/core/engine.c`'s (its head
comment, SETTINGS, has the detail):

| key | value | |
|---|---|---|
| `tree` * | a name, or the text of trees | 1 and 2 above |
| `traits` * | `aggression:2,caution:0.5` | each named trait's weight multiplied, on top of the bot's own roll; for all and for one the two multiply |
| `archetypes` | `camper:2,pusher:3` | the mix characters are drawn from |
| `archetype_table` | the text of an `archetypes.txt` | the kinds of player, read over the files' ([section 11](#11-characters-traits-archetypes-weights)) |
| `edit` * | `none`, `dig`, `build`, `all` | what a route may do to the map |
| `spend` | a number | blocks a route may use (50) |
| `zone` | `x0 y0 x1 y1 [nodig] [nobuild] [team N]`, more after `;`, or `clear` | the rectangles where routes and edit words do not edit (both, when neither is said), for everybody or for team N's bots; each set is the whole list |
| `protect` | `x y z` | a voxel the server will refuse to change |
| `water` | `lethal`, `safe`; `water.damage` a number | what wading costs |
| `fire` | `hold`, or nothing | the server forbids all fire: no bot pulls a trigger or strikes a blow, whatever its tree does (a tree decides what a bot goes to do; this is the server's rule, as the water is). A server at peace sets it beside `fact.peace`, which the shipped trees read to stop fights and grenades |
| `night.sight` | `0`, `1`; `night.cone`, `night.reach`, `night.far` | night sight and lamps (the night script sets them) |
| `night_vision` * | `0`, `1` | the bot sees by night as by day |
| `sight`, `fov`, `notice`, `memory`, `relay`, `board`, `noise_secs` | numbers | the senses |
| `leaders.per` | a number | squads: one leader for every n of a team (0: no squads): every person on a team leads (the bots close to him), bots drawn make up the rest |
| `plan.greed`, `plan.cap`, `plan.wait`, `plan.share` | | the route search (`plan.share=0`: no route board, every bot searches alone) |
| `gaze` | `0`, `1` | a travelling bot's head is its own |
| `ping_takers`, `ping_radius` | numbers | how many bots answer a ping, from how far |
| `cull` | `voxlap`, `openspades` | which floating blocks fall |
| `item.<name>` * | a count, `inf` | what a bot holds (lib_botlink sends it from the inventory) |
| `item.<name>.tree`, `.guide` | | 4 above |
| `extra.<name>.tree` | | 3 above |
| `fact.<name>` *, `place.<name>` * | | 8 and 9 below |
| `blueprint.<name>` | `x y z; x y z; ...` (empty: forgotten) | a structure for the team to build, a part each (`build_part`, [VOCAB.md](VOCAB.md)): its voxels in the order they rest on each other, team-scoped as places are (`blueprint.stair@1`); 16, of 8192 voxels at most. The same text again changes nothing (who holds which part, what is left alone, stand) |
| (structures) | botd's `structures/*.kv6`, then the operator's (`--user-structures`, the data volume's `structures/`) | PREFABS a leader orders built (`order_build <structure> [place]`, a tree's; or a person's build ping, "Build mirador here" from the pie's Build pie): set at the place, front toward him, as the blueprint `order<pid>` his squad builds (`build_part leader`, `leader_ordered`), in its colours; clipped by the zones; forgotten built whole. Every person on a team is a leader. Shipped: `bunker`, `mirador` (bot/tools/mkstructures.py writes them). Not in babel |
| anything else | any text | kept, for a tree's `if setting <key> [value]`: how a mode's tree reads the mode's own rules |

*Tested: `engine_test.c` ("settings", "traits"), `botlink_test.lua`
sections 9 and 11b.*

### 6. Orders

```lua
botlink_order(pid, {order = "hold", pos = {x = 256, y = 256, z = 40}});
botlink_order(pid, {order = "hunt", target = other_pid, secs = 30});
botlink_order(pid, {order = "none"});
```

`order`: `goto`, `hold`, `hunt`, `follow`, `none`; `pos` or `target` (a
player id); `secs`: how long it stands (0: until another). An order does
nothing by itself: a tree obeys with `do obey`, and asks with `if
has_order` / the score `has_order` -- the shipped trees have `option
none has_order x30` high in their list. The place `order` is where it
points.
*Tested: `botlink_test.lua` section 9, `bot/tests/skills_test.c`.*

### 7. What a bot does to the server

A bot acts through the same doors as a player, so a script reacts to it
as to a player and needs no bot-specific code:

- `do use <item>` runs the item's command (`inv <item> [x y z]`) as the
  bot: `handle_command(pid, text)`.
- `do ping <place> <label>` is a player's ping (the Teamplay
  extension).
- A route that digs or builds goes through `on_block_action` and
  `on_block_line`; a grenade through `on_grenade`; a hit through
  `on_hit` -- after the checks the server would make for a client.
- A bot dies, spawns, scores and picks up the intel as a player does:
  `mod.after.kill(pid, ...)` and the rest see it. `bot_is_bot(pid)`
  tells it from a person.

*Tested: `botlink_test.lua` section 7 ("actions go through the chains,
as the bot").*

### 8. A fact the trees can read

```lua
botlink_set("fact.alarm", 1);              -- for every bot
botlink_set("fact.alarm", 0, guard);       -- for one: its own is read before the world's
botlink_set("fact.alarm", "");             -- forgotten
```

In a tree: the condition `if fact alarm` (set, and above 0), `if fact
alarm 0.5` (at least that), and the score `option none fact alarm` (its
value, kept within 0 to 1; 0 when nobody set it). A fact is a number
and a name of the script's choosing: letters, digits and `_`, 23 at
most. 64 for the world and 8 a bot; one more, a bad name or a value that
is not a number is refused and said in the engine's log, never silently.
Nothing happens the moment a fact changes: a pick sees it the next time
it chooses, so put it under a pick whose `every` is as short as the
reaction should be (the top picks of the shipped trees look every
second).

### 9. A place of the script's naming

```lua
botlink_set("place.church", "286.5 268.5 30");   -- a point: x y z
botlink_set("place.boss", "pid " .. boss);       -- or wherever that player is, while he lives
botlink_set("place.church", "", pid);            -- a bot's own, forgotten: the world's again
```

In a tree it is written with an `@`, wherever a place goes: `do go_to
@church 3`, `do hold @church 60`, `do guard @vault`, `if at @church`,
`if knows @boss`, `do flank @church`, `do use rocket @boss`. The `@` is
what makes it a script's place: a name without it must be one of the
engine's ([VOCAB.md](VOCAB.md#places)), so `go_to enemy_bas` is still a
mistake the compiler catches, while `@anything` compiles before the
script has said where it is. Until it is set (and while the player it
follows is dead) `knows @name` is false and going there fails, as for
any place there is none of. 32 for the world, 4 a bot.

**A team's own.** A mode with one of a thing for each team (a stair, a
gate) tells it once for the team, not once for every bot: a world fact
or place whose name ends in `@1` or `@2` is read by that team's bots
under the bare name. A bot looks for its own first, then its team's,
then the world's:

```lua
botlink_set("place.stair@1", "158.5 255.5 46.8");   -- team 1's bots: `@stair`
botlink_set("place.stair@2", "353.5 255.5 46.8");   -- team 2's: the same name, their own
botlink_set("fact.stair_done@1", 0);                -- `if fact stair_done`
```

### 10. A word a tree says back: `do tell`

```lua
botlink_on("ring_bell", function(pid, words)
	-- words: what followed the name in the tree, strings, three at most
	play_sound_for_all("bell");            -- whatever the script does
end);
botlink_off("ring_bell");
```

In a tree: `do tell ring_bell church`. It succeeds at once, heard or
not. This is how a tree does something the engine has no action for:
open a door, score a point, start the next wave. One function a name;
one that raises is logged and dropped; a word nobody listens for is
counted (`botlink_stats().tells_unheard`) and is not an error. A tree is
ticked twenty times a second: put `tell` where it is reached once, or
under a `cooldown` -- and the engine sends the same word from the same
bot at most once in 0.2 seconds whatever the tree does.

**The three together** -- villagers who run to the church when the
script raises the alarm, and a guard who rings the bell once on getting
there:

```lua
local VILLAGER, GUARD = read_file("villager.bt"), read_file("guard.bt");   -- the two texts below

botlink_set("place.village", "214.5 246.5 30");
botlink_set("place.church", "286.5 268.5 30");
botlink_on("ring_bell", function(pid, words) bell_rings(words[1]); end);
for i = 1, 5 do botlink_add{team = 1, name = "Villager", tree = VILLAGER}; end
botlink_add{team = 1, name = "Guard", tree = GUARD};

function raise_alarm() botlink_set("fact.alarm", 1); end
function end_alarm() botlink_set("fact.alarm", ""); end
```

```bt
tree villager:
pick every=1 noise=0
	option none fact alarm x10                # the alarm: to the church, and stay
		seq
			do go_to @church 5
			do hold @church 60
	option none always                        # the day: about the village
		seq
			do go_to @village 8
			do look_around
			wait 2
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

*Tested: this very scenario is `engine_test.c`'s "a village: an alarm,
a church, a bell" (six bots; 30 s after the alarm the farthest is 1.3
from the church and the bell was rung once; 20 s after it ends they are
back; replayed, the same intents), with "the bridge" beside it for each
rule and limit; the Lua side is `botlink_test.lua` section 10b. On a
server it was seen so: a bot given the guard's tree, two places and a
listener set from the console, then `fact.alarm` -- "BELL: bot 3 rings
the bell at the church", `tells 1 unheard 0`.*

### What a script cannot do

- **Add a condition, a score or an action.** The vocabulary is C
  (`bot/core/vocab.c`). What a script can do instead is 8 to 10: a fact
  stands for a condition or a score the script computes itself, `tell`
  for an action the script carries out. What cannot be had that way is
  an action that *moves* the bot in a new manner -- routes, aim and
  cover are the engine's.
- **Read a bot's mind from Lua.** What a bot perceives and decides is
  in the engine; a script sees what a bot *does* (7), and a person can
  watch it think ([section 15](#15-debugging-watching-a-bot-think)).
- **Make a bot unarmed, slower, invisible.** The server is the authority
  on what a player may do: such rules are the gamemode's own Lua, for a
  bot as for a person.

## 14. Tuning

The loop -- state a situation, split, move a number -- is shown in the
tutorial ([step 4](trees/README.md#4-see-who-does-what-before-running-it),
[step 10](trees/README.md#10-tune-it-then-prove-it)). The reference:

```sh
bttree --split [--why] [--tree NAME] [--n 700] [--mix camper:2,pusher] [--level 5] FILE.bt... [WORD=VALUE]...
```

A crowd of bots is rolled; the tree is ticked once for each by the
engine's own code, in the situation given; what each ended up doing is
counted, in all and by kind of bot.

- a **score** is given 0 to 1; a **condition** 0 or 1; a word not given
  is 0 (`always` is 1);
- `"word arg=value"` sets it for those arguments only (`"enemy_far
  70=0.8"`, `"fact alarm=1"`, `"gun_is rifle=1"`); plain `word=` covers
  every use of it;
- an **action** is `run` by default (it is what the bot is then doing);
  `crouch=ok` for one that ends at once, so the tree goes on past it;
  `=fail` to see the fallback. `tell` ends at once by itself;
- `--n`, `--mix`, `--level` set the crowd. Each rolled bot has its own
  identity, so a `pick roll=once` shows its real shares -- give it a
  larger `--n` (7000) to see them to the percent. A `pick roll=each` is drawn once by each bot of the crowd: the shares come out as the odds of one bot's choice;
- the line **"asked and not given (so 0)"** is every word the tree
  consulted that was left at 0; "given but never asked" is a typo, or a
  branch that was not reached;
- `--why` adds, for every pick a bot came to, the mean of each option's
  score, weight and worth over the crowd and how many chose it
  ([section 6](#a-worked-example) has one).

The percentages are shares of the crowd, not odds for one bot
([section 6](#a-weight-is-not-a-probability)). `--split` knows the tree,
not the world: it cannot tell whether a score is ever above 0 on a real
map. After the numbers: `make -C bot test` (the scenarios pin outcomes),
the bench (`bot/BRAIN-STATUS.md`), and a look at the bots on a server.

## 15. Debugging: watching a bot think

### On a running server

```sh
docker exec -it lsd lsdctl bots list             # every bot: who, what tree, what it is doing
docker exec -it lsd lsdctl bots watch            # one bot's tree, live (Ctrl-C leaves)
docker exec -it lsd lsdctl bots watch Bot992     # that one, by name or by id
docker exec -it lsd lsdctl bots watch 1 --full   # every node, not only the path it is on
docker exec lsd lsdctl bots watch 1 --once       # one frame, and out (--json: the snapshot itself)
```

`bots list`:

```
  id  name             team  kind     level health  tree                 doing
   0  Bot923              1  scout        6    100  tdm                  pick:none > pick:aggression > seek
   1  Bot992              1  pusher       7    100  tdm                  pick:none > pick:aggression > fight
   3  Bot22               2  flanker      4    100  tdm                  pick:none > pick:flank > flank
the world runs: tdm
```

`bots watch 1` (a frame, captured from a server; it redraws four times
a second):

```
Bot992  #1, team 1: a pusher, level 7, health 100, alive
route 11/124 SPRINT; sees 1, engaged, fighting #4
weights: aggression 2.08 caution 0.88 objective 1.51 teamwork 0.48 builder 0.92 marksman 0.62 flank 0.86 stealth 0.41 curiosity 0.44 greed 1.61

tdm (its tree)  pick:none > pick:aggression > fight
 531 ▶ └─ select
 532 ▶    ├─ pick every=1 sticky=0.2 noise=0  [chose 0.2 s ago, again in 0.8 s]
 533      │  ├─ option none grenade_near x100  score 0  (+1)
 535      │  ├─ option none harmful_water x60  score 0  (+1)
 537      │  ├─ option none has_order x30  score 0  (+1)
 539      │  ├─ option none under_fire x10  score 0  (+15)
 555 ▶    │  ├─ option none enemy_visible x5  1.00 x 1.00 x 5 x 1.00 x 1.20 = 6.000  <- held
 556 ▶    │  │  └─ pick every=1.5 sticky=0.3 noise=0.15  [chose 1.3 s ago, again in 0.2 s]
 557      │  │     ├─ option caution pressed x1.8  (+1)
 559 ▶    │  │     ├─ option aggression enemy_visible
 560 ▶    │  │     │  └─ do fight
 561      │  │     ├─ option marksman standoff x1.1  (+1)
 563      │  │     ├─ option caution enemy_far 70 x0.9  (+1)
 565      │  │     ├─ option flank enemy_far 80 x0.6  (+1)
 567      │  │     └─ option greed grenade_worth x0.8  (+1)
 569      │  ├─ option curiosity search x2.5  score 0  (+1)
 571      │  └─ option none always  1.00 x 1.00 x 1 x 1.00 x 1.00 = 1.000  (+28)
 600      └─ limit 1  (+1)

tdm_also (ticked beside, at every decision)
 666   └─ seq  (+76)
  id   an option: score x weight x factor x luck x sticky = worth   (+N): nodes not shown; --full shows all
```

How to read it:

- The header: who it is, its route, what it perceives, its trait
  weights -- the facts a choice is made of.
- `▶` marks the nodes that are RUNNING: the path from the root to the
  action it is in. By default only that path is drawn, with what hangs
  directly from it (a pick's options, a seq's steps); `(+N)` is how many
  nodes are folded under a line.
- The ids are **the engine's own**, of the forest it runs -- with the
  `items` and `extras` it wrote, which is why this tree begins at 531.
- A pick says when it chose and when it will choose again. Each option
  it weighed says `score x weight x factor x luck x sticky = worth`; the
  highest was taken (`<- held`). `score 0`: it could not be chosen. An
  option with no numbers belongs to a pick that has not chosen since the
  watching began (they appear at its next choice).
- `tdm_also` is the tree ticked beside it.

### How it works, and what it costs

Nothing is watched unless somebody asks. The viewer leaves a small
request file in a directory the bot engine looks at four times a second
(`/data/rw/botdebug/`); the engine then turns its tracing on **for the
bots named, and only those** -- their picks note four numbers an option
each time they choose -- and botd writes each one's snapshot there as a
JSON file, atomically, a few times a second, with a roster of all the
bots once a second. When the viewer goes (or dies: a request not
touched for 15 seconds counts for nothing) the tracing is turned off and
the files are removed. A bot nobody watches pays nothing; a watched one
decides exactly as it would have (it is tested: 12 seconds of eight bots
fighting, replayed with all of them watched, give the same intents to
the bit). The formats are in [section 16](#16-for-tool-authors).

### One bot, offline

`bttree --trace` rolls one bot (`--as ARCHETYPE`, `--seed N`,
`--level L`), puts it in the situation you state (as for `--split`),
ticks its tree (`--secs S`: for that long, ten ticks a second; default
one tick), and draws it the same way:

```
$ bttree --trace --as soldier --seed 3 --secs 4 first.bt enemy_near=0.6 hurt=0.6
first: a soldier, level 5, after 40 ticks (4.0 s): RUNNING  pick:caution > retreat
  id   an option: score x weight x factor x luck x sticky = worth
   0 ▶ └─ select
   1      ├─ seq
   2      │  ├─ if health_below 30
   3      │  ├─ unless enemy_visible
   4      │  └─ do retreat
   5 ▶    ├─ pick every=3  [chose 0.9 s ago, again in 2.1 s]
   6      │  ├─ option aggression enemy_near x1.2  0.60 x 0.89 x 1.2 x 1.04 x 1.00 = 0.661
   7      │  │  └─ do fight
   8 ▶    │  ├─ option caution hurt x1.5  0.60 x 1.06 x 1.5 x 0.99 x 1.25 = 1.185  <- held
   9 ▶    │  │  └─ do retreat
  10      │  └─ option curiosity search  score 0: not to be chosen
  11      │     └─ do investigate
  12      └─ do seek
asked and not given (so 0): health_below 30, search
```

Use it for what cannot be staged on a server: a stated situation, a
character of your choosing, `sticky` and timers over a few seconds.

### Trying a tree on the bots that are playing

```sh
docker exec -i lsd lsdctl bots apply - --bot Bot992 < sentry.bt    # that bot, now
docker exec -i lsd lsdctl bots apply - --team 2 < sentry.bt        # a team
docker exec lsd lsdctl bots apply default --archetype camper       # a tree by name, to a kind of bot
docker exec lsd lsdctl bots revert --each                          # every bot back to the world's tree
```

No restart, no map change; a text that does not compile is refused with
all its mistakes and nothing changes for anybody. All of it, with the
JSON each gives: [section 17](#17-the-editors-backend-operations-and-their-json).
The engine's log lines about a bot (a stuck bot, a goal dropped) carry
its path through the tree as `pick:<trait> > <action>`, the same text as
`--split`'s rows and the `doing` column.

## 16. For tool authors

The text is the only form a tree is kept in. A tool reads it through the
engine's own parser and writes it back through the engine's own
serialiser, so what the tool shows and what a bot runs cannot disagree.

Every JSON document has a `"format"` and a `"version"`. A version goes
up when a field changes meaning or goes away; fields may be ADDED
without it, so a reader ignores what it does not know.

| format | version | what | who writes it |
|---|---|---|---|
| `lsd-bt` | 1 | trees as written: an editor's document | `bttree --json`, `lsdctl bots tree --json` |
| `lsd-bt-schema` | 2 | all a tree may be made of | `bttree --schema`, `lsdctl bots schema` |
| `lsd-bt-trees` | 1 | the trees there are | `bttree --list --json`, `lsdctl bots trees --json` |
| `lsd-bt-check` | 1 | every mistake of a text | `lsdctl bots check --json` |
| `lsd-bt-text` | 1 | a canonical text | `lsdctl bots format --json` |
| `lsd-bt-bots` | 1 | the engine's bots, now | the engine; `lsdctl bots list --json` |
| `lsd-bt-snapshot` | 1 | one bot thinking | the engine; `lsdctl bots watch --json` |
| `lsd-bt-apply` | 1 | who runs what after a change | `lsdctl bots apply`, `revert` |
| `lsd-bt-saved` | 1 | a text kept as a file | `lsdctl bots save --json` |
| `lsd-bt-error` | 1 | a command that could not | every `lsdctl bots ... --json` |
| `lsd-bt-trace` | 1 | one rolled bot, offline | `bttree --trace --json` |

### Two shapes: the source and the forest

- **The source** is the text as written: its trees, each node with its
  words, line, column and comments. `tree <name>` is a node like any
  other, and may name a tree the text does not have (`items`, `extras`,
  a tree of another file). An editor edits this.
- **The forest** is what is run: every reference opened where it stands,
  so a tree used twice is there twice. A debugger shows this, with a
  bot's state beside it. Each forest node names the source node it was
  written as; several may name the same one.

**Node ids.** A source node's id is its place among the node lines of
its text, from 0. A forest node's id is its place in the forest, in the
order the text is read with every reference opened; it is also the index
of its slot in a bot's state. Both are the same every time the same text
is compiled with the same vocabulary, in any process -- and that is all
that is promised: edit the text and they move. The ids of a live
snapshot are those of the forest **that engine** runs (its text includes
the `items` and `extras` it wrote): a viewer draws the snapshot's own
nodes and does not try to match them with ids from elsewhere. The
snapshot's `binding` number changes whenever the bot is given a tree, so
a viewer knows its picture of the nodes is stale.

### `lsd-bt`: the source as JSON (`bttree --json FILE...`)

```json
{"format": "lsd-bt", "version": 1,
  "files": [
    {"file": "first.bt", "trees": [
      {"name": "first", "line": 1, "header": true, "root":
        {"id": 0, "kind": "select", "line": 2, "column": 1, "text": "select", "children": [
          {"id": 5, "kind": "pick", "line": 7, "column": 2, "text": "pick every=3",
           "every": 3, "sticky": 0.25, "noise": 0.1, "defaults": ["sticky", "noise"], "children": [
            {"id": 6, "kind": "option", "line": 8, "column": 3, "text": "option aggression enemy_near x1.2",
             "trait": "aggression", "score": "enemy_near", "args": [], "factor": 1.2, "defaults": [],
             "comment": "an enemy close: fight him", "children": [
              {"id": 7, "kind": "do", "line": 9, "column": 4, "text": "do fight", "action": "fight", "args": []}
            ]}
          ]}
        ]}
      }
    ]}
  ]
}
```

(shortened: the real output has every node.)

| field | on | meaning |
|---|---|---|
| `id` | every node | its id in its file's source |
| `kind` | every node | the keyword: `seq`, `select`, `pick`, `option`, `if`, `unless`, `do`, `wait`, `invert`, `always`, `never`, `cooldown`, `limit`, `tree` |
| `line`, `column` | every node | where it is written, from 1 (a tab is one column) |
| `text` | every node | its words as written, one space apart. For reading only |
| `comment` | any node, any tree | the comment on its line, without the `#` |
| `above` | any node, any tree | the lines between the node before and this one: `# ...` comments as written and `""` for an empty line |
| `children` | nodes that have some | in order |
| `roll` | `pick` | `weighed` (the default), `once`, `life` or `each` ([section 6](#a-role-drawn-and-kept-pick-rollonce-pick-rolllife), [each](#a-lottery-at-every-choice-pick-rolleach)) |
| `every`, `sticky`, `noise` | `pick` | the numbers in force (not written for a pick that rolls once or per life; with `each`, `every` is, `sticky` and `noise` are not) |
| `trait`, `score`, `args`, `factor` | `option` | `args` are the score's, as written (strings) |
| `cond`, `args` | `if`, `unless` | |
| `action`, `args` | `do` | |
| `seconds` | `wait`, `cooldown`, `limit` | |
| `ref` | `tree` | the name referred to |
| `defaults` | `pick`, `option` | which of its numbers the text did not write: they are shown with their default value |
| `header` | a tree | `false` for the tree `main` of a text with no `tree <name>:` line |
| `tail` | a file | comments and empty lines after the last node, as `above` |

`--json --tree NAME` gives that tree alone. `--json --expanded` adds
`"forest"`: the trees with their root ids, and every forest node with
its `id`, `parent`, `tree`, and the `file` and `source` id of the node
it was written as (`file` -1: written by the tool in place of the
engine's `items` and `extras`), and `via` for the root of a tree opened
in place -- the `tree <name>` node that brought it there.

### Back to text (`bttree --from-json FILE`)

Takes that JSON (a whole document with `"files"`, or one file object
with `"trees"`; `-` reads the standard input) and writes canonical tree
text. So an editor loads with `--json`, changes the structure, and saves
through `--from-json`: it never writes tree text itself.

- Each node's words are put together from its fields. `text`, `id`,
  `line` and `column` are ignored: they describe what was read.
- A `pick`'s `every`, `sticky`, `noise` and an `option`'s `factor` are
  written (but for a pick with `roll` `once` or `life`, which has none of
  the three, and `roll` `each`, which has `every` only) unless the number is absent, or is listed in `defaults` and
  still equal to the default. So changing the number is enough; an
  editor need not maintain `defaults`.
- `above` lines that do not begin with `#` are made comments. `comment`
  is written after the node.
- The text is then read by the engine's parser. If it is not a tree
  (an unknown word, a wrong argument, a child under a leaf),
  `--from-json` writes nothing, says what is wrong and which node line,
  and exits 1.

`bttree --roundtrip FILE...` checks text → JSON → text for files (it is
part of `make -C bot test` for the shipped trees), `bttree --format
FILE...` writes the canonical text directly, and `--format --tree NAME`
one tree of it.

**Canonical text**: a tab a level; a tree's root at no indent under its
header; words one space apart; a comment on a node's line at column 47
(a tab counted as four; one space after a longer line), as `# text`;
comment lines above a node at the node's indent, as they were written;
empty lines where they were. Reading it and writing it again gives the
same bytes. The shipped trees are written this way (`--roundtrip` says
how many of the files given are canonical already, byte for byte).

### `lsd-bt-schema`: what a tree may be made of (`bttree --schema`)

Everything an editor's palette and property panel need, as JSON (here
shortened to one entry of each list):

```json
{"format": "lsd-bt-schema", "version": 2,
 "limits": {"args": 4, "name": 31, "depth": 32, "words_a_line": 16},
 "answers": ["SUCCESS", "FAILURE", "RUNNING"],
 "kinds": [
   {"name": "pick", "children": "options",
    "params": [
      {"name": "every", "type": "number", "written": "every=<secs>", "required": false, "default": 2, "min": 0, "doc": "..."},
      {"name": "sticky", "type": "number", "written": "sticky=<x>", "required": false, "default": 0.25, "min": 0, "doc": "..."},
      {"name": "noise", "type": "number", "written": "noise=<x>", "required": false, "default": 0.1, "min": 0, "max": 1, "doc": "..."}],
    "answers": "...", "doc": "..."}],
 "conditions": [
   {"name": "at", "usage": "<place> [voxels]",
    "args": [{"name": "place", "required": true, "type": "place"},
             {"name": "voxels", "required": false, "type": "number", "min": 0, "default": 4}],
    "doc": "it is within that of the place (default 4)"}],
 "scores": [],
 "actions": [
   {"name": "follow", "usage": "[mate|caller|order|leader]",
    "args": [{"name": "who", "required": false, "type": "enum", "values": ["mate", "caller", "order", "leader"], "default": "mate"}],
    "doc": "..."},
   {"name": "camp", "usage": "[secs]",
    "args": [{"name": "secs", "required": false, "type": "number", "min": 0,
              "default_note": "its patience: 25 to 120 s by its caution and marksmanship"}],
    "doc": "..."}],
 "traits": [{"name": "aggression", "doc": "take the fight, close the distance"}],
 "trait_range": [0.2, 3],
 "archetypes": [{"name": "camper", "doc": "careful and a marksman: ...",
                 "weights": {"none": 1, "aggression": 0.5, "caution": 1.8},
                 "spread": {"none": 0, "aggression": 0.3, "caution": 0.4}}],
 "places": [{"name": "own_intel", "alias": "our_intel", "doc": "its team's intel, where it is now"}]}
```

- `kinds[].children` is `none`, `one`, `many` or `options` (a pick's:
  only `option` nodes); `option` has `"parent": "pick"`.
- A word's `args[]`, in order: `type` is `number`, `place` (one of
  `places`, by `name` or `alias`), `enum` (one of `values`) or `text`
  (any word); `required`; `repeat` when it may be given several times;
  `min` and `max` for a number; `default` -- a number, or a word -- for
  what leaving it out means, or `default_note` when that is not one
  value.
- **These are the engine's own tables**, the same data the compiler
  checks a tree against: an argument the schema allows compiles, and one
  it does not is refused.
- An archetype's `weights` are the centres its traits are drawn around,
  `spread` the standard deviation of the draw.

(Version 2: a word's arguments come from the engine's table where
version 1 guessed them from the usage text; the type `string` is now
`text`; an enum-or-place is gone, those arguments are places; an
archetype has `doc` and `spread`, and its `weights` are the exact
centres, not a sample's mean.)

### `lsd-bt-trees`: the trees there are (`bttree --list --json FILE...`)

```json
{"format": "lsd-bt-trees", "version": 1, "trees": [
  {"name": "ctf_duty", "file": "trees/ctf.bt", "line": 40, "refers": ["ctf_round", "ctf_camp", "ctf_net"], "nodes": 27,
   "about": "The game. Chosen for a good while; chosen again when an intel is taken, dropped or captured."}
]}
```

`refers`: the trees it names; `nodes`: its own, references not opened;
`about`: the comment right above its header, or on it. `lsdctl bots
trees --json` adds `from` and `replaced` to each and `world`
([section 17](#17-the-editors-backend-operations-and-their-json)).

### Mistakes as data (`bttree --check --json FILE...`)

```json
{"ok": false, "diagnostics": [
  {"file": "mine.bt", "line": 4, "column": 19, "message": "enemy_within: <voxels> is a number, not 'near'"},
  {"file": "mine.bt", "line": 5, "column": 6, "message": "no action called figth"},
  {"file": "mine.bt", "line": 6, "column": 11, "message": "go_to: no place called nowhere"}
]}
```

**Every** mistake of each file (up to 50 a file), in the order of the
text; then, if each file is right alone, those of the files together (a
tree defined twice, a reference to no tree, a circle). `column` is that
of the word at fault, 0 when the mistake is not in one word. A line
whose words are wrong keeps its place in the tree, so its children are
still read; what only follows from a line that had to be dropped (a
child with no parent) is not reported. Exit status 1 when not ok.

### `lsd-bt-bots`: the engine's bots, now

Written by the engine (to `bots.json` in the debug directory, once a
second while anybody asks); `lsdctl bots list --json` and `bttree --bots
--json` pass it through.

```json
{"format": "lsd-bt-bots", "version": 1, "time": 8.333,
  "world": {"tree": "tdm", "night": false},
  "trees": [{"name": "ctf", "from": "files"}, {"name": "tdm", "from": "files"}],
  "bots": [
    {"pid": 1, "name": "Bot992", "team": 1, "alive": true, "archetype": "pusher", "level": 7, "health": 100,
     "tree": "tdm", "tree_from": "files", "tree_set": "world",
     "doing": "pick:none > pick:aggression > fight", "watched": false}
  ]
}
```

| field | meaning |
|---|---|
| `time` | the engine's clock, seconds since it attached |
| `world.tree` | the tree every bot runs that has none of its own |
| `trees[]` | the trees the engine holds, by name; `from`: `files` (built-in and the operator's), `server` (a text the server sent for everybody), `fallback` (the engine's own last resort) |
| `pid` | the bot's id: the server's player id. A bot removed and made again has a new one |
| `name` | what the server calls it |
| `tree` | the tree it runs now |
| `tree_from` | where that tree's text is from: `files`, `server`, `own` (a text given to this bot alone), `fallback`, `none` |
| `tree_set` | `bot`: this bot was given a tree (a text, or a name) for itself; `world`: it runs the world's |
| `doing` | its path through its tree, `pick:<trait> > <action>`; `dead`; `idle` |
| `watched` | its picks are noting what they weigh |

### `lsd-bt-snapshot`: one bot thinking

Written by the engine (to `bot-<pid>.json`, at the rate asked);
`lsdctl bots watch <bot> --json` passes snapshots through, one after
another, and `--once --json` gives one.

```json
{"format": "lsd-bt-snapshot", "version": 1, "time": 31.25,
  "bot": {"pid": 1, "name": "Bot992", "team": 1, "alive": true, "archetype": "pusher", "level": 7, "health": 100,
    "tree": "tdm", "tree_from": "files", "tree_set": "world", "doing": "pick:none > pick:aggression > fight", "watched": true,
    "pos": [231.5, 262.5, 59.75], "sees": 1, "knows": true, "alert": "engaged", "target": 4, "route": "route 11/124 SPRINT",
    "summary": "pusher L7 | pick:none > pick:aggression > fight | route 11/124 SPRINT | sees 1",
    "weights": {"none": 1, "aggression": 2.08, "caution": 0.88},
    "facts": {"alarm": 1}, "places": {"church": [286.5, 268.5, 30]}},
  "binding": 1, "traced": true,
  "trees": [{"role": "main", "name": "tdm", "root": 531, "end": 602, "running": [531, 532, 555, 556, 559, 560]},
            {"role": "also", "name": "tdm_also", "root": 666, "end": 743, "running": []}],
  "nodes": [
    {"id": 532, "parent": 531, "kind": "pick", "text": "pick every=1 sticky=0.2 noise=0", "line": 21, "running": true,
     "child": 555, "elapsed": 0.2, "remaining": 0.8},
    {"id": 555, "parent": 532, "kind": "option", "text": "option none enemy_visible x5", "line": 32, "running": true,
     "comment": "somebody in sight",
     "worth": {"score": 1, "weight": 1, "factor": 5, "luck": 1, "sticky": 1.2, "worth": 6, "held": true}},
    {"id": 560, "parent": 559, "kind": "do", "text": "do fight", "line": 100, "running": true}
  ]
}
```

| field | meaning |
|---|---|
| `bot` | as in `lsd-bt-bots`, and: `pos` (its eye), `sees` (enemies in sight), `knows` (of an enemy at all), `alert` (`calm`, `suspicious`, `engaged`), `target` (the pid it fights, -1), `route` (`route <step>/<steps> <KIND>`, `planning`, `no route`), `summary` (the engine's one line), `weights` (its trait weights, as its picks multiply them), `facts` (what scripts told it: name to number, its own over the world's) and `places` (a script's places: name to `[x, y, z]`, or `null` while there is none) |
| `binding` | goes up each time the bot is given a tree: the nodes below are another tree's when it changes |
| `traced` | its picks are noting what they weigh: `worth` appears on options |
| `trees[]` | the bot's main tree (`role` `main`) and the one ticked beside it (`also`, if it has one): `root` and `end` (the ids of its nodes are `root` to `end` - 1), and `running`: the ids of the RUNNING nodes, root first -- empty when the tree is not RUNNING |
| `nodes[]` | every node of those trees, in id order (a parent before its children) |
| node `id`, `parent` | forest ids; `parent` -1 for a root |
| node `kind`, `text`, `comment` | as in `lsd-bt` |
| node `line` | its line in the text the engine compiled (the files one after another, then what it wrote): good for order, not for opening a file |
| node `running` | it is on a RUNNING path |
| node `child` | a `seq` or `select`: the child it will resume at; a `pick`: the option it holds (for a pick that rolls: its role, RUNNING or not) |
| node `roll` | a pick that rolls: `once`, `life` or `each` |
| node `elapsed`, `remaining` | seconds: a RUNNING `pick` (since it chose; until it chooses again), `wait`, `limit`; `remaining` alone on a `cooldown` that is cooling |
| node `worth` | an `option` its pick has weighed since the watching began: `score`, `weight`, `factor`, `luck`, `sticky` (1, or 1 + the pick's sticky if it was the one held), `worth` (their product), `held` (it is the one the pick holds now). Under a pick that rolls: `share` (its part of the lottery, 0 to 1) and `draw` (the number drawn, the same for every option; for `each`, the last one); `luck` and `sticky` are 1 |

A snapshot of a bot of the tdm tree is about 13 KiB.

### The debug directory: asking and being answered

For a tool that talks to the engine directly rather than through
`lsdctl`. The directory is `$LSD_DATA/rw/botdebug` (`/data/rw/botdebug`
in the container; botd's `--debug-dir`), made by botd, mode 0700, owned
by the user the server runs as.

**Ask** by writing a file there, any name ending `.req` (write it
beside and rename it over):

```
watch=1,4
hz=4
```

- `watch=`: the pids to watch, with commas; or `all`; or nothing (only
  the roster is wanted).
- `hz=`: snapshots a second for each watched bot, 1 to 20 (default 4).
- **Keep it alive**: a request whose file was last written more than 15
  seconds ago counts for nothing. Write it again every few seconds, and
  remove it when done.
- Several requests may be there at once (one a viewer): the bots watched
  are those any of them names, at the highest rate asked.
- At most 1024 bytes; a regular file (a link is not read). Nothing else
  is understood: unknown lines are ignored.

**Be answered** in the same directory, while any request is alive:

- `bots.json` -- the roster, once a second (and at once when the first
  request appears);
- `bot-<pid>.json` -- each watched bot's snapshot, at the rate asked;
  none for a pid there is no bot of, and it is removed when the bot
  goes or is no longer asked for.

Each is written whole beside and renamed over: a reader never sees half
a file. When the last request dies, the files are removed. botd looks
for requests four times a second, so the first answer comes within a
quarter of a second or so.

### `lsd-bt-trace`: one rolled bot, offline (`bttree --trace --json`)

```json
{"format": "lsd-bt-trace", "version": 1, "tree": "first", "root": 0, "ticks": 1, "answer": "RUNNING",
  "bot": {"archetype": "soldier", "level": 5, "weights": {"none": 1, "aggression": 1.14, "caution": 0.92}},
  "running": [0, 5, 6, 7],
  "nodes": [
    {"id": 5, "parent": 0, "file": 0, "source": 5, "kind": "pick", "text": "pick every=3",
     "running": true, "child": 6, "elapsed": 0, "remaining": 3},
    {"id": 6, "parent": 5, "file": 0, "source": 6, "kind": "option", "text": "option aggression enemy_near x1.2",
     "running": true,
     "worth": {"score": 0.6, "weight": 1.14, "factor": 1.2, "luck": 1.06, "sticky": 1, "worth": 0.873, "held": true}}
  ]}
```

Ids here are forest ids of the files given; `file` and `source` lead
back to the node of `--json`. `bttree --view FILE` draws a snapshot kept
in a file.

### The C API

For a tool that links the core rather than calling `bttree`.

`bot/core/bt.h` (the tree runtime; knows nothing of the engine):

| call | gives |
|---|---|
| `bt_parse(vocab, text, &diag)` | the source of a text: checked exactly as the compiler checks it, references not looked up |
| `bt_diagnose(vocab, text, link, out[], max)` | every mistake of a text, up to `max`; the first is the one `bt_compile` says |
| `bt_source_trees`, `bt_source_tree`, `bt_source_nodes`, `bt_source_node`, `bt_source_tail` | walk it: a tree's name, root, line, comments; a node as a `bt_node` |
| `bt_source_text(src, out, size)` | the canonical text |
| `bt_compile_diag(vocab, text, &diag)` | `bt_compile`, with the mistake as line, column, message |
| `bt_forest_source`, `bt_forest_trees`, `bt_forest_tree`, `bt_forest_node` | walk what is run; each node's `source` and `via` |
| `bt_state_running`, `bt_state_node` | which nodes are RUNNING; what one remembers |
| `bt_state_trace`, `bt_state_worths` | have one bot's picks note what they weighed; read it |
| `bt_vocab_args(vocab, kind, name, specs, n)`, `bt_vocab_set(vocab, name, "a\|b\|c")` | what a word takes, said by the host: the compiler then checks every use |
| `bt_kind_name` | the keyword of a kind |

A `bt_node` has: `id`, `kind`, `tree`, `parent`, `first_child`,
`next_sibling`, `n_children`, `source`, `via`, `line`, `column`, `text`,
`name`, `trait`, `args`, `secs`, `every`, `sticky`, `noise`, `factor`,
`written` (which of the four numbers the text gave), `comment`, `above`.
A `bt_arg_spec` has: `name`, `type` (number, one of, text), `required`,
`repeat`, `has_default` and `def`, `has_min`/`min`, `has_max`/`max`,
`values`, `set` (a named list), `def_text`, `def_note`.

`bot/core/vocab.h`, `persona.h` (the engine's words, as data):
`bc_vocab_count`, `bc_vocab_word(i, &word)` (kind, name, doc, its
argument specs), `bc_vocab_usage`, `bc_place_count`, `bc_place_at`,
`bc_trait_name`, `bc_trait_doc`, `bc_archetype_name`,
`bc_archetype_doc`, `bc_archetype_trait` (centre and spread),
`bc_trait_range`.

`bot/core/engine.h` (a running engine): `bc_engine_watch(e, pid, on)`,
`bc_engine_watched`, `bc_engine_snapshot(e, pid, out, size)`,
`bc_engine_roster(e, out, size)` -- the two JSON documents above,
written into the caller's buffer; the core does no I/O.

## 17. The editor's backend: operations and their JSON

An editor of trees needs a small set of operations: see what a tree may
be made of, see the trees there are, check and format what is being
written, see the bots and what one is thinking, give a tree to one bot,
to many or to all while they play, take it back, and keep a text.
**Each is an `lsdctl bots` command that takes and gives JSON**, and this
section is their contract: the formats are versioned, and a front end is
built on nothing else. The first one is a desktop application that runs
these commands over `docker exec`.

Common to all:

- `--json`: the answer is one JSON document on the standard output, and
  the exit status is 0. When the command cannot do what was asked the
  document is an **`lsd-bt-error`** and the status is 1:

  ```json
  {"format": "lsd-bt-error", "version": 1, "ok": false, "error": "the tree does not compile: nothing was changed",
   "diagnostics": [{"line": 3, "column": 5, "message": "no action called figth"},
                   {"line": 4, "column": 11, "message": "go_to: no place called nowhere"}]}
  ```

  `error`: one line for a person. `diagnostics`: there when the reason
  is a text that does not compile -- all its mistakes.
- Without `--json`: text for a person; errors on the standard error.
- A tree **text** is given as a file (`--file F`, or a path where the
  command takes one) or on the standard input (`-`). It may be tree text
  or an `lsd-bt` JSON document (it is told by its first character, `{`):
  an editor sends what it holds.
- Run in the container, as `docker exec [-i] <server> lsdctl bots ...`.

### The operations

**schema** -- `lsdctl bots schema` → `lsd-bt-schema`
([section 15](#lsd-bt-schema-what-a-tree-may-be-made-of-bttree---schema)),
from the engine of the image that is running.

**trees** -- `lsdctl bots trees --json` → the trees of the built-in
files and of the operator's (`/data/trees/`):

```json
{"format": "lsd-bt-trees", "version": 1, "world": "tdm", "trees": [
  {"name": "tdm", "from": "builtin", "file": "/opt/botd/trees/tdm.bt", "line": 18, "nodes": 20,
   "refers": ["tdm_under_fire", "tdm_contact", "tdm_search"], "replaced": true},
  {"name": "tdm", "from": "user", "file": "/data/trees/mine.bt", "line": 2, "nodes": 9, "refers": []},
  {"name": "sentry", "from": "user", "file": "/data/trees/sentry.bt", "line": 2, "nodes": 7, "refers": []}
]}
```

`from`: `builtin` or `user`. `replaced`: an operator's tree of the same
name stands in its place. `world`: the tree the world runs now -- there
only while the server runs with bots.

**tree** -- `lsdctl bots tree <name>` → that tree's canonical text;
`--json` → it as an `lsd-bt` document (one file, one tree). The
operator's, if he has one of that name.

**check** -- `lsdctl bots check [<file> | -] --json`:

```json
{"format": "lsd-bt-check", "version": 1, "ok": false, "trees": [],
 "diagnostics": [{"line": 4, "column": 19, "message": "enemy_within: <voxels> is a number, not 'near'"}]}
```

`ok`, the names of the `trees` in the text (when it compiles), every
mistake. Status 1 when not ok (the document is still an `lsd-bt-check`).
The text is checked as the engine will compile it when it is applied:
alone, with `items` and `extras`.

**format** -- `lsdctl bots format [<file> | -]` → the canonical text;
`--json` → `{"format": "lsd-bt-text", "version": 1, "ok": true, "text":
"..."}`. This is also how a JSON tree becomes text. A text that does not
compile is not formatted: an error with its diagnostics.

**bots** -- `lsdctl bots list --json` → `lsd-bt-bots`
([section 15](#lsd-bt-bots-the-engines-bots-now)).

**watch** -- `lsdctl bots watch [<name or id>] --once --json` → one
`lsd-bt-snapshot`; without `--once`, a stream of them, one after
another, at `--hz` (1 to 20, default 4) until the caller goes. With no
bot named: the first that is alive.

**apply** -- give a tree to bots, live:

```
lsdctl bots apply <tree name>   <whom> [--json]      a tree the engine has, by name
lsdctl bots apply --file <f>    <whom> [--json]      a text
lsdctl bots apply -             <whom> [--json]      a text, on the standard input
```

`<whom>`, one or more of:

| | |
|---|---|
| `--bot <id or name>[,...]` | those bots |
| `--team <1\|2>` | every bot of a team |
| `--archetype <kind>` | every bot of a kind (`camper`, `pusher`...) |
| `--each` | every engine bot, one by one |
| `--all` | **the world's tree**: what every bot runs that has none of its own. A bot that was given one keeps it |

```json
{"format": "lsd-bt-apply", "version": 1, "ok": true, "action": "apply", "scope": "bots", "tree": "sentry", "world": "tdm",
 "bots": [{"pid": 1, "name": "Bot992", "team": 1, "tree": "sentry", "tree_from": "own", "tree_set": "bot", "ok": true}]}
```

- **Refused whole, before anybody is touched**, with an `lsd-bt-error`:
  a text that does not compile (its diagnostics), one over 60000 bytes,
  a name there is no tree of, a bot there is none of, nobody named.
- Otherwise the tree is given, and about a second later the engine is
  asked what each of those bots runs: that is `bots[]` -- `tree`,
  `tree_from`, `tree_set` as in `lsd-bt-bots`, and `ok` for each (`ok`
  at the top: all of them). `scope`: `bots` or `world`. `tree`: the
  name applied (for a text: its first tree, which is the one run).
  `world`: the world's tree now. If the engine did not take it (it says
  why in its log) `ok` is false, `error` says so, and the status is 1.
- A text given to bots is **each bot's own**: compiled for it, kept
  until it is given another or reverted. It must stand alone (it may
  refer to `items` and `extras`, not to the built-in files' trees). A
  **name** is a tree the engine holds: `lsd-bt-bots` lists them
  (`trees`). One that is only a file yet -- just saved, the engine reads
  the folder at the next map load -- is refused, with the way out in the
  message: apply its text, or change the map.

**revert** -- `lsdctl bots revert <whom> [--json]` → an `lsd-bt-apply`
with `"action": "revert"`: those bots back to the world's tree; with
`--all`, the world back to the operator's `engine_bots_tree` if he set
one, else the gamemode's.

**save** -- `lsdctl bots save <name> [--file <f> | -] [--json]`: keep a
text as the operator's tree file `/data/trees/<name>.bt`, written
canonical, whole and at once (beside, and renamed over).

```json
{"format": "lsd-bt-saved", "version": 1, "ok": true, "file": "/data/trees/sentry.bt", "trees": ["sentry"],
 "note": "read by the bot engine at the next map load; ..."}
```

`<name>` is letters, digits, `_` and `-`, 31 at most: anything else is
refused (it becomes a file name; no path is ever taken). A text that
does not compile is not saved. The engine reads the file at the next
map load; until then the text can be run with `apply`.

### What lasts, and what does not

- A tree given to a bot, and the world's tree, are settings the server
  keeps (lib_botlink): they are sent again if the bot engine restarts or
  re-attaches. They are **not** written to the settings file: a server
  restart forgets them. What is to last is `save`d, and named in the
  setting `engine_bots_tree` (or sent by the gamemode).
- A tree is given to a bot **id**. A bot that is removed and made again
  (the count lowered and raised, a `once` bot that died) is a new bot
  with a new id and the world's tree.
- A map change keeps both.

### What a front end can rely on

- **Atomic.** A change is refused whole, before anybody is touched, or
  made; the answer says which bots run what, read back from the engine.
- **Checked on this side.** A text is compiled by the command (the
  engine's own compiler) before it is given to anybody, whatever the
  caller checked; it is at most 60000 bytes, and the engine never runs a
  part of one.
- **Names are validated, paths never taken.** `save` accepts a name of
  letters, digits, `_` and `-` and makes the path itself; `apply` hands
  the server a file NAME inside the debug directory, which the server
  checks again before reading. Bot ids are numbers by the time they
  reach the server's console; tree names are checked against the names
  there are.
- **It is an administrator's tool.** A tree is not code -- it can only
  name the engine's words -- but it acts: `do use <item>` runs a
  command as the bot, `do tell` calls a script. `lsdctl` runs as the
  server's own user inside the container; whoever may `docker exec` may
  do all of this, and nobody else can. The debug directory is that
  user's alone (0700).
- **A snapshot shows what a bot perceives** (positions, targets): it is
  for whoever administers the server, not for players.
- **Nothing is left running.** A watch that is not kept alive ends in 15
  seconds; with nobody watching the engine does no extra work.

## 18. Review: what an editor and a debugger need

What a visual tree editor and a live debugger need from the engine, and
where each stands.

| need | state |
|---|---|
| The tree as a structure, from the engine's own parser | **there**: `bt_parse` / `bt_source_*`, `lsd-bt` |
| Comments kept through load and save | **there**: on a node's line and above it, on tree headers, at the end of a file |
| Which numbers were written and which are defaults | **there**: `written` / `"defaults"` |
| Structure back to text, one canonical form | **there**: `bt_source_text`, `--from-json`, `--format`; round trip tested on every shipped tree |
| Mistakes as data, with a position -- all of them | **there**: `bt_diagnose`, `--check --json`, `lsd-bt-check` |
| A palette: every keyword and word, with parameters, types, defaults, docs | **there**: `lsd-bt-schema`, from the engine's own tables; the compiler checks a tree against the same data |
| Per-bot state: what is RUNNING, timers, the option held, why a pick chose | **there**: `bt_state_*`, and live: `lsd-bt-snapshot` |
| A live view of a running server | **there**: `lsdctl bots watch`, the debug directory; opt-in per bot, nothing when nobody watches |
| Giving a tree to one bot, to many, to all, live; taking it back | **there**: `lsdctl bots apply`, `revert` |
| Keeping what was tried | **there**: `lsdctl bots save` |
| Every operation as JSON in, JSON out, errors too | **there**: section 17 |
| Stable node identity | **there**, for one compiled text. **Not** across edits |
| Behaviour a script adds without C | **there**: facts, places, `tell` (section 13) |

**Still missing for a GUI editor**, plainly:

1. **The editor itself**: a desktop application, built apart from the
   engine on the operations of section 17.
2. **An id that follows a node through edits.** Ids are positions. An
   editor keeps its own ids in memory and maps by position after each
   load; a debugger re-reads the nodes when `binding` changes.
3. **Layout.** Where the user put each node belongs in a file of the
   editor's own; the text has no place for it.
4. **History of a decision.** A snapshot says what a pick weighed last,
   not before; a viewer that wants a timeline keeps the snapshots.
5. **"What would it choose now?"** outside a tick is not offered: it
   would call the scores (the engine's business) and draw from the bot's
   dice, which would change what it does next. Offline, `bttree --trace`
   and `--split` answer it for a stated situation.
6. **Mapping a live node to a file line.** A snapshot's `line` is a line
   of the text the engine put together (files one after another, then
   `items` and `extras`); it does not say which file. A viewer shows the
   node's own text; an editor that wants "open this node in its file"
   needs the engine to carry each tree's origin, which it does not.
7. **Surviving a server restart** for a tree applied live: by design it
   does not (save it, and name it in a setting).
8. **A snapshot for a human player** (what would a bot do in my place):
   nothing computes it.

## 19. Limits

| | |
|---|---|
| words on a line | 16 |
| arguments of a leaf (after its name) | 4 |
| a name (tree, word) | 31 characters |
| depth of a tree, references opened | 32 levels |
| nodes in a forest, references opened | 262 144 |
| words in a vocabulary | 512 |
| `noise` | 0 to 1 |
| `every`, `sticky`, a factor, seconds | 0 or more |
| a trait weight | 0.2 to 3 |
| a tree text sent to the engine (`botlink_set`, `lsdctl bots apply`) | 60 000 bytes (64 KiB in the engine); in pieces of 900 over the link |
| mistakes reported for one file | 50 |
| a debug request file | 1024 bytes; alive 15 s after it was last written |
| snapshots a second for a watched bot | 1 to 20 (default 4) |
| a saved tree's name | letters, digits, `_`, `-`; 31 characters |
| a fact's or a script place's name | letters, digits, `_`; 23 characters |
| facts | 64 for the world, 8 a bot |
| script places | 32 for the world, 4 a bot |
| `do tell` | the name and 3 words; the same name from one bot once in 0.2 s |
