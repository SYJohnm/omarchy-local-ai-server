const test = require("node:test")
const assert = require("node:assert")
const LS = require("../LlamaSwap.js")

const MODEL = "/models/qwen3-35b-a3b.gguf"

function tuning(overrides) {
  return Object.assign(LS.defaults(), overrides || {})
}

// The config a user might hand-write around the plugin's blocks.
const CONFIG = [
  "# my router",
  "healthCheckTimeout: 600",
  "models:",
  "  # hand-written, no marker: never rewritten",
  "  \"chat\":",
  "    cmd: |",
  "      /usr/bin/llama-server --port ${PORT} --model /m/chat.gguf",
  "    ttl: 300",
  "",
  "  # managed: /m/qwen.gguf",
  "  \"qwen\":",
  "    cmd: |-",
  "      /usr/bin/llama-server --port ${PORT} --model /m/qwen.gguf --ctx-size 4096",
  "    env: [\"A=1\"]",
  "",
  "hooks:",
  "  on_startup:",
  "    preload: [\"qwen\"]",
  ""
].join("\n")

test("shellQuote and shellSplit round-trip every word the config can hold", () => {
  const words = [
    "/models/a.gguf", "/models/with space/b.gguf", "/models/it's.gguf",
    "/models/$HOME.gguf", "/models/a\\b", "/models/a;b", "/models/a&b",
    "-1", "", "${PORT}", "--alias", "a model with # and ~"
  ]
  for (const word of words) {
    assert.deepStrictEqual(LS.shellSplit(LS.shellQuote(word)), [word], word)
  }
  assert.deepStrictEqual(LS.shellSplit("a  b\tc"), ["a", "b", "c"])
  assert.deepStrictEqual(LS.shellSplit("'a b' \"c d\" e"), ["a b", "c d", "e"])
})

test("buildArgs emits the tuning flags with the router's port macro", () => {
  const out = LS.buildArgs({
    modelPath: MODEL,
    tuning: tuning({
      gpuLayers: "99", contextSize: "80000", threads: "7",
      batchSize: "1024", ubatchSize: "512", flashAttn: "on",
      cacheTypeK: "turbo4", cacheTypeV: "turbo3", parallel: "2",
      temperature: "0.7", nCpuMoe: "12", noRepack: true,
      reasoningPreserve: "on", specType: "draft-mtp"
    }),
    mtpDirs: { "/models": "/models/qwen3-35b-a3b-mtp.gguf" }
  })
  assert.deepStrictEqual(out.args.slice(0, 4), ["--port", "${PORT}", "--model", MODEL])
  assert.deepStrictEqual(out.args, [
    "--port", "${PORT}", "--model", MODEL,
    "--gpu-layers", "99",
    "--cache-type-k", "turbo4", "--cache-type-v", "turbo3",
    "--flash-attn", "on", "--load-mode", "auto",
    "--model-draft", "/models/qwen3-35b-a3b-mtp.gguf",
    "--parallel", "2",
    "--reasoning-preserve",
    "--threads", "7",
    "--n-cpu-moe", "12", "--no-repack",
    "--spec-type", "draft-mtp",
    "--ctx-size", "80000",
    "--batch-size", "1024", "--ubatch-size", "512", "--temp", "0.7"
  ])
  assert.deepStrictEqual(out.ignored, [])
})

test("a flag the build does not know is dropped and reported", () => {
  const build = { flags: ["--port", "--model", "--ctx-size"] }
  const out = LS.buildArgs({
    modelPath: MODEL, build: build,
    tuning: tuning({ contextSize: "4096", threads: "8", noRepack: true })
  })
  assert.ok(out.args.indexOf("--threads") === -1)
  assert.ok(out.ignored.indexOf("--threads") !== -1)
  assert.ok(out.ignored.indexOf("--no-repack") !== -1)
  assert.ok(out.args.indexOf("--ctx-size") !== -1)
})

