"use strict"

// Regression coverage for markup-shaped input.
//
// Omarchy's plugins run inside the shell's long-lived, unsandboxed Quickshell
// process, and QML Text defaults to Text.AutoText -- which interprets
// markup-shaped strings as rich text and fetches what they point at. The
// plugin displays file names from a disk scan, model names from an HTTP API,
// `--help` descriptions and journal output, none of which are its own
// strings. Its own Text elements declare Text.PlainText; everything handed to
// a shared component that owns its Text goes through these helpers first.

const test = require("node:test")
const assert = require("node:assert")
const Model = require("../Model.js")
const Backends = require("../Backends.js")

const BEACON = '<img src="http://attacker.invalid/beacon.png">'

const HELPERS = [["Model.plainText", Model.plainText], ["Backends.plain", Backends.plain]]

for (const [name, plain] of HELPERS) {
  test(name + " strips an image tag that would make the shell fetch a URL", () => {
    const out = plain(BEACON + "model.gguf")
    assert.strictEqual(out, "model.gguf")
    assert.ok(!/attacker\.invalid/.test(out), "the URL must not survive")
  })

  test(name + " leaves no angle bracket for a tag to be reassembled from", () => {
    for (const input of [
      BEACON,
      "<img src=x onerror=1>",
      "a<unclosed tag",
      "<<img src=x>>",
      "<!DOCTYPE html>",
      "<html><body>x",
      "</div>",
      "<a href='http://x'>link</a>"
    ]) {
      const out = plain(input)
      assert.ok(!out.includes("<") && !out.includes(">"),
        JSON.stringify(input) + " left a bracket: " + JSON.stringify(out))
    }
  })

  test(name + " removes invisible and control characters", () => {
    // A zero-width or bidi mark in a label is only ever there to mislead
    // about which file is about to be loaded. Built from char codes so this
    // test file stays readable ASCII.
    const ZWSP = String.fromCharCode(0x200b)
    const RLO = String.fromCharCode(0x202e)
    const NUL = String.fromCharCode(0x00)
    const LSEP = String.fromCharCode(0x2028)
    const input = "safe" + ZWSP + RLO + "model" + NUL + LSEP + "name"
    const out = plain(input)
    for (const ch of [ZWSP, RLO, NUL, LSEP])
      assert.ok(!out.includes(ch), "invisible char survived: " + JSON.stringify(out))
    assert.strictEqual(out, "safe model name")
  })

  test(name + " bounds the length, so one long string cannot fill the panel", () => {
    const out = plain("x".repeat(10000))
    assert.strictEqual(out.length, 400)
    assert.ok(out.endsWith("…"))
    assert.strictEqual(plain("y".repeat(50), 10).length, 10)
  })

  test(name + " leaves ordinary model names and paths exactly as they are", () => {
    for (const input of [
      "Qwen3.8-35B-A3B-Q4_K_M.gguf",
      "/run/media/sxy/marge/models/HauhauCS/model-Q4_K_M.gguf",
      "qwen3:8b",
      "llama-server · 3a1f2bc · 2026-10-02 · cuda",
      "--n-cpu-moe"
    ]) {
      assert.strictEqual(plain(input), input)
    }
  })

  test(name + " turns an absent value into an empty string, not \"undefined\"", () => {
    assert.strictEqual(plain(undefined), "")
    assert.strictEqual(plain(null), "")
    assert.strictEqual(plain(""), "")
  })
}

test("a build label carrying markup is neutralised where it is built", () => {
  // fork/commit/date/gpu are parsed out of paths and `--help` output by
  // llama_builds.py, and the label is rendered by shared components.
  const label = Backends.buildLabel({
    fork: "turboquant" + BEACON, commit: "abcdef1234", date: "2026-10-02", gpu: "cuda"
  })
  assert.ok(!label.includes("<") && !label.includes(">"), label)
  assert.ok(!/attacker\.invalid/.test(label))
  assert.ok(label.startsWith("turboquant"))
})

test("an ordinary build label is unchanged", () => {
  assert.strictEqual(
    Backends.buildLabel({ fork: "llama-server", commit: "3a1f2bcdd", date: "2026-10-02", gpu: "cuda" }),
    "llama-server · 3a1f2bc · 2026-10-02 · cuda")
})

test("an empty build has no label", () => {
  assert.strictEqual(Backends.buildLabel(null), "")
  assert.strictEqual(Backends.buildLabel(undefined), "")
})
