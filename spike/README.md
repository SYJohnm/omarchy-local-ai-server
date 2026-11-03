# Spike: native llama-server router + build relay

Status: **proof of concept** on `spike/native-router`. Nothing here is wired
into the widget yet; `Panel.qml`, `LlamaSwap.js` and the manifest are untouched.

The question: can we drop llama-swap, use `llama-server` router mode, and still
serve models from several builds/forks behind **one port**?

The blocker in llama.cpp is that a router launches every child with **its own
binary** (`bin_path = get_server_exec_path()` in `tools/server/server-models.cpp`),
and a preset cannot name another executable. The relay solves that by running
**one router per build** and keeping the public port itself.

## What the spike proves

- **Preset generation** (`preset.js`): `version = 1`, an optional `[*]`, one
  section per model, path as section id (so path-based clients keep working),
  `model` / `mmproj` / `model-draft` and arbitrary CLI keys, router-reserved
  keys dropped, deterministic output.
- **Native compatibility** (`check_native_router.sh`): the installed
  `llama-server` accepts that INI, lists the model as `unloaded`, and renders
  `--ctx-size`, `--n-gpu-layers`, `--jinja` into the child argv.
- **One port, two builds** (`relay_test.py`): the relay aggregates a catalog
  from both builds, routes a chat request to the right build, stops the old
  router and starts the new one, and keeps answering on the public port while
  that happens.
- **Drain**: an in-flight request on the previous build finishes before its
  router is stopped; the request for the new build waits for it instead of
  getting a connection refused.
- **Real model**: validated once against the mounted library with
  `LFM3-Omni-2B-Q8_0` on the main build (`8642541b2`): the router listed it as
  `unloaded`, loaded it on the first chat request and answered in ~1.9 s.

Measured locally (fake routers, 4 tests): catalog, routing/switch, drain and
port-open, health/metrics proxy — all pass in ~5.5 s.

## Design

```
client ──► :8080  relay  (owns the public port for its whole lifetime)
                     │
                     ├── catalog: model id / path / aliases → build
                     ├── active = one Router at a time
                     │
                     ├── router "main"  :5801  preset main.ini  env main
                     └── router "turbo" :5802  preset turbo.ini env turbo
```

Rules:

- **One active router at a time.** No cross-build VRAM conflict; the native
  router still handles `--models-max`, `--models-memory-margin` and `--fit`
  inside its build. Sleep is deliberately disabled: the relay owns idle
  unloading because it must save prompt-cache slots before a model goes away.
- **Model switch inside a build**: native, no restart.
- **Build switch**: drain the old build → stop its router → start the target
  router → wait for `/models` → forward. The public port never closes.
- **Env is per build** (router process env), which is what forks need.
- `/v1/models` and `/models` come from the catalog, with statuses merged from
  the active router; other builds show `unloaded`.
- `spike.config.json` shows the production shape: `binary`, `preset`, `port`,
  `args`, `env`. The `command` field used by the tests is a test seam only.

## Run

```sh
# preset generator (Node)
node --test spike/preset.test.js

# relay end-to-end (Python, fake routers, ~6 s)
python3 spike/relay_test.py

# real router accepts the generated INI shape
spike/check_native_router.sh /home/sxy/llama.cpp/build/bin/llama-server
```

## Limits of this spike

- JSON request bodies are read whole; **chunked request bodies are rejected**
  (411). SSE responses stream chunk by chunk, both directions.
- No auth, TLS or CORS beyond a permissive `OPTIONS`; bind loopback.
- Switch policy is last-request-wins: interleaved requests for two builds can
  thrash. Production needs a debounce or a sticky window.
- No TTL yet: sleep is disabled, so the relay will implement idle unload and
  save the prompt cache before calling `/models/unload`.
- Metrics are the active build's; a multi-build gauge would need aggregation.
- The catalog is static config; production generates it from the model scan and
  rewrites each build's INI when tuning/model selection changes.

## Next steps (outside this branch)

1. Generate per-build INIs from `Backends.resolveBuild` + `Params`/`buildArgs`;
   strip router-reserved keys.
2. Replace the systemd unit's `llama-swap -config …` with the relay; routers are
   its children. `survive shell restart` then applies to the relay.
3. Panel: replace llama-swap `/running`, `/logs`, `loadUrl`/`unloadUrl` with the
   catalog plus native `/models`, `/models/load`, `/models/unload`.
4. Migration: read the old YAML, split managed blocks by binary into builds,
   write INIs + profiles; keep path aliases.
5. Hooks/scripts: same endpoint, add `build` per model in the JSON.

## Notes

- `./spike/check_native_router.sh` uses a fake model path on purpose: the
  router lists presets without loading them, so this validates the INI and the
  rendered argv without touching VRAM.
- The real `llama-router` (per-model `spawn.command`) was proposed in
  [ggml-org/llama.cpp#17629](https://github.com/ggml-org/llama.cpp/pull/17629)
  and closed unmerged, so it is not a dependency option.
