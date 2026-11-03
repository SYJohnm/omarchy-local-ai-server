#!/usr/bin/env bash
# Smoke test: the installed llama-server really accepts the preset INI shape
# the spike generates, lists the models as unloaded, and renders our keys into
# the child argv (ctx-size, n-gpu-layers, jinja).
#
# Usage: spike/check_native_router.sh [path-to-llama-server]
set -euo pipefail

BIN="${1:-${LLAMA_SERVER:-llama-server}}"
if ! command -v "$BIN" >/dev/null 2>&1 && [ ! -x "$BIN" ]; then
  echo "llama-server not found: $BIN" >&2
  exit 1
fi

TMP="$(mktemp -d)"
PORT="$(python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
)"
MODEL="$TMP/fake model.gguf"

cat > "$TMP/preset.ini" <<EOF
version = 1

[*]
c = 4096

[$MODEL]
model = $MODEL
ngl = 0
jinja = true
EOF

"$BIN" --host 127.0.0.1 --port "$PORT" --models-preset "$TMP/preset.ini" \
  --models-max 1 --models-memory-margin 0 >"$TMP/router.log" 2>&1 &
PID=$!
cleanup() {
  kill "$PID" 2>/dev/null || true
  sleep 0.3
  kill -9 "$PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

for _ in $(seq 1 60); do
  if curl -sf -m 1 "http://127.0.0.1:$PORT/models" >"$TMP/models.json" 2>/dev/null; then
    break
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "router exited during startup:" >&2
    tail -20 "$TMP/router.log" >&2
    exit 1
  fi
  sleep 0.2
done

python3 - "$TMP/models.json" "$MODEL" <<'PY'
import json
import sys

path, model = sys.argv[1], sys.argv[2]
data = json.load(open(path))["data"]
entry = next((item for item in data if item["id"] == model), None)
assert entry is not None, "preset model missing from /models: %r" % (data,)
assert entry["status"]["value"] == "unloaded", entry["status"]
args = entry["status"]["args"]
for expected in ("--ctx-size", "4096", "--n-gpu-layers", "0", "--jinja"):
    assert expected in args, "missing %r in rendered args: %r" % (expected, args)
print("native router OK: %s listed as unloaded with rendered args" % model)
PY
