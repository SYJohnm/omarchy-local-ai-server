"use strict"

const test = require("node:test")
const assert = require("node:assert")
const B = require("../Backends.js")
const Model = require("../Model.js")

test("mergeBuilds keeps a vanished build as missing and lets fresh data win", () => {
  const previous = [
    { path: "/b/llama-server", real: "/b/llama-server", fork: "old", version: "1" },
    { path: "/a/llama-server", real: "/a/llama-server", fork: "gone" }
  ]
  const fresh = [
    { path: "/a/llama-server", real: "/a/llama-server", fork: "main", version: "2" }
  ]
  const merged = B.mergeBuilds(previous, fresh)
  assert.deepStrictEqual(merged.map(b => [b.path, b.missing, b.fork, b.version]), [
    ["/a/llama-server", false, "main", "2"],
    ["/b/llama-server", true, "old", "1"]
  ])
})

test("a missing build is not usable and never wins auto", () => {
  const builds = [
    { path: "/m/llama-server", missing: true, cacheTypes: ["f16"] },
    { path: "/a/llama-server", cacheTypes: ["f16"] }
  ]
  assert.strictEqual(B.buildSupports(builds[0], []), false)
  assert.strictEqual(B.buildAvailable(builds[0]), false)
  assert.strictEqual(B.resolveBuild(builds, "", "f16", "f16").path, "/a/llama-server")
  assert.strictEqual(B.resolveBuild(builds, "/m/llama-server", "f16", "f16").path, "/a/llama-server",
    "an explicitly chosen build that vanished falls back to a usable one")
  assert.strictEqual(B.resolveBuild([{ path: "/m/llama-server", missing: true }], "", "f16", "f16"), null)
})

test("mergeDirs is a stable union that keeps a saved folder when a scan misses it", () => {
  const merged = B.mergeDirs(
    ["/run/media/disk/models", "/home/u/models"],
    ["/home/u/models", "/home/u/.cache/llama.cpp", ""]
  )
  assert.deepStrictEqual(merged, [
    "/run/media/disk/models",
    "/home/u/models",
    "/home/u/.cache/llama.cpp"
  ])
})

test("detached launches prefix umask 077 in both carriers", () => {
  for (const argv of [B.detachedCommand(true, "u", "echo hi"), B.detachedCommand(false, "u", "echo hi")]) {
    assert.ok(argv.includes("umask 077; echo hi"), argv.join(" "))
  }
})

test("the launch declares a private umask on the unit as well as in the script", () => {
  // Slot files hold the prompt's token ids. The shell prefix covers the
  // setsid fallback, which has no unit; the property means the protection
  // does not rest on that prefix alone.
  const argv = B.detachedCommand(true, "u", "echo hi")
  assert.ok(argv.includes("--property=UMask=0077"), argv.join(" "))
  assert.ok(argv.includes("umask 077; echo hi"), argv.join(" "))
})

// ---- settings file readability ----

test("a missing or empty settings file is a first run, not a broken one", () => {
  // A fresh install must still save, which is why loadSettings("") has to
  // flip settingsLoaded.
  for (const raw of ["", "   ", "\n", undefined, null]) {
    const r = Model.readSettings(raw)
    assert.strictEqual(r.broken, false, JSON.stringify(raw))
    assert.strictEqual(r.parsed, null)
  }
})

test("a good settings file comes back parsed", () => {
  const r = Model.readSettings('{"backend":"llamacpp","host":"127.0.0.1"}')
  assert.strictEqual(r.broken, false)
  assert.strictEqual(r.parsed.backend, "llamacpp")
})

test("a present but unreadable settings file is broken, so it is not saved over", () => {
  // One mistyped comma used to cost the selected model, the per-backend ports,
  // the model directories, the setup flag and the instance assignments: the
  // defaults were loaded and written back 200 ms later.
  for (const raw of [
    '{"backend":"llamacpp",}',      // trailing comma
    '{"backend":"llamacpp"',        // truncated
    "{'backend':'llamacpp'}",       // single quotes
    "not json at all",
    "\u0000\u0001garbage"
  ]) {
    const r = Model.readSettings(raw)
    assert.strictEqual(r.broken, true, JSON.stringify(raw))
    assert.strictEqual(r.parsed, null)
  }
})

test("valid JSON that is not a settings object is broken too", () => {
  // Writing over it would lose whatever the file actually was.
  for (const raw of ["null", "7", '"a string"', "[1,2,3]", "true"]) {
    assert.strictEqual(Model.readSettings(raw).broken, true, raw)
  }
})

test("mergeBuilds prunes a build that is gone and no longer configured", () => {
  const stale = { path: "/home/u/beellama/llama-server", real: "/home/u/beellama/llama-server", missing: true }
  const live = { path: "/usr/bin/llama-server", real: "/usr/bin/llama-server", missing: false }
  const merged = B.mergeBuilds([stale, live], [live], [])
  assert.deepStrictEqual(merged.map(b => b.path), ["/usr/bin/llama-server"])
})

test("mergeBuilds keeps a gone build the user named by hand", () => {
  const named = { path: "/home/u/fork/llama-server", real: "/home/u/fork/llama-server", missing: true }
  const merged = B.mergeBuilds([named], [], ["/home/u/fork/llama-server"])
  assert.strictEqual(merged.length, 1)
  assert.strictEqual(merged[0].missing, true)
})

test("mergeBuilds without a configured list prunes nothing (startup restore)", () => {
  const held = { path: "/home/u/a/llama-server", real: "/home/u/a/llama-server", missing: true }
  assert.strictEqual(B.mergeBuilds([held], []).length, 1)
})

test("mergeBuilds does not prune a build this scan only just lost", () => {
  const wasOk = { path: "/mnt/drive/llama-server", real: "/mnt/drive/llama-server", missing: false }
  const merged = B.mergeBuilds([wasOk], [], [])
  assert.strictEqual(merged.length, 1)
  assert.strictEqual(merged[0].missing, true)
})

test("mergeBuilds does not prune when the scan reported nothing", () => {
  // A probe that fails (no python3, bad JSON) hands in an empty list. Treating
  // that as "every build is gone" would empty the panel's list on a hiccup.
  const stale = { path: "/home/u/gone/llama-server", real: "/home/u/gone/llama-server", missing: true }
  assert.strictEqual(B.mergeBuilds([stale], [], []).length, 1)
})
