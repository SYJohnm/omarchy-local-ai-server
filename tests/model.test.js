const test = require("node:test")
const assert = require("node:assert")
const Model = require("../Model.js")
const Backends = require("../Backends.js")
const Hardware = require("../Hardware.js")

// Real lines captured from `journalctl -u ollama` on 2026-09-06, running
// qwen3:8b. ollama embeds llama.cpp and re-exports its server logs verbatim,
// so these double as llama.cpp coverage for the prefixed format.
const OLLAMA_PP = "Sep 06 00:23:01 host ollama[390904]: slot print_timing: id  0 | task 0 | prompt eval time =     521.34 ms /    11 tokens (   47.39 ms per token,    21.10 tokens per second)"
const OLLAMA_TG = "Sep 06 00:23:01 host ollama[390904]: slot print_timing: id  0 | task 0 |        eval time =     941.26 ms /     8 tokens (  134.47 ms per token,     7.44 tokens per second)"
const OLLAMA_TOTAL = "Sep 06 00:23:01 host ollama[390904]: slot print_timing: id  0 | task 0 |       total time =    1462.59 ms /    19 tokens"

// The bare, unprefixed form older llama.cpp builds emit.
const BARE_PP = "prompt eval time =    1234.56 ms /   512 tokens (    2.41 ms per token,   414.72 tokens per second)"
const BARE_TG = "       eval time =    1234.56 ms /   128 tokens (    9.65 ms per token,   103.63 tokens per second)"

test("parseTimingLine distinguishes pp from tg on prefixed lines", () => {
  // The regression this guards: an anchored ^prompt test misses the marker on
  // "slot print_timing: ... | prompt eval time" and reports pp as tg.
  assert.deepStrictEqual(Model.parseTimingLine(OLLAMA_PP), { kind: "pp", tps: 21.10 })
  assert.deepStrictEqual(Model.parseTimingLine(OLLAMA_TG), { kind: "tg", tps: 7.44 })
})

test("parseTimingLine handles the bare llama.cpp form", () => {
  assert.deepStrictEqual(Model.parseTimingLine(BARE_PP), { kind: "pp", tps: 414.72 })
  assert.deepStrictEqual(Model.parseTimingLine(BARE_TG), { kind: "tg", tps: 103.63 })
})

test("parseTimingLine ignores non-timing lines", () => {
  assert.strictEqual(Model.parseTimingLine(OLLAMA_TOTAL), null, "total time has no t/s clause")
  assert.strictEqual(Model.parseTimingLine("srv update_slots: all slots are idle"), null)
  assert.strictEqual(Model.parseTimingLine(""), null)
  assert.strictEqual(Model.parseTimingLine(null), null)
})

test("parseTokensPerSecond stays tg-only", () => {
  assert.strictEqual(Model.parseTokensPerSecond(OLLAMA_TG), 7.44)
  assert.strictEqual(Model.parseTokensPerSecond(OLLAMA_PP), null, "pp must not be reported as tg")
  assert.strictEqual(Model.parseTokensPerSecond(BARE_PP), null)
})

test("parsePromptProgressLine reads live ingestion progress", () => {
  // Real line from llama-server while ingesting a long prompt; /slots reports
  // the same sweep with n_prompt_tokens_processed flat between batches, which
  // is why this line, not the poll, is what puts a rate next to the percent.
  const line = "5.27.453.169 I slot print_timing: id  0 | task 118 | prompt processing, n_tokens =  14336, progress = 0.46, t = 280.52 s / 51.11 tokens per second"
  assert.deepStrictEqual(Model.parsePromptProgressLine(line),
                         { kind: "pp_progress", tps: 51.11, percent: 46 })
  assert.strictEqual(Model.parsePromptProgressLine(OLLAMA_PP), null, "completion timings are not progress")
  assert.strictEqual(Model.parsePromptProgressLine("unrelated log line"), null)
})

test("metricText degrades when pp percent is unknown", () => {
  // The ollama path has no live pp% sweep; the bar must still render.
  assert.strictEqual(Model.metricText(true, false, 0, 7.44, 0), "7.4 t/s")
  assert.strictEqual(Model.metricText(true, true, 94, 0, 320), "94% - 320 t/s")
  assert.strictEqual(Model.metricText(true, true, 45, 0, 0), "45%", "percent alone when the rate is unknown")
  assert.strictEqual(Model.metricText(false, true, 94, 0, 320), "", "hidden when showMetric is off")
})

// Real sequence from a crashed llama-server unit: the diagnostic, then the
// C++ exception, then systemd-coredump's backtrace, then systemd's summary.
// The useful line is in the middle; everything after it is louder and matches
// the same keywords.
const CRASH_LOG = [
  "0.00.034.474 I srv    load_model: loading model '/var/lib/ollama/blobs/sha256-dec52a…'",
  "0.00.430.315 E llama_model_load: error loading model: error loading model hyperparameters: key qwen35.rope.dimension_sections has wrong array length; expected 4, got 3",
  "0.00.571.354 E common_fit_params: encountered an error while trying to fit params to free device memory: failed to load model",
  "terminate called after throwing an instance of 'std::runtime_error'",
  "  what():  failed to fit parameters to device memory (hard error); retry with -fit off",
  "Process 2548865 (llama-server) of user 1000 dumped core.",
  "Stack trace of thread 2548865:",
  "#0  0x00007f6f5745e07c n/a (libc.so.6 + 0x9e07c)",
  "#2  0x00007f6f57425685 abort (libc.so.6 + 0x25685)",
  "#7  0x00007f6f6b903792 in common_init_result::common_init_result() [clone .cold] ()",
  "ELF object binary architecture: AMD x86-64",
  "sxy-local-ai-server-llamacpp.service: Main process exited, code=dumped, status=6/ABRT",
  "sxy-local-ai-server-llamacpp.service: Failed with result 'core-dump'."
]

