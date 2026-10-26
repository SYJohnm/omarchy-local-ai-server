const test = require("node:test")
const assert = require("node:assert")
const Migration = require("../Migration.js")
const LS = require("../LlamaSwap.js")

const CHAT = "/models/chat.gguf"
const OTHER = "/models/other.gguf"
const DEC = "/models/decision.gguf"

function serviceModels(result, which) {
  return LS.parseConfig(which === "systemone" ? result.systemone.text : result.main.text).models
}

function findModel(result, which, path) {
  return serviceModels(result, which).filter(function(m) { return m.modelPath === path })[0]
}

function settingsV3(overrides) {
  return Object.assign({
    version: 3,
    backend: "llamacpp",
    host: "127.0.0.1",
    backendPorts: { llamacpp: "8080", systemone: "8081", ollama: "11434" },
    selectedModel: CHAT,
    systemoneModel: DEC,
    systemoneCtx: "4096",
    profiles: {
      ["llamacpp::" + CHAT]: {
        gpuLayers: "99", contextSize: "80000", threads: "7",
        cacheTypeK: "f16", cacheTypeV: "f16",
        llamaBuild: "/opt/fork/llama-server",
        extraEnv: "FOO=bar",
        customParams: [{ key: "--jinja", value: "true" }]
      },
      ["systemone::" + DEC]: { gpuLayers: "0", parallel: "2" },
      ["ollama::qwen3:8b"]: { contextSize: "4096" }
    }
  }, overrides || {})
}

const builds = [{ path: "/opt/fork/llama-server", fork: "turbo", real: "/opt/fork/llama-server" }]
const scan = { models: [CHAT, OTHER], visionDirs: { "/models": "/models/mmproj.gguf" }, mtpDirs: {} }

test("needsMigration only for a settings file older than the router format", () => {
  assert.strictEqual(Migration.needsMigration(null), false)
  assert.strictEqual(Migration.needsMigration({ version: 3 }), true)
  assert.strictEqual(Migration.needsMigration({ version: 3, configVersion: 4 }), false)
})

test("v3 profiles become managed blocks with their tuning", () => {
  const out = Migration.plan({ settings: settingsV3(), builds, scan })

  const chat = findModel(out, "main", CHAT)
  assert.ok(chat)
  assert.strictEqual(chat.managedPath, CHAT)
  assert.strictEqual(chat.id, "chat")
  assert.ok(chat.cmd.indexOf("/opt/fork/llama-server") === 0)
  assert.ok(chat.cmd.indexOf("--ctx-size 80000") !== -1)
  assert.ok(chat.cmd.indexOf("--gpu-layers 99") !== -1)
  assert.ok(chat.cmd.indexOf("--threads 7") !== -1)
  assert.ok(chat.cmd.indexOf("--jinja") !== -1)
  assert.ok(chat.cmd.indexOf("--mmproj /models/mmproj.gguf") !== -1)
  assert.deepStrictEqual(chat.env, ["FOO=bar"])
  assert.deepStrictEqual(out.main.preload, ["chat"])

  // A model nobody tuned is still routed, on defaults.
  const other = findModel(out, "main", OTHER)
  assert.ok(other)
  assert.strictEqual(other.managedPath, OTHER)
  assert.ok(other.cmd.indexOf("--ctx-size") === -1)
  assert.ok(other.cmd.indexOf("--gpu-layers -1") !== -1)
})

test("System One gets only its own models, with its own context", () => {
  const out = Migration.plan({ settings: settingsV3(), builds, scan })
  const models = serviceModels(out, "systemone")
  assert.deepStrictEqual(models.map(function(m) { return m.id }), ["decision"])
  const dec = models[0]
  assert.ok(dec.cmd.indexOf("--ctx-size 4096") !== -1)
  assert.ok(dec.cmd.indexOf("--parallel 2") !== -1)
  assert.ok(dec.cmd.indexOf("--mmproj") === -1)
  assert.deepStrictEqual(out.systemone.preload, ["decision"])
})

test("a shared scan does not leak chat models into System One", () => {
  const out = Migration.plan({
    settings: { version: 3, selectedModel: CHAT, systemoneModel: DEC, profiles: {} },
    builds, scan
  })
  assert.deepStrictEqual(
    serviceModels(out, "systemone").map(function(m) { return m.modelPath }), [DEC])
})

test("a dedicated System One directory contributes its models", () => {
  const out = Migration.plan({
    settings: {
      version: 3, selectedModel: CHAT, systemoneModel: DEC,
      systemoneModelsDir: "/decisions", profiles: {}
    },
    builds, scan,
    systemoneScan: { models: [DEC, "/decisions/other.gguf"], visionDirs: {}, mtpDirs: {} }
  })
  assert.deepStrictEqual(
    serviceModels(out, "systemone").map(function(m) { return m.modelPath }),
    [DEC, "/decisions/other.gguf"])
})

test("v1 flat settings keep the selected model tuned and default the rest", () => {
  const out = Migration.plan({
    settings: {
      version: 2, backend: "llamacpp", selectedModel: "/models/tuned.gguf",
      contextSize: "12000", threads: "6"
    },
    builds,
    scan: { models: ["/models/tuned.gguf", "/models/plain.gguf"], visionDirs: {}, mtpDirs: {} }
  })
  const tuned = findModel(out, "main", "/models/tuned.gguf")
  assert.ok(tuned.cmd.indexOf("--ctx-size 12000") !== -1)
  assert.ok(tuned.cmd.indexOf("--threads 6") !== -1)
  const plain = findModel(out, "main", "/models/plain.gguf")
  assert.ok(plain.cmd.indexOf("--ctx-size") === -1)
  assert.ok(plain.cmd.indexOf("--threads") === -1)
  assert.deepStrictEqual(out.main.preload, ["tuned"])
})

