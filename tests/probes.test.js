const test = require("node:test")
const assert = require("node:assert")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const { execFileSync } = require("node:child_process")

const ROOT = path.join(__dirname, "..")
const PROBE = path.join(ROOT, "gguf_probe.py")
const BLOBS = path.join(ROOT, "ollama_blobs.py")
const BUILDS = path.join(ROOT, "llama_builds.py")

function tmpdir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "local-ai-"))
}

function ggufString(s) {
  const b = Buffer.from(s)
  const len = Buffer.alloc(8)
  len.writeBigUInt64LE(BigInt(b.length))
  return Buffer.concat([len, b])
}

test("gguf_probe caps a huge string and keeps parsing the next key", () => {
  const dir = tmpdir()
  try {
    const file = path.join(dir, "huge.gguf")
    const header = Buffer.alloc(24)
    header.write("GGUF", 0)
    header.writeUInt32LE(3, 4)
    header.writeBigUInt64LE(0n, 8) // tensors
    header.writeBigUInt64LE(2n, 16) // kv pairs

    const type8 = Buffer.alloc(4)
    type8.writeUInt32LE(8)
    const huge = "A".repeat(2 * 1024 * 1024)
    const kv1 = Buffer.concat([ggufString("tokenizer.chat_template"), type8, ggufString(huge)])
    const kv2 = Buffer.concat([ggufString("general.name"), type8, ggufString("test")])
    fs.writeFileSync(file, Buffer.concat([header, kv1, kv2]))

    const out = JSON.parse(execFileSync("python3", [PROBE, file], {
      encoding: "utf8",
      maxBuffer: 8 * 1024 * 1024
    }))
    assert.strictEqual(out[file]["general.name"], "test")
    assert.strictEqual(out[file]["tokenizer.chat_template"].length, 1 << 20)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

function ggufHeader(tensors, kvPairs) {
  const header = Buffer.alloc(24)
  header.write("GGUF", 0)
  header.writeUInt32LE(3, 4)
  header.writeBigUInt64LE(BigInt(tensors), 8)
  header.writeBigUInt64LE(BigInt(kvPairs), 16)
  return header
}

function u32(n) {
  const b = Buffer.alloc(4)
  b.writeUInt32LE(n)
  return b
}

function u64(n) {
  const b = Buffer.alloc(8)
  b.writeBigUInt64LE(BigInt(n))
  return b
}

function probeFile(file) {
  return JSON.parse(execFileSync("python3", ["-I", PROBE, file], {
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
    timeout: 30000
  }))[file]
}

test("gguf_probe refuses an array whose element count cannot fit, instead of spinning", () => {
  // The bound used to be `count > bytes left`, which bounds bytes rather than
  // elements. With a one-byte element type that let count reach the size of
  // the file and the skip loop then ran that many times: 83 ns an element, so
  // a 20 GB model allowed about half an hour on one file with the panel stuck
  // on "Scanning...". The file can be sparse, so it costs 4 KB on disk.
  const dir = tmpdir()
  try {
    const file = path.join(dir, "huge-array.gguf")
    const N = 200_000_000
    const body = Buffer.concat([
      ggufHeader(0, 1),
      ggufString("x"), u32(9),   // value type 9 = array
      u32(0),                     // element type 0 = uint8, one byte each
      u64(N)
    ])
    const fd = fs.openSync(file, "w")
    fs.writeSync(fd, body)
    fs.ftruncateSync(fd, body.length + N + 1024) // sparse: bytes left > count
    fs.closeSync(fd)
    assert.ok(fs.statSync(file).size > N, "the declared count must fit in the file")

    const started = Date.now()
    const out = probeFile(file)
    const elapsed = Date.now() - started
    // Seeked past in one step rather than walked. Before the fix this file
    // took 16.6 s; the budget is loose enough for a slow machine and still
    // nowhere near a walk.
    assert.ok(elapsed < 5000, "took " + elapsed + "ms, which means it walked the array")
    // It stops at that key rather than inventing data for it.
    assert.ok(!("x" in out), JSON.stringify(out))
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test("gguf_probe rejects an array of strings that cannot fit", () => {
  // A string element costs at least its 8-byte length, which is the bound.
  const dir = tmpdir()
  try {
    const file = path.join(dir, "string-array.gguf")
    fs.writeFileSync(file, Buffer.concat([
      ggufHeader(0, 1),
      ggufString("x"), u32(9),
      u32(8),            // element type 8 = string
      u64(1_000_000)     // far more than 8 bytes each in this tiny file
    ]))
    assert.match(probeFile(file).error, /runs past end of file/)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test("gguf_probe rejects an implausible metadata or tensor count", () => {
  // Both counts are read straight from the header. Each loop eats at least a
  // dozen bytes a turn, so on a large model an absurd count is minutes of
  // walking before it reaches the end.
  const dir = tmpdir()
  try {
    const kv = path.join(dir, "kv.gguf")
    fs.writeFileSync(kv, ggufHeader(0, 2 ** 40))
    assert.match(probeFile(kv).error, /metadata keys/)

    const tensors = path.join(dir, "tensors.gguf")
    fs.writeFileSync(tensors, ggufHeader(2 ** 40, 0))
    assert.match(probeFile(tensors).error, /tensors/)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test("gguf_probe still reads a normal array-valued key", () => {
  // The fix must not skip arrays the probe is meant to walk past.
  const dir = tmpdir()
  try {
    const file = path.join(dir, "ok.gguf")
    fs.writeFileSync(file, Buffer.concat([
      ggufHeader(0, 2),
      // An ordinary uint32 array, as a tokenizer list would be.
      ggufString("tokenizer.ggml.token_type"), u32(9), u32(4), u64(3),
      u32(1), u32(1), u32(1),
      ggufString("general.name"), u32(8), ggufString("after the array")
    ]))
    assert.strictEqual(probeFile(file)["general.name"], "after the array")
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test("ollama_blobs ignores a manifest digest that escapes the store", () => {
  const dir = tmpdir()
  try {
    const store = path.join(dir, "store")
    const manifests = path.join(store, "manifests", "registry.ollama.ai", "library", "bad")
    fs.mkdirSync(manifests, { recursive: true })
    fs.mkdirSync(path.join(store, "blobs"), { recursive: true })
    // store/blobs/../../escape resolves to this file.
    fs.writeFileSync(path.join(dir, "escape"), Buffer.concat([Buffer.from("GGUF"), Buffer.alloc(8)]))

    const digest = "a".repeat(64)
    const blob = path.join(store, "blobs", "sha256-" + digest)
    fs.writeFileSync(blob, Buffer.concat([Buffer.from("GGUF"), Buffer.alloc(8)]))

    fs.writeFileSync(path.join(manifests, "1"), JSON.stringify({
      layers: [
        { mediaType: "application/vnd.ollama.image.model", digest: "../../escape", size: 12 },
        { mediaType: "application/vnd.ollama.image.model", digest: "sha256:" + digest, size: 12 }
      ]
    }))

    const out = JSON.parse(execFileSync("python3", [BLOBS, store], { encoding: "utf8" }))
    assert.deepStrictEqual(Object.keys(out), ["bad:1"])
    assert.strictEqual(out["bad:1"].path, blob)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test("llama_builds emits both long and short flags from --help", () => {
  const dir = tmpdir()
  try {
    const fake = path.join(dir, "fake-llama-server")
    fs.writeFileSync(fake, [
      "#!/bin/sh",
      'case "$1" in',
      '  --version) echo "version: 1234 (build 5678, commit abcdef0)" ;;',
      '  --help) printf "%s\\n" \\',
      '    "-t,    --threads N                      number of CPU threads" \\',
      '    "-ngl, --gpu-layers N                   layers to offload" \\',
      '    "--flash-attn [on|off|auto]             flash attention" ;;',
      "esac",
      ""
    ].join("\n"))
    fs.chmodSync(fake, 0o755)

    const builds = JSON.parse(execFileSync("python3", [BUILDS, fake], { encoding: "utf8" }))
    const build = builds.find((b) => b.path === fake)
    assert.ok(build, "fake build was not described")
    for (const flag of ["-t", "--threads", "-ngl", "--gpu-layers", "--flash-attn"])
      assert.ok(build.flags.includes(flag), flag + " missing from " + build.flags.join(" "))
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

// Identifying a build means running it: --version carries the build number
// and commit, --help the KV cache types, and nothing on disk carries either.
// So the run is confined instead of avoided, and these tests prove the
// confinement rather than assuming it -- the fake build reports its uid,
// whether it can see /home and whether it kept any capabilities, smuggled out
// through --cache-type-k's allowed values, which is a field the probe parses.
// Asserting only that the build is absent from the list would prove nothing:
// it would pass just as well if the binary had been run unconfined and then
// rejected.
const SNITCH = (extra) => [
  "#!/bin/sh",
  'case "$1" in',
  '  --version) echo "version: 9.9 (build 42, commit abcdef0)" ;;',
  '  --help)',
  '    caps=$(awk \'/CapEff/{print ($2 == "0000000000000000") ? "nocaps" : "hascaps"}\' /proc/self/status)',
  '    home=$([ -d /home ] && echo sawhome || echo nohome)',
  '    printf "%s\\n" "  -ctk,  --cache-type-k TYPE" \\',
  '      "                 allowed values: uid$(id -u), $home, $caps"',
  '    ;;',
  "esac",
  ...(extra || []),
  ""
].join("\n")

function fakeBuild(dir, name) {
  fs.mkdirSync(dir, { recursive: true })
  const file = path.join(dir, name || "llama-server")
  fs.writeFileSync(file, SNITCH())
  fs.chmodSync(file, 0o755)
  return file
}

function probe(home, args) {
  return JSON.parse(execFileSync("python3", [BUILDS].concat(args || []), {
    encoding: "utf8",
    env: { ...process.env, HOME: home }
  }))
}

test("a build under ~/Downloads is identified in a sandbox, not launched", () => {
  const home = tmpdir()
  try {
    const fake = fakeBuild(path.join(home, "Downloads", "llama-test-bin", "llama-test"))
    const build = probe(home).find((b) => b.path === fake)

    assert.ok(build, "the build was not listed; the user cannot decide about a build they cannot see")
    assert.strictEqual(build.version, "9.9", "it was not identified, so it was never actually run")

    // What the sandbox was for.
    assert.ok(build.cacheTypes.includes("uid65534"),
      "ran as the desktop user, not as nobody: " + build.cacheTypes.join(" "))
    assert.ok(build.cacheTypes.includes("nohome"),
      "the user's home was reachable from inside: " + build.cacheTypes.join(" "))
    assert.ok(build.cacheTypes.includes("nocaps"),
      "kept capabilities: " + build.cacheTypes.join(" "))

    // Identified is not launchable. `missing` is what keeps it out of Auto.
    assert.strictEqual(build.needsApproval, true)
    assert.strictEqual(build.missing, true)
    assert.ok((build.why || []).join(" ").includes("Downloads"),
      "no reason given for holding it: " + JSON.stringify(build.why))
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
})

test("--trust makes a held build launchable", () => {
  const home = tmpdir()
  try {
    const fake = fakeBuild(path.join(home, "Downloads", "llama-test-bin", "llama-test"))
    const build = probe(home, ["--trust", fake]).find((b) => b.path === fake)
    assert.ok(build, "a trusted build vanished from the list")
    assert.strictEqual(build.version, "9.9")
    assert.ok(!build.needsApproval, "still held after being trusted")
    assert.ok(!build.missing, "still kept out of Auto after being trusted")
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
})

// Naming a path says where to look, which is not the same as vouching for
// what is at it -- a stale or mistyped path would otherwise carry the
// authority of an approval.
test("a configured path is not itself approval", () => {
  const home = tmpdir()
  try {
    const fake = fakeBuild(path.join(home, "Downloads", "llama-test-bin"))
    const build = probe(home, [fake]).find((b) => b.path === fake)
    assert.ok(build, "a configured build was not listed")
    assert.strictEqual(build.version, "9.9", "a configured build was not identified")
    assert.strictEqual(build.needsApproval, true, "a configured path approved itself")
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
})

test("a configured fork path that disappeared is reported as missing", () => {
  const dir = tmpdir()
  try {
    const gone = path.join(dir, "gone", "llama-server")
    const builds = JSON.parse(execFileSync("python3", [BUILDS, gone], { encoding: "utf8" }))
    const entry = builds.find((b) => b.path === gone)
    assert.ok(entry, "missing configured path was silently dropped")
    assert.strictEqual(entry.missing, true)
    assert.strictEqual(entry.fork, "missing")
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})
