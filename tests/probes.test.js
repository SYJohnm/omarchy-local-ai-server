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
  '    pw=$([ -r /etc/passwd ] && echo sawetcpw || echo noetcpw)',
  '    printf "%s\\n" "  -ctk,  --cache-type-k TYPE" \\',
  '      "                 allowed values: uid$(id -u), $home, $caps, $pw"',
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
    // The sandbox shows only what linking needs, not the account config.
    assert.ok(build.cacheTypes.includes("noetcpw"),
      "/etc/passwd was readable from inside: " + build.cacheTypes.join(" "))

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

// A build with BUILD_SHARED_LIBS=OFF has no libggml-cuda.so beside it, which
// is not the same as having no GPU backend. Reported as "CPU", it sent people
// to the wrong build for the exact reason they keep several of them.
test("llama_builds reads the GPU backend of a statically linked build", () => {
  const home = tmpdir()
  try {
    const dir = path.join(home, "static-build", "build", "bin")
    fs.mkdirSync(dir, { recursive: true })
    const fake = path.join(dir, "llama-server")
    // No sibling ggml libraries; the runtime is named in the file itself, as
    // a DT_NEEDED entry would be.
    fs.writeFileSync(fake, SNITCH().replace("#!/bin/sh",
      "#!/bin/sh\n# NEEDED libcudart.so.13 libcublas.so.13"))
    fs.chmodSync(fake, 0o755)
    const build = probe(home, ["--trust", fake]).find((b) => b.path === fake)
    assert.ok(build, "static build was not listed")
    assert.strictEqual(build.gpu, "CUDA", "a static CUDA build was reported as " + build.gpu)
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
})

// Most forks rename themselves and the repository name identifies them. One
// that kept the upstream name does not: unslothai/llama.cpp and
// ggml-org/llama.cpp both came out "llama.cpp", so the Build picker showed two
// identical rows for the one thing it exists to tell apart.
test("llama_builds names a fork that kept the upstream repository name", () => {
  const home = tmpdir()
  try {
    const root = path.join(home, "someones-llamacpp")
    const dir = path.join(root, "build", "bin")
    fs.mkdirSync(dir, { recursive: true })
    execFileSync("git", ["init", "-q", root], { encoding: "utf8" })
    execFileSync("git", ["-C", root, "remote", "add", "origin",
      "https://github.com/unslothai/llama.cpp"], { encoding: "utf8" })
    const fake = path.join(dir, "llama-server")
    fs.writeFileSync(fake, SNITCH())
    fs.chmodSync(fake, 0o755)
    const build = probe(home, ["--trust", fake]).find((b) => b.path === fake)
    assert.ok(build, "fork build was not listed")
    assert.strictEqual(build.fork, "unslothai",
      "a fork of llama.cpp is indistinguishable from upstream: " + build.fork)
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
})

// "bin" names no build. A release unpacked as llamacpp-0.9.0/bin/llama-server
// has no build/ segment, so the directory holding the binary is plumbing and
// the one above it is the name.
test("llama_builds names a build sitting in a plain bin directory", () => {
  const home = tmpdir()
  try {
    // Named as a path to look at as well as trusted: a plain bin directory
    // is not somewhere the scan looks on its own.
    const fake = fakeBuild(path.join(home, "llamacpp-0.9.0", "bin"))
    const build = probe(home, [fake, "--trust", fake]).find((b) => b.path === fake)
    assert.ok(build, "build was not listed")
    assert.strictEqual(build.fork, "llamacpp-0.9.0", "named after plumbing: " + build.fork)
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
})

// A build reached through a symlink -- ~/.local/bin/llama-server pointing into
// an unpacked release -- is the common shape of a hand-installed llama.cpp.
// The sandbox binds the directory the file really lives in, so invoking it by
// the link's path finds nothing there, and failing to exec looks exactly like
// "not a llama-server": the build was listed, unidentified, for no stated
// reason.
test("llama_builds identifies a build reached through a symlink", () => {
  const home = tmpdir()
  try {
    const real = fakeBuild(path.join(home, "llamacpp-9.9.9", "bin"))
    const linkDir = path.join(home, ".local", "bin")
    fs.mkdirSync(linkDir, { recursive: true })
    const link = path.join(linkDir, "llama-server")
    fs.symlinkSync(real, link)

    const build = probe(home, ["--trust", link]).find((b) => b.path === link)
    assert.ok(build, "symlinked build was not listed")
    assert.strictEqual(build.version, "9.9", "not identified through the link")
    assert.strictEqual(build.real, real, "the link's target was not recorded")
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
})

// A hand-installed llama.cpp is usually a link in ~/.local/bin pointing at an
// unpacked release elsewhere. Resolving the link first threw away the one
// thing that said the user meant to install it -- that they put it there --
// and the build was held for approval on its target's location instead.
test("llama_builds trusts a link the user placed in an install directory", () => {
  const home = tmpdir()
  try {
    const real = fakeBuild(path.join(home, "llamacpp-9.9.9", "bin"))
    const linkDir = path.join(home, ".local", "bin")
    fs.mkdirSync(linkDir, { recursive: true })
    const link = path.join(linkDir, "llama-server")
    fs.symlinkSync(real, link)

    const build = probe(home).find((b) => b.path === link)
    assert.ok(build, "the installed build was not listed")
    assert.ok(!build.needsApproval,
      "held despite being installed in ~/.local/bin: " + JSON.stringify(build.why))
    assert.ok(!build.missing, "installed build was kept out of Auto")

    // The release it points at is still only a release: found on its own, it
    // is not installed and still asks.
    const direct = probe(home).find((b) => b.path === real)
    assert.ok(!direct || direct.needsApproval === true,
      "the target vouched for itself through the link")
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
})

test("llama_builds caps what a build can print into the probe", () => {
  // The sandbox bounds what a build can reach, not what it writes, and the
  // probe reads its output into a Python process that is not confined. Under
  // a 256 MB address-space limit this used to die with MemoryError in under a
  // second, and four builds are identified at once.
  const dir = tmpdir()
  try {
    const bin = path.join(dir, "llama-server")
    fs.writeFileSync(bin, "#!/bin/sh\nexec dd if=/dev/zero bs=1M 2>/dev/null\n")
    fs.chmodSync(bin, 0o755)
    const out = execFileSync("python3", ["-I", "-c", [
      "import resource, sys",
      "resource.setrlimit(resource.RLIMIT_AS, (256 << 20, 256 << 20))",
      "sys.path.insert(0, " + JSON.stringify(ROOT) + ")",
      "import llama_builds as L",
      "box = " + JSON.stringify(dir) + " if L.BWRAP else None",
      "print(len(L.run([" + JSON.stringify(bin) + ", '--version'], confine=box) or ''))"
    ].join("\n")], { encoding: "utf8", timeout: 60000 })
    assert.strictEqual(Number(out.trim()), 1024 * 1024,
      "the probe read more than the cap, or died trying")
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test("llama_builds reads a whole real-sized --help", () => {
  // Builds here print 60-75 KB of --help, and the flags the panel reads to
  // decide which options a build accepts are spread through all of it. A cap
  // that merely looks generous (64 KiB did) silently drops the last ones.
  const home = tmpdir()
  try {
    const dir = path.join(home, "Downloads", "llama-big-help")
    fs.mkdirSync(dir, { recursive: true })
    const bin = path.join(dir, "llama-server")
    fs.writeFileSync(bin, [
      "#!/bin/sh",
      'case "$1" in',
      '  --version) echo "version: 9.9 (build 42, commit abcdef0)" ;;',
      '  --help)',
      '    i=0',
      '    while [ $i -lt 2000 ]; do',
      '      echo "  --filler-$i N            padding padding padding padding padding"',
      '      i=$((i + 1))',
      '    done',
      '    echo "  -ctk, --cache-type-k TYPE  the last flag in a long listing"',
      '    ;;',
      "esac",
      ""
    ].join("\n"))
    fs.chmodSync(bin, 0o755)

    const build = probe(home).find((b) => b.path === bin)
    assert.ok(build, "the build was not listed at all")
    assert.ok(build.flags.includes("--cache-type-k"),
      "the end of a 100 KB --help was cut off: " + build.flags.length + " flags read")
  } finally {
    fs.rmSync(home, { recursive: true, force: true })
  }
})
