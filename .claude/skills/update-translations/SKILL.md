---
name: update-translations
description: Bring every language (fr, es, zh, ru) up to date after scripts gained or reworded messages, so the parity test passes. Use when dev/test.sh fails on l10n parity, after adding/changing any {en = ...} text, a command desc, a pie label, or a callout, or when asked to "update translations".
---

# Update translations

Every language must translate every message (`tests/l10n_test.lua`).
Full background: [docs/translations.md](../../../docs/translations.md).

## 1. Refresh templates and .po files

```sh
luajit dev/l10n.lua            # rewrite templates, merge new/changed messages into every .po
luajit dev/l10n.lua --check    # must say "up to date"
```

"en= is not a literal" notes are expected for a few dynamic messages; ignore them.

## 2. See what each language needs

```sh
for l in fr es zh ru; do
  printf '%s: ' $l; luajit dev/l10n_review.lua todo $l | grep -c '^	{file'
done
```

All zeros → skip to step 5.

## 3. Translate: one cheap agent per language, in parallel

For each language with entries, write its list to the scratchpad:

```sh
luajit dev/l10n_review.lua todo <lang> > <scratchpad>/l10n/todo_<lang>.lua
```

Then spawn one agent per language **in a single message** with
`model: "haiku"` (use `sonnet` only for a list over ~300 entries or one
a haiku run got wrong). Give each this brief, filled in:

> Translate the game-server UI strings in `<scratchpad>/l10n/todo_<lang>.lua`
> into <language>. It is a Lua list of `{file, ctx, en, draft, str}`.
> Write `<scratchpad>/l10n/done_<lang>.lua`: the same list, every entry
> kept as is (`file`, `ctx`, `en` unchanged) with `str` set to the
> translation. A `draft` is a machine draft: fix it, don't trust it.
> Rules: keep every `%(name)` placeholder exactly; never translate
> `/commands`, setting names, or "gg"; keep it as short as the English
> (pie labels are 1–3 words); `ctx` says where the text appears
> (e.g. "command" = a command description: <infinitive / imperative
> style for the language>). Game words: Ace of Spades terms — intel,
> tent, babel, digger, spade, grenade — use the same rendering as the
> language's existing `catalog/**/locales/<lang>.po` (grep them).
> Then run `cd <repo> && luajit dev/l10n_review.lua apply <lang> <done file>`;
> if it refuses an entry (placeholder mismatch), fix that entry and
> re-apply. Finish when `luajit dev/l10n_review.lua todo <lang> | grep -c '^	{file'`
> prints 0. Don't run git or dev/l10n.lua. Report counts and any
> wording choices worth a human look.

Language notes to put in the brief:
- **fr**: French spacing before `! ? : ;`, "tu" form, intel = "renseignements".
- **es**: neutral Spanish, "tú" form.
- **zh**: Simplified Chinese, full-width punctuation, no spaces around placeholders unless the English has them.
- **ru**: informal "ты" in commands to the player.

## 4. Plurals (not in the todo list)

`todo` skips plural entries (`msgid_plural`). Find empty ones and fill
the `msgstr[n]` forms by hand (ru needs 3 forms, zh 1, fr/es 2):

```sh
find catalog -path '*/locales/*.po' | xargs grep -A4 'msgid_plural' | grep -B3 'msgstr\[0\] ""'
```

## 5. Verify

```sh
luajit dev/l10n.lua --check && luajit tests/l10n_test.lua | tail -3
```

Then `dev/test.sh`. Skim a few translations of each language in the
diff (`git diff -- '*.po'`) before committing; the pre-commit hook
re-stages locales it normalises.
