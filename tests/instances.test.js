"use strict"

const test = require("node:test")
const assert = require("node:assert")
const Instances = require("../Instances.js")
const Backends = require("../Backends.js")

const PLUGIN = "io.github.syjohnm.local-ai-server"

function planFor(overrides) {
  return Instances.plan(Object.assign({
    pluginId: PLUGIN,
    backendId: "llamacpp",
    portBase: 8080,
    count: 1,
    reserved: [],
    unitName: Backends.unitName,
    procMarker: Backends.procMarker
  }, overrides || {}))
}

// ---- clampCount ----

test("only llama.cpp runs several instances", () => {
  assert.strictEqual(Instances.clampCount(4, "llamacpp"), 4)
  // ollama is one daemon configured by environment; a second on another port
  // would serve the same store with the same settings.
  assert.strictEqual(Instances.clampCount(4, "ollama"), 1)
  assert.strictEqual(Instances.clampCount(4, "systemone"), 1)
})

test("a router already answers for every model, so it stays one process", () => {
  assert.strictEqual(Instances.clampCount(3, "llamacpp", true), 1)
  assert.strictEqual(Instances.clampCount(3, "llamacpp", false), 3)
})

test("an unusable count reads as one rather than none", () => {
  for (const bad of [0, -2, "", null, undefined, "abc", NaN]) {
    assert.strictEqual(Instances.clampCount(bad, "llamacpp"), 1, `count ${String(bad)}`)
  }
})

test("the count is capped so a typo cannot launch a hundred servers", () => {
  assert.strictEqual(Instances.clampCount(999, "llamacpp"), Instances.MAX_INSTANCES)
})

test("a decimal count truncates instead of producing a fractional index", () => {
  assert.strictEqual(Instances.clampCount("2.9", "llamacpp"), 2)
})

// ---- portFor ----

test("ports are allocated from the base upwards", () => {
  assert.strictEqual(Instances.portFor(8080, 0), 8080)
  assert.strictEqual(Instances.portFor(8080, 3), 8083)
  assert.strictEqual(Instances.portFor("8080", 1), 8081)
})

test("a port that would not fit in 16 bits is refused, not wrapped", () => {
  assert.strictEqual(Instances.portFor(65535, 1), 0)
  assert.strictEqual(Instances.portFor(65534, 2), 0)
  assert.strictEqual(Instances.portFor(65534, 1), 65535)
})

test("a reserved port is skipped, so the decision companion is never collided with", () => {
  // System One defaults to 8081, which is exactly what chat instance 1 would
  // otherwise be handed from a base of 8080 -- and both would bind it.
  assert.strictEqual(Instances.portFor(8080, 0, [8081]), 8080)
  assert.strictEqual(Instances.portFor(8080, 1, [8081]), 8082)
  assert.strictEqual(Instances.portFor(8080, 2, [8081]), 8083)
  // Several reserved ports, in any order.
  assert.strictEqual(Instances.portFor(8080, 1, [8083, 8081]), 8082)
  assert.strictEqual(Instances.portFor(8080, 2, [8083, 8081]), 8084)
})

test("the base port is never skipped, even if it is reserved", () => {
  // Index 0 is the server the page has always managed; moving it would orphan
  // whatever is already running on it.
  assert.strictEqual(Instances.portFor(8080, 0, [8080]), 8080)
  assert.strictEqual(Instances.portFor(8080, 1, [8080]), 8081)
})

test("reserved ports are ignored when they are not ports", () => {
  assert.strictEqual(Instances.portFor(8080, 1, ["", null, "abc", 0, -1]), 8081)
  assert.strictEqual(Instances.portFor(8080, 1, undefined), 8081)
})

test("the plan routes around the companion's port", () => {
  const rows = planFor({ count: 3, reserved: [8081] })
  assert.deepStrictEqual(rows.map(r => r.port), [8080, 8082, 8083])
})

test("a nonsense base yields no port", () => {
  assert.strictEqual(Instances.portFor("", 0), 0)
  assert.strictEqual(Instances.portFor(0, 0), 0)
  assert.strictEqual(Instances.portFor("abc", 0), 0)
})

// ---- plan ----

test("one instance keeps the names an older version launched under", () => {
  const [first] = planFor({ count: 1 })
  // Index 0 carries no suffix, so a server left running by a previous build
  // of the widget is still found by its unit and its marker.
  assert.strictEqual(first.unitName, "io-github-syjohnm-local-ai-server-llamacpp")
  assert.strictEqual(first.procMarker, "io-github-syjohnm-local-ai-server-llamacpp-proc")
  assert.strictEqual(first.port, 8080)
  assert.strictEqual(first.primary, true)
})

