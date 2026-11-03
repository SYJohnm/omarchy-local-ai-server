"use strict"

const test = require("node:test")
const assert = require("node:assert")
const { plan } = require("../Service.js")

function unit(overrides) {
  return Object.assign({
    persistent: true,
    exists: true,
    loadState: "loaded",
    activeState: "active",
    enabled: "enabled",
    configMatches: true
  }, overrides || {})
}

function desired(overrides) {
  return Object.assign({ running: true, enabled: true }, overrides || {})
}

function verbs(result) {
  return result.actions.map(a => a.verb)
}

test("a healthy running unit needs no action", () => {
  const result = plan({ desired: desired(), unit: unit(), endpoint: { responsive: true, healthy: true } })
  assert.deepStrictEqual(verbs(result), [])
  assert.strictEqual(result.healthy, true)
  assert.strictEqual(result.summary, "running and healthy")
})

test("a missing unit is written, reloaded and started", () => {
  const result = plan({
    desired: desired(),
    unit: unit({ exists: false, loadState: "not-found", activeState: "inactive" }),
    endpoint: { responsive: false, healthy: false }
  })
  assert.deepStrictEqual(verbs(result), ["write-unit", "daemon-reload", "start"])
})

test("a failed unit is reset before it is started again", () => {
  const result = plan({
    desired: desired(),
    unit: unit({ activeState: "failed", enabled: "disabled" }),
    endpoint: { responsive: false, healthy: false }
  })
  assert.deepStrictEqual(verbs(result), ["reset-failed", "start", "enable"])
})

test("an active unit with an unhealthy endpoint is restarted", () => {
  const result = plan({
    desired: desired(),
    unit: unit(),
    endpoint: { responsive: true, healthy: false }
  })
  assert.deepStrictEqual(verbs(result), ["restart"])
  assert.strictEqual(result.healthy, false)
})

test("a config change rewrites and restarts an active unit", () => {
  const result = plan({
    desired: desired(),
    unit: unit({ configMatches: false }),
    endpoint: { responsive: true, healthy: true }
  })
  assert.deepStrictEqual(verbs(result), ["write-unit", "daemon-reload", "restart"])
})

test("a config change while stopped is written but not restarted", () => {
  const result = plan({
    desired: desired({ running: false }),
    unit: unit({ activeState: "inactive", configMatches: false }),
    endpoint: { responsive: false, healthy: false }
  })
  assert.deepStrictEqual(verbs(result), ["write-unit", "daemon-reload"])
  assert.strictEqual(result.healthy, true)
})

test("desired stopped stops an active unit and clears a failed one", () => {
  const active = plan({
    desired: desired({ running: false }),
    unit: unit(),
    endpoint: { responsive: true, healthy: true }
  })
  assert.deepStrictEqual(verbs(active), ["stop"])

  const failed = plan({
    desired: desired({ running: false }),
    unit: unit({ activeState: "failed" }),
    endpoint: { responsive: false, healthy: false }
  })
  assert.deepStrictEqual(verbs(failed), ["reset-failed"])
})

test("enabled state is reconciled only for persistent units", () => {
  const enabled = plan({
    desired: desired({ enabled: true }),
    unit: unit({ enabled: "disabled" }),
    endpoint: { responsive: true, healthy: true }
  })
  assert.deepStrictEqual(verbs(enabled), ["enable"])

  const transient = plan({
    desired: desired({ enabled: true }),
    unit: unit({ persistent: false, enabled: "static" }),
    endpoint: { responsive: true, healthy: true }
  })
  assert.deepStrictEqual(verbs(transient), [])
})

test("a unit that is still activating is waited on, not restarted", () => {
  const result = plan({
    desired: desired(),
    unit: unit({ activeState: "activating" }),
    endpoint: { responsive: false, healthy: false }
  })
  assert.deepStrictEqual(verbs(result), [])
  assert.strictEqual(result.healthy, false)
})

test("a not-found load state is treated like a missing unit", () => {
  const result = plan({
    desired: desired(),
    unit: unit({ exists: undefined, loadState: "not-found", activeState: "inactive" }),
    endpoint: { responsive: false, healthy: false }
  })
  assert.deepStrictEqual(verbs(result), ["write-unit", "daemon-reload", "start"])
})
