# Behaviour trees

What a bot does is decided by a tree: a short text that says what can be
done and what bears on it. This page is the reference for writing one --
every keyword, what it answers, its defaults -- for giving bots a tree
and weights of your own, and for whoever writes a tool (an editor, a
debugger) on top.

- The words a tree may use (conditions, scores, actions, traits, places):
  [VOCAB.md](VOCAB.md), generated from the engine.
- The tool used all through this page: `bttree`. Build it with
  `make -C bot tools` (it is then `bot/build/bin/bttree`); in the image it
  is on the path: `docker exec <server> bttree /opt/botd/trees/tdm.bt`.
- The trees that ship: [`trees/`](trees). Read `default.bt` first, then
  `tdm.bt`.

Every tree shown in a block on this page is compiled by `make -C bot test`
(`bttree --doc TREES.md`), with the engine's own compiler and words.

Contents: [what a tree is](#1-what-a-tree-is-and-why) ·
[a first tree](#2-a-first-tree) · [the text](#3-the-text) ·
[the three answers](#4-the-three-answers) ·
[every node](#5-every-node) · [pick, in full](#6-pick-in-full) ·
[when actions are stopped](#7-when-an-action-is-stopped) ·
[time](#8-time) · [several trees](#9-several-trees-in-a-text) ·
[compiled and used](#10-how-trees-are-compiled-and-used) ·
[characters](#11-characters-traits-archetypes-weights) ·
[writing your own](#12-writing-your-own) · [tuning](#13-tuning) ·
[debugging](#14-debugging-watching-a-bot-think) ·
[for tool authors](#15-for-tool-authors) ·
[review](#16-review-what-an-editor-and-a-debugger-need) ·
[limits](#17-limits)

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

Read from the top:

- `select` tries its children in order and stops at the first that does
  not fail. It is a priority list.
- Its first child is a `seq`: all of its children, in order, as long as
  each succeeds. Under 30 health, with no enemy in sight: retreat.
  Otherwise the `seq` fails at the `if` or the `unless`, and the `select`
  goes on to its next child.
- The `pick` weighs three options. With an enemy 24 voxels away
  (`enemy_near` is then 0.6) and 40 health (`hurt` is 0.6), a bold bot
  fights and a careful one retreats: [section 6](#6-pick-in-full) does
  the sum. It chooses again every 3 seconds. With no enemy, no wound and
  nothing to search, all three scores are 0 and the `pick` fails.
- Then the `select` reaches its last child: `do seek`.

Save it as `first.bt` and look at it:

```sh
bttree first.bt                  # drawn, sub-trees opened in place
bttree --check first.bt          # only: is it right? ("ok: 1 file(s)", or the line and what is wrong)
bttree --as pusher first.bt      # beside each option, what a pusher's weight for its trait is
```

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
| [`pick`](#pick-and-option) | 1 or more, all `option` | `pick [every=<secs>] [sticky=<x>] [noise=<x>]` |
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
([section 13](#13-tuning)):

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

Three things lean the whole crowd, all settings the server sends
([section 12](#12-writing-your-own)):

- `archetypes=camper:2,pusher:1` -- the mix characters are drawn from;
- `traits=aggression:2,caution:0.5` -- every bot's weight for those
  traits multiplied, on top of its own roll, still within 0.2 to 3. The
  bots keep their differences; the lot leans. It can be set for one bot
  too, and the two multiply;
- the tree's own factors, which weigh an option for everybody.

**Level** (1 to 10) is apart from character: how good the bot is --
reaction, aim, turn rate -- not what it prefers. A tree never reads it.

## 12. Writing your own

Whoever you are, the loop is the same: write the text, `bttree --check`
it, look at it (`bttree FILE`), try the situations that matter with
`--split` ([section 13](#13-tuning)), then give it to the bots.

### As an operator: a file, and three settings

Put a file `<name>.bt` in the **`trees/` directory of the data volume**
(`/data/trees/` in the container). It is read with the built-in trees
when the server starts and **again at each map load**: edit the file,
change the map, and the bots have the new tree -- no restart.

- User trees are loaded after the built-in ones. **A tree with the name
  of a built-in one replaces it** (your own `tdm`); any other name is
  added, to be chosen by name.
- A file that does not compile is said in botd's log -- `tree error:
  /data/trees/mine.bt: line 12: no action called figth` -- and skipped;
  the built-in trees stay.

Then say how the engine's bots play, with the three settings of the
`engine_bots` script (`catalog/bots/engine_bots`), each empty by default
and applied live, within a second:

| setting | example | what it does |
|---|---|---|
| `engine_bots_tree` | `mine` | the tree the bots run, by name: a built-in one or yours. Empty: the gamemode's |
| `engine_bots_archetypes` | `camper:2,pusher:1` | the mix of characters. Empty: every kind, equally |
| `engine_bots_traits` | `aggression:2,caution:0.5` | every bot's trait weights multiplied. Empty: as rolled |

```sh
docker cp mine.bt lsd:/data/trees/mine.bt
docker exec lsd bttree --check /data/trees/mine.bt      # add the built-in files it refers to, if any
docker exec lsd lsdctl set engine_bots_tree "'mine'"
docker exec lsd lsdctl set engine_bots_traits "'aggression:1.5,teamwork:0.7'"
```

A tree of your own for a mode that already has one is easiest begun as a
copy: `docker exec lsd cat /opt/botd/trees/tdm.bt > mine.bt`, rename its
trees (`tdm` to `mine`, `tdm_also` to `mine_also`, and so on down the
file), and change it. A small one from nothing:

```bt
# mine.bt -- hold the base, and go out only for a sure thing
tree mine:
select
	pick every=1 sticky=0.3 noise=0.1
		option none grenade_near x100         # a grenade at its feet: run
			do evade
		option none has_order x30             # the server said so
			do obey
		option caution under_fire x2          # shot at: to cover, and fight from it
			do take_cover
		option aggression enemy_near 40 x1.5  # one close enough to be sure of
			do fight
		option marksman enemy_visible         # one far off: from where it stands
			do camp 6
		option curiosity search x0.4          # a noise: the curious go and look
			do investigate
		option none always x0.5               # the post
			do guard own_base 20
	limit 1
		do look_around

tree mine_also:
seq
	always
		tree extras
	always
		tree items
```

### As a gamemode author: send the text

A gamemode's Lua gives every engine bot its tree with one call. The
value is a tree's name, or -- when it has more than one line -- the text
of trees, of which **the first is the one run**:

```lua
local TREE = [[
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
]];

function mod.on_load()
	botlink_set("tree", TREE);            -- for every bot
	botlink_set("archetypes", "pusher:3,flanker:1");
	botlink_set("traits", "aggression:1.3");
end
```

The text is compiled beside the built-in trees, so it may refer to them
(`tree tdm_search`) and to `items` and `extras`. If it does not compile,
the engine says so with the line and the bots keep the tree they had.
With no call at all, lib_botlink names the tree after the gamemode
(`tdm`, `ctf`...), and a mode with no tree of that name gets `default`.
A mode's tree reads the mode's own rules with `if setting <key> [value]`:
anything sent with `botlink_set(key, value)` that the engine does not
know is kept for that.

The same tree, as it must compile:

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

**A fragment for an item.** Whoever defines an inventory item says when
a bot should use it: `inventory_define(key, {..., bot = ...})`. A list
of lines is a `seq`; a string is a whole fragment. The engine puts `if
has_item <key>` in front and adds it to `tree items`.

```lua
inventory_define("medkit", {label = {en = "Medkit"}, command = "reward medkit",
	bot = {"if health_below 50", "do use medkit self"}});
```

```bt
seq
	if health_below 50
	do use medkit self
```

**A fragment for a script** that changes how every bot behaves without
being an item (the night script and its lamps): `botlink_set("extra.<name>.tree",
text)`; an empty text withdraws it. It becomes part of `tree extras`.
Keep it to actions that end at once.

```bt
pick noise=0
	option none night_vision x10    # it sees in the dark: stay dark
		do lamp off
	option stealth night            # the stealthy stay dark and listen
		do lamp off
	option none night x1.2          # anybody else, at night: light up
		do lamp on
```

A fragment that does not compile is said in the log, with the line in
ITS text, and left out; the rest stand.

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

## 13. Tuning

`bttree --split` answers "in this situation, who does what?". You state
the situation as the worth of the words the tree asks about; a crowd of
bots is rolled; the tree is ticked once for each by the engine's own
code; what each ended up doing is counted, in all and by kind of bot.

```sh
bttree --split --tree tdm_search bot/trees/tdm.bt rumour=0.6 flank_open=1 "vantage rifle=1"
```

- a **score** is given 0 to 1; a **condition** 0 or 1; a word not given
  is 0 (`always` is 1);
- `"word arg=value"` sets it for those arguments only; plain `word=`
  covers every use of it;
- an **action** is `run` by default (it is what the bot is then doing);
  `crouch=ok` for one that ends at once, so the tree goes on past it;
  `=fail` to see the fallback;
- `--n 700`, `--mix camper:2,pusher`, `--level 5` set the crowd;
- read the line **"asked and not given (so 0)"** every time: it is every
  word the tree consulted that you left at 0.

`--split --why` adds, for every pick a bot came to, the mean of each
option's numbers over the crowd and how many chose it: the table in
[section 6](#a-worked-example). It is where to look when a row is not
what you expected: which option is too strong, and whether it is its
score, its factor or the weights.

Then change a factor, a `sticky=`, a `noise=`, an option's trait, and
run it again. Try several situations for each change (nothing known, an
enemy far, shot at, hurt, the objective taken): a factor that fixes one
usually moves another.

`--split` knows the tree, not the world: it cannot tell whether a score
is ever above 0 on a real map. After the numbers, `make -C bot test`
(the scenarios pin outcomes) and a look at the bots on a server.

## 14. Debugging: watching a bot think

**One bot, offline.** `bttree --trace` rolls one bot (`--as ARCHETYPE`,
`--seed N`, `--level L`), puts it in the situation you state (as for
`--split`), ticks its tree (`--secs S`: for that long, ten ticks a
second; default one tick), and draws the tree *as the engine holds it*
-- references opened, every node with its id -- with the nodes that are
RUNNING marked, each timer, and for every option the numbers its pick
multiplied:

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

`--trace --json` is the same as data ([section 15](#15-for-tool-authors)).

**On a running server.** The engine's log lines about a bot (a stuck
bot, a goal dropped) carry its path through the tree as
`pick:<trait> > <action>` -- the same text as `--split`'s rows. A tree
can be tried on a running server without a rebuild:
`botlink_set("tree", <text>)` from the admin console, or a file in
`/data/trees/` and a map change.

**In code.** Everything `--trace` shows comes from four calls of
`bot/core/bt.h` that read a bot's state between two ticks and change
nothing: `bt_state_running` (the path of RUNNING nodes),
`bt_state_node` (what one node remembers: the child held, the time
left), `bt_state_trace` (ask the picks of ONE bot to note what they
weighed) and `bt_state_worths` (read it). Tracing is off unless asked
for, bot by bot; a bot that is not watched pays one test for each option
weighed and nothing else.

## 15. For tool authors

The text is the only form a tree is kept in. A tool reads it through the
engine's own parser and writes it back through the engine's own
serialiser, so what the tool shows and what a bot runs cannot disagree.

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
that is promised: edit the text and they move. A debugger attached to a
live engine must be given the forest by that engine (its text includes
the `items` and `extras` it wrote); ids from another compilation of
other text are other ids.

### `bttree --json FILE...`: the source as JSON

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
| `every`, `sticky`, `noise` | `pick` | the numbers in force |
| `trait`, `score`, `args`, `factor` | `option` | `args` are the score's, as written (strings) |
| `cond`, `args` | `if`, `unless` | |
| `action`, `args` | `do` | |
| `seconds` | `wait`, `cooldown`, `limit` | |
| `ref` | `tree` | the name referred to |
| `defaults` | `pick`, `option` | which of its numbers the text did not write: they are shown with their default value |
| `header` | a tree | `false` for the tree `main` of a text with no `tree <name>:` line |
| `tail` | a file | comments and empty lines after the last node, as `above` |

`--json --expanded` adds `"forest"`: the trees with their root ids, and
every forest node with its `id`, `parent`, `tree`, and the `file` and
`source` id of the node it was written as (`file` -1: written by the
tool in place of the engine's `items` and `extras`), and `via` for the
root of a tree opened in place -- the `tree <name>` node that brought it
there.

### `bttree --from-json FILE`: back to text

Takes that JSON (a whole document with `"files"`, or one file object
with `"trees"`; `-` reads the standard input) and writes canonical tree
text. So an editor loads with `--json`, changes the structure, and saves
through `--from-json`: it never writes tree text itself.

- Each node's words are put together from its fields. `text`, `id`,
  `line` and `column` are ignored: they describe what was read.
- A `pick`'s `every`, `sticky`, `noise` and an `option`'s `factor` are
  written unless the number is absent, or is listed in `defaults` and
  still equal to the default. So changing the number is enough; an
  editor need not maintain `defaults`.
- `above` lines that do not begin with `#` are made comments. `comment`
  is written after the node.
- The text is then read by the engine's parser. If it is not a tree
  (an unknown word, a child under a leaf), `--from-json` writes nothing,
  says what is wrong and which node line, and exits 1.

`bttree --roundtrip FILE...` checks text → JSON → text for files (it is
part of `make -C bot test` for the shipped trees), and `bttree --format
FILE...` writes the canonical text directly.

**Canonical text**: a tab a level; a tree's root at no indent under its
header; words one space apart; a comment on a node's line at column 47
(a tab counted as four; one space after a longer line), as `# text`;
comment lines above a node at the node's indent, as they were written;
empty lines where they were. Reading it and writing it again gives the
same bytes. The shipped trees are written this way (`--roundtrip` says
how many of the files given are canonical already, byte for byte).

### `bttree --schema`: what a tree may be made of

Everything an editor's palette and property panel need, as JSON (here
shortened to one entry of each list):

```json
{"format": "lsd-bt-schema", "version": 1,
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
             {"name": "voxels", "required": false, "type": "number", "default": 4}],
    "doc": "it is within that of the place (default 4)"}],
 "scores": [], "actions": [],
 "traits": [{"name": "aggression", "doc": "take the fight, close the distance"}],
 "trait_range": [0.2, 3],
 "archetypes": [{"name": "camper", "weights": {"none": 1.00, "aggression": 0.51, "caution": 1.79}}],
 "places": [{"name": "own_base", "doc": "its team's base"}]}
```

- `kinds[].children` is `none`, `one`, `many` or `options` (a pick's:
  only `option` nodes); `option` has `"parent": "pick"`.
- A word's `args[]`: `type` is `number`, `place` (one of `places`),
  `string`, or `enum` with `values` (and `"or": "place"` when a place
  may be given instead); `repeat` when it may be given several times;
  `min`, `max` and `default` where known.
- **A word's arguments are derived, today, from the usage text** the
  engine carries for it (`<x>` required, `[x]` optional, `a|b|c` one of,
  `...` repeated), a number's type from its name, and its default from
  the sentence ("(default 4)") where there is exactly one for each
  optional number. Where that cannot be done the field is absent. The
  compiler does not check a leaf's arguments at all: a wrong argument is
  read by the action as it sees fit (usually as its default).

### `bttree --check --json FILE...`: mistakes as data

```json
{"ok": false, "diagnostics": [
  {"file": "mine.bt", "line": 12, "column": 5, "message": "no action called figth"}
]}
```

One diagnostic at most per file (the compiler stops at the first
mistake), then one for the files together (a tree defined twice, a
reference to no tree, a circle). `column` is that of the word at fault,
0 when the mistake is not in one word. Exit status 1 when not ok.

### `bttree --trace --json`: a bot's state as data

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

Ids here are forest ids; `file` and `source` lead back to the node of
`--json`.

### The C API (`bot/core/bt.h`)

For a tool that links the core rather than calling `bttree`:

| call | gives |
|---|---|
| `bt_parse(vocab, text, &diag)` | the source of a text: checked exactly as the compiler checks it, references not looked up |
| `bt_source_trees`, `bt_source_tree`, `bt_source_nodes`, `bt_source_node`, `bt_source_tail` | walk it: a tree's name, root, line, comments; a node as a `bt_node` |
| `bt_source_text(src, out, size)` | the canonical text |
| `bt_compile_diag(vocab, text, &diag)` | `bt_compile`, with the mistake as line, column, message |
| `bt_forest_source`, `bt_forest_trees`, `bt_forest_tree`, `bt_forest_node` | walk what is run; each node's `source` and `via` |
| `bt_state_running`, `bt_state_node` | which nodes are RUNNING; what one remembers |
| `bt_state_trace`, `bt_state_worths` | have one bot's picks note what they weighed; read it |
| `bt_kind_name` | the keyword of a kind |

A `bt_node` has: `id`, `kind`, `tree`, `parent`, `first_child`,
`next_sibling`, `n_children`, `source`, `via`, `line`, `column`, `text`,
`name`, `trait`, `args`, `secs`, `every`, `sticky`, `noise`, `factor`,
`written` (which of the four numbers the text gave), `comment`, `above`.

## 16. Review: what an editor and a debugger need

What a visual tree editor and a live debugger need from the engine, and
where each stands.

| need | state |
|---|---|
| The tree as a structure, from the engine's own parser | **there**: `bt_parse` / `bt_source_*`, `bttree --json`. Before, the compiler kept only what a tick needs, and the tool read the text a second time with its own approximate grammar |
| Comments kept through load and save | **there**: on a node's line and above it, on tree headers, at the end of a file; the compiler used to drop them |
| Which numbers were written and which are defaults | **there**: `written` / `"defaults"` |
| Structure back to text, one canonical form | **there**: `bt_source_text`, `bttree --from-json`, `--format`; round trip tested on every shipped tree |
| Mistakes as data, with a position | **there**: line, column, message (`bt_diag`, `--check --json`). **One at a time**: the compiler stops at the first mistake, so an editor shows one problem, not all |
| A palette: every keyword and word, with parameters, types, defaults, docs | **there** for keywords, traits, archetypes, places (`--schema`). **Partly** for a word's arguments: derived from usage text, see below |
| Stable node identity | **there**, for one compiled text. **Not** across edits: there is no id that follows a node when lines are inserted above it. An editor keeps its own ids in memory and maps by position after each load; a debugger re-reads the forest when the text changes |
| Per-bot state: what is RUNNING, timers, the option held | **there**: `bt_state_running`, `bt_state_node` |
| Why a pick chose: each option's score, weight, factor, luck, sticky | **there**, opt-in per bot: `bt_state_trace`, `bt_state_worths`; no cost to bots not watched |
| A debug view | **there offline** (`bttree --trace`, one bot in a stated situation). **Missing live**: see below |

**Still missing**, plainly:

1. **A live debug channel.** Nothing carries a running bot's state out
   of botd: the API above is what such a channel would call, but botd
   has no command to dump its forest and a bot's `bt_state_running` /
   `bt_state_worths`, and the link file has no place for them. Until it
   has, a live view is the log line with `pick:<trait> > <action>`.
2. **Word arguments as data.** A condition's, score's or action's
   arguments exist only as a usage string and a sentence in
   `core/vocab.c`; `--schema` parses those. The table should carry, for
   each argument: name, required or optional, type (number, place, enum
   with its values, text), default, range, whether it repeats; and the
   compiler could then check a leaf's arguments, which it does not. The
   same for the list of places, which today is an if-chain in
   `skill_misc.c`, and for a trait's one line, which is a comment in
   `persona.h` (the tool repeats both).
3. **All the mistakes of a text at once.** Needs a compiler that goes on
   after a mistake.
4. **Layout.** A visual editor stores where the user put each node. The
   text has no place for it, and should not: an editor keeps it in a
   file of its own, keyed by tree name and node id, and drops what no
   longer matches.
5. **History of a decision.** The state says what a pick weighed last,
   not what it weighed before; a debugger that wants a timeline records
   it itself, tick by tick.
6. **No score without its bot.** `bt_state_worths` reports what was
   computed in play. Asking "what would this bot choose now?" outside a
   tick would call the scores, which is the engine's business, and draw
   from the bot's dice, which would change what it does next.

## 17. Limits

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
