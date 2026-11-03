#!/usr/bin/env python3
"""End-to-end tests for the native-router spike relay.

Runs the relay as a real process with two fake llama-server routers (one per
build). Covers: catalog aggregation, model routing, build switching, draining
an in-flight request before stopping its router, and keeping the public port
open while the switch happens.
"""
import http.client
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
RELAY = os.environ.get("RELAY", str(HERE / "relay.py"))
FAKE = str(HERE / "fake_router.py")

MAIN_MODELS = ["/models/main-a.gguf", "/models/main-b.gguf"]
TURBO_MODELS = ["/models/turbo-a.gguf"]


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def request(port, method, path, body=None, timeout=30):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    headers = {}
    payload = None
    if body is not None:
        payload = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    conn.request(method, path, body=payload, headers=headers)
    response = conn.getresponse()
    data = response.read()
    headers_out = dict(response.getheaders())
    conn.close()
    return response.status, headers_out, data


def chat(port, model, stream=True):
    status, _headers, data = request(
        port,
        "POST",
        "/v1/chat/completions",
        {"model": model, "messages": [{"role": "user", "content": "hi"}], "stream": stream},
    )
    return status, data.decode("utf-8", "replace")


def state(port):
    status, _headers, data = request(port, "GET", "/spike/state")
    assert status == 200, (status, data)
    return json.loads(data)


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


class RelaySpikeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="relay-spike-test-")
        cls.dir = Path(cls.tmp.name)
        cls.relay_port = free_port()
        main_port = free_port()
        turbo_port = free_port()
        cls.config = {
            "listen": {"host": "127.0.0.1", "port": cls.relay_port},
            "start_timeout_s": 10,
            "stop_timeout_s": 5,
            "drain_timeout_s": 10,
            "default_model": "/models/main-a.gguf",
            "prompt_cache": False,
            "routers": {
                "main": {
                    "port": main_port,
                    "command": [
                        sys.executable, FAKE, "--build", "main",
                        "--port", "{port}", "--preset", "{preset}",
                        "--models", "{models}", "--delay", "0.7",
                    ],
                },
                "turbo": {
                    "port": turbo_port,
                    "command": [
                        sys.executable, FAKE, "--build", "turbo",
                        "--port", "{port}", "--preset", "{preset}",
                        "--models", "{models}",
                    ],
                },
            },
            "models": [
                {"id": MAIN_MODELS[0], "path": MAIN_MODELS[0], "build": "main", "aliases": ["main-a"]},
                {"id": MAIN_MODELS[1], "path": MAIN_MODELS[1], "build": "main"},
                {"id": TURBO_MODELS[0], "path": TURBO_MODELS[0], "build": "turbo", "aliases": ["turbo-a"]},
            ],
        }
        config_path = cls.dir / "config.json"
        config_path.write_text(json.dumps(cls.config, indent=2))

        cls.log_path = cls.dir / "relay.log"
        cls.log = cls.log_path.open("wb")
        cls.relay = subprocess.Popen(
            [sys.executable, RELAY, "--config", str(config_path), "--state-dir", str(cls.dir)],
            stdout=cls.log,
            stderr=subprocess.STDOUT,
        )
        port_file = cls.dir / "relay.port"
        deadline = time.time() + 15
        while time.time() < deadline:
            if cls.relay.poll() is not None:
                raise RuntimeError("relay exited\n" + cls.tail())
            if port_file.exists() and port_file.read_text().strip():
                break
            time.sleep(0.05)
        else:
            raise RuntimeError("relay did not write its port\n" + cls.tail())
        cls.port = int(port_file.read_text().strip())

        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                if state(cls.port):
                    break
            except Exception:
                time.sleep(0.05)

    @classmethod
    def tail(cls):
        try:
            return cls.log_path.read_text(errors="replace")[-4000:]
        except OSError:
            return ""

    @classmethod
    def tearDownClass(cls):
        if cls.relay.poll() is None:
            cls.relay.terminate()
            try:
                cls.relay.wait(timeout=10)
            except subprocess.TimeoutExpired:
                cls.relay.kill()
                cls.relay.wait(timeout=5)
        try:
            cls.log.close()
        except Exception:
            pass
        cls.tmp.cleanup()

    def test_catalog_lists_every_build(self):
        status, _headers, data = request(self.port, "GET", "/v1/models")
        self.assertEqual(status, 200)
        payload = json.loads(data)
        ids = {item["id"] for item in payload["data"]}
        self.assertEqual(ids, set(MAIN_MODELS + TURBO_MODELS))
        builds = {item["id"]: item["build"] for item in payload["data"]}
        self.assertEqual(builds[MAIN_MODELS[0]], "main")
        self.assertEqual(builds[TURBO_MODELS[0]], "turbo")

    def test_model_routes_to_its_build_and_switches_router(self):
        status, body = chat(self.port, MAIN_MODELS[0])
        self.assertEqual(status, 200)
        self.assertIn("hello from main", body)
        first = state(self.port)
        self.assertEqual(first["active_build"], "main")
        main_pid = first["router_pid"]

        status, body = chat(self.port, TURBO_MODELS[0])
        self.assertEqual(status, 200)
        self.assertIn("hello from turbo", body)
        second = state(self.port)
        self.assertEqual(second["active_build"], "turbo")
        self.assertNotEqual(second["router_pid"], main_pid)
        deadline = time.time() + 5
        while time.time() < deadline and pid_alive(main_pid):
            time.sleep(0.05)
        self.assertFalse(pid_alive(main_pid), "previous build router must be stopped")

    def test_inflight_request_drains_and_public_port_stays_open(self):
        # Warm the main build so the slow request does not pay a switch.
        self.assertEqual(chat(self.port, MAIN_MODELS[0])[0], 200)
        self.assertEqual(state(self.port)["active_build"], "main")

        result = {}

        def slow_main():
            started = time.time()
            status, body = chat(self.port, MAIN_MODELS[0])
            result["main"] = (status, body, time.time() - started)

        worker = threading.Thread(target=slow_main)
        worker.start()
        time.sleep(0.15)

        observed_open = []
        stop_poll = threading.Event()

        def poll_state():
            while not stop_poll.is_set():
                try:
                    observed_open.append(state(self.port))
                except Exception:
                    time.sleep(0.02)
                time.sleep(0.05)

        poller = threading.Thread(target=poll_state)
        poller.start()
        started = time.time()
        status, body = chat(self.port, TURBO_MODELS[0])
        elapsed = time.time() - started
        stop_poll.set()
        poller.join()
        worker.join(timeout=10)

        self.assertEqual(status, 200)
        self.assertIn("hello from turbo", body)
        self.assertEqual(result["main"][0], 200)
        self.assertIn("hello from main", result["main"][1])
        # The turbo request had to wait for the slow main request, then switch.
        self.assertGreaterEqual(elapsed, 0.4)
        self.assertGreaterEqual(result["main"][2], 0.5)
        self.assertTrue(observed_open, "state endpoint must answer during the switch")
        self.assertTrue(any(s.get("switching") for s in observed_open), "a switch should have been observed")
        self.assertEqual(state(self.port)["active_build"], "turbo")

    def test_health_and_metrics_proxy(self):
        status, _headers, data = request(self.port, "GET", "/health")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data)["status"], "ok")

        self.assertEqual(chat(self.port, MAIN_MODELS[0])[0], 200)
        status, _headers, data = request(self.port, "GET", "/metrics?model=" + MAIN_MODELS[0])
        self.assertEqual(status, 200)
        self.assertIn(b"llama_prompt_tokens_per_seconds", data)


if __name__ == "__main__":
    unittest.main(verbosity=2)
