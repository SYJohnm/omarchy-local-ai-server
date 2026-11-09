// Router mode: models.ini data -> llama.cpp preset INI conversion and args.
const test = require("node:test")
const assert = require("node:assert")
const ModelsIni = require("../ModelsIni.js")
const Profiles = require("../Profiles.js")

const MODEL = "/models/Router-Case-Q4_K_M.gguf"

// fromProfiles() yields camelCase tuning keys.
const iniData = ModelsIni.fromProfiles({
  "llamacpp::/models/Test-Model-Q4_K_M.gguf": {
    alias: "test-model",
    contextSize: "131072",
    batchSize: "2048",
    ubatchSize: "0",
    gpuLayers: "-1",
    cacheTypeK: "f16",
    cacheTypeV: "f16",
    flashAttn: "on",
    loadMode: "auto",            // tri-state default: skipped
    cpuMoe: true,
    nCpuMoe: "38",
    noRepack: true,
    parallel: "",
    reasoningPreserve: "default",
    threads: "0",                // 0 = auto: skipped
    mmprojPath: "",
    mmprojMode: "auto",
    mmprojOffload: "off",
    extraArgs: "--context-shift --cache-reuse 256",
    llamaBuild: "",
    // proof these page-only fields never leak into the preset
    hiddenBuiltins: ["threads"],
    builtinStash: { x: 1 },
    specTypeUserSet: true
  },
  "llamacpp::/models/Second.gguf": {}
}, "")

function iniValue(m, alias, key) {
  const rx = new RegExp("\\[" + alias + "\\][\\s\\S]*?(?=\\n\\n|\\n\\[|$)")
  const m2 = rx.exec(m)
  assert.ok(m2, "section [" + alias + "] present")
  const kv = new RegExp("^" + key + " = (.+)$", "m")
  const v = kv.exec(m2[0])
  return v ? v[1] : null
}

test("tuning fields become llama.cpp long-flag keys with defaults skipped", () => {
  const ini = ModelsIni.toRouterIni(iniData)
  assert.match(ini, /^version = 1/)
  assert.equal(iniValue(ini, "test-model", "model"), "/models/Test-Model-Q4_K_M.gguf")
  assert.equal(iniValue(ini, "test-model", "ctx-size"), "131072")
  assert.equal(iniValue(ini, "test-model", "batch-size"), "2048")
  assert.equal(iniValue(ini, "test-model", "gpu-layers"), "-1")
  assert.equal(iniValue(ini, "test-model", "cache-type-k"), "f16")
  assert.equal(iniValue(ini, "test-model", "cpu-moe"), "true")
  assert.equal(iniValue(ini, "test-model", "n-cpu-moe"), "38")
  assert.equal(iniValue(ini, "test-model", "no-repack"), "true")
  assert.equal(iniValue(ini, "test-model", "flash-attn"), "on")
  // defaults, empties and page-only fields are dropped
  assert.equal(iniValue(ini, "test-model", "load-mode"), null)
  assert.equal(iniValue(ini, "test-model", "parallel"), null)
  assert.equal(iniValue(ini, "test-model", "threads"), null)
  assert.equal(iniValue(ini, "test-model", "ubatch-size"), null)
  assert.equal(iniValue(ini, "test-model", "reasoning-preserve"), null)
  assert.equal(iniValue(ini, "test-model", "hiddenBuiltins"), null)
  assert.equal(iniValue(ini, "test-model", "builtinStash"), null)
  // extra args re-emitted as INI pairs
  assert.equal(iniValue(ini, "test-model", "context-shift"), "true")
  assert.equal(iniValue(ini, "test-model", "cache-reuse"), "256")
})

test("a model without a profile gets only its path, under a derived alias", () => {
  const ini = ModelsIni.toRouterIni(iniData)
  assert.equal(iniValue(ini, "second", "model"), "/models/Second.gguf")
})

test("on/off flags use true/false or their no- form, and a duplicate alias is suffixed", () => {
  const src = ModelsIni.fromProfiles({
    "llamacpp::/models/Real.gguf": { alias: "dup", reasoningPreserve: "on" },
    "llamacpp::/models/Stale-Q4-K-M.gguf": { alias: "dup", reasoningPreserve: "off" },
    "llamacpp::/models/Other.gguf": { reasoningPreserve: "off" }
  }, "")
  const ini = ModelsIni.toRouterIni(src)
  assert.equal(iniValue(ini, "dup", "model"), "/models/Real.gguf")
  assert.equal(iniValue(ini, "dup", "reasoning-preserve"), "true")
  assert.equal(iniValue(ini, "dup", "no-reasoning-preserve"), null)
  assert.equal((ini.match(/^\[dup\]$/gm) || []).length, 1)
  // The second model keeps its section under a suffixed alias. Dropping it
  // made it unreachable by any name in router mode.
  assert.equal(iniValue(ini, "dup-2", "model"), "/models/Stale-Q4-K-M.gguf")
  assert.equal(iniValue(ini, "dup-2", "no-reasoning-preserve"), "true")
  assert.equal(iniValue(ini, "other", "no-reasoning-preserve"), "true")
})

