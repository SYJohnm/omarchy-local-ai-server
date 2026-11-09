"use strict"

const test = require("node:test")
const assert = require("node:assert")
const B = require("../Backends.js")

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
