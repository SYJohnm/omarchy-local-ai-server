const test = require("node:test")
const assert = require("node:assert")
const fs = require("node:fs")
const http = require("node:http")
const net = require("node:net")
const os = require("node:os")
const path = require("node:path")
const { spawn, execFileSync } = require("node:child_process")
const Backends = require("../Backends.js")
const Model = require("../Model.js")

// ---- Pure helpers ----

test("installedBackends offers only backends with a binary", () => {
  const ids = (list) => list.map((b) => b.id)
  assert.deepStrictEqual(ids(Backends.installedBackends({ llamacpp: true, ollama: false }, true)), ["llamacpp"])
  assert.deepStrictEqual(ids(Backends.installedBackends({ llamacpp: false, ollama: true }, true)), ["ollama"])
  // Not probed yet: nothing is known, so nothing is hidden.
  assert.deepStrictEqual(ids(Backends.installedBackends({}, false)), ["llamacpp", "ollama"])
  // Nothing installed: keep both, so the binary settings still make sense.
  assert.deepStrictEqual(ids(Backends.installedBackends({}, true)), ["llamacpp", "ollama"])
})

test("statusLabel names the restart wait", () => {
  assert.strictEqual(Model.statusLabel(true, false, 0, "draining", 1), "Restarting · waiting for 1 request")
  assert.strictEqual(Model.statusLabel(true, false, 0, "draining", 2), "Restarting · waiting for 2 requests")
  assert.strictEqual(Model.statusLabel(true, false, 0, "", 0), "Running")
  assert.strictEqual(Model.statusLabel(false, true, 3, "", 0), "Starting… 3s")
})

test("slotPrefix is the model's file name, made filename-safe", () => {
  assert.strictEqual(Backends.slotPrefix("/m/Qwen 3.6 (Q4).gguf"), "Qwen_3.6__Q4_.gguf")
  assert.strictEqual(Backends.slotPrefix(""), "")
})

// ---- slot_kv.py against a fake llama-server ----

const SLOT_KV = path.join(__dirname, "..", "slot_kv.py")
const FAKE = path.join(__dirname, "fixtures", "fake_backend.py")

function freePort() {
  return new Promise((resolve) => {
    const srv = net.createServer().listen(0, "127.0.0.1", () => {
      const port = srv.address().port
      srv.close(() => resolve(port))
    })
  })
}

function post(port, body) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, path: "/completion", method: "POST" }, (res) => {
      res.resume()
      res.on("end", resolve)
    })
    req.on("error", reject)
    req.end(JSON.stringify(body || {}))
  })
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function startFake(t, name, slotDir) {
  const port = await freePort()
  const proc = spawn("python3", [FAKE, String(port)],
    { env: { ...process.env, NAME: name, SLOT_DIR: slotDir }, stdio: ["ignore", "pipe", "pipe"] })
  t.after(() => proc.kill("SIGTERM"))
  for (let i = 0; i < 50; i++) {
    const up = await new Promise((resolve) => {
      http.get({ host: "127.0.0.1", port, path: "/health" }, (res) => { res.resume(); resolve(res.statusCode === 200) })
        .on("error", () => resolve(false))
    })
    if (up) break
    await sleep(100)
  }
  return { port, stop: () => proc.kill("SIGTERM") }
}

function slotKv(action, port, dir, prefix) {
  return execFileSync("python3", [SLOT_KV, action, "--url", "http://127.0.0.1:" + port,
    "--dir", dir, "--prefix", prefix], { encoding: "utf8" }).trim()
}

function tmpDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "lai-slotkv-"))
}

test("save writes one file per non-empty slot and no stray .tmp", async (t) => {
  const dir = tmpDir()
  const srv = await startFake(t, "A", dir)
  await post(srv.port)
  const out = slotKv("save", srv.port, dir, "A.gguf")
  assert.match(out, /^saved 100 tokens/)
  assert.deepStrictEqual(fs.readdirSync(dir).sort(), ["A.gguf.slot0.bin"])
})

test("restore brings a saved cache back into a fresh server", async (t) => {
  const dir = tmpDir()
  const first = await startFake(t, "A", dir)
  await post(first.port)
  await post(first.port)
  slotKv("save", first.port, dir, "A.gguf")
  first.stop()
  const second = await startFake(t, "A", dir)
  assert.match(slotKv("restore", second.port, dir, "A.gguf"), /^restored 200 tokens/)
})

