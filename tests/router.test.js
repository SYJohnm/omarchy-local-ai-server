"use strict"

const test = require("node:test")
const assert = require("node:assert")
const R = require("../Router.js")

test("argvToParams pairs flags and values, keeps negative numbers", () => {
  const params = R.argvToParams([
    "--model", "/m/a.gguf",
    "--host", "127.0.0.1",
    "--port", "8080",
    "--metrics",
    "--gpu-layers", "-1",
    "--ctx-size", "32768",
    "--flash-attn", "on",
    "--no-repack",
    "--jinja",
    "--temp", "0.7",
    "--model-draft", "/m/draft.gguf"
  ])
  assert.deepStrictEqual(params, {
    "gpu-layers": "-1",
    "ctx-size": "32768",
    "flash-attn": "on",
    "no-repack": true,
    jinja: true,
    temp: "0.7",
    "model-draft": "/m/draft.gguf"
  })
})

test("argvToParams handles --flag=value and the last duplicate wins", () => {
  const params = R.argvToParams([
    "--ctx-size=4096",
    "--ctx-size", "8192",
    "--cache-type-k", "q8_0",
    "--cache-type-v", "q8_0"
  ])
  assert.strictEqual(params["ctx-size"], "8192")
  assert.strictEqual(params["cache-type-k"], "q8_0")
})

test("router-owned flags never leak into a preset", () => {
  const params = R.argvToParams([
    "--models-max", "2", "--slot-save-path", "/x", "--alias", "a",
    "--api-key", "secret", "--ctx-size", "4096"
  ])
  assert.deepStrictEqual(params, { "ctx-size": "4096" })
})

test("build groups models per build and assigns distinct internal ports", () => {
  const { config, modelCount, buildCount } = R.build({
    host: "127.0.0.1", port: 8080, stateDir: "/state",
    defaultModel: "/m/a.gguf",
    env: { CUDA_VISIBLE_DEVICES: "0" },
    models: [
      { path: "/m/a.gguf", build: "/b/main/llama-server", args: ["--ctx-size", "4096"] },
      { path: "/m/b.gguf", build: "/b/main/llama-server" },
      { path: "/m/c.gguf", build: "/b/turbo/llama-server" }
    ]
  })
  assert.strictEqual(modelCount, 3)
  assert.strictEqual(buildCount, 2)
  assert.strictEqual(config.listen.port, 8080)
  assert.strictEqual(config.default_model, "/m/a.gguf")
  assert.strictEqual(config.routers["/b/main/llama-server"].port, 5800)
  assert.strictEqual(config.routers["/b/turbo/llama-server"].port, 5801)
  assert.deepStrictEqual(config.routers["/b/main/llama-server"].env, { CUDA_VISIBLE_DEVICES: "0" })
  assert.deepStrictEqual(config.models[0].params, { "ctx-size": "4096" })
  assert.strictEqual(config.models[1].params["ctx-size"], undefined)
})

test("build refuses an empty catalogue", () => {
  assert.throws(() => R.build({ models: [] }), /no model/)
})

test("unitFile uses a private umask and the exact relay invocation", () => {
  const unit = R.unitFile({
    relayPath: "/plugins/io.github.syjohnm.local-ai-server/router/relay.py",
    configPath: "/state/router.json",
    stateDir: "/state/router",
    workDir: "/state"
  })
  assert.ok(unit.includes("UMask=0077"))
  assert.ok(unit.includes("Restart=on-failure"))
  assert.ok(unit.includes('ExecStart="python3" "/plugins/io.github.syjohnm.local-ai-server/router/relay.py"'))
  assert.ok(unit.includes('--config "/state/router.json"'))
})

test("router args are filtered by each build's own --help flags", () => {
  const { config } = R.build({
    stateDir: "/state",
    models: [
      { path: "/m/a.gguf", build: "/b/old/llama-server", flags: ["--models-max"], args: [] },
      { path: "/m/b.gguf", build: "/b/new/llama-server", flags: ["--models-max", "--models-memory-margin"], args: [] }
    ]
  })
  assert.deepStrictEqual(config.routers["/b/old/llama-server"].args, ["--models-max", "2"])
  assert.deepStrictEqual(config.routers["/b/new/llama-server"].args,
    ["--models-max", "2", "--models-memory-margin", "512"])
})
