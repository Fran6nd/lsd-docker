---
name: add-language
description: Add a new player-facing language to the catalog (machine draft with LibreTranslate, then reviewed to full parity). Use when asked to add or support a language such as German, Italian or Portuguese.
---

# Add a language

Background: [docs/translations.md](../../../docs/translations.md), "Adding a language".

1. **Check the client can draw it.** ZeroSpades draws Latin, Cyrillic,
   Greek and CJK, left to right only. No right-to-left or joined
   scripts (that is why there is no Arabic). If it cannot, stop and say so.

2. **Machine draft** (needs Docker; downloads the models once):

   ```sh
   dev/l10n_mt.sh <lang>
   ```

   This creates `locales/<lang>.po` beside every template, all fuzzy.
   From now on the language counts for parity: tests fail until it is
   complete. If Docker or the network is unavailable, use
   `luajit dev/l10n.lua --new <lang>` instead (empty entries) and let
   the agents translate from scratch.

3. **Glossary**, optional: `dev/l10n_glossary/<lang>.tsv`
   (`English<TAB>target` per line) for game names the engine mangles;
   re-run step 2 on cleared entries if it matters.

4. **Review everything** with the `update-translations` skill, steps
   2–5: the drafts appear in the todo list as `draft`, and the agents
   turn them into reviewed entries. Split a large list (500+ entries)
   across several agents by file and apply each part.

5. **Document it**: add a row to the "What players get" table in
   `docs/translations.md`. Nothing else lists languages: the server and
   `/lang` find them from the `.po` files.

6. `dev/test.sh`, then commit: the language, its `.po` files, and the docs.