test("an empty save never overwrites a good cache", async (t) => {
  const dir = tmpDir()
  const first = await startFake(t, "A", dir)
  await post(first.port)
  slotKv("save", first.port, dir, "A.gguf")
  first.stop()
  const second = await startFake(t, "A", dir)
  // Nothing processed yet: slot 0 is empty, so the 100-token file must survive.
  assert.match(slotKv("save", second.port, dir, "A.gguf"), /^saved 0 tokens/)
  assert.match(slotKv("restore", second.port, dir, "A.gguf"), /^restored 100 tokens/)
})

test("restore falls back to the old single-file name for slot 0", async (t) => {
  const dir = tmpDir()
  fs.writeFileSync(path.join(dir, "A.gguf.slot.bin"), JSON.stringify({ model: "A", tokens: 42 }))
  const srv = await startFake(t, "A", dir)
  assert.match(slotKv("restore", srv.port, dir, "A.gguf"), /slot 0 <- A\.gguf\.slot\.bin: 42 tokens/)
})

test("a cache the server rejects is reported, not fatal", async (t) => {
  const dir = tmpDir()
  fs.writeFileSync(path.join(dir, "A.gguf.slot0.bin"), JSON.stringify({ model: "B", tokens: 5 }))
  const srv = await startFake(t, "A", dir)
  assert.match(slotKv("restore", srv.port, dir, "A.gguf"), /slot 0 rejected/)
})

test("nothing saved and nothing reachable both exit cleanly", async (t) => {
  const dir = tmpDir()
  const srv = await startFake(t, "A", dir)
  assert.strictEqual(slotKv("restore", srv.port, dir, "A.gguf"), "no saved cache for A.gguf")
  const dead = await freePort()
  assert.match(slotKv("save", dead, dir, "A.gguf"), /^save failed: /)
})

// ---- llama.cpp builds ----

const BASE = { path: "/h/llama.cpp/build/bin/llama-server", real: "/h/llama.cpp/build/bin/llama-server",
  fork: "llama.cpp", commit: "662a0b0", date: "2026-08-31", gpu: "CUDA",
  cacheTypes: ["f32", "f16", "q8_0", "q4_0"] }
const TURBO = { path: "/h/tq/build/bin/llama-server", real: "/h/tq/build/bin/llama-server",
  fork: "llama-cpp-turboquant-cuda", commit: "424c3361e", date: "2026-09-02", gpu: "CUDA",
  cacheTypes: ["f32", "f16", "q8_0", "q4_0", "turbo4", "vbr"] }

test("auto picks the first build that accepts the cache types", () => {
  assert.strictEqual(Backends.resolveBuild([BASE, TURBO], "", "f16", "f16"), BASE)
  assert.strictEqual(Backends.resolveBuild([BASE, TURBO], "", "turbo4", "turbo4"), TURBO)
  assert.strictEqual(Backends.resolveBuild([BASE, TURBO], "", "q8_0", "vbr"), TURBO)
  // Nothing accepts it: still launchable on the first build, which reports why.
  assert.strictEqual(Backends.resolveBuild([BASE, TURBO], "", "nope", "f16"), BASE)
  assert.strictEqual(Backends.resolveBuild([], "", "f16", "f16"), null)
})

test("an explicit build wins, matched by path or real path", () => {
  assert.strictEqual(Backends.resolveBuild([BASE, TURBO], TURBO.path, "f16", "f16"), TURBO)
  const linked = Object.assign({}, TURBO, { path: "/h/.local/bin/llama-server" })
  assert.strictEqual(Backends.resolveBuild([BASE, linked], TURBO.real, "f16", "f16"), linked)
  // A build that has since disappeared falls back to auto.
  assert.strictEqual(Backends.resolveBuild([BASE], "/gone/llama-server", "f16", "f16"), BASE)
})

test("cache types follow the chosen build; auto offers every build's", () => {
  assert.deepStrictEqual(Backends.buildCacheTypes([BASE, TURBO], BASE.path), BASE.cacheTypes)
  assert.deepStrictEqual(Backends.buildCacheTypes([BASE, TURBO], ""),
    ["f32", "f16", "q8_0", "q4_0", "turbo4", "vbr"])
})

test("a build with an unreadable --help is not ruled out", () => {
  const blind = { path: "/x", cacheTypes: [] }
  assert.ok(Backends.buildSupports(blind, ["turbo4"]))
  assert.strictEqual(Backends.resolveBuild([blind, TURBO], "", "turbo4", "turbo4"), blind)
})

test("buildLabel names fork, short commit, date and GPU", () => {
  assert.strictEqual(Backends.buildLabel(TURBO), "llama-cpp-turboquant-cuda · 424c336 · 2026-09-02 · CUDA")
  assert.strictEqual(Backends.buildLabel({ fork: "llama.cpp (system package)", gpu: "CPU" }),
    "llama.cpp (system package) · CPU")
})
