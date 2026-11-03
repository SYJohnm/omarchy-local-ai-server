#!/usr/bin/env python3
"""Spike: one public OpenAI endpoint in front of one llama-server router per build.

The relay owns the public port for the whole lifetime of the process. It never
forwards across builds: it stops the active router, starts the router of the
requested model's build, waits for that router to answer /models, then forwards.
Requests for the previous build finish before the switch (drain); requests for
the new build wait for it.

This is a proof of concept, not production: it reads JSON bodies whole, has no
auth, no CORS, no chunked request bodies and a simple last-request-wins switch
policy. It is deliberately small so the router/relay split can be evaluated.
Sleep is intentionally not used: idle unload has to stay relay-driven so the
prompt cache can be saved before a model goes away.

Config: see spike/spike.config.json.
"""
import argparse
import http.client
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "host", "content-length",
}

LOCAL_GET = {"/health", "/v1/models", "/models", "/spike/state", "/admin/state"}


def ini_value(value):
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return ""
    return str(value).replace("\r", " ").replace("\n", " ")


def slot_prefix(path):
    """Match Backends.slotPrefix: readable basename + djb2 hash of full path."""
    base = os.path.basename(str(path))
    h = 5381
    for ch in str(path):
        h = ((h * 33) + ord(ch)) & 0xFFFFFFFF
    return re.sub(r"[^A-Za-z0-9._-]", "_", base) + "-" + ("%08x" % h)


def render_preset(models, slot_dir=""):
    """One INI section per model; the section name is the model id."""
    lines = ["version = 1", ""]
    if slot_dir:
        lines += ["[*]", "slot-save-path = " + slot_dir, ""]
    for model in models:
        name = str(model["id"])
        if name == "" or "]" in name or "\n" in name:
            raise ValueError("invalid preset model id: %r" % (name,))
        lines.append("[" + name + "]")
        lines.append("model = " + str(model.get("path") or name))
        for key, value in (model.get("params") or {}).items():
            key = str(key).lstrip("-").strip()
            if key == "":
                continue
            lines.append(key + " = " + ini_value(value))
        lines.append("")
    return "\n".join(lines)


def log(message):
    sys.stderr.write("[relay] " + message + "\n")
    sys.stderr.flush()


def env_map(value):
    if not value:
        return {}
    if isinstance(value, dict):
        return {str(k): str(v) for k, v in value.items()}
    out = {}
    for item in value:
        key, _, val = str(item).partition("=")
        out[key] = val
    return out


class Router:
    """One llama-server router process for one build."""

    def __init__(self, build, spec, state_dir, start_timeout, stop_timeout, slot_dir=""):
        self.build = build
        self.spec = spec
        self.port = int(spec["port"])
        self.state_dir = state_dir
        self.slot_dir = slot_dir
        self.preset = spec.get("preset") or os.path.join(
            state_dir, "preset-" + re.sub(r"[^A-Za-z0-9_.-]", "_", build) + ".ini")
        self.start_timeout = start_timeout
        self.stop_timeout = stop_timeout
        self.env = dict(os.environ)
        self.env.update(env_map(spec.get("env")))
        self.log_path = os.path.join(state_dir, build + ".log")
        self.proc = None
        self.log_file = None

    def write_preset(self, models):
        text = render_preset(models, self.slot_dir)
        os.makedirs(self.state_dir, exist_ok=True)
        with open(self.preset, "w", encoding="utf-8") as handle:
            handle.write(text)

    def command(self, model_ids):
        spec = self.spec
        if spec.get("command"):
            fill = {
                "port": str(self.port),
                "preset": self.preset or "",
                "models": ",".join(model_ids),
            }
            argv = []
            for part in spec["command"]:
                text = str(part)
                for key, value in fill.items():
                    text = text.replace("{" + key + "}", value)
                argv.append(text)
            return argv
        argv = [str(spec["binary"]), "--host", "127.0.0.1", "--port", str(self.port)]
        if self.preset:
            argv += ["--models-preset", self.preset]
        argv += [str(arg) for arg in spec.get("args", [])]
        return argv

    def start(self, models):
        if not self.spec.get("command"):
            self.write_preset(models)
        model_ids = [m["id"] for m in models]
        os.makedirs(os.path.dirname(self.log_path), exist_ok=True)
        self.log_file = open(self.log_path, "ab")
        argv = self.command(model_ids)
        log("start %s: %s" % (self.build, " ".join(argv)))
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=self.log_file,
            stderr=subprocess.STDOUT,
            env=self.env,
            start_new_session=True,
        )

    def _tail(self, lines=8):
        try:
            with open(self.log_path, "r", encoding="utf-8", errors="replace") as handle:
                return "".join(handle.readlines()[-lines:]).strip()
        except OSError:
            return ""

    def wait_ready(self):
        deadline = time.time() + self.start_timeout
        while time.time() < deadline:
            if self.proc is not None and self.proc.poll() is not None:
                raise RuntimeError(
                    "router %s exited with %s\n%s" % (self.build, self.proc.returncode, self._tail())
                )
            try:
                conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=1)
                conn.request("GET", "/models")
                response = conn.getresponse()
                response.read()
                conn.close()
                if response.status == 200:
                    return
            except OSError:
                pass
            time.sleep(0.1)
        raise RuntimeError("router %s did not become ready on port %d\n%s" % (self.build, self.port, self._tail()))

    def stop(self):
        proc = self.proc
        self.proc = None
        if proc is None:
            return
        log("stop %s (pid %s)" % (self.build, proc.pid))
        # The router spawns model children in its own session. Signalling only
        # the router can leave a child holding the port and the systemd cgroup,
        # which wedges the unit in "deactivating". Signal the whole group.
        try:
            group = os.getpgid(proc.pid)
        except OSError:
            group = None
        try:
            if group is not None:
                os.killpg(group, signal.SIGTERM)
            else:
                proc.terminate()
            proc.wait(timeout=self.stop_timeout)
        except Exception:
            try:
                if group is not None:
                    os.killpg(group, signal.SIGKILL)
                else:
                    proc.kill()
                proc.wait(timeout=5)
            except Exception:
                pass
        finally:
            if self.log_file is not None:
                try:
                    self.log_file.close()
                except OSError:
                    pass
                self.log_file = None


