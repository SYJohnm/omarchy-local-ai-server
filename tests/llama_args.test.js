"use strict"

// The launch line. This is the function that decides what actually gets
// started, and until it was extracted from Panel.qml no test could reach it --
// which is how a ReferenceError in the alias branch survived several releases
// and shipped, making direct llama.cpp launches do nothing at all.

const test = require("node:test")
const assert = require("node:assert")
const LlamaArgs = require("../LlamaArgs.js")
const Backends = require("../Backends.js")
const Model = require("../Model.js")
const Params = require("../Params.js")
const ModelsIni = require("../ModelsIni.js")
const Profiles = require("../Profiles.js")

const MODEL = "/models/Qwen3-8B-Q4_K_M.gguf"

// A build that understands every flag the built-in controls can emit.
const FULL_BUILD = {
  path: "/b/llama-server", real: "/b/llama-server", fork: "llama.cpp",
  flags: ["--gpu-layers", "--cache-type-k", "--cache-type-v", "--flash-attn",
          "--load-mode", "--threads", "--ctx-size", "--batch-size", "--ubatch-size",
          "--alias", "--parallel", "--temp", "--cache-ram", "--n-cpu-moe", "--cpu-moe",
          "--no-repack", "--spec-type", "--reasoning-preserve", "--no-reasoning-preserve",
          "--model-draft", "--mmproj-offload", "--no-mmproj-offload"]
}

function argv(tuning, extra) {
  const cfg = Object.assign({
    model: MODEL,
    build: FULL_BUILD,
    binary: "/b/llama-server",
    host: "127.0.0.1",
    port: 8080,
    slotDir: "/state/slots",
    backend: "llamacpp",
    tuning: Profiles.resolve(tuning || {}),
    ownedFlags: {},
    supportsFlag: Backends.supportsFlag,
    customArgv: e => Params.toArgv(Params.find([], e.key) || Params.fallbackSpec(e.key, e.type), e.value),
    splitExtraArgs: Model.splitExtraArgs,
    parseArgs: Model.parseArgs,
    deriveDefaultAlias: ModelsIni.deriveDefaultAlias
  }, extra || {})
  return LlamaArgs.build(cfg)
}

function valueOf(args, flag) {
  const i = args.indexOf(flag)
  return i === -1 ? null : args[i + 1]
}

test("the endpoint, the model and the cache path always come first", () => {
  const { args } = argv()
  assert.deepStrictEqual(args.slice(0, 8), [
    "/b/llama-server", "--model", MODEL, "--host", "127.0.0.1", "--port", "8080",
    "--slot-save-path"
  ])
  assert.strictEqual(args[8], "/state/slots")
  assert.ok(args.includes("--metrics"))
})

test("an alias is derived from the model when the row is left on auto", () => {
  // This is the branch that threw. "auto" is the default, so every default
  // direct launch went through it and built no argv at all.
  const { args } = argv()
  assert.strictEqual(valueOf(args, "--alias"), "qwen3-8b")
})

test("an alias the user set wins over the derived one", () => {
  assert.strictEqual(valueOf(argv({ modelAlias: "my-model" }).args, "--alias"), "my-model")
})

test("the tuning rows become their flags", () => {
  const { args } = argv({
    gpuLayers: "24", threads: "12", contextSize: "32768", batchSize: "2048",
    ubatchSize: "512", cacheTypeK: "q8_0", cacheTypeV: "q8_0", cacheRam: "8192",
    temperature: "0.7", parallel: "4"
  })
  assert.strictEqual(valueOf(args, "--gpu-layers"), "24")
  assert.strictEqual(valueOf(args, "--threads"), "12")
  assert.strictEqual(valueOf(args, "--ctx-size"), "32768")
  assert.strictEqual(valueOf(args, "--batch-size"), "2048")
  assert.strictEqual(valueOf(args, "--ubatch-size"), "512")
  assert.strictEqual(valueOf(args, "--cache-type-k"), "q8_0")
  assert.strictEqual(valueOf(args, "--cache-type-v"), "q8_0")
  assert.strictEqual(valueOf(args, "--cache-ram"), "8192")
  assert.strictEqual(valueOf(args, "--temp"), "0.7")
  assert.strictEqual(valueOf(args, "--parallel"), "4")
})

test("-1 layers is passed through, a silly count is clamped", () => {
  // -1 is llama.cpp's "fit as many as VRAM allows" sentinel, not a count.
  assert.strictEqual(valueOf(argv({ gpuLayers: "-1" }).args, "--gpu-layers"), "-1")
  assert.strictEqual(valueOf(argv({ gpuLayers: "9999" }).args, "--gpu-layers"), "999")
  assert.strictEqual(valueOf(argv({ gpuLayers: "nonsense" }).args, "--gpu-layers"), "0")
})

test("zero and empty mean 'leave it to llama.cpp'", () => {
  const { args } = argv({ threads: "0", contextSize: "0", batchSize: "0", ubatchSize: "0",
                          cacheRam: "", temperature: "", parallel: "" })
  for (const flag of ["--threads", "--ctx-size", "--batch-size", "--ubatch-size",
                      "--cache-ram", "--temp", "--parallel"]) {
    assert.ok(!args.includes(flag), flag + " must be left out")
  }
})

