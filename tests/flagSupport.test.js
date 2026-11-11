// Tests for étape 7: supportsFlag — tolérance aux paramètres non supportés
import { test, after } from "node:test"
import assert from "node:assert"
import Backends from "../Backends.js"

const dummyBuild = {
  path: "/usr/bin/llama-server",
  real: "/usr/bin/llama-server",
  fork: "llama-server",
  commit: "abc123",
  date: "2026-01-01",
  gpu: "CUDA",
  cacheTypes: ["f16", "q4_0"],
  flags: ["--gpu-layers", "--cache-type-k", "--cache-type-v", "--flash-attn"]
}

const oldBuild = {
  path: "/usr/bin/llama-server-old",
  real: "/usr/bin/llama-server-old",
  fork: "llama-server",
  commit: "old123",
  date: "2025-01-01",
  gpu: "CUDA",
  cacheTypes: ["f16"],
  flags: ["--gpu-layers", "--cache-type-k"]
  // No --cache-type-v, --flash-attn
}

const noFlagsBuild = {
  path: "/usr/bin/llama-server-noflags",
  real: "/usr/bin/llama-server-noflags",
  fork: "llama-server",
  commit: "noflags123",
  date: "2026-01-01",
  gpu: "CPU",
  cacheTypes: [],
  flags: []
}

after(() => {
  // Reset flagAliases between test runs
  Backends.registerFlagAliases("--cache-type-k", ["--cache-type-k"])
  Backends.registerFlagAliases("--cache-type-v", ["--cache-type-v"])
  Backends.registerFlagAliases("--flash-attn", ["--flash-attn"])
})

test("supportsFlag returns true for flag present in build", () => {
  assert.strictEqual(Backends.supportsFlag(dummyBuild, "--gpu-layers"), true)
  assert.strictEqual(Backends.supportsFlag(dummyBuild, "--cache-type-k"), true)
  assert.strictEqual(Backends.supportsFlag(dummyBuild, "--flash-attn"), true)
})

test("supportsFlag returns false for flag absent from build", () => {
  assert.strictEqual(Backends.supportsFlag(oldBuild, "--cache-type-v"), false)
  assert.strictEqual(Backends.supportsFlag(oldBuild, "--flash-attn"), false)
  assert.strictEqual(Backends.supportsFlag(oldBuild, "--load-mode"), false)
})

test("supportsFlag returns true for unknown build", () => {
  assert.strictEqual(Backends.supportsFlag(null, "--load-mode"), true)
  assert.strictEqual(Backends.supportsFlag(undefined, "--load-mode"), true)
})

test("supportsFlag returns true when build has no flags array (probe failed)", () => {
  const probeFailed = { ...dummyBuild, flags: undefined }
  assert.strictEqual(Backends.supportsFlag(probeFailed, "--load-mode"), true)
  assert.strictEqual(Backends.supportsFlag(probeFailed, "--unknown-flag"), true)
})

test("supportsFlag returns true when build has empty flags array", () => {
  assert.strictEqual(Backends.supportsFlag(noFlagsBuild, "--load-mode"), true)
  assert.strictEqual(Backends.supportsFlag(noFlagsBuild, "--cache-type-v"), true)
})

test("supportsFlag respects registered aliases", () => {
  Backends.registerFlagAliases("--cache-type-k", ["--cache-type-k", "--ctx-k"])
  assert.strictEqual(Backends.supportsFlag(oldBuild, "--cache-type-k"), true)
  assert.strictEqual(Backends.supportsFlag(oldBuild, "--ctx-k"), true)
  assert.strictEqual(Backends.supportsFlag(dummyBuild, "--cache-type-k"), true)
  Backends.registerFlagAliases("--cache-type-v", ["--cache-type-v", "--ctx-v"])
  assert.strictEqual(Backends.supportsFlag(oldBuild, "--cache-type-v"), false)
  assert.strictEqual(Backends.supportsFlag(oldBuild, "--ctx-v"), false)
})

test("flag kept in profile but ignored at launch on build B", () => {
  assert.strictEqual(Backends.supportsFlag(dummyBuild, "--flash-attn"), true)
  assert.strictEqual(Backends.supportsFlag(oldBuild, "--flash-attn"), false)
  assert.strictEqual(Backends.supportsFlag(dummyBuild, "--flash-attn"), true)
})

// ---- The gate blocks a launch, not just the list ----
//
// A build held for approval carries `missing: true`, which is the flag the
// launch paths already key on. These assert that, because the whole gate rests
// on it: if a held build could win Auto, it would be started unconfined with
// the models and the network, which is the one thing approval exists to stop.

const heldBuild = {
  path: "/home/u/Downloads/llama-x/llama-server",
  fork: "llama-x",
  cacheTypes: ["f16", "q8_0"],
  flags: ["--ctx-size"],
  missing: true,
  needsApproval: true,
  why: ["is in ~/Downloads, so its presence only shows that something was downloaded"]
}
const okBuild = {
  path: "/usr/bin/llama-server",
  fork: "llama.cpp (system package)",
  cacheTypes: ["f16", "q8_0"],
  flags: ["--ctx-size"]
}

test("a build held for approval is not available to launch", () => {
  assert.strictEqual(Backends.buildAvailable(heldBuild), false)
  assert.strictEqual(Backends.buildAvailable(okBuild), true)
})

test("a build held for approval cannot serve a model's tuning", () => {
  // Its --help said it supports these types; being held still rules it out.
  assert.strictEqual(Backends.buildSupports(heldBuild, ["f16", "f16"]), false)
  assert.strictEqual(Backends.buildSupports(okBuild, ["f16", "f16"]), true)
})

test("Auto never resolves to a build held for approval", () => {
  assert.strictEqual(Backends.resolveBuild([heldBuild], "", "f16", "f16"), null)
  assert.strictEqual(
    Backends.resolveBuild([heldBuild, okBuild], "", "f16", "f16").path, okBuild.path)
})

test("picking a held build explicitly does not launch it either", () => {
  // Selecting it by hand is not approval: the Build picker can still name a
  // path that the gate has not cleared.
  assert.strictEqual(Backends.resolveBuild([heldBuild], heldBuild.path, "f16", "f16"), null)
})
