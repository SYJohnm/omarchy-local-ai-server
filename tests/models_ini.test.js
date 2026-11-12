const test = require("node:test")
const assert = require("node:assert")
const ModelsIni = require("../ModelsIni.js")

test("deriveDefaultAlias cleans common quantization and model names", () => {
  assert.strictEqual(
    ModelsIni.deriveDefaultAlias("/path/to/Qwen3.8-35B-A3B-Q4_K_M.gguf"),
    "qwen3.8-35b-a3b"
  )
  assert.strictEqual(
    ModelsIni.deriveDefaultAlias("LFM3-Omni-2B-Q8_0.gguf"),
    "lfm3-omni-2b"
  )
  assert.strictEqual(
    ModelsIni.deriveDefaultAlias("DeepSeek-R1-Distill-Qwen-14B-IQ4_NL.gguf"),
    "deepseek-r1-distill-qwen-14b"
  )
  assert.strictEqual(
    ModelsIni.deriveDefaultAlias("Mistral-7B-Instruct-v0.3.BF16.gguf"),
    "mistral-7b-instruct-v0.3"
  )
})

test("parse and serialize round-trips model and fork sections", () => {
  const iniText = `# Comment
[models."/m/qwen.gguf"]
alias = qwen-custom
preferred_build = /bin/llama-turbo
threads = 4
gpu_layers = -1
cpu_moe = false

[models."/m/qwen.gguf"::turboquant]
cache_type_k = turbo4
cache_type_v = turbo3
ctx_size = 95000
cpu_moe = true
`
  const parsed = ModelsIni.parse(iniText)
  assert.ok(parsed.models["/m/qwen.gguf"])
  assert.strictEqual(parsed.models["/m/qwen.gguf"].common.alias, "qwen-custom")
  assert.strictEqual(parsed.models["/m/qwen.gguf"].common.preferredBuild, "/bin/llama-turbo")
  assert.strictEqual(parsed.models["/m/qwen.gguf"].common.threads, "4")
  assert.strictEqual(parsed.models["/m/qwen.gguf"].common.cpuMoe, false)

  assert.ok(parsed.models["/m/qwen.gguf"].forks.turboquant)
  assert.strictEqual(parsed.models["/m/qwen.gguf"].forks.turboquant.cacheTypeK, "turbo4")
  assert.strictEqual(parsed.models["/m/qwen.gguf"].forks.turboquant.cpuMoe, true)

  const serialized = ModelsIni.serialize(parsed)
  const roundTripped = ModelsIni.parse(serialized)
  assert.deepStrictEqual(parsed, roundTripped)
})

test("resolveModelTuning merges common and fork overrides and fills alias", () => {
  const iniText = `
[models."/m/test.gguf"]
gpu_layers = -1
threads = 2
preferred_build = /bin/turbo

[models."/m/test.gguf"::/bin/turbo]
threads = 8
cache_type_k = turbo4
`
  const parsed = ModelsIni.parse(iniText)
  const resolved = ModelsIni.resolveModelTuning(parsed, "/m/test.gguf", "/bin/turbo")
  assert.strictEqual(resolved.alias, "test")
  assert.strictEqual(resolved.tuning.gpuLayers, "-1")
  assert.strictEqual(resolved.tuning.threads, "8")
  assert.strictEqual(resolved.tuning.cacheTypeK, "turbo4")
  assert.strictEqual(resolved.preferredBuild, "/bin/turbo")
})

test("fromProfiles converts legacy profiles store", () => {
  const legacy = {
    "llamacpp::/m/model.gguf": {
      threads: "4",
      llamaBuild: "/bin/turbo"
    },
    "llamacpp::/m/model.gguf::build::/bin/turbo": {
      cacheTypeK: "turbo4"
    }
  }
  const iniObj = ModelsIni.fromProfiles(legacy)
  assert.ok(iniObj.models["/m/model.gguf"])
  assert.strictEqual(iniObj.models["/m/model.gguf"].common.threads, "4")
  assert.strictEqual(iniObj.models["/m/model.gguf"].common.preferredBuild, "/bin/turbo")
  assert.strictEqual(iniObj.models["/m/model.gguf"].forks["/bin/turbo"].cacheTypeK, "turbo4")
})

test("toRouterIni cleans an alias set by hand", () => {
  // models.ini is documented as editable by hand, so the alias arrives
  // unchecked. It becomes an INI section name: "[my model]" and "[a]b]" are
  // read differently or rejected, and the model answers to no name at all.
  const ini = ModelsIni.toRouterIni({
    models: {
      "/m/one.gguf": { common: { alias: "my model" } },
      "/m/two.gguf": { common: { alias: "gemma[v2]" } }
    }
  })
  assert.ok(ini.includes("[my-model]"), ini)
  assert.ok(ini.includes("[gemma-v2]"), ini)
  assert.ok(!/\[[^\]\n]*[ \[]/.test(ini), "a section name still carries a space or a bracket: " + ini)
})

test("a file name that cleans to nothing still gets a usable alias", () => {
  // The fallback used to hand back the raw name, which is exactly the
  // characters the cleaning exists to remove.
  const ini = ModelsIni.toRouterIni({ models: { "/m/[[[.gguf": { common: {} } } })
  assert.ok(ini.includes("[model]"), ini)
})