test("a custom parameter owns its flag and is always emitted", () => {
  const out = LS.buildArgs({
    modelPath: MODEL,
    tuning: tuning({ gpuLayers: "-1" }),
    customParams: [{ key: "--gpu-layers", value: "12" }, { key: "--jinja", value: "true" }],
    catalogue: []
  })
  const at = out.args.indexOf("--gpu-layers")
  assert.ok(at !== -1)
  assert.strictEqual(out.args[at + 1], "12")
  // Exactly once: the built-in was skipped, the custom one emitted.
  assert.strictEqual(out.args.filter(function(a) { return a === "--gpu-layers" }).length, 1)
  assert.ok(out.args.indexOf("--jinja") !== -1)
})

test("a cmd round-trips through the tuning pages", () => {
  const before = tuning({
    gpuLayers: "99", contextSize: "80000", threads: "7",
    batchSize: "1024", flashAttn: "on", cacheTypeK: "turbo4",
    cacheTypeV: "turbo3", parallel: "2", temperature: "0.7",
    nCpuMoe: "12", noRepack: true, reasoningPreserve: "off",
    mmprojMode: "custom", mmprojPath: "/models/mmproj with space.gguf",
    specType: "draft-mtp", draftPath: "/models/draft.gguf",
    extraArgs: "--threads-http 4; --alias 'my model'",
    extraEnv: "LLAMA_ARG_FOO=bar"
  })
  const cmd = LS.modelCommand("/opt/llama b/llama-server", { modelPath: MODEL, tuning: before })
  const parsed = LS.parseCmd(cmd.cmd)

  assert.strictEqual(parsed.binary, "/opt/llama b/llama-server")
  assert.strictEqual(parsed.modelPath, MODEL)
  assert.strictEqual(parsed.portSeen, true)
  assert.strictEqual(parsed.tuning.extraArgs, "--threads-http 4;--alias 'my model'")
  assert.deepStrictEqual(cmd.env, ["LLAMA_ARG_FOO=bar"])

  const again = LS.buildArgs({ modelPath: parsed.modelPath, tuning: parsed.tuning })
  assert.deepStrictEqual(again.args, LS.buildArgs({ modelPath: MODEL, tuning: before }).args)
})

test("parseCmd drops what llama-swap owns but keeps the model path", () => {
  const parsed = LS.parseCmd(
    "llama-server --host 0.0.0.0 --port ${PORT} --slot-save-path /s --metrics " +
    "--model \"/m/it's here.gguf\" --ctx-size 2048")
  assert.strictEqual(parsed.modelPath, "/m/it's here.gguf")
  assert.strictEqual(parsed.tuning.contextSize, "2048")
  assert.strictEqual(parsed.tuning.extraArgs, "")
})

test("parseConfig finds managed and user blocks without confusing them", () => {
  const parsed = LS.parseConfig(CONFIG)
  assert.strictEqual(parsed.models.length, 2)

  const chat = parsed.models[0]
  assert.strictEqual(chat.id, "chat")
  assert.strictEqual(chat.managedPath, "")
  assert.strictEqual(chat.modelPath, "/m/chat.gguf")

  const qwen = parsed.models[1]
  assert.strictEqual(qwen.id, "qwen")
  assert.strictEqual(qwen.managedPath, "/m/qwen.gguf")
  assert.strictEqual(qwen.modelPath, "/m/qwen.gguf")
  assert.strictEqual(qwen.tuning.contextSize, "4096")
  assert.deepStrictEqual(qwen.env, ["A=1"])
  assert.deepStrictEqual(parsed.preload, ["qwen"])
})

test("updating a managed block leaves every other line alone", () => {
  const out = LS.setManagedModel(CONFIG, {
    path: "/m/qwen.gguf", id: "qwen",
    cmd: "/usr/bin/llama-server --port ${PORT} --model /m/qwen.gguf --ctx-size 8192",
    env: ["B=2"]
  })
  assert.strictEqual(out.action, "updated")
  assert.ok(out.text.indexOf("# my router") !== -1)
  assert.ok(out.text.indexOf("ttl: 300") !== -1)
  assert.ok(out.text.indexOf("hand-written, no marker") !== -1)
  assert.ok(out.text.indexOf("--ctx-size 8192") !== -1)
  assert.ok(out.text.indexOf("--ctx-size 4096") === -1)

  const parsed = LS.parseConfig(out.text)
  assert.strictEqual(parsed.models.length, 2)
  assert.strictEqual(parsed.models[1].tuning.contextSize, "8192")
  assert.deepStrictEqual(parsed.models[1].env, ["B=2"])
})

