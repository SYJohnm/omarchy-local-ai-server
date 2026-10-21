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
