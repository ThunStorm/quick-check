"""Compile and run integration checks against a loopback Chat Completions fixture."""

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
        body = json.dumps({"choices": [{"message": {"content": "" if model == "empty" else text}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def main():
    root = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory() as temporary, ThreadingHTTPServer(("127.0.0.1", 0), Provider) as server:
        directory = Path(temporary)
        binary = directory / "checks"
        dictionary = directory / "dictionary.sqlite3"
        with gzip.open(root / "Resources/dictionary.sqlite3.gz", "rb") as compressed, dictionary.open("wb") as raw:
            shutil.copyfileobj(compressed, raw)
        subprocess.run(["xcrun", "swiftc", str(root / "Sources/Dictionary.swift"),
                        str(root / "Sources/Translation.swift"), str(root / "Tests/Checks.swift"),
                        "-o", str(binary)], check=True)
        worker = Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            subprocess.run([binary, dictionary, f"http://127.0.0.1:{server.server_port}"], check=True, timeout=20)
        finally:
            server.shutdown()
            worker.join()


if __name__ == "__main__":
    main()