test("a new model is added after the last one, before the next section", () => {
  const out = LS.setManagedModel(CONFIG, {
    path: "/m/new.gguf", id: "new",
    cmd: "/usr/bin/llama-server --port ${PORT} --model /m/new.gguf"
  })
  assert.strictEqual(out.action, "added")
  const parsed = LS.parseConfig(out.text)
  assert.deepStrictEqual(parsed.models.map(function(m) { return m.id }), ["chat", "qwen", "new"])
  // The hooks section stays below the models.
  assert.ok(out.text.indexOf("hooks:") > out.text.indexOf("\"new\":"))
  assert.deepStrictEqual(parsed.preload, ["qwen"])
})

test("a hand-written model id is never reused or overwritten", () => {
  const out = LS.setManagedModel(CONFIG, {
    path: "/m/other.gguf", id: "chat",
    cmd: "/usr/bin/llama-server --port ${PORT} --model /m/other.gguf"
  })
  assert.strictEqual(out.id, "chat-2")
  const parsed = LS.parseConfig(out.text)
  assert.strictEqual(parsed.models.length, 3)
  const chat = parsed.models.filter(function(m) { return m.id === "chat" })[0]
  assert.strictEqual(chat.managedPath, "")
  assert.strictEqual(chat.modelPath, "/m/chat.gguf")
})

test("a config without a models section gains one", () => {
  const out = LS.setManagedModel("healthCheckTimeout: 60\n", {
    path: "/m/a.gguf", id: "a",
    cmd: "/usr/bin/llama-server --port ${PORT} --model /m/a.gguf"
  })
  assert.strictEqual(out.action, "added")
  const parsed = LS.parseConfig(out.text)
  assert.strictEqual(parsed.modelsLine, out.text.split("\n").indexOf("models:"))
  assert.strictEqual(parsed.models.length, 1)
  assert.strictEqual(parsed.models[0].managedPath, "/m/a.gguf")
})

test("removeManagedModel only removes plugin blocks", () => {
  const gone = LS.removeManagedModel(CONFIG, "/m/qwen.gguf")
  assert.strictEqual(gone.action, "removed")
  const parsed = LS.parseConfig(gone.text)
  assert.deepStrictEqual(parsed.models.map(function(m) { return m.id }), ["chat"])

  // By id too, so the UI can pass either.
  assert.strictEqual(LS.removeManagedModel(gone.text, "chat").action, "missing")
  assert.strictEqual(LS.removeManagedModel(CONFIG, "chat").action, "missing")
})

test("preload is written without touching the rest of the hooks block", () => {
  const added = LS.setPreload("models:\n  \"a\":\n    cmd: x\n", ["a"])
  assert.deepStrictEqual(LS.parsePreload(added.split("\n")), ["a"])
  assert.ok(added.indexOf("models:") === 0)

  const replaced = LS.setPreload(CONFIG, ["chat", "qwen"])
  assert.deepStrictEqual(LS.parsePreload(replaced.split("\n")), ["chat", "qwen"])

  const cleared = LS.setPreload(CONFIG, [])
  assert.deepStrictEqual(LS.parsePreload(cleared.split("\n")), [])
  assert.ok(cleared.indexOf("preload: []") !== -1)
})

test("other on_startup keys survive a preload rewrite", () => {
  const text = [
    "hooks:",
    "  on_startup:",
    "    other: keep",
    "    preload: [\"old\"]",
    "  on_shutdown:",
    "    other: also keep",
    ""
  ].join("\n")
  const out = LS.setPreload(text, ["new"])
  assert.ok(out.indexOf("other: keep") !== -1)
  assert.ok(out.indexOf("on_shutdown:") !== -1)
  assert.ok(out.indexOf("also keep") !== -1)
  assert.deepStrictEqual(LS.parsePreload(out.split("\n")), ["new"])
})

