# Quick Check dictionary data attribution

## Bilingual dictionary

The bilingual SQLite file is adapted from the following sources and distributed
under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/legalcode).

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

## English definitions and examples

The separate `wordnet.sqlite3` file is adapted from [Open English WordNet 2025](https://github.com/globalwordnet/english-wordnet/releases/tag/2025-edition).
Copyright © 2019–present, The Open English WordNet Team.
The supplement is distributed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/legalcode).
The original [Princeton WordNet notice](WORDNET_PRINCETON_LICENSE.txt) also applies to the underlying data.
See the [upstream license and disclaimer](https://github.com/globalwordnet/english-wordnet/blob/2025-edition/LICENSE.md).

The WN-LMF source archive SHA-256 is
`9ca6d1dcb75f822fdd66617f7d9da48142ace38dd544d6ad5e2feca1674ad3fe`.
The conversion in `../tools/build_wordnet.py` indexes English headwords and
keeps definitions, parts of speech, and up to two examples per sense.