class Relay:
    def __init__(self, config, state_dir):
        self.config = config
        self.state_dir = state_dir
        self.start_timeout = float(config.get("start_timeout_s", 20))
        self.stop_timeout = float(config.get("stop_timeout_s", 10))
        self.drain_timeout = float(config.get("drain_timeout_s", 30))
        self.cond = threading.Condition()
        self.inflight = {}
        self.active = None
        self.switching = False
        self.closing = False

        self.models = []
        self.by_name = {}
        for raw in config.get("models", []):
            model = dict(raw)
            model.setdefault("id", model.get("path"))
            model.setdefault("aliases", [])
            model.setdefault("build", "default")
            if not model.get("id"):
                raise ValueError("model entry needs id or path: %r" % (raw,))
            self.models.append(model)
            for name in [model["id"], model.get("path")] + list(model["aliases"]):
                if name:
                    self.by_name[name] = model

        self.prompt_cache = bool(config.get("prompt_cache", True))
        self.slot_dir = config.get("slot_dir") or os.path.join(state_dir, "slots")
        self.slot_kv = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "slot_kv.py")
        self.restored = set()
        self.preparing = set()
        self.prepare_cond = threading.Condition()
        os.makedirs(self.slot_dir, mode=0o700, exist_ok=True)

        self.routers = {}
        for build, spec in (config.get("routers") or {}).items():
            self.routers[build] = Router(build, spec, state_dir, self.start_timeout, self.stop_timeout, self.slot_dir)
        for model in self.models:
            if model["build"] not in self.routers:
                raise ValueError("model %s names unknown build %r" % (model["id"], model["build"]))

        self.default_model = config.get("default_model")
        if self.default_model and self.default_model not in self.by_name:
            raise ValueError("default_model %r is not in the catalog" % (self.default_model,))
        self.port_file = os.path.join(state_dir, "relay.port")

    def models_for(self, build):
        return [m for m in self.models if m["build"] == build]

    def find(self, name):
        if not name:
            return None
        return self.by_name.get(name)

    def pick_model(self, name):
        if name:
            return self.find(name)
        if self.default_model:
            return self.find(self.default_model)
        if len(self.models) == 1:
            return self.models[0]
        return None

    def statuses(self):
        """Current router statuses, keyed by model id. Never blocks a switch."""
        out = {}
        active = self.active
        if active is not None:
            try:
                conn = http.client.HTTPConnection("127.0.0.1", active.port, timeout=1)
                conn.request("GET", "/models")
                response = conn.getresponse()
                payload = json.loads(response.read() or b"{}")
                conn.close()
                for item in payload.get("data", []):
                    out[item.get("id")] = item.get("status") or {"value": "unloaded"}
            except Exception:
                pass
        return out

    def router_base(self, router):
        return "http://127.0.0.1:%d" % router.port

    def loaded_models(self, router):
        try:
            conn = http.client.HTTPConnection("127.0.0.1", router.port, timeout=2)
            conn.request("GET", "/models")
            response = conn.getresponse()
            payload = json.loads(response.read() or b"{}")
            conn.close()
        except Exception:
            return []
        out = []
        for item in payload.get("data", []):
            status = item.get("status") or {}
            if status.get("value") == "loaded":
                out.append(item.get("id"))
        return [m for m in out if m]

    def run_slot_kv(self, action, router, model):
        try:
            result = subprocess.run(
                [sys.executable, self.slot_kv, action,
                 "--url", self.router_base(router),
                 "--dir", self.slot_dir,
                 "--prefix", slot_prefix(model),
                 "--model", model],
                capture_output=True, text=True, timeout=15)
            line = (result.stdout or result.stderr or "").strip()
            if line:
                log("slot %s %s: %s" % (action, os.path.basename(model), line))
        except Exception as error:
            log("slot %s failed for %s: %s" % (action, model, error))

    def save_slots(self, router):
        if not self.prompt_cache or router is None:
            return
        for model in self.loaded_models(router):
            self.run_slot_kv("save", router, model)

    def prepare_model(self, model):
        """Load the model (if needed) and restore its prompt cache once."""
        if not self.prompt_cache or self.active is None or not model:
            return
        router = self.active
        key = (router.build, model)
        with self.prepare_cond:
            # Concurrent first requests for the same model must not all load
            # and restore it: one does the work, the others wait.
            while key in self.preparing:
                self.prepare_cond.wait(timeout=0.5)
            if key in self.restored:
                return
            self.preparing.add(key)
        try:
            try:
                body = json.dumps({"model": model}).encode()
                conn = http.client.HTTPConnection("127.0.0.1", router.port, timeout=300)
                conn.request("POST", "/models/load", body=body,
                             headers={"Content-Type": "application/json"})
                response = conn.getresponse()
                response.read()
                conn.close()
            except Exception as error:
                log("preload failed for %s: %s" % (model, error))
            self.run_slot_kv("restore", router, model)
        finally:
            with self.prepare_cond:
                self.preparing.discard(key)
                self.restored.add(key)
                self.prepare_cond.notify_all()

    def acquire(self, build):
        with self.cond:
            self.inflight[build] = self.inflight.get(build, 0) + 1
            while True:
                active = self.active
                if active is not None and active.build == build and not self.switching:
                    return
                if self.switching:
                    self.cond.wait(timeout=0.2)
                    continue
                if active is not None:
                    if self.inflight.get(active.build, 0) > 0:
                        self.cond.wait(timeout=0.2)
                        continue
                self.switching = True
                old = active
                break

        try:
            if old is not None:
                try:
                    self.save_slots(old)
                finally:
                    old.stop()
            router = self.routers[build]
            router.start(self.models_for(build))
            router.wait_ready()
        except Exception:
            with self.cond:
                # The old router is already stopped; leaving it as active would
                # forward the next request to a dead port.
                self.active = None
                self.switching = False
                self.cond.notify_all()
            raise

        with self.cond:
            self.active = router
            self.restored = set()
            self.switching = False
            self.cond.notify_all()
        log("active build: %s (pid %s, port %s)" % (build, router.proc.pid, router.port))

    def release(self, build):
        with self.cond:
            current = self.inflight.get(build, 0)
            self.inflight[build] = max(0, current - 1)
            self.cond.notify_all()

    def close(self):
        with self.cond:
            self.closing = True
            self.cond.notify_all()
        if self.active is not None:
            active = self.active
            self.active = None
            try:
                self.save_slots(active)
            finally:
                active.stop()

    def state(self):
        active = self.active
        return {
            "active_build": active.build if active else None,
            "router_pid": active.proc.pid if active and active.proc else None,
            "router_port": active.port if active else None,
            "switching": self.switching,
            "inflight": dict(self.inflight),
            "models": len(self.models),
        }


class RelayHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    @property
    def relay(self):
        return self.server.relay

    def _json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def _read_body(self):
        if (self.headers.get("Transfer-Encoding") or "").lower() == "chunked":
            raise ValueError("chunked request bodies are not supported by the spike")
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_PUT(self):
        self._handle("PUT")

    def do_PATCH(self):
        self._handle("PATCH")

    def do_DELETE(self):
        self._handle("DELETE")

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def _handle(self, method):
        try:
            body = self._read_body()
        except ValueError as error:
            return self._json({"error": {"message": str(error), "type": "invalid_request_error"}}, 411)

        url = urlsplit(self.path)
        path = url.path

        if method == "GET" and path in LOCAL_GET:
            return self._local_get(path)
        if method == "OPTIONS":
            return None

        model_name = None
        if method in ("POST", "PUT", "PATCH") and body:
            try:
                parsed = json.loads(body)
            except Exception:
                return self._json({"error": {"message": "invalid JSON body", "type": "invalid_request_error"}}, 400)
            if isinstance(parsed, dict):
                model_name = parsed.get("model")
        if model_name is None:
            query = parse_qs(url.query)
            values = query.get("model") or []
            model_name = values[0] if values else None

        model = self.relay.pick_model(model_name)
        if model is None:
            return self._json(
                {"error": {"message": "model not found; pass a catalog model id", "type": "invalid_request_error"}},
                404,
            )

        build = model["build"]

        # Status/metrics reads must never drive a build switch: the panel polls
        # /slots?model=<selected> while a request runs on another build, and
        # taking that as intent caused an endless switch loop. Serve the read
        # from the active router only when it owns the model's build.
        # Every GET is diagnostic/polling. Only POST (inference, explicit
        # load/unload) expresses "serve this model now"; a metrics probe must
        # never drag the relay back to the previously selected build.
        read_only = method == "GET"
        if read_only:
            active = self.relay.active
            if active is None or active.build != build:
                return self._json({"error": {"message": "model build is not active", "type": "invalid_request_error"}}, 404)
            return self._forward(method, self.path, body, build)

        try:
            self.relay.acquire(build)
        except Exception as error:
            log("router %s failed: %s" % (build, error))
            self.relay.release(build)
            return self._json({"error": {"message": str(error), "type": "server_error"}}, 502)

        try:
            self.relay.prepare_model(model["id"])
            self._forward(method, self.path, body, build)
        finally:
            self.relay.release(build)

    def _local_get(self, path):
        relay = self.relay
        if path in ("/spike/state", "/admin/state"):
            return self._json(relay.state())
        if path == "/health":
            return self._json({"status": "ok", "active_build": relay.state()["active_build"]})
        if path in ("/v1/models", "/models"):
            statuses = relay.statuses()
            data = []
            for model in relay.models:
                item = {
                    "id": model["id"],
                    "object": "model",
                    "created": 0,
                    "owned_by": "local",
                    "path": model.get("path", model["id"]),
                    "build": model["build"],
                    "aliases": list(model.get("aliases") or []),
                    "status": statuses.get(model["id"], {"value": "unloaded"}),
                }
                data.append(item)
            return self._json({"object": "list", "data": data})
        return self._json({"error": "not found"}, 404)

    def _forward(self, method, path, body, build):
        relay = self.relay
        router = relay.active
        if router is None:
            return self._json({"error": {"message": "no active router", "type": "server_error"}}, 503)

        headers = {}
        for key, value in self.headers.items():
            if key.lower() in HOP_BY_HOP:
                continue
            headers[key] = value
        headers["Accept-Encoding"] = "identity"

        conn = http.client.HTTPConnection("127.0.0.1", router.port, timeout=600)
        try:
            conn.request(method, path, body=body if body else None, headers=headers)
            response = conn.getresponse()
            content_type = response.getheader("Content-Type") or ""
            streaming = (
                "text/event-stream" in content_type
                or (response.getheader("Transfer-Encoding") or "").lower() == "chunked"
                or response.getheader("Content-Length") is None
            )

            self.send_response(response.status, response.reason)
            for key, value in response.getheaders():
                if key.lower() in {"connection", "transfer-encoding", "content-length", "keep-alive"}:
                    continue
                self.send_header(key, value)
            self.send_header("Connection", "close")
            self.close_connection = True

            if not streaming:
                payload = response.read()
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                self.wfile.flush()
                return

            self.end_headers()
            try:
                while True:
                    chunk = response.read(4096)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
        finally:
            conn.close()


class RelayServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, relay):
        self.relay = relay
        super().__init__(address, RelayHandler)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--port", type=int, default=None)
    parser.add_argument("--state-dir", default=None)
    args = parser.parse_args()

    with open(args.config, "r", encoding="utf-8") as handle:
        config = json.load(handle)

    state_dir = args.state_dir or tempfile.mkdtemp(prefix="dsh-relay-spike-")
    os.makedirs(state_dir, exist_ok=True)
    relay = Relay(config, state_dir)

    listen = config.get("listen") or {}
    host = listen.get("host", "127.0.0.1")
    port = args.port if args.port is not None else int(listen.get("port", 8080))
    server = RelayServer((host, port), relay)
    with open(relay.port_file, "w", encoding="utf-8") as handle:
        handle.write(str(server.server_address[1]))

    def stop(_sig, _frame):
        log("shutting down")
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    print(
        "[relay] listening on http://%s:%d (state %s)"
        % (host, server.server_address[1], state_dir),
        flush=True,
    )
    try:
        server.serve_forever()
    finally:
        relay.close()
        server.server_close()


if __name__ == "__main__":
    main()
