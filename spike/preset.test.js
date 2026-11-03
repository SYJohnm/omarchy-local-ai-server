"use strict"

const test = require("node:test")
const assert = require("node:assert")
const P = require("./preset.js")

test("renderPreset emits version, [*] defaults and one section per model", () => {
  const text = P.renderPreset({
    defaults: { c: 8192, "no-mmap": true, "models-max": 4 },
    models: [
      {
        id: "/models/qwen3.gguf",
        path: "/models/qwen3.gguf",
        params: { ngl: 99, c: 32768, jinja: true, "no-mmproj": false }
      },
      {
        id: "/models/mistral.gguf",
        path: "/models/mistral.gguf",
        mmproj: "/models/mmproj.gguf",
        draft: "/models/draft.gguf",
        params: { "ctx-size": 16384 }
      }
    ]
  })

  assert.equal(text, [
    "version = 1",
    "",
    "[*]",
    "c = 8192",
    "no-mmap = true",
    "",
    "[/models/qwen3.gguf]",
    "model = /models/qwen3.gguf",
    "ngl = 99",
    "c = 32768",
    "jinja = true",
    "no-mmproj = false",
    "",
    "[/models/mistral.gguf]",
    "model = /models/mistral.gguf",
    "mmproj = /models/mmproj.gguf",
    "model-draft = /models/draft.gguf",
    "ctx-size = 16384",
    ""
  ].join("\n"))
})

test("renderPreset drops router-reserved keys from defaults and models", () => {
  const text = P.renderPreset({
    defaults: { host: "0.0.0.0", port: 1, "models-dir": "/x", c: 4096 },
    models: [{
      id: "m",
      path: "/m.gguf",
      params: { alias: "nope", "api-key": "secret", port: 2, ngl: 4, model: "/other.gguf" }
    }]
  })
  assert.match(text, /^\[m\]$/m)
  assert.match(text, /^model = \/m\.gguf$/m)
  assert.match(text, /^ngl = 4$/m)
  assert.doesNotMatch(text, /alias/)
  assert.doesNotMatch(text, /api-key/)
  assert.doesNotMatch(text, /^port =/m)
  assert.doesNotMatch(text, /models-dir/)
  assert.doesNotMatch(text, /other\.gguf/)
})

test("renderPreset keeps one line per value and section ids with spaces", () => {
  const text = P.renderPreset({
    models: [{ id: "/models/with space.gguf", path: "/models/with space.gguf", params: { "chat-template": "line one\nline two" } }]
  })
  assert.match(text, /^\[\/models\/with space\.gguf\]$/m)
  assert.match(text, /^chat-template = line one line two$/m)
})

test("renderPreset refuses an id that would break the INI section", () => {
  assert.throws(() => P.renderPreset({ models: [{ id: "bad]id", path: "/m.gguf" }] }), /section id/)
  assert.throws(() => P.renderPreset({ models: [{ id: "bad\nid", path: "/m.gguf" }] }), /section id/)
  assert.throws(() => P.renderPreset({ models: [{ id: "", path: "" }] }), /section id/)
})

test("splitByBuild groups in catalog order and defaults missing builds", () => {
  const groups = P.splitByBuild([
    { id: "a", build: "main" },
    { id: "b", build: "turbo" },
    { id: "c", build: "main" },
    { id: "d" }
  ])
  assert.deepEqual([...groups.keys()], ["main", "turbo", "default"])
  assert.deepEqual(groups.get("main").map(m => m.id), ["a", "c"])
  assert.deepEqual(groups.get("default").map(m => m.id), ["d"])
})
