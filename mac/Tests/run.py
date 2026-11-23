"""Compile and run offline checks, plus loopback fixture tests by default."""

import argparse
import gzip
import json
import shutil
import subprocess
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread


class Provider(BaseHTTPRequestHandler):
    def do_POST(self):
        assert self.path == "/v1/chat/completions"
        assert self.headers["Authorization"] == "Bearer test-only"
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        system, user = request["messages"]
        assert system["role"] == "system" and user["role"] == "user"
        payload = json.loads(user["content"])
        multilingual = payload["text"] == "Le train part demain matin."
        if multilingual:
            assert payload["from"] == "French" and payload["to"] == "Korean"
        else:
            assert payload["text"] == "我这边都行，你定吧。"
            assert payload["from"] == "Simplified Chinese" and payload["to"] == "English"
        model = request["model"]
        if model in ("limit", "unauthorized"):
            self.send_response(429 if model == "limit" else 401)
            self.end_headers()
            return
        if model == "redirect":
            self.send_response(302)
            self.send_header("Location", "/unexpected")
            self.end_headers()
            return
        text = ("Please choose whichever works best for you."
                if "courteous" in payload["tone"] else "Whatever works for you.")
        if multilingual:
            text = "기차는 내일 아침에 출발합니다."
        body = json.dumps({"choices": [{"message": {"content": "" if model == "empty" else text}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true", help="Run checks without sending any translation requests")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        binary = directory / "checks"
        dictionary = directory / "dictionary.sqlite3"
        for name in ("dictionary", "wordnet"):
            source = root / f"Resources/{name}.sqlite3.gz"
            with gzip.open(source, "rb") as compressed, (directory / f"{name}.sqlite3").open("wb") as raw:
                shutil.copyfileobj(compressed, raw)
        subprocess.run(["xcrun", "swiftc", str(root / "Sources/Dictionary.swift"), str(root / "Sources/Language.swift"),
                        str(root / "Sources/Translation.swift"), str(root / "Tests/Checks.swift"),
                        "-o", str(binary)], check=True)
        if args.offline:
            subprocess.run([binary, dictionary], check=True, timeout=20)
            return
        with ThreadingHTTPServer(("127.0.0.1", 0), Provider) as server:
            worker = Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                subprocess.run([binary, dictionary, f"http://127.0.0.1:{server.server_port}"], check=True, timeout=20)
            finally:
                server.shutdown()
                worker.join()


if __name__ == "__main__":
    main()
