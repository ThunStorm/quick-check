"""Build the offline Open English WordNet supplement from the official WN-LMF gzip."""

import argparse
import gzip
import shutil
import sqlite3
import tempfile
import unicodedata
import xml.etree.ElementTree as ET
from pathlib import Path


PARTS = {"n": "名词", "v": "动词", "a": "形容词", "s": "形容词", "r": "副词"}


def normalize(term):
    return " ".join(unicodedata.normalize("NFKC", term).lower().split())


def contents(element):
    return " ".join("".join(element.itertext()).split())


def import_lexicon(database, source):
    with gzip.open(source, "rb") as xml:
        for _, entry in ET.iterparse(xml, events=("end",)):
            if entry.tag == "LexicalEntry":
                word = normalize(entry.find("Lemma").attrib["writtenForm"])
                database.executemany("INSERT OR IGNORE INTO words VALUES (?, ?, ?)", (
                    (word, index, sense.attrib["synset"]) for index, sense in enumerate(entry.findall("Sense"))
                ))
                entry.clear()
            elif entry.tag == "Synset":
                part = PARTS.get(entry.attrib["partOfSpeech"])
                definition = " / ".join(filter(None, map(contents, entry.findall("Definition"))))
                examples = list(dict.fromkeys(filter(None, map(contents, entry.findall("Example")))))
                if part and definition:
                    database.execute("INSERT INTO senses VALUES (?, ?, ?, ?)", (
                        entry.attrib["id"], part, definition, "\n".join(examples[:2])
                    ))
                entry.clear()


def build(source, output):
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "wordnet.sqlite3"
        with sqlite3.connect(path) as database:
            database.executescript("""
                CREATE TABLE words (
                    word TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    sense TEXT NOT NULL,
                    PRIMARY KEY (word, position, sense)
                ) WITHOUT ROWID;
                CREATE TABLE senses (
                    id TEXT PRIMARY KEY,
                    part TEXT NOT NULL,
                    definition TEXT NOT NULL,
                    examples TEXT NOT NULL
                ) WITHOUT ROWID;
            """)
            import_lexicon(database, source)
        with sqlite3.connect(path) as database:
            database.execute("VACUUM")
            count = database.execute(
                "SELECT count(*), sum(examples != '') FROM senses"
            ).fetchone()
            if not all(count) or database.execute("PRAGMA quick_check").fetchone() != ("ok",):
                raise ValueError("Incomplete or invalid WordNet database")
            print(f"{count[0]} senses, {count[1]} with examples")
        with path.open("rb") as raw, output.open("wb") as stream:
            with gzip.GzipFile(filename="", mode="wb", fileobj=stream, mtime=0) as compressed:
                shutil.copyfileobj(raw, compressed)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xml", type=Path)
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    build(arguments.xml, arguments.output)