test("each extra instance gets its own unit, marker and port", () => {
  const rows = planFor({ count: 3 })
  assert.strictEqual(rows.length, 3)
  assert.deepStrictEqual(rows.map(r => r.port), [8080, 8081, 8082])
  assert.deepStrictEqual(rows.map(r => r.unitName), [
    "io-github-syjohnm-local-ai-server-llamacpp",
    "io-github-syjohnm-local-ai-server-llamacpp-1",
    "io-github-syjohnm-local-ai-server-llamacpp-2"
  ])
  // Distinct markers are what keep one instance's orphan sweep off another's
  // process.
  assert.strictEqual(new Set(rows.map(r => r.procMarker)).size, 3)
  assert.deepStrictEqual(rows.map(r => r.primary), [true, false, false])
})

test("the plan stops at the last index that has a usable port", () => {
  const rows = planFor({ count: 4, portBase: 65534 })
  assert.deepStrictEqual(rows.map(r => r.port), [65534, 65535])
})

test("the primary is still listed when its own port is unusable", () => {
  // The page has to be able to say why nothing can start, which it cannot do
  // for a row that is not there.
  const rows = planFor({ count: 2, portBase: "nonsense" })
  assert.strictEqual(rows.length, 1)
  assert.strictEqual(rows[0].port, 0)
})

test("a non-llama.cpp backend plans exactly one instance", () => {
  const rows = planFor({ backendId: "ollama", portBase: 11434, count: 4 })
  assert.strictEqual(rows.length, 1)
  assert.strictEqual(rows[0].port, 11434)
})

// ---- healthVerdict ----

test("an answering poll is alive", () => {
  assert.strictEqual(Instances.healthVerdict({ running: true, failures: 0 }), "alive")
})

test("a single missed poll is not a dead server", () => {
  // curl's timeout is one second and a busy server can be slower than that.
  assert.strictEqual(Instances.healthVerdict({ running: true, failures: 1 }), "grace")
  assert.strictEqual(Instances.healthVerdict({ running: true, failures: 2 }), "grace")
})

test("misses in a row are what call a running server gone", () => {
  assert.strictEqual(
    Instances.healthVerdict({ running: true, failures: Instances.FAILURES_BEFORE_GONE }), "gone")
  assert.strictEqual(Instances.healthVerdict({ running: true, failures: 99 }), "gone")
})

test("a starting server is never declared gone by a failed poll", () => {
  // It has not answered yet by definition; the startup timeout bounds the wait.
  assert.strictEqual(
    Instances.healthVerdict({ running: false, starting: true, failures: 99 }), "grace")
  assert.strictEqual(
    Instances.healthVerdict({ running: true, starting: true, failures: 99 }), "grace")
})

test("the threshold is adjustable for a slower poll", () => {
  assert.strictEqual(Instances.healthVerdict({ running: true, failures: 1, threshold: 1 }), "gone")
})

// ---- rateAfterIdle ----

test("a rate shows while tokens are still arriving", () => {
  assert.strictEqual(Instances.rateAfterIdle(24.5, 0), 24.5)
  assert.strictEqual(Instances.rateAfterIdle(24.5, 1000), 24.5)
})

test("a rate is released once the server has been quiet", () => {
  // The old behaviour kept the last rate for the life of the process, so the
  // bar reported a request that had finished an hour earlier.
  assert.strictEqual(Instances.rateAfterIdle(24.5, Instances.RATE_LINGER_MS + 1), 0)
})

test("the linger is configurable and a zero linger releases at once", () => {
  assert.strictEqual(Instances.rateAfterIdle(24.5, 10, 5), 0)
  assert.strictEqual(Instances.rateAfterIdle(24.5, 10, 50), 24.5)
})

test("an absent rate stays absent", () => {
  assert.strictEqual(Instances.rateAfterIdle(0, 0), 0)
  assert.strictEqual(Instances.rateAfterIdle(NaN, 0), 0)
  assert.strictEqual(Instances.rateAfterIdle(-3, 0), 0)
})

test("an unknown idle time holds the rate rather than inventing an idle", () => {
  assert.strictEqual(Instances.rateAfterIdle(24.5, NaN), 24.5)
})

// ---- stateLabel ----