test("crash triage reports the application's error, not the noise around it", () => {
  const picked = Model.pickErrorLine(CRASH_LOG, "")
  assert.match(picked, /failed to fit parameters to device memory/,
    "the exception message, not a backtrace frame or systemd's summary")
  assert.ok(!/^#\d/.test(picked), "never a stack frame")
  assert.ok(!/Failed with result/.test(picked), "never systemd's verdict")
  assert.ok(!/ELF object/.test(picked), "never coredump metadata")
})

test("coredump and systemd lines are classified", () => {
  assert.ok(Model.isCoredumpNoise("#2  0x00007f6f57425685 abort (libc.so.6 + 0x25685)"))
  assert.ok(Model.isCoredumpNoise("ELF object binary architecture: AMD x86-64"))
  assert.ok(Model.isCoredumpNoise("Stack trace of thread 2548865:"))
  assert.ok(Model.isSystemdNoise("foo.service: Failed with result 'core-dump'."))
  assert.ok(Model.isSystemdNoise("Main process exited, code=dumped, status=6/ABRT"))
  // An application line that merely mentions a module must not be swallowed.
  assert.ok(!Model.isCoredumpNoise("error loading model: unsupported architecture"))
  assert.ok(!Model.isSystemdNoise("0.00.430.315 E llama_model_load: error loading model"))
})

test("triage degrades gracefully", () => {
  // Nothing but noise: systemd's summary beats reporting nothing at all.
  assert.match(Model.pickErrorLine(["svc.service: Failed with result 'core-dump'."], ""), /Failed with result/)
  // No log at all: fall back to the last line seen.
  assert.strictEqual(Model.pickErrorLine([], "last thing"), "last thing")
  assert.strictEqual(Model.pickErrorLine([], ""), "")
  // Plain output with no error keyword still reports something.
  assert.strictEqual(Model.pickErrorLine(["listening on 127.0.0.1:8080"], ""), "listening on 127.0.0.1:8080")
})

test("cache-type helpers are exported", () => {
  // These were reachable from QML but missing from module.exports, so the
  // binary-selection logic could not be tested at all.
  assert.strictEqual(Model.recommendedCacheTypeV("turbo4"), "turbo3")
  assert.strictEqual(Model.recommendedCacheTypeV("q8_0"), null)
  assert.strictEqual(Model.isTurboQuantCacheType("vbr"), true)
  assert.strictEqual(Model.isTurboQuantCacheType("q8_0"), false)
})

test("backend registry resolves and falls back", () => {
  assert.strictEqual(Backends.get("ollama").defaultPort, 11434)
  assert.strictEqual(Backends.get("llamacpp").defaultPort, 8080)
  assert.strictEqual(Backends.get("nonsense").id, "llamacpp", "unknown id falls back")
  assert.strictEqual(Backends.supports("ollama", "slotKv"), false)
  assert.strictEqual(Backends.supports("llamacpp", "slotKv"), true)
})

test("backend URLs match each server's actual API", () => {
  assert.strictEqual(Backends.healthUrl("ollama", "127.0.0.1", 11434), "http://127.0.0.1:11434/api/version")
  assert.strictEqual(Backends.healthUrl("llamacpp", "127.0.0.1", 8080), "http://127.0.0.1:8080/health")
  assert.strictEqual(Backends.loadedModelsUrl("ollama", "h", 1), "http://h:1/api/ps")
  assert.strictEqual(Backends.loadedModelsUrl("llamacpp", "h", 1), "http://h:1/slots")
})

test("ollama launch puts host in the environment, not argv", () => {
  const out = Backends.ollamaLaunch({ binary: "ollama", host: "0.0.0.0", port: 11434 })
  assert.deepStrictEqual(out.argv, ["ollama", "serve"])
  assert.strictEqual(out.env.OLLAMA_HOST, "0.0.0.0:11434")
  assert.ok(!("OLLAMA_MODELS" in out.env), "models dir omitted unless overridden")
})

// Mirrors Panel.qml's per-backend port resolution.
const portFor = (backendPorts, backend) => {
  const stored = backendPorts[backend]
  if (stored !== undefined && String(stored).trim() !== "") return String(stored)
  return String(Backends.get(backend).defaultPort)
}

test("each backend keeps its own port", () => {
  // Regression: one shared port was rewritten by the backend-change handler,
  // so llama.cpp could end up holding ollama's 11434 whenever that handler
  // did not run -- e.g. the backend changed in the settings file directly.
  const ports = {}
  assert.strictEqual(portFor(ports, "llamacpp"), "8080", "falls back to the backend default")
  assert.strictEqual(portFor(ports, "ollama"), "11434")

  // Setting one leaves the other alone.
  ports.ollama = "11500"
  assert.strictEqual(portFor(ports, "ollama"), "11500")
  assert.strictEqual(portFor(ports, "llamacpp"), "8080", "unaffected by the other backend")

  // A deliberate port survives switching away and back, including one that
  // happens to equal the other backend's default.
  ports.llamacpp = "11434"
  assert.strictEqual(portFor(ports, "llamacpp"), "11434", "a pinned port is not reset")
  assert.strictEqual(portFor(ports, "ollama"), "11500")
})

test("a blank stored port falls back to the default", () => {
  assert.strictEqual(portFor({ llamacpp: "" }, "llamacpp"), "8080")
  assert.strictEqual(portFor({ llamacpp: "   " }, "llamacpp"), "8080")
})

test("shared tuning controls actually reach ollama", () => {
  // Regression: the Context field emitted --ctx-size, a llama.cpp flag ollama
  // never sees, so the control rendered but did nothing -- while separately
  // adding OLLAMA_CONTEXT_LENGTH as a custom parameter did work.
  const out = Backends.ollamaLaunch({
    host: "127.0.0.1", port: 11434,
    contextSize: "65536", cacheType: "q8_0", flashAttn: "on"
  })
  assert.strictEqual(out.env.OLLAMA_CONTEXT_LENGTH, "65536")
  assert.strictEqual(out.env.OLLAMA_KV_CACHE_TYPE, "q8_0")
  assert.strictEqual(out.env.OLLAMA_FLASH_ATTENTION, "1")
})

test("ollama only receives KV cache types it understands", () => {
  // Regression: the shared control also offers llama.cpp's types and, with an
  // alternate binary, fork-only tiers. Passing "turbo3" through meant ollama
  // was launched with a value it cannot honour.
  assert.ok(!("OLLAMA_KV_CACHE_TYPE" in Backends.ollamaLaunch({ host: "h", port: 1, cacheType: "turbo3" }).env))
  assert.ok(!("OLLAMA_KV_CACHE_TYPE" in Backends.ollamaLaunch({ host: "h", port: 1, cacheType: "vbr" }).env))
  assert.strictEqual(Backends.ollamaLaunch({ host: "h", port: 1, cacheType: "q8_0" }).env.OLLAMA_KV_CACHE_TYPE, "q8_0")
  assert.strictEqual(Backends.ollamaLaunch({ host: "h", port: 1, cacheType: "Q4_0" }).env.OLLAMA_KV_CACHE_TYPE, "q4_0")
})

test("ollama is launched against the store holding the models", () => {
  // Regression: without OLLAMA_MODELS the server falls back to the per-user
  // default, which is empty on a system-package install -- so every model
  // request 404s even though the models are on disk.
  const out = Backends.ollamaLaunch({ host: "h", port: 1, modelsDir: "/var/lib/ollama" })
  assert.strictEqual(out.env.OLLAMA_MODELS, "/var/lib/ollama")
})

test("unset shared controls leave ollama's own defaults alone", () => {
  const out = Backends.ollamaLaunch({ host: "h", port: 1, contextSize: "0", flashAttn: "auto" })
  assert.ok(!("OLLAMA_CONTEXT_LENGTH" in out.env), "0 means unset, as for --ctx-size")
  assert.ok(!("OLLAMA_FLASH_ATTENTION" in out.env), "auto defers to ollama")
  assert.ok(!("OLLAMA_KV_CACHE_TYPE" in out.env))
})

test("features match what each backend can actually do", () => {
  // ollama has no thread or GPU-layer variable, so those controls must not be
  // offered; it does have KV cache type and flash attention.
  assert.strictEqual(Backends.supports("ollama", "threads"), false)
  assert.strictEqual(Backends.supports("ollama", "ngl"), false)
  assert.strictEqual(Backends.supports("ollama", "cacheType"), true)
  assert.strictEqual(Backends.supports("ollama", "flashAttn"), true)
  assert.strictEqual(Backends.supports("llamacpp", "threads"), true)
  assert.strictEqual(Backends.supports("llamacpp", "ngl"), true)
})

test("unit and marker names are namespaced per backend", () => {
  // The original plugin used one global "Tray-llama-server" marker, so a
  // second widget's pkill would kill the first widget's server.
  assert.notStrictEqual(
    Backends.unitName("sxy.local-ai-server", "ollama"),
    Backends.unitName("sxy.local-ai-server", "llamacpp")
  )
  assert.ok(!Backends.unitName("sxy.local-ai-server", "ollama").includes("."),
    "dots are not valid in a systemd unit name segment")
})

test("detached command survives shell teardown either way", () => {
  const withSystemd = Backends.detachedCommand(true, "u", "echo hi")
  assert.strictEqual(withSystemd[0], "systemd-run")
  assert.ok(withSystemd.includes("--user"))
  const without = Backends.detachedCommand(false, "u", "echo hi")
  assert.strictEqual(without[0], "setsid")
})

test("only ollama declares a distribution system unit", () => {
  assert.strictEqual(Backends.get("ollama").systemUnit, "ollama")
  assert.strictEqual(Backends.get("llamacpp").systemUnit, undefined,
    "llama-server has no distribution service to take over from")
})

test("takeover stops the system unit, not a user unit", () => {
  // Must NOT be `systemctl --user`: the unit is system-scope and root-owned,
  // and the resulting polkit prompt is the user authorising the takeover.
  const cmd = Backends.takeoverStopCommand("ollama")
  assert.deepStrictEqual(cmd, ["systemctl", "stop", "ollama"])
  assert.ok(!cmd.includes("--user"))
})

test("model store is discovered from the unit's own environment", () => {
  // Real `systemctl show ollama -p Environment` output.
  const real = "Environment=HOME=/var/lib/ollama OLLAMA_MODELS=/var/lib/ollama"
  assert.strictEqual(Backends.modelsDirFromUnitEnvironment(real), "/var/lib/ollama")
  assert.strictEqual(Backends.modelsDirFromUnitEnvironment('Environment=OLLAMA_MODELS="/srv/models"'), "/srv/models")
  assert.strictEqual(Backends.modelsDirFromUnitEnvironment("Environment=HOME=/x"), "",
    "absent means unset, not a bogus path")
  assert.strictEqual(Backends.modelsDirFromUnitEnvironment(""), "")
})

test("a taken-over ollama serves the system store, not an empty one", () => {
  // Verified against a live server: pointing at the system store lists and
  // serves the existing models; the per-user default is empty.
  const out = Backends.ollamaLaunch({
    binary: "ollama", host: "127.0.0.1", port: 11434, modelsDir: "/var/lib/ollama"
  })
  assert.strictEqual(out.env.OLLAMA_MODELS, "/var/lib/ollama")
})

// --- Parameter catalogue -------------------------------------------------

const Params = require("../Params.js")

// Verbatim lines from `llama-server --help`, covering each shape the parser
// has to handle: aliases in their own column, enum placeholders, a default
// buried mid-parenthetical, a wrapped description, and a bare switch.
const HELP = [
  "----- common params -----",
  "",
  "-t,    --threads N                      number of CPU threads to use during generation (default: -1)",
  "                                        (env: LLAMA_ARG_THREADS)",
  "-c,    --ctx-size N                     size of the prompt context (default: 0, 0 = loaded from model)",
  "-fa,   --flash-attn [on|off|auto]       set Flash Attention use ('on', 'off', or 'auto', default: 'auto')",
  "--temp, --temperature N                 temperature (default: 0.80)",
  "--poll <0...100>                        use polling level to wait for work (0 - no polling, default: 50)",
  "--swa-full                              use full-size SWA cache (default: false)",
  "-tb,   --threads-batch N                number of threads to use during batch and prompt processing (default:",
  "                                        same as --threads)",
  "-n,    --predict, --n-predict N         number of tokens to predict (default: -1, -1 = infinity)"
].join("\n")

test("parses flags, types and defaults from real help text", () => {
  const p = Params.parseLlamaHelp(HELP)
  const by = k => Params.find(p, k)

  assert.strictEqual(by("--threads").type, "int")
  assert.strictEqual(by("--threads").defaultValue, "-1")

  // Regression: the default was lost when the flag aliases occupied their own
  // column chunk and the chunks were rejoined before re-splitting.
  assert.strictEqual(by("--ctx-size").defaultValue, "0", "trailing prose is trimmed")

  // Regression: "default:" is not the first token in this parenthetical.
  assert.strictEqual(by("--flash-attn").type, "enum")
  assert.strictEqual(by("--flash-attn").defaultValue, "auto")
  assert.deepStrictEqual(by("--flash-attn").options, ["on", "off", "auto"])

  assert.strictEqual(by("--temperature").type, "float")
  assert.strictEqual(by("--temperature").defaultValue, "0.80")
  assert.deepStrictEqual(by("--temperature").flags, ["--temp", "--temperature"], "aliases kept")

  assert.strictEqual(by("--poll").defaultValue, "50", "default found after other prose")
  assert.strictEqual(by("--swa-full").type, "bool", "no placeholder means a bare switch")

  // A non-literal default yields no value rather than a bogus one.
  assert.strictEqual(by("--threads-batch").defaultValue, "")

  // The longest long-form wins, so the key is stable across releases.
  assert.strictEqual(by("--n-predict").type, "int")
  assert.strictEqual(Params.find(p, "--predict"), null)
})

test("description text is never mistaken for a flag", () => {
  // "-1 = infinity" begins with a dash but is prose.
  const p = Params.find(Params.parseLlamaHelp(HELP), "--n-predict")
  assert.ok(!p.flags.includes("-1"))
  assert.strictEqual(p.defaultValue, "-1")
})

test("ollama parameters come from its environment variable list", () => {
  const out = Params.parseOllamaHelp([
    "Environment Variables:",
    "      OLLAMA_KEEP_ALIVE             The duration that models stay loaded in memory (default \"5m\")",
    "      OLLAMA_MAX_QUEUE              Maximum number of queued requests"
  ].join("\n"))
  assert.strictEqual(out.length, 2)
  assert.strictEqual(out[0].key, "OLLAMA_KEEP_ALIVE")
  assert.strictEqual(out[0].defaultValue, "5m")
})

test("values render into argv, and blanks produce nothing", () => {
  const p = Params.parseLlamaHelp(HELP)
  assert.deepStrictEqual(Params.toArgv(Params.find(p, "--temperature"), "0.6"), ["--temperature", "0.6"])
  assert.deepStrictEqual(Params.toArgv(Params.find(p, "--swa-full"), "true"), ["--swa-full"])
  assert.deepStrictEqual(Params.toArgv(Params.find(p, "--swa-full"), "false"), [],
    "an off switch contributes nothing")
  // An added-but-unset parameter must not emit a flag with no argument.
  assert.deepStrictEqual(Params.toArgv(Params.find(p, "--threads"), ""), [])
  assert.deepStrictEqual(Params.toArgv(null, "x"), [])
})

test("picker hides already-added and built-in parameters", () => {
  const p = Params.parseLlamaHelp(HELP)
  const opts = Params.availableOptions(p, ["--temperature"], ["--ctx-size", "--threads"])
  const keys = opts.map(o => o.value)
  assert.ok(!keys.includes("--temperature"), "already added")
  assert.ok(!keys.includes("--ctx-size"), "has a dedicated control")
  assert.ok(keys.includes("--poll"), "everything else is offered")
})

// Mirrors Panel.qml's tuning sub-pagination. Added parameters fill the first
// page's leftover room before any new tab appears; the first page holds fewer
// because the built-in controls and the footer occupy slots there.
const CAPACITY = 6
// ollama shows 2 built-in rows (context, threads); llama.cpp shows 6.
const firstCapacity = coreRows => Math.max(0, CAPACITY - coreRows - 1)
const pageCount = (n, coreRows) => {
  const overflow = n - firstCapacity(coreRows)
  return overflow <= 0 ? 1 : 1 + Math.ceil(overflow / CAPACITY)
}
const effectivePage = (page, n, coreRows) =>
  Math.max(0, Math.min(page, pageCount(n, coreRows) - 1))
const paramsForPage = (list, page, coreRows) => {
  const first = firstCapacity(coreRows)
  if (page <= 0) return list.slice(0, first)
  const start = first + (page - 1) * CAPACITY
  return list.slice(start, start + CAPACITY)
}

const mk = n => Array.from({ length: n }, (_, i) => ({ key: "--p" + i, value: "" }))

test("added parameters fill the first page before a tab appears", () => {
  // ollama: 2 built-in rows leaves room for 3 on the first page.
  assert.strictEqual(firstCapacity(2), 3)
  assert.strictEqual(pageCount(3, 2), 1, "three fit alongside the controls, no second tab")
  assert.deepStrictEqual(paramsForPage(mk(3), 0, 2).map(p => p.key), ["--p0", "--p1", "--p2"])

  // The fourth is what creates the second tab.
  assert.strictEqual(pageCount(4, 2), 2)
  assert.deepStrictEqual(paramsForPage(mk(4), 1, 2).map(p => p.key), ["--p3"])
})

test("a backend with more built-in controls has less first-page room", () => {
  // llama.cpp's six control rows fill the first page on their own, so the
  // very first added parameter starts a second tab.
  assert.strictEqual(firstCapacity(6), 0)
  assert.strictEqual(pageCount(1, 6), 2)
  assert.deepStrictEqual(paramsForPage(mk(1), 0, 6), [])
  assert.deepStrictEqual(paramsForPage(mk(1), 1, 6).map(p => p.key), ["--p0"])
})

test("removing the last parameter on a page never leaves it blank", () => {
  // Regression: viewing a later page and deleting down to fewer pages left the
  // index past the end, so the tab strip clamped but the content did not --
  // rendering an empty Tuning page.
  assert.strictEqual(pageCount(10, 2), 3)
  assert.strictEqual(effectivePage(2, 10, 2), 2)

  // Down to one page's worth: page 2 no longer exists.
  assert.strictEqual(effectivePage(2, 4, 2), 1, "clamps to the last real page")
  assert.ok(paramsForPage(mk(4), effectivePage(2, 4, 2), 2).length > 0, "and it has content")

  // All removed: only the first page remains, and it renders its controls.
  assert.strictEqual(effectivePage(2, 0, 2), 0)
  assert.deepStrictEqual(paramsForPage([], effectivePage(2, 0, 2), 2), [])
})

test("overflow pages carry the full capacity", () => {
  const nine = mk(9)
  assert.deepStrictEqual(paramsForPage(nine, 0, 2).map(p => p.key), ["--p0", "--p1", "--p2"])
  assert.deepStrictEqual(paramsForPage(nine, 1, 2).map(p => p.key),
    ["--p3", "--p4", "--p5", "--p6", "--p7", "--p8"])
  assert.strictEqual(pageCount(9, 2), 2, "nine still fit in two pages")
})

// --- Hardware suggestions ------------------------------------------------

const RIG_4GB = { vendor: "nvidia", gpuName: "NVIDIA GeForce GTX 1650", vramMb: 4096, ramMb: 23687, cores: 8, threads: 12 }
const CPU_ONLY = { vendor: "cpu", gpuName: "", vramMb: 0, ramMb: 16384, cores: 4, threads: 8 }
const BIG_GPU = { vendor: "nvidia", gpuName: "RTX 4090", vramMb: 24564, ramMb: 65536, cores: 16, threads: 32 }
const MAC = { vendor: "metal", gpuName: "Apple M3 Pro", vramMb: 36864, ramMb: 36864, cores: 12, threads: 12 }

test("suggestions adapt to the machine", () => {
  // A 4GB card still has ~3.3GB usable, so auto-fit is the right answer.
  assert.strictEqual(Hardware.suggestGpuLayers(RIG_4GB), -1)
  assert.strictEqual(Hardware.suggestGpuLayers(CPU_ONLY), 0, "no GPU means no offload")
  assert.strictEqual(Hardware.suggestGpuLayers(MAC), -1, "unified memory always auto-fits")

  // Threads follow physical cores, never the 12 hyperthreads.
  assert.strictEqual(Hardware.suggestThreads(RIG_4GB), 7)
  assert.strictEqual(Hardware.suggestThreads(CPU_ONLY), 4, "small core counts are not decremented")

  // Context scales with the memory that will actually hold the KV cache.
  assert.ok(Hardware.suggestContextSize(RIG_4GB) < Hardware.suggestContextSize(BIG_GPU))

  // Batch size no longer hardcodes the 1024 tuned for one rig.
  assert.strictEqual(Hardware.suggestBatchSize(RIG_4GB), 512)
  assert.strictEqual(Hardware.suggestBatchSize(BIG_GPU), 2048)
  assert.ok(Hardware.suggestUbatchSize(BIG_GPU) <= 512)
})

test("CUDA env vars are gated on an actual NVIDIA GPU", () => {
  assert.strictEqual(Hardware.isCuda(RIG_4GB), true)
  assert.strictEqual(Hardware.isCuda(MAC), false)
  assert.strictEqual(Hardware.isCuda(CPU_ONLY), false)
})

test("parseProbe survives garbage and missing fields", () => {
  const empty = Hardware.parseProbe("not json")
  assert.strictEqual(empty.vendor, "cpu")
  assert.strictEqual(empty.vramMb, 0)
  assert.strictEqual(Hardware.parseProbe('{"vendor":"nvidia","vramMb":4096}').cores, 0)
})

// Real geometry read from Qwen3.6-35B-A3B-UD-IQ4_XS.gguf by gguf_probe.py.
const QWEN_GEOM = {
  block_count: 41, head_count_kv: 2, head_count: 16,
  key_length: 256, value_length: 256, embedding_length: 2048,
  context_length: 262144
}

test("kvBytesPerToken uses the model's real attention geometry", () => {
  // 41 layers x 2 kv heads x (256 + 256) x 2 bytes = 83,968 bytes/token
  assert.strictEqual(Math.round(Hardware.kvBytesPerToken(QWEN_GEOM, "f16", "f16")), 83968)
  // A quantized cache scales it down proportionally.
  assert.ok(Hardware.kvBytesPerToken(QWEN_GEOM, "turbo3", "turbo3") <
            Hardware.kvBytesPerToken(QWEN_GEOM, "q8_0", "q8_0"))
  assert.strictEqual(Hardware.kvBytesPerToken(null, "f16", "f16"), 0, "unknown geometry is not zero cost")
  assert.strictEqual(Hardware.kvBytesPerToken({}, "f16", "f16"), 0)
})

test("kvBytesPerToken derives head_dim when lengths are absent", () => {
  // Older GGUFs omit key_length/value_length: embedding 2048 / 16 heads = 128.
  const partial = { block_count: 41, head_count_kv: 2, head_count: 16, embedding_length: 2048 }
  const expected = 41 * 2 * (128 * 2 + 128 * 2)
  assert.strictEqual(Math.round(Hardware.kvBytesPerToken(partial, "f16", "f16")), expected)
})

test("context suggestion reflects cache type and MoE offload", () => {
  // Regression: a VRAM-only heuristic suggested 8192 for a configuration
  // measured to sustain 65536, because it ignored both the quantized KV cache
  // and the experts being offloaded to CPU.
  const mine = { geometry: QWEN_GEOM, cacheTypeK: "turbo3", cacheTypeV: "turbo3", cpuMoeActive: true }
  assert.strictEqual(Hardware.suggestContextSize(RIG_4GB, mine), 65536)

  // Each factor independently reduces what fits.
  const noOffload = Object.assign({}, mine, { cpuMoeActive: false })
  const f16 = Object.assign({}, mine, { cacheTypeK: "f16", cacheTypeV: "f16" })
  assert.ok(Hardware.suggestContextSize(RIG_4GB, noOffload) < 65536)
  assert.ok(Hardware.suggestContextSize(RIG_4GB, f16) < 65536)
})

test("context suggestion never exceeds the trained context length", () => {
  const short = Object.assign({}, QWEN_GEOM, { context_length: 8192 })
  const cfg = { geometry: short, cacheTypeK: "turbo1_tcq", cacheTypeV: "turbo1_tcq", cpuMoeActive: true }
  assert.ok(Hardware.suggestContextSize(BIG_GPU, cfg) <= 8192,
    "a 24GB card must not be told to exceed what the model was trained for")
})

test("cache-ram does not buy context", () => {
  // --cache-ram sizes llama.cpp's prompt cache, not live KV storage, so it
  // must not inflate the budget.
  const base = { geometry: QWEN_GEOM, cacheTypeK: "f16", cacheTypeV: "f16", cpuMoeActive: false }
  const withRam = Object.assign({}, base, { cacheRamMb: 8192 })
  assert.strictEqual(Hardware.suggestContextSize(RIG_4GB, base),
                     Hardware.suggestContextSize(RIG_4GB, withRam))
})

test("suggestContextSize falls back without geometry", () => {
  assert.strictEqual(Hardware.suggestContextSize(RIG_4GB, {}), 4096)
  assert.strictEqual(Hardware.suggestContextSize(CPU_ONLY, {}), 8192)
})

test("parseProbeGeometry skips entries with no geometry", () => {
  const raw = JSON.stringify({
    "/a.gguf": { block_count: 41, head_count_kv: 2, key_length: 256, value_length: 256, context_length: 4096 },
    "/b.gguf": { error: "not gguf" }
  })
  const out = Model.parseProbeGeometry(raw)
  assert.strictEqual(out["/a.gguf"].block_count, 41)
  assert.strictEqual(out["/a.gguf"].context_length, 4096)
  assert.ok(!("/b.gguf" in out), "a failed probe contributes no geometry")
})

test("summary describes the detected hardware", () => {
  assert.strictEqual(Hardware.summary(RIG_4GB), "NVIDIA GeForce GTX 1650 · 4.0GB VRAM · 23GB RAM · 8 cores")
})


// Real llama-server --help excerpts. Each spells a fixed value set a different
// way, and only the first form used to be recognised -- the rest reached the
// UI as free-text fields where a typo is found by a server that will not boot.
const HELP_ENUMS = [
  "-fa,   --flash-attn [on|off|auto]       set Flash Attention use ('on', 'off', or 'auto', default: 'auto')",
  "--rope-scaling {none,linear,yarn}       RoPE frequency scaling method, defaults to linear unless specified by the model",
  "--spec-type none,draft-simple,draft-mtp,ngram-mod    speculative decoding type",
  "-ctk,  --cache-type-k TYPE              KV cache data type for K",
  "                                        allowed values: f32, f16, q8_0, turbo4, vbr",
  "                                        (default: vbr (implicit t4 floor))",
  "-lm,   --load-mode MODE                 model loading mode (default: auto)",
  "                                        - auto: mmap, unless a device does not support it",
  "                                        - mmap: memory-map model",
  "                                        - mlock: force system to keep model in RAM",
].join("\n")

test("parse reads a value set however the help spells it", () => {
  const params = Params.parse("llamacpp", HELP_ENUMS)
  const optionsFor = (key) => {
    const spec = Params.find(params, key)
    assert.ok(spec, key + " missing from the catalogue")
    assert.strictEqual(spec.type, "enum", key + " must be a closed choice")
    return spec.options
  }
  assert.deepStrictEqual(optionsFor("--flash-attn"), ["on", "off", "auto"])
  assert.deepStrictEqual(optionsFor("--rope-scaling"), ["none", "linear", "yarn"])
  assert.deepStrictEqual(optionsFor("--spec-type"),
                         ["none", "draft-simple", "draft-mtp", "ngram-mod"])
  assert.deepStrictEqual(optionsFor("--cache-type-k"),
                         ["f32", "f16", "q8_0", "turbo4", "vbr"])
  assert.deepStrictEqual(optionsFor("--load-mode"), ["auto", "mmap", "mlock"])
})

test("a repeatable format is not a value set", () => {
  // These sit between the same brackets as a real choice, but every entry is
  // an invented example. Offering them as a dropdown is worse than a text
  // field: it looks authoritative and every option in it is wrong.
  const help = [
    "-dev,  --device [<dev1|dev2|..>]        comma-separated list of devices",
    "-ts,   --tensor-split [N0|N1|N2|...]    fraction of the model to offload per device",
    "--override-kv [KEY=TYPE:VALUE|...]      advanced option to override model metadata",
    "--lora-scaled [FNAME:SCALE|...]         path to LoRA adapter with user defined scaling",
  ].join("\n")
  const params = Params.parse("llamacpp", help)
  for (const key of ["--device", "--tensor-split", "--override-kv", "--lora-scaled"]) {
    const spec = Params.find(params, key)
    assert.ok(spec, key + " missing from the catalogue")
    assert.notStrictEqual(spec.type, "enum", key + " is a format, not a choice")
    assert.deepStrictEqual(spec.options, [])
  }
})

test("a range placeholder stays numeric", () => {
  const params = Params.parse("llamacpp", "--top-k <0...100>    top-k sampling (default: 40)")
  assert.strictEqual(Params.find(params, "--top-k").type, "int")
})

// ---- Negatable flags -------------------------------------------------------
//
// llama.cpp writes both halves of a boolean on one help line. Real lines,
// captured from `llama-server --help` on 2026-09-10 (build b6xxx).

const NEGATABLE_HELP = [
  "--jinja, --no-jinja                     whether to use jinja template engine for chat (default: enabled)",
  "                                        (env: LLAMA_ARG_JINJA)",
  "--reasoning-preserve, --no-reasoning-preserve",
  "                                        preserve reasoning trace in the full history, not just the last",
  "                                        assistant message (default: template default)",
  "-np,   --parallel N                     number of server slots (default: -1, -1 = auto)",
  "-mm,   --mmproj FILE                    path to a multimodal projector file. see tools/mtmd/README.md",
  "--mmproj-offload, --no-mmproj-offload   whether to enable GPU offloading for multimodal projector (default:",
  "                                        enabled)"
].join("\n")

test("a negatable flag is named after its positive half", () => {
  // The regression: "--no-" is three characters longer than what it negates,
  // so picking the longest flag named every such parameter after its own
  // negation -- and adding one from the picker then switched the setting off
  // while the row read as switching it on.
  const catalogue = Params.parseLlamaHelp(NEGATABLE_HELP)
  assert.ok(Params.find(catalogue, "--reasoning-preserve"))
  assert.strictEqual(Params.find(catalogue, "--no-reasoning-preserve"), null)
  assert.ok(Params.find(catalogue, "--jinja"))
  assert.ok(Params.find(catalogue, "--mmproj-offload"))
})

test("a short alias is not mistaken for a negation", () => {
  // "-np" does not start with "--", so negating it produced "-np" itself --
  // which made every flag carrying a short alias look like a negatable pair.
  const catalogue = Params.parseLlamaHelp(NEGATABLE_HELP)
  const parallel = Params.find(catalogue, "--parallel")
  assert.strictEqual(parallel.type, "int")
  assert.strictEqual(parallel.negatedFlag, "")
  assert.strictEqual(Params.find(catalogue, "--mmproj").type, "string")
})

test("a negatable flag has three states, not two", () => {
  const catalogue = Params.parseLlamaHelp(NEGATABLE_HELP)
  const preserve = Params.find(catalogue, "--reasoning-preserve")
  assert.strictEqual(preserve.type, "tristate")
  assert.deepStrictEqual(preserve.options, ["default", "on", "off"])
  // "default" passes nothing, which is the only correct reading of a flag
  // documented as "(default: template default)".
  assert.deepStrictEqual(Params.toArgv(preserve, "default"), [])
  assert.deepStrictEqual(Params.toArgv(preserve, "on"), ["--reasoning-preserve"])
  assert.deepStrictEqual(Params.toArgv(preserve, "off"), ["--no-reasoning-preserve"])
  // A value stored before this type existed must not be read as a state.
  assert.deepStrictEqual(Params.toArgv(preserve, ""), [])
})

test("a plain bool still contributes only itself", () => {
  const catalogue = Params.parseLlamaHelp(
    "--no-repack                             disable weight repacking (default: false)")
  const repack = Params.find(catalogue, "--no-repack")
  assert.strictEqual(repack.type, "bool")
  assert.deepStrictEqual(Params.toArgv(repack, "true"), ["--no-repack"])
  assert.deepStrictEqual(Params.toArgv(repack, "false"), [])
})

test("a flag resolves from any name it is written under", () => {
  // Extra args are typed by hand, where "-np" is as likely as "--parallel"
  // and a negation never appears in the catalogue under its own name.
  const catalogue = Params.parseLlamaHelp(NEGATABLE_HELP)
  assert.strictEqual(Params.findByFlag(catalogue, "-np").key, "--parallel")
  assert.strictEqual(Params.findByFlag(catalogue, "--parallel").key, "--parallel")
  assert.strictEqual(Params.findByFlag(catalogue, "--no-reasoning-preserve").key,
                     "--reasoning-preserve")
  assert.strictEqual(Params.findByFlag(catalogue, "--nonsense"), null)
})

// ---- Splitting a pasted command line ---------------------------------------

const SPLIT_HELP = [
  "-np,   --parallel N                     number of server slots (default: -1, -1 = auto)",
  "-ngl,  --gpu-layers, --n-gpu-layers N   number of layers to store in VRAM",
  "-c,    --ctx-size N                     size of the prompt context (default: 4096)",
  "--reasoning-preserve, --no-reasoning-preserve",
  "                                        preserve reasoning trace in the full history",
  "--no-repack                             disable weight repacking (default: false)"
].join("\n")

function split(line) {
  const catalogue = Params.parseLlamaHelp(SPLIT_HELP)
  let tokens = []
  for (const piece of Model.splitExtraArgs(line)) tokens = tokens.concat(Model.parseArgs(piece))
  return Params.fromTokens(catalogue, tokens)
}

test("a pasted line becomes one entry per parameter", () => {
  const { params, leftover } = split("-np 1 --reasoning-preserve")
  assert.deepStrictEqual(params, [
    { key: "--parallel", value: "1" },
    { key: "--reasoning-preserve", value: "on" }
  ])
  assert.deepStrictEqual(leftover, [])
})

test("a value that looks like a flag is still a value", () => {
  // "--gpu-layers -1" and "--no-repack --parallel 2" are indistinguishable to
  // a scanner reading token shape; the catalogue says which flags take a value.
  assert.deepStrictEqual(split("-ngl -1").params, [{ key: "--n-gpu-layers", value: "-1" }])
  assert.deepStrictEqual(split("--no-repack --parallel 2").params, [
    { key: "--no-repack", value: "true" },
    { key: "--parallel", value: "2" }
  ])
})

test("a negation is stored as the flag it negates, switched off", () => {
  assert.deepStrictEqual(split("--no-reasoning-preserve").params,
    [{ key: "--reasoning-preserve", value: "off" }])
})

test("the = form is accepted", () => {
  assert.deepStrictEqual(split("--ctx-size=8192").params, [{ key: "--ctx-size", value: "8192" }])
})

test("an unrecognised flag is kept, with its shape recorded", () => {
  // It may come from an alternate build. Dropping it would lose what the user
  // typed; guessing silently at launch would lose which half was the value.
  const { params } = split("--turbo-thing 4 --turbo-switch")
  assert.deepStrictEqual(params, [
    { key: "--turbo-thing", value: "4", type: "string" },
    { key: "--turbo-switch", value: "true", type: "bool" }
  ])
  // And that recorded shape is what lets it reach the server anyway.
  assert.deepStrictEqual(
    Params.toArgv(Params.fallbackSpec("--turbo-thing", "string"), "4"),
    ["--turbo-thing", "4"])
  assert.deepStrictEqual(
    Params.toArgv(Params.fallbackSpec("--turbo-switch", "bool"), "true"),
    ["--turbo-switch"])
})

test("a token belonging to no flag is reported, not swallowed", () => {
  const { params, leftover } = split("stray --parallel 2")
  assert.deepStrictEqual(params, [{ key: "--parallel", value: "2" }])
  assert.deepStrictEqual(leftover, ["stray"])
  // A trailing flag whose value never arrived is leftover too, rather than
  // becoming a dangling flag with no argument.
  assert.deepStrictEqual(split("--parallel").leftover, ["--parallel"])
})

test("splitting the same line twice is idempotent", () => {
  // The field is re-split whenever the catalogue changes, so a second pass
  // over what is left must find nothing to do.
  const first = split("-np 1 --reasoning-preserve")
  const again = split(first.leftover.join(" "))
  assert.deepStrictEqual(again.params, [])
})

// ---- Tuning sub-pages ------------------------------------------------------

function rows(ids) {
  return ids.map((id) => (typeof id === "string" ? { id, weight: 1 } : id))
}
function ids(pages) {
  return pages.map((page) => page.map((slot) => slot.id))
}

// What the page carries with nothing added and nothing removed.
const DEFAULT_ROWS = ["cacheType", "flashAttn", "ngl", "cpuMoe", "ctxSize", "threads", "batchSize"]

test("the default set of rows still fits on one page", () => {
  // Built-in rows used to be exempt from the count and simply ran past the
  // bottom of the panel. Counting them is the fix — but counting them at a
  // capacity below what they already occupy would split a page that fits.
  assert.deepStrictEqual(ids(Model.paginateRows(rows(DEFAULT_ROWS), 7, 0)), [DEFAULT_ROWS])
})

test("rows past the capacity get a page instead of running off the panel", () => {
  const all = DEFAULT_ROWS.concat(["parallel", "reasoning", "specType"])
  assert.deepStrictEqual(ids(Model.paginateRows(rows(all), 7, 0)), [
    DEFAULT_ROWS,
    ["parallel", "reasoning", "specType"]
  ])
})

test("a two-slot row moves as one", () => {
  // The projector's path field belongs with the mode control that reveals it;
  // splitting them would put a text field on a page with nothing explaining it.
  const list = rows(["a", "b", "c", "d", "e", "f"]).concat([{ id: "vision", weight: 2 }])
  const pages = ids(Model.paginateRows(list, 7, 0))
  assert.deepStrictEqual(pages, [["a", "b", "c", "d", "e", "f"], ["vision"]])
})

test("the first page gives up a slot to the note under it", () => {
  assert.deepStrictEqual(ids(Model.paginateRows(rows(DEFAULT_ROWS), 7, 1)), [
    DEFAULT_ROWS.slice(0, 6),
    DEFAULT_ROWS.slice(6)
  ])
})

test("a row heavier than a page still lands on one", () => {
  // Guards the loop: deferring a row that can never fit would defer it forever.
  const pages = ids(Model.paginateRows([{ id: "huge", weight: 9 }, { id: "after", weight: 1 }], 3, 0))
  assert.deepStrictEqual(pages, [["huge"], ["after"]])
})

test("an empty page list is still one page", () => {
  // The section renders whatever page is current; there is no "no page".
  assert.deepStrictEqual(Model.paginateRows([], 7, 0), [[]])
})