test("the MoE flags are mutually exclusive, with the count winning", () => {
  assert.ok(argv({ cpuMoe: true }).args.includes("--cpu-moe"))
  const both = argv({ cpuMoe: true, nCpuMoe: "18" }).args
  assert.strictEqual(valueOf(both, "--n-cpu-moe"), "18")
  assert.ok(!both.includes("--cpu-moe"), "llama.cpp takes one or the other")
})

test("a tri-state row emits the flag or its no- form, and nothing on default", () => {
  assert.ok(argv({ reasoningPreserve: "on" }).args.includes("--reasoning-preserve"))
  assert.ok(argv({ reasoningPreserve: "off" }).args.includes("--no-reasoning-preserve"))
  const d = argv({ reasoningPreserve: "default" }).args
  assert.ok(!d.includes("--reasoning-preserve") && !d.includes("--no-reasoning-preserve"))
})

test("the projector follows its mode, not whatever path is stored", () => {
  const stored = { mmprojPath: "/models/custom-proj.gguf" }
  const beside = { autoMmproj: "/models/beside-proj.gguf" }

  const off = argv(Object.assign({ mmprojMode: "off" }, stored), beside).args
  assert.ok(off.includes("--no-mmproj"))
  assert.ok(!off.includes("--mmproj"))

  const auto = argv(Object.assign({ mmprojMode: "auto" }, stored), beside).args
  assert.strictEqual(valueOf(auto, "--mmproj"), "/models/beside-proj.gguf")

  const custom = argv(Object.assign({ mmprojMode: "custom" }, stored), beside).args
  assert.strictEqual(valueOf(custom, "--mmproj"), "/models/custom-proj.gguf")

  // No projector anywhere: say nothing rather than pass an empty path.
  const none = argv({ mmprojMode: "auto" }).args
  assert.ok(!none.includes("--mmproj") && !none.includes("--no-mmproj"))
})

test("the projector stays off the GPU unless asked", () => {
  const beside = { autoMmproj: "/models/p.gguf" }
  // GPU offload is llama.cpp's default but rarely fits beside the model, and
  // the failure is an allocation abort rather than a clean error.
  assert.ok(argv({ mmprojMode: "auto", mmprojOffload: "off" }, beside).args.includes("--no-mmproj-offload"))
  assert.ok(argv({ mmprojMode: "auto", mmprojOffload: "on" }, beside).args.includes("--mmproj-offload"))
})

test("an MTP draft is loaded only while the spec type uses it", () => {
  const beside = { autoMtp: "/models/draft.gguf" }
  // --model-draft on its own loads the weights and decodes nothing with them.
  assert.strictEqual(valueOf(argv({ specType: "draft-mtp" }, beside).args, "--model-draft"),
                     "/models/draft.gguf")
  assert.ok(!argv({ specType: "none" }, beside).args.includes("--model-draft"))
})

test("a flag the build does not describe is left out and reported", () => {
  const thin = { path: "/b/old", real: "/b/old", fork: "fork", flags: ["--gpu-layers", "--threads"] }
  const { args, ignoredFlags } = argv({ cacheTypeK: "q8_0", contextSize: "4096" }, { build: thin })
  assert.ok(!args.includes("--cache-type-k"))
  assert.ok(ignoredFlags.includes("--cache-type-k"), JSON.stringify(ignoredFlags))
  // The page reads ignoredFlags to mark that row as unsupported.
  assert.ok(ignoredFlags.includes("--ctx-size"))
})

test("an added parameter takes its flag over from the built-in row", () => {
  // Emitting both is how a launch line ended up carrying two "--load-mode":
  // llama.cpp keeps the last, so the duplicate is silent while the control
  // still shows its own value.
  const { args } = argv(
    { loadMode: "mmap", customParams: [{ key: "--load-mode", value: "mlock", type: "string" }] },
    { ownedFlags: { "--load-mode": "loadMode" } })
  assert.strictEqual(args.filter(a => a === "--load-mode").length, 1)
  assert.strictEqual(valueOf(args, "--load-mode"), "mlock")
})

test("extra args are appended last, so a hand-written flag gets the last word", () => {
  const { args } = argv({ contextSize: "4096", extraArgs: "--ctx-size 8192" })
  assert.strictEqual(args.lastIndexOf("--ctx-size"), args.length - 2)
  assert.strictEqual(args[args.length - 1], "8192")
})

test("extra args split on semicolons as well as spaces", () => {
  const { args } = argv({ extraArgs: "--temp 0.5; --no-warmup" })
  assert.strictEqual(valueOf(args, "--temp"), "0.5")
  assert.ok(args.includes("--no-warmup"))
})

test("a build the probe has not resolved yet emits only the endpoint", () => {
  // buildsProbed gates the launch, but the function must not invent flags for
  // a build it knows nothing about.
  const { args } = argv({ threads: "8" }, { build: null })
  assert.ok(!args.includes("--threads"))
  assert.ok(args.includes("--model") && args.includes("--port"))
})

test("two instances of the same model and tuning differ only in the port", () => {
  const tuning = { gpuLayers: "-1", threads: "8", contextSize: "16384" }
  const a = argv(tuning, { port: 8080 }).args
  const b = argv(tuning, { port: 8081 }).args
  assert.deepStrictEqual(a.filter(x => x !== "8080"), b.filter(x => x !== "8081"))
})
