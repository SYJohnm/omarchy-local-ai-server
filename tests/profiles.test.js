const test = require("node:test")
const assert = require("node:assert")
const Profiles = require("../Profiles.js")

// The live property object Panel.qml snapshots from.
function live(overrides) {
  return Object.assign({
    gpuLayers: "-1", threads: "7", contextSize: "80000",
    batchSize: "1024", ubatchSize: "512",
    cacheTypeK: "turbo4", cacheTypeV: "turbo3", cacheRam: "", temperature: "0.6",
    cpuMoe: true, nCpuMoe: "", noRepack: true,
    loadMode: "mmap", flashAttn: "on", specType: "draft-mtp", specTypeUserSet: true,
    extraArgs: "-np 1", keepAlive: "",
    hiddenBuiltins: ["threads"], builtinStash: { threads: "4" },
    customParams: [{ key: "--parallel", value: "2" }]
  }, overrides || {})
}

test("a profile is keyed by backend as well as model", () => {
  // The same weights reachable both ways still need two profiles: one is argv
  // flags, the other environment variables.
  assert.notStrictEqual(
    Profiles.key("llamacpp", "qwen3:8b"),
    Profiles.key("ollama", "qwen3:8b"))
  // No model, no key -- the caller stores against the defaults instead.
  assert.strictEqual(Profiles.key("llamacpp", ""), "")
})

test("rekey moves a System One profile to the model it now keys on", () => {
  const from = live()
  const store = Profiles.set({}, "systemone", "/m/chat.gguf", from)

  const moved = Profiles.rekey(store, "systemone", "/m/chat.gguf", "/m/decision.gguf")
  assert.deepStrictEqual(Profiles.get(moved, "systemone", "/m/decision.gguf"), Profiles.resolve(from))
  assert.strictEqual(Profiles.get(moved, "systemone", "/m/chat.gguf"), null)

  // A target that already has a profile wins; the other one is left alone.
  const both = Profiles.set(moved, "systemone", "/m/chat.gguf", live({ threads: "9" }))
  const kept = Profiles.rekey(both, "systemone", "/m/chat.gguf", "/m/decision.gguf")
  assert.strictEqual(Profiles.get(kept, "systemone", "/m/decision.gguf"),
                     Profiles.get(both, "systemone", "/m/decision.gguf"))
  assert.notStrictEqual(Profiles.get(kept, "systemone", "/m/chat.gguf"), null)

  // Nothing to move, or nowhere to move it.
  assert.strictEqual(Profiles.rekey(both, "systemone", "", "/m/x.gguf"), both)
  assert.strictEqual(Profiles.rekey(both, "systemone", "/m/chat.gguf", ""), both)
})

test("snapshot copies structured fields rather than aliasing them", () => {
  const source = live()
  const snap = Profiles.snapshot(source)
  source.customParams.push({ key: "--threads-http", value: "4" })
  source.hiddenBuiltins.push("ngl")
  source.builtinStash.threads = "99"
  assert.deepStrictEqual(snap.customParams, [{ key: "--parallel", value: "2" }])
  assert.deepStrictEqual(snap.hiddenBuiltins, ["threads"])
  assert.deepStrictEqual(snap.builtinStash, { threads: "4" })
})

test("resolve fills fields a stored profile predates", () => {
  // A profile written before the plugin gained a field must not leave that
  // field holding whatever the previously selected model set it to.
  const resolved = Profiles.resolve({ contextSize: "4096" })
  assert.strictEqual(resolved.contextSize, "4096")
  assert.strictEqual(resolved.flashAttn, "auto")
  assert.strictEqual(resolved.cpuMoe, false)
  assert.deepStrictEqual(resolved.customParams, [])
})

test("set and remove return new stores, leaving the old one intact", () => {
  // QML re-evaluates bindings on assignment, not mutation.
  const empty = {}
  const one = Profiles.set(empty, "llamacpp", "/models/qwen.gguf", live())
  assert.deepStrictEqual(empty, {})
  assert.strictEqual(Profiles.has(one, "llamacpp", "/models/qwen.gguf"), true)

  const gone = Profiles.remove(one, "llamacpp", "/models/qwen.gguf")
  assert.strictEqual(Profiles.has(gone, "llamacpp", "/models/qwen.gguf"), false)
  assert.strictEqual(Profiles.has(one, "llamacpp", "/models/qwen.gguf"), true)
})

test("one model's tuning does not reach another", () => {
  let store = {}
  store = Profiles.set(store, "llamacpp", "/models/qwen35b.gguf", live({ contextSize: "80000", cpuMoe: true }))
  store = Profiles.set(store, "llamacpp", "/models/minicpm.gguf", live({ contextSize: "8192", cpuMoe: false }))
  assert.strictEqual(Profiles.get(store, "llamacpp", "/models/qwen35b.gguf").contextSize, "80000")
  assert.strictEqual(Profiles.get(store, "llamacpp", "/models/minicpm.gguf").contextSize, "8192")
  assert.strictEqual(Profiles.get(store, "llamacpp", "/models/qwen35b.gguf").cpuMoe, true)
  assert.strictEqual(Profiles.get(store, "llamacpp", "/models/minicpm.gguf").cpuMoe, false)
})

test("a model with no profile reports none rather than an empty one", () => {
  assert.strictEqual(Profiles.get({}, "llamacpp", "/models/unknown.gguf"), null)
  assert.strictEqual(Profiles.has({}, "llamacpp", "/models/unknown.gguf"), false)
  // Which is what lets the panel fall back to resolve(null).
})



test("migrating a pre-profile settings file keeps the tuned model tuned", () => {
  // The one flat tuning set in an older file was tuned for the model it names,
  // so it becomes that model's profile.
  const parsed = { version: 2, backend: "llamacpp", selectedModel: "/models/minicpm.gguf" }
  const { profiles } = Profiles.fromSettings(parsed, Profiles.snapshot(live()))
  assert.strictEqual(Profiles.get(profiles, "llamacpp", "/models/minicpm.gguf").cacheTypeK, "turbo4")
  // The profile is seeded from the live values, not a separate defaults store.
  assert.strictEqual(Profiles.get(profiles, "llamacpp", "/models/minicpm.gguf").contextSize, "80000")
})

test("migrating a file with no selected model writes no profile", () => {
  const { profiles } = Profiles.fromSettings(
    { version: 2, backend: "llamacpp" }, Profiles.snapshot(live()))
  assert.deepStrictEqual(profiles, {})
})

test("a v3 file round-trips", () => {
  const parsed = {
    version: 3,
    backend: "ollama",
    profiles: { "llamacpp::/models/qwen.gguf": { contextSize: "80000" } }
  }
  const { profiles } = Profiles.fromSettings(parsed, Profiles.snapshot(live({ contextSize: "8192" })))
  assert.strictEqual(Profiles.get(profiles, "llamacpp", "/models/qwen.gguf").contextSize, "80000")
})
