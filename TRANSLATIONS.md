# Translations

How the server speaks each player's language, and how the translations
are made: extracted from the scripts, drafted by machine translation,
reviewed by people, and kept in step with the code.

- [What players get](#what-players-get)
- [The files](#the-files)
- [The pipeline](#the-pipeline)
- [Adding a language](#adding-a-language)
- [Reviewing machine translations](#reviewing-machine-translations)
- [Writing translatable scripts](#writing-translatable-scripts)
- [When LSd or a script changes](#when-lsd-or-a-script-changes)
- [Tools reference](#tools-reference)

## What players get

| Language | Code | State |
|---|---|---|
| English | `en` | the source text |
| French | `fr` | translated by hand |
| Spanish | `es` | machine-translated drafts, waiting for review |
| Chinese (Simplified) | `zh` | machine-translated drafts, waiting for review |
| Russian | `ru` | machine-translated drafts, waiting for review |

A player reads the language they chose with `/lang <code>`, else the
locale their client reports, else `l10n_default_lang`. A locale falls
back to its language (`es_mx` to `es`), then to the default, then to
English. Anything not translated yet is shown in English.

**Only the current ZeroSpades is translated for.** It is the client that
reports its locale, speaks UTF-8 and draws the scripts translated into.
Every other client reads `l10n_default_lang`, and `/lang` tells it what
translations need. The gate is the setting

```
l10n_clients = {ZeroSpades: '0.0.9'}
```

client names and the oldest version of each, matched in the version
string a client reports ("... | ZeroSpades 0.0.9 b3432453 (arm64)").

Machine-translated drafts are **fuzzy**: present in the files, never
shown to a player until a translator has checked them (see
[Reviewing](#reviewing-machine-translations)).

## The files

Translations live with the script they translate, as gettext files any
`.po` editor opens:

```
catalog/tools/votekick/
├── votekick.lua
└── locales/
    ├── template.pot   every message of the script (generated)
    ├── fr.po          its French
    ├── es.po          its Spanish
    └── ...
```

Upstream LSd's own messages, and the stock tips and motd of
`image/config.lua`, are in `catalog/overrides/locales/`.

The image installs each `locales/<lang>.po` as
`scripts/locales/<lang>/<id>.po` (upstream's as `lsd.po`), and the
server merges a language's files the first time a player needs it.

## The pipeline

```
 scripts (.lua)                 {en = "..."}, l10n_msg("..."), desc = "..."
      │  dev/l10n.lua           extract, per script
      ▼
 locales/template.pot           every message, in English
      │  dev/l10n.lua           merge into each language
      ▼
 locales/<lang>.po              new texts empty; gone ones kept (#~);
      │                         a reworded one keeps its translation, fuzzy
      │  dev/l10n_mt.sh         machine translation (LibreTranslate)
      ▼
 locales/<lang>.po              empty entries filled, marked fuzzy
      │  a translator           Poedit: fix, clear "fuzzy"
      ▼
 locales/<lang>.po              reviewed: what players read
      │  tests                  placeholders kept, templates current
      ▼
 image → scripts/locales/<lang>/<id>.po → lib_l10n, per player
```

Two steps run by themselves:

- **On every commit**, `githooks/pre-commit` runs `dev/l10n.lua` and
  stages what it changed, so a commit that adds or changes a message
  carries its templates and `.po` files. (Enable the hooks once with
  `git config core.hooksPath githooks`.)
- **On every LSd bump**, `dev/bump-lsd.sh` does the same and lists the
  translations that turned fuzzy.

The tests (`dev/test.sh`, and CI) fail when a template is out of date
or when a translation lost or gained a `%(placeholder)`.

## Adding a language

1. Draft it by machine:

   ```sh
   dev/l10n_mt.sh de          # several at once: dev/l10n_mt.sh de it pt
   ```

   This starts [LibreTranslate](https://github.com/LibreTranslate/LibreTranslate)
   in Docker (open source, self-hosted: the only network use is the
   first download of its language models), creates `locales/de.po` in
   every script, fills each empty entry, and stops the container. About
   500 entries take a few minutes. Every draft is fuzzy.

2. Add a glossary if the language needs one (see below), and run it
   again on what came out wrong: clear those entries and re-run, or
   fix them by hand.

3. [Review](#reviewing-machine-translations) the drafts.

4. Check the client can show the script. ZeroSpades draws Latin,
   Cyrillic, Greek and CJK, left to right; it does not lay out
   right-to-left scripts or join Arabic letters, which is why there is
   no Arabic.

5. Commit. The hook and the tests do the rest.

A language can also be started empty for a person to translate from
scratch: `luajit dev/l10n.lua --new de` (or `--new de catalog/tools/votekick`
for some scripts only).

### Glossaries

`dev/l10n_glossary/<lang>.tsv` holds, per line, an English word or
phrase, a tab, and what it must become:

```
Type	Escribe
the Fall	la Caída
votekick	votación de expulsión
```

Matched as written (case included, whole words), and inserted as
given, so game names and words the engine gets wrong read the same
everywhere. Keep it short: an inserted word does not agree with the
sentence around it, which the review then fixes.

## Reviewing machine translations

Machine translation gets plain sentences mostly right and game language
often wrong: "kicked" as a literal kick, "Type /y" as the noun "type",
grammar broken around glossary words, technical words ("glob")
translated literally. So drafts are never shown until reviewed.

In [Poedit](https://poedit.net) (or any gettext editor):

1. Open a script's `locales/<lang>.po`.
2. Go to the next fuzzy entry; each draft carries the comment
   `# machine-translated (LibreTranslate)`.
3. Fix the text; keep every `%(name)` exactly as it is, and leave
   `/commands` untranslated.
4. Clear the fuzzy flag. The entry is now what players read.

`msgfmt -c --statistics locales/<lang>.po` shows how far a file is.
A team can put the same files on a translation platform (zerospades
uses Crowdin); they are plain gettext.

`luajit dev/l10n_mt.lua <lang> --accept` writes drafts as reviewed,
for a language where a rough translation beats English. Nothing does
this by default.

## Writing translatable scripts

Write every message in English, as a table with `en`; placeholders are
`%(name)`:

```lua
l10n_send_chat(pid, {en = "%(name) was kicked"}, {name = n})
server_msg(PID_BROADCAST, l10n_msg({en = "Round over."}))
l10n_msgn({en = "%(n) bot", en_plural = "%(n) bots"}, count)
{en = "Open", ctx = "door"}              -- tells two "Open"s apart
```

A command's `desc` and a pie menu slice's `label` and `tooltip` are
picked up the same way. The text must be a literal (or literals joined
with `..`): `dev/l10n.lua` reads the source, it does not run it.

Operators' own text in the settings (motd, tips, kick reasons) is a
string or a language map, `{en: 'Welcome', es: 'Bienvenido'}`; no `.po`
needed.

## When LSd or a script changes

- **A new message** is added to the template and, empty, to every
  `.po` on the next commit.
- **A reworded message** takes the translation of the closest gone one
  (70% alike, same placeholders), marked fuzzy: not shown until
  checked, not lost.
- **A removed message** is kept commented out (`#~`) at the end of the
  file, so its translation can still be copied.

## Tools reference

| Command | Does |
|---|---|
| `luajit dev/l10n.lua` | rewrite every template, merge every `.po` |
| `luajit dev/l10n.lua --check` | fail if anything is out of date (tests, CI) |
| `luajit dev/l10n.lua --new <lang> [<path>...]` | start a language, empty |
| `dev/l10n_mt.sh [--accept] <lang>...` | start LibreTranslate, start and draft languages, stop it |
| `luajit dev/l10n_mt.lua <lang> [--url URL] [--accept] [<path>...]` | draft against a LibreTranslate already running |

`dev/l10n_mt.sh` reads `LIBRETRANSLATE_IMAGE` (default
`libretranslate/libretranslate:latest`) and `LIBRETRANSLATE_PORT`
(default 5055).

At runtime, `lib_l10n` (in `catalog/overrides/`) does the rest; the
settings are `l10n_default_lang`, `l10n_clients` and `l10n_log_lang`
(the server log's language, English).