test("routerLaunchArgs builds the native router argv", () => {
  const args = ModelsIni.routerLaunchArgs("/bin/llama-server", "127.0.0.1", 8080, "/tmp/router.ini", { modelsMax: 2 })
  assert.deepEqual(args,
    ["/bin/llama-server", "--host", "127.0.0.1", "--port", "8080",
     "--models-preset", "/tmp/router.ini", "--metrics", "--models-max", "2"])
})

test("generated preset is accepted by llama-server", () => {
  const fs = require("node:fs")
  const os = require("node:os")
  const path = require("node:path")
  const bin = "/home/sxy/llama.cpp/build/bin/llama-server"
  if (!fs.existsSync(bin)) return // machine without that build: skip
  const file = path.join(os.tmpdir(), "local-ai-router-test.ini")
  fs.writeFileSync(file, ModelsIni.toRouterIni(iniData))
  const { spawnSync } = require("node:child_process")
  // Start the real router briefly: a bad preset key aborts the process during
  // startup, before it ever attempts to load a model.
  const r = spawnSync(bin, ["--models-preset", file, "--host", "127.0.0.1", "--port", "0"], {
    encoding: "utf8", timeout: 5000, killSignal: "SIGKILL"
  })
  const out = String(r.stderr || "") + String(r.stdout || "")
  assert.doesNotMatch(out, /not recognized in preset|failed to parse server config/i)
  fs.unlinkSync(file)
})

test("extra args split on semicolons, as they are stored everywhere else", () => {
  // Model.splitExtraArgs is the storage format. Splitting on whitespace alone
  // put the semicolon inside the value ("temp = 0.5;") and turned a bare ";"
  // into its own key.
  const profiles = Profiles.setFor({}, "llamacpp", MODEL, "", { extraArgs: "--temp 0.5; --no-warmup" })
  const lines = ModelsIni.toRouterIni(ModelsIni.fromProfiles(profiles, MODEL)).split("\n")
  assert.ok(lines.includes("temp = 0.5"), lines.join("\n"))
  assert.ok(lines.includes("no-warmup = true"), lines.join("\n"))
  assert.ok(!lines.some(l => /;/.test(l)), "no semicolon may survive into a key or value")
})

test("the projector follows its mode instead of any stored path", () => {
  const stored = { mmprojPath: "/m/stale-proj.gguf" }
  const render = (tuning, autoMmproj) => {
    const profiles = Profiles.setFor({}, "llamacpp", MODEL, "", tuning)
    const data = ModelsIni.fromProfiles(profiles, MODEL)
    if (autoMmproj !== undefined) data.models[MODEL].autoMmproj = autoMmproj
    return ModelsIni.toRouterIni(data).split("\n").filter(l => /mmproj/.test(l))
  }
  // "off" used to emit no-mmproj AND mmproj = <path>, which contradict.
  assert.deepStrictEqual(render(Object.assign({ mmprojMode: "off" }, stored)), ["no-mmproj = true"])
  // "auto" used to emit the custom path the user had switched away from.
  assert.deepStrictEqual(render(Object.assign({ mmprojMode: "auto" }, stored)), [])
  // "auto" with a projector beside the model must match the direct launch,
  // which passes --mmproj <detected>; otherwise vision dies behind the router.
  assert.deepStrictEqual(
    render(Object.assign({ mmprojMode: "auto" }, stored), "/m/beside-proj.gguf"),
    ["mmproj = /m/beside-proj.gguf", "no-mmproj-offload = true"])
  assert.deepStrictEqual(render(Object.assign({ mmprojMode: "custom" }, stored)),
    ["mmproj = /m/stale-proj.gguf", "no-mmproj-offload = true"])
})

test("two models with the same file name both reach the preset", () => {
  // The default alias is the base name. Skipping the collision dropped the
  // second model from the preset entirely -- unreachable by any name.
  const a = "/models/a/Qwen3-8B-Q4_K_M.gguf"
  const b = "/mnt/nvme/Qwen3-8B-Q4_K_M.gguf"
  let profiles = Profiles.setFor({}, "llamacpp", a, "", { threads: "4" })
  profiles = Profiles.setFor(profiles, "llamacpp", b, "", { threads: "8" })
  const ini = ModelsIni.toRouterIni(ModelsIni.fromProfiles(profiles, a))
  assert.ok(ini.includes("model = " + a), ini)
  assert.ok(ini.includes("model = " + b), ini)
  const sections = ini.split("\n").filter(l => l.startsWith("["))
  assert.strictEqual(new Set(sections).size, 2, "both sections, distinct aliases: " + sections)
})
