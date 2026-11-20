# Quick Check dictionary data attribution

The bundled SQLite dictionary is adapted from the following sources. The data
is distributed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/legalcode).
This license applies to the dictionary data.

- [CC-CEDICT](https://cc-cedict.org/wiki/), copyright CC-CEDICT contributors,
  published by [MDBG](https://www.mdbg.net/chinese/dictionary?page=cc-cedict).
  Referenced work CEDICT copyright © 1997–1998 Paul Andrew Denisowski.
  Data is from the 2026-11-20 MDBG archive, SHA-256
  `7991fba1e823833722a05d49f1a2ba74e8bbf603bdafebadaf029b14af47fe7b`.
- [Tomoshi open dictionary data v2026-11-16](https://github.com/tomoshi-app/tomoshi-dict-data/releases/tag/v2026-11-16).
  JMdict © Electronic Dictionary Research and Development Group
  ([EDRDG](https://www.edrdg.org/)); derivations and Chinese gloss translations © Y1Z.
  Source asset SHA-256 `793d26a8963bff8b4dc39e83190d6f1608449f25aa5a8b5f9163c44e8c39b684`.
  The conversion reads the CC BY-SA 4.0 `entries`, `freq_rank`, and `zh_defs`
  tables. See [the source licensing notice](https://github.com/tomoshi-app/tomoshi-dict-data/blob/main/LICENSE.md).

Quick Check normalizes and indexes headwords and selected glosses, derives
reverse lookup keys from glosses, summarizes Japanese parts of speech, selects
common Japanese entries, and adds a small number of editorial entries.
The conversion is in `../tools/build_dictionary.py` in the source repository.
