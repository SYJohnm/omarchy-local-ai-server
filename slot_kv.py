#!/usr/bin/env python3
"""Saves or restores every llama-server slot's KV cache, then exits.

    slot_kv.py save    --url http://127.0.0.1:8080 --dir SLOT_DIR --prefix PREFIX
    slot_kv.py restore --url http://127.0.0.1:8080 --dir SLOT_DIR --prefix PREFIX

The prompt cache is what makes a restart expensive -- re-reading a long agent
prompt costs minutes on a small GPU, reloading the weights does not -- so the
widget saves it before stopping or restarting a server and restores it once the
new one answers /health. SLOT_DIR must be the server's --slot-save-path: the
server itself writes and reads the files, this only names them.

Files are "<prefix>.slot<N>.bin", one per slot. A save goes to a .tmp name and
is renamed only once the server reports tokens written, so an empty or failed
save never overwrites a good cache. Restore falls back to "<prefix>.slot.bin",
the single-file name older versions of the widget used for slot 0.

Prints one summary line; always exits 0, because a cache that cannot be saved
or restored only costs a cold start and must never block a stop or a start.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# One slow slot used to hold Stop for two minutes, and four slots for eight.
# The cache is a convenience; a stop must finish even when the server is
# wedged. shortcut: 60 s for a save and 120 s for a restore, then give up.
SAVE_BUDGET = 60
RESTORE_BUDGET = 120

# /slots and the save/restore replies are tiny. A misconfigured or hostile
# endpoint must not be able to make this helper read an unbounded body into
# memory: the timeout bounds time, not bytes. Apply the same cap to HTTP error
# bodies, which also come from the endpoint.
MAX_RESPONSE_BYTES = 1 << 20


def read_body(stream, headers, limit=MAX_RESPONSE_BYTES):
    """Read at most `limit` bytes, refusing a lying/oversized Content-Length."""
    value = headers.get("Content-Length") if headers is not None else None
    if value is not None:
        try:
            length = int(value)
        except (TypeError, ValueError):
            raise ValueError("invalid Content-Length")
        if length < 0 or length > limit:
            raise ValueError("response too large")
    data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError("response too large")
    return data


def check_url(url):
    """Accept only a plain http(s) endpoint.

    The URL is built by the widget from host:port, so this is defence in depth
    rather than a fix for a known path: urlopen also speaks file:, ftp: and
    data:, and a scheme that reached here from a settings file copied between
    machines would make this helper read a local file and POST nothing.
    """
    parsed = urllib.parse.urlsplit(str(url))
    if parsed.scheme not in ("http", "https"):
        raise ValueError("endpoint must be http or https")
    if not parsed.netloc:
        raise ValueError("endpoint has no host")
    return url


def with_model(url, model):
    if not model:
        return url
    return url + ("&" if "?" in url else "?") + "model=" + urllib.parse.quote(model, safe="")


def call(url, method="GET", body=None, timeout=10):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(read_body(resp, resp.headers) or b"null")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(read_body(e, e.headers) or b"null")
        except ValueError:
            return e.code, None


def slot_ids(base, model=""):
    status, data = call(with_model(base + "/slots", model))
    if status != 200 or not isinstance(data, list):
        return []
    return [s["id"] for s in data if isinstance(s, dict) and isinstance(s.get("id"), int)]


def private_dir(path):
    """Create the cache directory private, and repair an existing one."""
    os.makedirs(path, mode=0o700, exist_ok=True)
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass


def save(base, slot_dir, prefix, model=""):
    saved, notes = 0, []
    private_dir(slot_dir)
    deadline = time.monotonic() + SAVE_BUDGET
    for sid in slot_ids(base, model):
        left = deadline - time.monotonic()
        if left <= 0:
            notes.append("deadline reached")
            break
        name = "%s.slot%d.bin" % (prefix, sid)
        tmp = name + ".tmp"
        body = {"filename": tmp}
        if model:
            body["model"] = model
        status, data = call("%s/slots/%d?action=save" % (base, sid), "POST",
                            body, timeout=min(120, max(1, int(left))))
        n = int(data.get("n_saved") or 0) if status == 200 and isinstance(data, dict) else 0
        tmp_path = os.path.join(slot_dir, tmp)
        try:
            if n > 0:
                final_path = os.path.join(slot_dir, name)
                os.replace(tmp_path, final_path)
                # The server writes the file; this process narrows it again in
                # case the launch umask was permissive.
                try:
                    os.chmod(final_path, 0o600)
                except OSError:
                    pass
                saved += n
                notes.append("slot %d: %d tokens" % (sid, n))
            elif os.path.exists(tmp_path):
                os.unlink(tmp_path)
        except OSError as e:
            notes.append("slot %d: %s" % (sid, e))
    return "saved %d tokens%s" % (saved, " (" + ", ".join(notes) + ")" if notes else "")


def restore(base, slot_dir, prefix, model=""):
    restored, notes = 0, []
    deadline = time.monotonic() + RESTORE_BUDGET
    for sid in slot_ids(base, model):
        left = deadline - time.monotonic()
        if left <= 0:
            notes.append("deadline reached")
            break
        candidates = ["%s.slot%d.bin" % (prefix, sid)]
        if sid == 0:
            candidates.append("%s.slot.bin" % prefix)
        name = next((c for c in candidates if os.path.exists(os.path.join(slot_dir, c))), None)
        if name is None:
            continue
        body = {"filename": name}
        if model:
            body["model"] = model
        status, data = call("%s/slots/%d?action=restore" % (base, sid), "POST",
                            body, timeout=min(300, max(1, int(left))))
        if status == 200 and isinstance(data, dict):
            n = int(data.get("n_restored") or 0)
            restored += n
            notes.append("slot %d <- %s: %d tokens" % (sid, name, n))
        else:
            # Saved under different tuning (cache type, context size): it does
            # not fit this server, and the start is simply cold.
            notes.append("slot %d rejected %s" % (sid, name))
    if not notes:
        return "no saved cache for " + prefix
    return "restored %d tokens (%s)" % (restored, ", ".join(notes))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("action", choices=["save", "restore"])
    ap.add_argument("--url", required=True, help="server base URL, e.g. http://127.0.0.1:8080")
    ap.add_argument("--dir", required=True, help="the server's --slot-save-path")
    ap.add_argument("--prefix", required=True, help="file prefix, normally the model's file name")
    ap.add_argument("--model", default="", help="router model id; required when the URL is a router")
    args = ap.parse_args()

    # Literal prompt tokens live in the slot files; never create artifacts
    # readable by another local user.
    os.umask(0o077)
    try:
        base = check_url(args.url.rstrip("/"))
    except ValueError as e:
        print("%s failed: %s" % (args.action, e))
        sys.stdout.flush()
        return
    try:
        line = (save if args.action == "save" else restore)(base, args.dir, args.prefix, args.model)
    except (OSError, ValueError) as e:
        line = "%s failed: %s" % (args.action, e)
    print(line)
    sys.stdout.flush()


if __name__ == "__main__":
    main()
