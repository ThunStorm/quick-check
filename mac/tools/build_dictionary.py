"""Build the local dictionary or refresh its reviewed interface terminology."""

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

# Common interface terms with reviewed equivalents. Chinese keys use the canonical gloss.
TECHNICAL = (
    ("console panel", "控制台面板"),
    ("control panel", "控制面板"),
    ("settings panel", "设置面板"),
    ("status bar", "状态栏"),
    ("menu bar", "菜单栏"),
    ("title bar", "标题栏"),
    ("navigation bar", "导航栏"),
    ("side panel", "侧边面板"),
    ("sidebar", "侧边栏"),
    ("toolbar", "工具栏"),
    ("taskbar", "任务栏"),
    ("context menu", "上下文菜单"),
    ("keyboard shortcut", "键盘快捷键"),
    ("drop-down menu", "下拉菜单"),
    ("dialog box", "对话框"),
    ("notification center", "通知中心"),
    ("browser inspector", "浏览器检查器"),
    ("developer tools", "开发者工具"),
    ("command palette", "命令面板"),
    ("command line", "命令行"),
    ("terminal window", "终端窗口"),
    ("debug console", "调试控制台"),
    ("log viewer", "日志查看器"),
    ("source code", "源代码"),
    ("file picker", "文件选择器"),
    ("scroll bar", "滚动条"),
    ("progress bar", "进度条"),
    ("search bar", "搜索栏"),
    ("input method", "输入法"),
    ("clipboard history", "剪贴板历史"),
    ("dark mode", "深色模式"),
    ("light mode", "浅色模式"),
    ("network error", "网络错误"),
    ("request timeout", "请求超时"),
    ("submit button", "提交按钮"),
)

# Retain general senses for words that also appear in interfaces and developer tools.
POLYSEMOUS = (
    ("attachment", "名词  附件、附加文件；附属物；依恋、眷恋"),
    ("branch", "名词  分支、支线；树枝；分部、分店\n动词  分叉、分支"),
    ("commit", "名词  （版本控制）提交、提交记录\n动词  （版本控制）提交；承诺、投入；犯（罪、错）"),
    ("console", "名词  控制台、操作台；游戏主机；靠墙桌\n动词  安慰、宽慰、抚慰"),
    ("dock", "名词  （界面）程序坞；码头、船坞；（法庭）被告席\n动词  靠岸、进坞；对接；扣减"),
    ("folder", "名词  文件夹、资料夹；折叠式印刷品"),
    ("output", "名词  输出、输出结果；产量、产出\n动词  输出、产生"),
    ("pane", "名词  （界面）窗格、分栏；窗玻璃"),
    ("permission", "名词  （系统）权限、访问权限；许可、准许"),
    ("port", "名词  （网络）端口；（硬件）接口；港口、左舷\n动词  （软件）移植"),
    ("preferences", "名词  （软件）偏好设置、首选项；喜好、偏好"),
    ("prompt", "名词  提示、提示符；（AI）提示词\n动词  提示、促使\n形容词  迅速的、及时的"),
    ("shell", "名词  （计算机）命令解释器、外壳程序；壳、外壳；炮弹\n动词  去壳；炮击"),
    ("tab", "名词  （界面）标签页、选项卡；制表符；标签、拉片；账单"),
    ("terminal", "名词  （计算机）终端、终端程序；航站楼、客运站；接线端子\n形容词  末端的；（疾病）晚期的"),
    ("thread", "名词  （计算机）线程；（论坛）讨论串；线、细线；螺纹\n动词  穿线、穿过"),
    ("token", "名词  （认证）令牌；（语言模型）词元；代币、凭证；象征、标志"),
    ("window", "名词  （界面）窗口、视窗；窗、窗户；时间窗口"),
)


def apply_technical_entries(database):
    english = [entry("en-zh", key, 0, key, "名词", chinese) for key, chinese in TECHNICAL]
    english.extend(entry("en-zh", key, 0, key, "", meaning) for key, meaning in POLYSEMOUS)
    chinese = [entry("zh-en", key, 0, key, "名词", gloss) for gloss, key in TECHNICAL]
    database.executemany("DELETE FROM entries WHERE direction = 'en-zh' AND query = ?",
                         ((row[1],) for row in english))
    database.executemany("INSERT OR IGNORE INTO entries VALUES (?, ?, ?, ?, ?, ?)", english + chinese)


def write_dictionary(path, output):
    with path.open("rb") as source, output.open("wb") as stream:
        with gzip.GzipFile(filename="", mode="wb", fileobj=stream, mtime=0) as compressed:
            shutil.copyfileobj(source, compressed)


def update_technical_dictionary(existing, output):
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "dictionary.sqlite3"
        with gzip.open(existing, "rb") as compressed, path.open("wb") as database:
            shutil.copyfileobj(compressed, database)
        with sqlite3.connect(path) as database:
            apply_technical_entries(database)
            assert database.execute("PRAGMA quick_check").fetchone() == ("ok",)
        write_dictionary(path, output)


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
            apply_technical_entries(database)
        with sqlite3.connect(path) as database:
            database.execute("VACUUM")
            print(dict(database.execute("SELECT direction, count(*) FROM entries GROUP BY direction")))
            assert database.execute("PRAGMA quick_check").fetchone() == ("ok",)
        write_dictionary(path, output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update-technical", type=Path, metavar="EXISTING")
    parser.add_argument("paths", nargs="+", type=Path, metavar="PATH")
    args = parser.parse_args()
    if args.update_technical and len(args.paths) == 1:
        update_technical_dictionary(args.update_technical, args.paths[0])
    elif not args.update_technical and len(args.paths) == 3:
        build(*args.paths)
    else:
        parser.error("provide CEDICT TOMOSHI OUTPUT or --update-technical EXISTING OUTPUT")
