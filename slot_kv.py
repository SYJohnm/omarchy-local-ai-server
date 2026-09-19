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
import urllib.error
import urllib.request


def call(url, method="GET", body=None, timeout=10):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"null")
        except ValueError:
            return e.code, None


def slot_ids(base):
    status, data = call(base + "/slots")
    if status != 200 or not isinstance(data, list):
        return []
    return [s["id"] for s in data if isinstance(s, dict) and isinstance(s.get("id"), int)]


def save(base, slot_dir, prefix):
    saved, notes = 0, []
    for sid in slot_ids(base):
        name = "%s.slot%d.bin" % (prefix, sid)
        tmp = name + ".tmp"
        status, data = call("%s/slots/%d?action=save" % (base, sid), "POST", {"filename": tmp}, timeout=120)
        n = int(data.get("n_saved") or 0) if status == 200 and isinstance(data, dict) else 0
        tmp_path = os.path.join(slot_dir, tmp)
        try:
            if n > 0:
                os.replace(tmp_path, os.path.join(slot_dir, name))
                saved += n
                notes.append("slot %d: %d tokens" % (sid, n))
            elif os.path.exists(tmp_path):
                os.unlink(tmp_path)
        except OSError as e:
            notes.append("slot %d: %s" % (sid, e))
    return "saved %d tokens%s" % (saved, " (" + ", ".join(notes) + ")" if notes else "")


def restore(base, slot_dir, prefix):
    restored, notes = 0, []
    for sid in slot_ids(base):
        candidates = ["%s.slot%d.bin" % (prefix, sid)]
        if sid == 0:
            candidates.append("%s.slot.bin" % prefix)
        name = next((c for c in candidates if os.path.exists(os.path.join(slot_dir, c))), None)
        if name is None:
            continue
        status, data = call("%s/slots/%d?action=restore" % (base, sid), "POST", {"filename": name}, timeout=300)
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
    args = ap.parse_args()

    base = args.url.rstrip("/")
    try:
        line = (save if args.action == "save" else restore)(base, args.dir, args.prefix)
    except (OSError, ValueError) as e:
        line = "%s failed: %s" % (args.action, e)
    print(line)
    sys.stdout.flush()


if __name__ == "__main__":
    main()
