#!/usr/bin/env python3
"""Fake llama-server router used only by the spike's relay tests.

It speaks the subset of the native router API the relay relies on:
/health, /models, /v1/models, /models/load, /models/unload, /metrics and
/v1/chat/completions (streaming SSE included). It deliberately runs one OS
process per build, exactly like a real llama-server router would.
"""
import argparse
import json
import re
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {
    "build": "unknown",
    "models": [],
    "loaded": set(),
    "delay": 0.0,
    "lock": threading.Lock(),
}


def preset_ids(path):
    ids = []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                match = re.match(r"^\[(.+)\]\s*$", line.strip())
                if match and match.group(1) != "*":
                    ids.append(match.group(1))
    except OSError:
        pass
    return ids


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("fake_router[%s] " % STATE["build"] + (fmt % args) + "\n")
        sys.stderr.flush()

    def _json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _model(self, body):
        try:
            parsed = json.loads(body or b"{}")
        except Exception:
            parsed = {}
        model = parsed.get("model") if isinstance(parsed, dict) else None
        if not model:
            model = STATE["models"][0] if STATE["models"] else "unknown"
        return model

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/health":
            return self._json({"status": "ok"})
        if path in ("/models", "/v1/models"):
            with STATE["lock"]:
                data = [
                    {
                        "id": model,
                        "object": "model",
                        "created": 0,
                        "owned_by": "fake",
                        "build": STATE["build"],
                        "status": {"value": "loaded" if model in STATE["loaded"] else "unloaded"},
                    }
                    for model in STATE["models"]
                ]
            return self._json({"object": "list", "data": data})
        if path == "/metrics":
            text = (
                "# HELP llama_prompt_tokens_per_seconds Prompt speed\n"
                "llama_prompt_tokens_per_seconds{build=\"%s\"} 111.5\n"
                "llama_tokens_per_seconds{build=\"%s\"} 22.5\n"
                % (STATE["build"], STATE["build"])
            )
            body = text.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True
            return
        if path == "/props":
            return self._json({"build": STATE["build"], "is_sleeping": False})
        return self._json({"error": "not found"}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        path = self.path.split("?")[0]

        if path in ("/models/load", "/models/unload"):
            try:
                model = json.loads(body or b"{}").get("model")
            except Exception:
                model = None
            with STATE["lock"]:
                if path.endswith("/load"):
                    if model:
                        STATE["loaded"].add(model)
                else:
                    STATE["loaded"].discard(model)
            return self._json({"success": True})

        if path == "/v1/chat/completions":
            model = self._model(body)
            with STATE["lock"]:
                STATE["loaded"].add(model)
            if STATE["delay"]:
                time.sleep(STATE["delay"])
            try:
                stream = bool(json.loads(body or b"{}").get("stream"))
            except Exception:
                stream = False
            text = "hello from %s (%s)" % (STATE["build"], model)
            if stream:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "close")
                self.end_headers()
                chunk = {
                    "id": "fake",
                    "object": "chat.completion.chunk",
                    "choices": [{"index": 0, "delta": {"role": "assistant", "content": text}, "finish_reason": None}],
                }
                self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                done = {
                    "id": "fake",
                    "object": "chat.completion.chunk",
                    "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                }
                self.wfile.write(("data: " + json.dumps(done) + "\n\n").encode())
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                self.close_connection = True
                return
            return self._json(
                {
                    "id": "fake",
                    "object": "chat.completion",
                    "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}],
                }
            )

        return self._json({"error": "not found"}, 404)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--build", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--preset", default=None)
    parser.add_argument("--models", default=None)
    parser.add_argument("--delay", type=float, default=0.0)
    args = parser.parse_args()

    STATE["build"] = args.build
    STATE["models"] = args.models.split(",") if args.models else preset_ids(args.preset or "")
    STATE["delay"] = args.delay

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True

    def stop(_sig, _frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print("fake_router[%s] listening on %d" % (args.build, args.port), flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
