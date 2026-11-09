const test = require("node:test")
const assert = require("node:assert")

const Model = require("../Model.js")
const Backends = require("../Backends.js")

test("slotFilePrefix splits a slot file name", () => {
  assert.equal(Model.slotFilePrefix("qwen.gguf-77c342cd.slot0.bin"), "qwen.gguf-77c342cd")
  assert.equal(Model.slotFilePrefix("qwen.gguf.slot12.bin"), "qwen.gguf")
})

test("slotFilePrefix refuses anything that is not a slot file", () => {
  // The sweep deletes what this names, so an unrecognised file must score "".
  assert.equal(Model.slotFilePrefix("notes.txt"), "")
  assert.equal(Model.slotFilePrefix("qwen.gguf.slot.bin"), "")
  assert.equal(Model.slotFilePrefix(".staging"), "")
  assert.equal(Model.slotFilePrefix(""), "")
  assert.equal(Model.slotFilePrefix(null), "")
})

test("parseSlotListing reads find's size/name pairs", () => {
  const files = Model.parseSlotListing("1024\ta.gguf.slot0.bin\n2048\tb.gguf.slot1.bin\n")
  assert.deepEqual(files, [
    { name: "a.gguf.slot0.bin", size: 1024 },
    { name: "b.gguf.slot1.bin", size: 2048 },
  ])
})

test("parseSlotListing drops malformed and nested entries", () => {
  // A name carrying a separator did not come from the flat listing.
  const files = Model.parseSlotListing("\n5\t.staging/x.bin\nnotanumber\tz.bin\n7\t\n12\tok.gguf.slot0.bin\n")
  assert.deepEqual(files, [{ name: "ok.gguf.slot0.bin", size: 12 }])
})

test("slotOrphans keeps live models and sweeps the rest", () => {
  const live = "/home/u/models/qwen.gguf"
  const keep = [Backends.slotPrefix(live), Backends.legacySlotPrefix(live)]
  const files = [
    { name: Backends.slotPrefix(live) + ".slot0.bin", size: 10 },
    { name: Backends.legacySlotPrefix(live) + ".slot1.bin", size: 20 },
    { name: "deleted-model.gguf-deadbeef.slot0.bin", size: 30 },
  ]
  const orphans = Model.slotOrphans(files, keep)
  assert.deepEqual(orphans.map(f => f.name), ["deleted-model.gguf-deadbeef.slot0.bin"])
})

test("slotOrphans never returns a non-slot file", () => {
  const files = [{ name: "README", size: 1 }, { name: "writer.lock", size: 2 }]
  assert.deepEqual(Model.slotOrphans(files, []), [])
})

test("slotOrphans tolerates empty input", () => {
  assert.deepEqual(Model.slotOrphans(null, null), [])
  assert.deepEqual(Model.slotOrphans([], ["x"]), [])
})

test("legacySlotPrefix is slotPrefix without the hash", () => {
  const p = "/home/u/models/My Model.gguf"
  assert.equal(Backends.legacySlotPrefix(p), "My_Model.gguf")
  assert.ok(Backends.slotPrefix(p).startsWith("My_Model.gguf-"))
  assert.equal(Backends.legacySlotPrefix(""), "")
})

test("totalSlotBytes sums sizes", () => {
  assert.equal(Model.totalSlotBytes([{ size: 1 }, { size: 2 }, {}]), 3)
  assert.equal(Model.totalSlotBytes(null), 0)
})

test("formatBytes reads in binary units", () => {
  assert.equal(Model.formatBytes(0), "0 B")
  assert.equal(Model.formatBytes(512), "512 B")
  assert.equal(Model.formatBytes(1536), "1.5 KB")
  assert.equal(Model.formatBytes(3 * 1024 * 1024 * 1024), "3.0 GB")
})
