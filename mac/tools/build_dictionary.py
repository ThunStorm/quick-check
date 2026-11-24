"""Build the local dictionary from a CC-CEDICT ZIP and an unpacked Tomoshi database."""

import argparse
import gzip
import json
import re
import shutil
import sqlite3
import tempfile
import unicodedata
import zipfile
from pathlib import Path


def lookup_key(value):
    return " ".join(unicodedata.normalize("NFKC", value).lower().split())


def entry(direction, query, priority, headword, detail, meaning):
    return direction, lookup_key(query), priority, headword, detail, meaning


def cedict_rows(source):
    pattern = re.compile(r"^(\S+) (\S+) \[([^\]]+)\] /(.+)/$")
    with zipfile.ZipFile(source) as archive, archive.open("cedict_ts.u8") as lines:
        for line in lines:
            match = pattern.fullmatch(line.decode("utf-8").strip())
            if not match:
                continue
            traditional, simplified, reading, definitions = match.groups()
            senses = [sense for sense in definitions.split("/") if not sense.startswith("CL:")]
            if not senses:
                continue
            detail = reading if traditional == simplified else f"{traditional} · {reading}"
            for query in dict.fromkeys((simplified, traditional)):
                yield entry("zh-en", query, 20, simplified, detail, " / ".join(senses[:6]))
            for index, sense in enumerate(senses[:10]):
                # Parentheticals often qualify a gloss, not the English lookup phrase.
                query = re.sub(r"\s*\([^)]*\)", "", sense).strip()
                without_to = query[3:] if query.startswith("to ") else query
                if re.fullmatch(r"[A-Za-z][A-Za-z' -]{0,55}", without_to):
                    for form in dict.fromkeys((query, without_to)):
                        yield entry("en-zh", form, 20 + index, simplified, detail, simplified)


def japanese_pos(sense):
    labels = []
    for name in sense.get("pos", []):
        if name.startswith(("noun", "proper noun")):
            labels.append("名词")
        elif "verb" in name and "adverb" not in name:
            labels.append("动词")
        elif "adjective" in name:
            labels.append("形容词")
        elif "adverb" in name:
            labels.append("副词")
    return "、".join(dict.fromkeys(labels))


def japanese_rows(source):
    sql = """
        SELECT e.data, z.data, COALESCE(f.rank, 9999)
        FROM entries AS e
        JOIN zh_defs AS z ON e.id = z.entry_id AND z.locale = 'zh-CN'
        LEFT JOIN freq_rank AS f ON f.entry_id = e.id
        WHERE e.is_common = 1
        ORDER BY e.id
    """
    with sqlite3.connect(f"{source.resolve().as_uri()}?mode=ro", uri=True) as database:
        for raw_entry, raw_chinese, rank in database.execute(sql):
            word = json.loads(raw_entry)
            chinese = json.loads(raw_chinese).get("senses", {})
            readings = [item["text"] for item in word["kana"]]
            spellings = [item["text"] for item in word["kanji"]]
            forms = list(dict.fromkeys(spellings + readings))
            if not forms:
                continue
            headword = forms[0]
            reading = readings[0] if spellings and readings else ""
            meanings = []
            for index, sense in enumerate(word["senses"]):
                if len(meanings) == 5:
                    break
                glosses = chinese.get(str(index), {}).get("glosses", [])
                gloss = "；".join(gloss["text"].strip() for gloss in glosses if gloss.get("text"))
                if not gloss:
                    continue
                part = japanese_pos(sense)
                meanings.append(f"{part}  {gloss}" if part else gloss)
                for key in re.split("[；;、]", gloss):
                    key = re.sub(r"[（(][^）)]*[）)]", "", key).strip()
                    if re.fullmatch(r"[\u3400-\u9fff]{1,12}", key):
                        yield entry("zh-ja", key, 10 + rank, headword, reading, headword)
            if meanings:
                for form in forms:
                    yield entry("ja-zh", form, 10 + rank, headword, reading, "\n".join(meanings))


# Short, hand-edited entries for ambiguous or commonly searched everyday vocabulary.
EDITORIAL = (
    ("en-zh", "draft", 0, "draft", "", "名词  草稿、草案；气流\n动词  起草、拟定"),
    ("en-zh", "deadline", 0, "deadline", "名词", "截止时间；最后期限"),
    ("en-zh", "love", 0, "love", "", "名词  爱意、爱情、喜爱\n动词  爱、热爱、喜欢"),
    ("zh-en", "希望", 0, "希望", "动词、名词", "hope；wish"),
    ("en-zh", "swim", 0, "swim", "动词", "游泳；游过"),
    ("en-zh", "write", 0, "write", "动词", "写；撰写；书写"),
    ("zh-en", "我的", 0, "我的", "", "限定词  my\n代词  mine"),
    ("zh-en", "你的", 0, "你的", "", "限定词  your\n代词  yours"),
    ("zh-en", "他的", 0, "他的", "限定词、代词", "his"),
    ("zh-en", "她的", 0, "她的", "", "限定词  her\n代词  hers"),
    ("zh-en", "我们的", 0, "我们的", "", "限定词  our\n代词  ours"),
    ("zh-en", "他们的", 0, "他们的", "", "限定词  their\n代词  theirs"),
    ("zh-en", "好的", 0, "好的", "短语", "OK；all right"),
    ("zh-en", "没问题", 0, "没问题", "短语", "no problem；sure"),
    ("zh-en", "不客气", 0, "不客气", "短语", "you're welcome；don't mention it"),
    ("zh-ja", "收据", 0, "領収書", "りょうしゅうしょ", "領収書"),
    ("ja-zh", "領収書", 0, "領収書", "りょうしゅうしょ · 名词", "正式收据；收款凭证"),
    ("zh-ja", "手纸", 0, "トイレットペーパー", "", "トイレットペーパー"),
    ("zh-ja", "手紙", 0, "トイレットペーパー", "", "トイレットペーパー"),
)


def build(cedict, japanese, output):
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "dictionary.sqlite3"
        with sqlite3.connect(path) as database:
            database.execute("""
                CREATE TABLE entries (
                    direction TEXT NOT NULL,
                    query TEXT NOT NULL,
                    priority INTEGER NOT NULL,
                    headword TEXT NOT NULL,
                    detail TEXT NOT NULL,
                    meaning TEXT NOT NULL,
                    PRIMARY KEY (direction, query, priority, headword, meaning)
                ) WITHOUT ROWID
            """)
            insert = "INSERT OR IGNORE INTO entries VALUES (?, ?, ?, ?, ?, ?)"
            database.executemany(insert, EDITORIAL)
            database.executemany(insert, cedict_rows(cedict))
            database.executemany(insert, japanese_rows(japanese))
            database.execute("""
                DELETE FROM entries
                WHERE priority > 0 AND EXISTS (
                    SELECT 1 FROM entries AS edited
                    WHERE edited.direction = entries.direction AND edited.query = entries.query
                      AND edited.headword = entries.headword AND edited.priority = 0
                )
            """)
        with sqlite3.connect(path) as database:
            database.execute("VACUUM")
            print(dict(database.execute("SELECT direction, count(*) FROM entries GROUP BY direction")))
            assert database.execute("PRAGMA quick_check").fetchone() == ("ok",)
        with path.open("rb") as source, output.open("wb") as stream:
            with gzip.GzipFile(filename="", mode="wb", fileobj=stream, mtime=0) as compressed:
                shutil.copyfileobj(source, compressed)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cedict", type=Path)
    parser.add_argument("tomoshi", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    build(args.cedict, args.tomoshi, args.output)
