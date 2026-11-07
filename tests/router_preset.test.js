// Router mode: models.ini data -> llama.cpp preset INI conversion and args.
const test = require("node:test")
const assert = require("node:assert")
const ModelsIni = require("../ModelsIni.js")

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

test("on/off flags use true/false or their no- form, and duplicate aliases collapse", () => {
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