test("a profile whose model is gone is skipped and reported", () => {
  const out = Migration.plan({
    settings: {
      version: 3, selectedModel: "", profiles: {
        ["llamacpp::/models/gone.gguf"]: { contextSize: "4096" }
      }
    },
    builds,
    scan: { models: ["/models/ok.gguf"], visionDirs: {}, mtpDirs: {} }
  })
  assert.deepStrictEqual(serviceModels(out, "main").map(function(m) { return m.id }), ["ok"])
  assert.ok(out.report.indexOf("/models/gone.gguf") !== -1)
  assert.ok(out.report.indexOf("model file not found") !== -1)
})

test("a hand-written block is never overwritten", () => {
  const existing = [
    "models:",
    "  \"chat\":",
    "    cmd: /usr/bin/llama-server --port ${PORT} --model " + CHAT,
    ""
  ].join("\n")
  const out = Migration.plan({
    settings: { version: 3, selectedModel: CHAT, profiles: {} },
    builds, scan, existingMain: existing
  })
  assert.ok(out.main.text.indexOf(existing.split("\n")[2]) !== -1)
  assert.ok(out.main.text.indexOf("# managed: " + CHAT) === -1)
  assert.ok(out.report.indexOf("already a hand-written model") !== -1)
})

test("running the migration again changes nothing", () => {
  const first = Migration.plan({ settings: settingsV3(), builds, scan })
  const second = Migration.plan({
    settings: settingsV3(), builds, scan,
    existingMain: first.main.text,
    existingSystemone: first.systemone.text
  })
  assert.strictEqual(second.main.text, first.main.text)
  assert.strictEqual(second.systemone.text, first.systemone.text)
  assert.deepStrictEqual(second.main.preload, ["chat"])
  assert.deepStrictEqual(second.systemone.preload, ["decision"])
})

test("editing one migrated model keeps the others and the user's settings", () => {
  const first = Migration.plan({ settings: settingsV3(), builds, scan })
  const changed = settingsV3({
    profiles: Object.assign({}, settingsV3().profiles, {
      ["llamacpp::" + CHAT]: { contextSize: "16000" }
    })
  })
  const second = Migration.plan({
    settings: changed, builds, scan,
    existingMain: "# mine\n" + first.main.text
  })
  assert.ok(second.main.text.indexOf("# mine") !== -1)
  assert.ok(second.main.text.indexOf("--ctx-size 16000") !== -1)
  assert.ok(second.main.text.indexOf("--ctx-size 80000") === -1)
  assert.ok(findModel(second, "main", OTHER))
})

test("a pinned build that vanished is still used, with a warning", () => {
  const settings = settingsV3()
  settings.profiles["llamacpp::" + CHAT].llamaBuild = "/opt/gone/llama-server"
  const out = Migration.plan({ settings, builds, scan })
  const chat = findModel(out, "main", CHAT)
  assert.ok(chat.cmd.indexOf("/opt/gone/llama-server") === 0)
  assert.ok(out.report.indexOf("was not detected") !== -1)
})

test("ollama-only settings produce no llama models", () => {
  const out = Migration.plan({
    settings: { version: 3, backend: "ollama", selectedModel: "qwen3:8b", profiles: {} },
    builds,
    scan: { models: [CHAT], visionDirs: {}, mtpDirs: {} }
  })
  // The shared scan still routes llama.cpp models if any were found; the
  // ollama model name must not become one.
  assert.deepStrictEqual(serviceModels(out, "main").map(function(m) { return m.modelPath }), [CHAT])
  assert.strictEqual(out.listen.ollama.port, "11434")
})

test("empty settings still produce valid router configs", () => {
  const out = Migration.plan({ settings: { version: 3 }, builds: [], scan: { models: [] } })
  const main = LS.parseConfig(out.main.text)
  assert.strictEqual(main.models.length, 0)
  assert.deepStrictEqual(main.preload, [])
  assert.ok(out.main.text.indexOf("startPort: 5800") !== -1)
  assert.ok(out.systemone.text.indexOf("startPort: 5900") !== -1)
})

test("malformed env is reported, valid entries survive", () => {
  const settings = settingsV3()
  settings.profiles["llamacpp::" + CHAT].extraEnv = "GOOD=1 BROKEN"
  settings.profiles["llamacpp::" + CHAT].customParams = []
  const out = Migration.plan({ settings, builds, scan })
  const chat = findModel(out, "main", CHAT)
  assert.deepStrictEqual(chat.env, ["GOOD=1"])
  assert.ok(out.report.indexOf("BROKEN") !== -1)
})

test("custom params survive the move into cmd", () => {
  const out = Migration.plan({ settings: settingsV3(), builds, scan })
  const chat = findModel(out, "main", CHAT)
  assert.ok(chat.cmd.indexOf("--jinja true") !== -1)
})

test("ports come from the old settings and are reported", () => {
  const settings = settingsV3({ backendPorts: { llamacpp: "9000", systemone: "9001", ollama: "11434" } })
  const out = Migration.plan({
    settings, builds, scan,
    ports: settings.backendPorts
  })
  assert.strictEqual(out.listen.main.port, "9000")
  assert.strictEqual(out.listen.systemone.port, "9001")
  assert.ok(out.report.indexOf("main 9000") !== -1)
})