test("createConfig makes a valid empty router config", () => {
  const text = LS.createConfig({ startPort: 5900, preload: ["a"] })
  const parsed = LS.parseConfig(text)
  assert.strictEqual(parsed.modelsLine, parsed.text.split("\n").indexOf("models:"))
  assert.strictEqual(parsed.models.length, 0)
  assert.deepStrictEqual(parsed.preload, ["a"])
  assert.ok(text.indexOf("startPort: 5900") !== -1)
})

test("model ids are readable and unique", () => {
  assert.strictEqual(LS.modelId("/models/Qwen3 35B.gguf", {}), "Qwen3_35B")
  assert.strictEqual(LS.modelId("/models/a.gguf", { a: true }), "a-2")
  assert.strictEqual(LS.modelId("/models/a.gguf", { a: true, "a-2": true }), "a-3")
  assert.strictEqual(LS.modelId("", {}), "model")
})

test("the systemd unit is persistent and quotes its arguments", () => {
  const unit = LS.unitFile({
    binary: "/usr/bin/llama-swap",
    configPath: "/home/u/state with space/config.yaml",
    host: "127.0.0.1", port: 8080,
    workDir: "/home/u/state with space",
    env: ["HOME=/home/u", "A=100%"],
    label: "main"
  })
  assert.ok(unit.indexOf("ExecStart=\"/usr/bin/llama-swap\" -config \"/home/u/state with space/config.yaml\" -listen 127.0.0.1:8080") !== -1)
  assert.ok(unit.indexOf("Environment=\"A=100%%\"") !== -1)
  assert.ok(unit.indexOf("WantedBy=default.target") !== -1)
  assert.ok(unit.indexOf("Restart=on-failure") !== -1)
})

test("API URLs keep model ids usable as route segments", () => {
  assert.strictEqual(LS.encodeModel("author/model"), "author/model")
  assert.strictEqual(LS.encodeModel("a b/c"), "a%20b/c")
  assert.strictEqual(LS.loadUrl("127.0.0.1", 8080, "a b/c"),
                     "http://127.0.0.1:8080/upstream/a%20b/c/")
  assert.strictEqual(LS.unloadUrl("127.0.0.1", 8080, "a b/c"),
                     "http://127.0.0.1:8080/api/models/unload/a%20b/c")
  assert.strictEqual(LS.logsUrl("127.0.0.1", 8080, "m", false),
                     "http://127.0.0.1:8080/logs/stream/m?no-history")
  assert.strictEqual(LS.runningUrl("127.0.0.1", 8081), "http://127.0.0.1:8081/running")
  assert.strictEqual(LS.versionUrl("127.0.0.1", 8080), "http://127.0.0.1:8080/api/version")
})

test("parseRunning separates loading from loaded", () => {
  const text = JSON.stringify({ running: [
    { model: "loading", state: "starting", cmd: "x", proxy: "", ttl: 0 },
    { model: "ready", state: "ready", cmd: "y", proxy: "http://127.0.0.1:5801", ttl: 300 }
  ] })
  const list = LS.parseRunning(text)
  assert.strictEqual(list.length, 2)
  assert.strictEqual(list[1].proxy, "http://127.0.0.1:5801")
  assert.strictEqual(LS.runningModel(text).model, "ready")
  assert.strictEqual(LS.runningModel(JSON.stringify({ running: [{ model: "x", state: "starting" }] })).model, "x")
  assert.strictEqual(LS.runningModel(JSON.stringify({ running: [] })), null)
  assert.deepStrictEqual(LS.parseRunning("not json"), [])
})

test("the version gate reads both the CLI and the API", () => {
  assert.strictEqual(LS.versionNumber("version: v262 (abc123), built at 2026-01-01"), 262)
  assert.strictEqual(LS.versionNumber("version: v263-4-gdeadbeef"), 263)
  assert.strictEqual(LS.versionNumber('{"version":"v262","commit":"abc"}'), 262)
  assert.strictEqual(LS.versionNumber("devel"), 0)
  assert.strictEqual(LS.versionAtLeast('{"version":"v262"}', 262), true)
  assert.strictEqual(LS.versionAtLeast('{"version":"v261"}', 262), false)
  assert.strictEqual(LS.versionAtLeast("devel", 262), false)
})