test("what is happening to an instance beats what it is doing", () => {
  assert.strictEqual(
    Instances.stateLabel({ running: true, stopping: true, tokensPerSec: 20 }), "stopping…")
  assert.strictEqual(
    Instances.stateLabel({ running: true, switching: true, tokensPerSec: 20 }), "restarting…")
  assert.strictEqual(
    Instances.stateLabel({ running: false, starting: true }), "starting…")
})

test("a stopped instance says whether it fell over", () => {
  assert.strictEqual(Instances.stateLabel({ running: false }), "stopped")
  assert.strictEqual(Instances.stateLabel({ running: false, failed: true }), "crashed")
})

test("ingestion reports how far along and how fast at once", () => {
  assert.strictEqual(
    Instances.stateLabel({ running: true, ppActive: true, ppPercent: 52.4, ppTokensPerSec: 63.2 }),
    "52% · 63 t/s")
  // No rate yet: the percentage is still the answer.
  assert.strictEqual(
    Instances.stateLabel({ running: true, ppActive: true, ppPercent: 52.4 }), "52%")
})

test("a running instance reports its rate, or that it is idle", () => {
  assert.strictEqual(Instances.stateLabel({ running: true, tokensPerSec: 24.47 }), "24.5 t/s")
  assert.strictEqual(Instances.stateLabel({ running: true, tokensPerSec: 0 }), "idle")
  assert.strictEqual(Instances.stateLabel({}), "stopped")
})

// ---- ownerLabel ----

test("a server this widget cannot stop says so", () => {
  assert.strictEqual(Instances.ownerLabel({ running: true, adopted: true, ownsUnit: false }), "external")
  assert.strictEqual(Instances.ownerLabel({ running: true, adopted: true, ownsUnit: true }), "adopted")
  assert.strictEqual(Instances.ownerLabel({ running: true }), "this widget")
  assert.strictEqual(Instances.ownerLabel({ running: false }), "")
})

// ---- aggregates ----

test("the bar adds up what every instance is generating", () => {
  const live = [
    { running: true, tokensPerSec: 20 },
    { running: true, tokensPerSec: 4.5 },
    { running: false, tokensPerSec: 99 },
    { running: true, tokensPerSec: 0 }
  ]
  assert.strictEqual(Instances.aggregateRate(live), 24.5)
  assert.strictEqual(Instances.aggregateRate([]), 0)
  assert.strictEqual(Instances.aggregateRate(undefined), 0)
})

test("ingestion is one prompt, so the furthest along is reported, not a sum", () => {
  const live = [
    { running: true, ppActive: true, ppPercent: 12 },
    { running: true, ppActive: true, ppPercent: 71 },
    { running: false, ppActive: true, ppPercent: 99 }
  ]
  assert.strictEqual(Instances.leadingPrompt(live).ppPercent, 71)
  assert.strictEqual(Instances.leadingPrompt([{ running: true }]), null)
})

test("the running tally counts only what is up", () => {
  assert.strictEqual(Instances.runningCount([
    { running: true }, { running: false }, { running: true }
  ]), 2)
  assert.strictEqual(Instances.runningCount([]), 0)
})

// ---- staleUnits ----

test("the indices a lowered count dropped are named for a sweep", () => {
  const units = Instances.staleUnits({
    pluginId: PLUGIN, backendId: "llamacpp", count: 2, unitName: Backends.unitName, max: 4
  })
  assert.deepStrictEqual(units, [
    "io-github-syjohnm-local-ai-server-llamacpp-2",
    "io-github-syjohnm-local-ai-server-llamacpp-3"
  ])
})

test("the primary is never swept, whatever the count says", () => {
  // Index 0 is adopted, not torn down: it is the server the page manages.
  for (const count of [1, 0, -5, "", null]) {
    const units = Instances.staleUnits({
      pluginId: PLUGIN, backendId: "llamacpp", count, unitName: Backends.unitName, max: 3
    })
    assert.ok(!units.some(u => u === "io-github-syjohnm-local-ai-server-llamacpp"),
      `count ${String(count)} must not sweep the primary`)
  }
})

test("a count at the cap leaves nothing to sweep", () => {
  assert.deepStrictEqual(Instances.staleUnits({
    pluginId: PLUGIN, backendId: "llamacpp",
    count: Instances.MAX_INSTANCES, unitName: Backends.unitName
  }), [])
})

test("without a namer there is nothing to sweep rather than an exception", () => {
  assert.deepStrictEqual(Instances.staleUnits({ count: 1 }), [])
  assert.deepStrictEqual(Instances.staleUnits(), [])
})
