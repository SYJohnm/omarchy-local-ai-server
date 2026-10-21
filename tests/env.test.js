const test = require("node:test")
const assert = require("node:assert")
const Model = require("../Model.js")

test("parseEnvAssignments reads bare, quoted and empty values", () => {
  const out = Model.parseEnvAssignments(`A=1 B="two words" C='three words' D= E=""`)
  assert.deepStrictEqual(out.env, [
    { name: "A", value: "1" },
    { name: "B", value: "two words" },
    { name: "C", value: "three words" },
    { name: "D", value: "" },
    { name: "E", value: "" }
  ])
  assert.deepStrictEqual(out.invalid, [])
})

test("parseEnvAssignments keeps the last duplicate and preserves order", () => {
  const out = Model.parseEnvAssignments("A=1 B=2 A=3")
  assert.deepStrictEqual(out.env, [
    { name: "A", value: "3" },
    { name: "B", value: "2" }
  ])
})

test("parseEnvAssignments reports malformed assignments", () => {
  const out = Model.parseEnvAssignments("1BAD=1 NOEQUALS BAD-NAME=3 GOOD=ok")
  assert.deepStrictEqual(out.env, [{ name: "GOOD", value: "ok" }])
  assert.deepStrictEqual(out.invalid, ["1BAD=1", "NOEQUALS", "BAD-NAME=3"])
})

test("formatEnvAssignments round-trips spaces, quotes and backslashes", () => {
  const env = [
    { name: "PLAIN", value: "value" },
    { name: "SPACES", value: "two words" },
    { name: "QUOTES", value: `he said "hi" and 'bye'` },
    { name: "BACKSLASH", value: "C:\\models\\x" },
    { name: "EMPTY", value: "" }
  ]
  const text = Model.formatEnvAssignments(env)
  assert.deepStrictEqual(Model.parseEnvAssignments(text).env, env)
})

test("formatEnvAssignments skips invalid names", () => {
  assert.strictEqual(Model.formatEnvAssignments([{ name: "1BAD", value: "x" }]), "")
})
