// Backend registry for the local AI server manager.
//
// Each backend describes how to find a server binary, launch it, ask it what
// models it has, check its health, and read throughput out of it. Panel.qml
// dispatches through these descriptors so it never branches on a backend id
// inline.
//
// Pure logic only -- no QML, no I/O. Everything here returns argv arrays,
// URLs or plain data for the caller to execute, which keeps it unit-testable
// under Node.

// ---- Path helpers ----

// Candidate absolute paths for a backend binary, in priority order. The
// caller resolves the first one that exists; a user-provided setting always
// takes precedence over this list.
function llamaBinaryCandidates(home) {
  var h = String(home || "")
  return [
    h + "/llama.cpp/build/bin/llama-server",
    h + "/.local/bin/llama-server",
    "/usr/bin/llama-server",
    "/usr/local/bin/llama-server",
    "/opt/llama.cpp/bin/llama-server"
  ]
}

function ollamaBinaryCandidates(home) {
  var h = String(home || "")
  return [
    "/usr/bin/ollama",
    "/usr/local/bin/ollama",
    h + "/.local/bin/ollama",
    "/opt/ollama/bin/ollama"
  ]
}

// Places ollama keeps its model store, in priority order.
//
// Resolved from this static list rather than only from the running service's
// environment: the store is worth finding on the llama.cpp backend too (its
// blobs are plain GGUF and can be served directly), and there the ollama
// service is never queried, so an environment-only lookup finds nothing.
function ollamaStoreCandidates(home) {
  var h = String(home || "")
  return [
    "/var/lib/ollama",             // Arch and most distro packages
    "/usr/share/ollama/.ollama",   // upstream install script
    h + "/.ollama"                 // per-user
  ]
}

// Directories worth scanning for .gguf files. Covers the llama.cpp download
// cache and the layouts LM Studio and jan.ai use, so a user who already has
// models does not have to configure anything.
function ggufSearchDirs(home) {
  var h = String(home || "")
  return [
    h + "/models",
    h + "/.cache/llama.cpp",
    h + "/.local/share/models",
    h + "/.lmstudio/models",
    h + "/.cache/lm-studio/models",
    h + "/jan/models"
  ]
}

// KV cache quantisations ollama supports. Its own documentation lists f16 as
// the default; q8_0 and q4_0 are the quantised options.
var OLLAMA_KV_CACHE_TYPES = ["f16", "q8_0", "q4_0"]

// ---- Backend descriptors ----

var LLAMA_CPP = {
  id: "llamacpp",
  label: "llama.cpp",
  // llama-server's own default port.
  defaultPort: 8080,
  healthPath: "/health",
  // Live per-slot telemetry: pp% sweep and running tg, polled over HTTP.
  metricsMode: "slots",
  // We always spawn llama-server ourselves, so stopping it is always ours.
  externallyManaged: false,
  // Model selection is a file path chosen from the gguf tree.
  modelKind: "file",
  // Features that only exist on this backend; Panel.qml hides the
  // corresponding controls when the active backend does not list them.
  features: ["ngl", "ctxSize", "threads", "batchSize", "ubatchSize", "cacheType",
             "flashAttn", "cpuMoe", "loadMode", "slotKv", "extraArgs",
             // Controls for what the plugin used to inject on its own, plus
             // the two flags most often hand-written into extra args.
             "parallel", "reasoning", "specType", "vision", "envVars"],
  binaryCandidates: llamaBinaryCandidates
}

var OLLAMA = {
  id: "ollama",
  label: "ollama",
  // ollama's fixed default; OLLAMA_HOST overrides it.
  defaultPort: 11434,
  // ollama has no /health; /api/version is the cheapest liveness probe.
  healthPath: "/api/version",
  // No /slots equivalent is exposed over HTTP, and no progress lines are
  // logged at default verbosity, so throughput is read from the timing lines
  // the embedded llama.cpp writes when each request completes. That yields
  // final pp and tg numbers per request rather than a live pp% sweep.
  metricsMode: "log",
  modelKind: "tag",
  // ollama is configured by environment, not flags, so a built-in control is
  // only meaningful here if a corresponding variable exists. Threads and GPU
  // layers are absent from `ollama serve --help` entirely -- there is no
  // server-level knob for either -- so those rows are not offered rather than
  // being shown and silently ignored.
  features: ["ctxSize", "cacheType", "flashAttn", "keepAlive", "parallel", "envVars"],
  // Built-in control -> environment variable. Without this the shared controls
  // render but never reach the server, which is exactly what made the Context
  // field inert while a manually added OLLAMA_CONTEXT_LENGTH worked.
  builtinEnv: {
    ctxSize: "OLLAMA_CONTEXT_LENGTH",
    keepAlive: "OLLAMA_KEEP_ALIVE",
    cacheType: "OLLAMA_KV_CACHE_TYPE",
    flashAttn: "OLLAMA_FLASH_ATTENTION",
    parallel: "OLLAMA_NUM_PARALLEL"
  },
  binaryCandidates: ollamaBinaryCandidates,
  // Distributions ship ollama as a system unit running as its own user. It
  // cannot be adopted as a process -- a unit owned by root is not ours to
  // signal -- so taking control means stopping it and starting our own.
  systemUnit: "ollama"
}

var BACKENDS = [LLAMA_CPP, OLLAMA]

function all() {
  return BACKENDS
}

function get(id) {
  var wanted = String(id || "")
  for (var i = 0; i < BACKENDS.length; i++)
    if (BACKENDS[i].id === wanted) return BACKENDS[i]
  return LLAMA_CPP
}

function ids() {
  return BACKENDS.map(function(b) { return b.id })
}

function labels() {
  return BACKENDS.map(function(b) { return b.label })
}

function supports(backendId, feature) {
  return get(backendId).features.indexOf(feature) !== -1
}

// ---- URLs ----

function baseUrl(host, port) {
  return "http://" + String(host || "127.0.0.1") + ":" + String(port || "")
}

function healthUrl(backendId, host, port) {
  return baseUrl(host, port) + get(backendId).healthPath
}

// Endpoint listing whatever the running server currently has loaded.
// llama.cpp reports per-slot state; ollama reports resident models plus their
// VRAM/RAM split.
function loadedModelsUrl(backendId, host, port) {
  return baseUrl(host, port) + (backendId === "ollama" ? "/api/ps" : "/slots")
}

// ollama-only: the catalogue of pulled models.
function tagsUrl(host, port) {
  return baseUrl(host, port) + "/api/tags"
}

// ---- Launch ----

// Builds the ollama server argv. ollama takes no tuning flags -- host and
// parallelism come from the environment, so those are returned separately
// for the caller to prepend as `KEY=value` assignments.
function ollamaLaunch(cfg) {
  cfg = cfg || {}
  var env = {}
  env.OLLAMA_HOST = String(cfg.host || "127.0.0.1") + ":" + String(cfg.port || OLLAMA.defaultPort)
  if (cfg.keepAlive) env.OLLAMA_KEEP_ALIVE = String(cfg.keepAlive)
  if (cfg.numParallel) env.OLLAMA_NUM_PARALLEL = String(cfg.numParallel)

  // Shared controls, translated to ollama's environment. A zero or blank
  // context means "unset", matching how llama.cpp treats --ctx-size 0.
  var ctx = parseInt(cfg.contextSize, 10)
  if (isFinite(ctx) && ctx > 0) env.OLLAMA_CONTEXT_LENGTH = String(ctx)

  // ollama accepts only these three KV cache types. The shared control also
  // offers llama.cpp's wider set (and, with an alternate binary, fork-only
  // tiers like "turbo3"), which ollama would reject or silently ignore -- so
  // an unsupported value is dropped rather than passed through.
  if (cfg.cacheType && OLLAMA_KV_CACHE_TYPES.indexOf(String(cfg.cacheType).toLowerCase()) !== -1)
    env.OLLAMA_KV_CACHE_TYPE = String(cfg.cacheType).toLowerCase()

  // OLLAMA_FLASH_ATTENTION is a boolean toggle, whereas the shared control is
  // tri-state; "auto" means "leave ollama to decide", so it sets nothing.
  var fa = String(cfg.flashAttn || "").trim()
  if (fa === "on") env.OLLAMA_FLASH_ATTENTION = "1"
  else if (fa === "off") env.OLLAMA_FLASH_ATTENTION = "0"
  // ollama's own model store; only set when the user overrode it, so the
  // service default (or the system unit's) is preserved otherwise.
  if (cfg.modelsDir) env.OLLAMA_MODELS = String(cfg.modelsDir)
  return { argv: [String(cfg.binary || "ollama"), "serve"], env: env }
}

// Renders an env map as shell `KEY='value'` assignments, using the caller's
// quoting function so values with spaces survive.
function envPrefix(env, quote) {
  var out = []
  for (var key in env) out.push(key + "=" + quote(String(env[key])))
  return out.join(" ")
}

// ---- Detached launch ----

// Wraps a shell command so it outlives the Quickshell process that spawned
// it. `omarchy restart shell` kills quickshell, and a plain child dies with
// it, so the server must be reparented out of the shell's process tree.
//
// systemd-run puts it in a transient user unit, which additionally routes
// output to journald -- that is what lets throughput keep being readable
// after a shell restart, since the original stdout pipe is gone by then.
// setsid is the fallback when systemd is unavailable: it detaches the
// process but leaves no way to read its output back.
function detachedCommand(hasSystemdRun, unitName, script) {
  if (hasSystemdRun) {
    return ["systemd-run", "--user",
            "--unit=" + unitName,
            "--collect",
            "--property=KillMode=mixed",
            "bash", "-lc", script]
  }
  return ["setsid", "bash", "-lc", script]
}

// Stops the distribution's system unit so our own instance can bind the port.
//
// This is a system unit owned by root, so systemctl raises a polkit
// authentication prompt. That is deliberate: silently stopping a system
// service would be a surprising thing for a bar widget to do, and the prompt
// is the user confirming the takeover.
function takeoverStopCommand(systemUnit) {
  return ["systemctl", "stop", String(systemUnit)]
}

// Parses `systemctl show <unit> -p Environment` output for the model store the
// system service uses, so a taken-over instance can serve the models already on
// disk instead of starting from an empty store. Returns "" when unset.
function modelsDirFromUnitEnvironment(showOutput) {
  var text = String(showOutput || "")
  var match = text.match(/OLLAMA_MODELS=("?)([^"\s]+)\1/)
  return match ? match[2] : ""
}

// Stop command matching whatever detachedCommand produced.
function stopCommand(hasSystemdRun, unitName, procMarker) {
  if (hasSystemdRun) return ["systemctl", "--user", "stop", unitName]
  return ["pkill", "-f", procMarker]
}

// Transient unit name for a backend instance. Namespaced by plugin id and
// backend so two widgets, or two backends, never collide on one unit.
// Dots are legal in systemd unit names, but they also delimit the unit-type
// suffix, so a dotted plugin id produces names that read as though they carry
// a type ("sxy.local-ai-server-ollama.service"). Normalising them to dashes
// keeps the generated unit unambiguous.
function unitName(pluginId, backendId) {
  return String(pluginId || "local-ai-server").replace(/[^A-Za-z0-9_-]/g, "-") +
         "-" + String(backendId || "server")
}

// Where a running server's output can be read from, as a journalctl argv, or
// null when it is not in a journal at all.
//
// The log view used to be wired up only on the paths that launch a server, so
// an adopted one showed an empty log: the transient unit was still writing to
// the user journal, and nothing was following it. Ownership, not how the
// server was started, is what decides the source:
//
//   ownsUnit  -- our transient unit, in the user journal (this covers both a
//                server we just launched and one a previous widget instance
//                left running, which is the adoption case).
//   otherwise -- the distribution's system unit for this backend, if it has
//                one (ollama.service).
//   null      -- a foreign server started by hand: its output went to whatever
//                terminal launched it, and no journal has it.
//
// tailLines seeds the view with recent history; pass 0 when following a unit
// from the moment it starts, where there is no history to miss.
function journalCommand(backendId, unitName, ownsUnit, tailLines) {
  var tail = String(tailLines === undefined ? 0 : tailLines)
  if (ownsUnit && unitName)
    return ["journalctl", "--user", "-u", String(unitName), "-f", "-n", tail, "-o", "cat"]
  var systemUnit = get(backendId).systemUnit
  if (systemUnit)
    return ["journalctl", "-u", String(systemUnit), "-f", "-n", tail, "-o", "cat"]
  return null
}

// ---- Prompt cache ----

// File prefix a model's saved slots go under ("<prefix>.slot<N>.bin"). Keyed by
// model only: a cache saved under different tuning is rejected at restore and
// the start is simply cold, then the next save replaces it.
function slotPrefix(model) {
  var base = String(model || "").replace(/^.*\//, "")
  return base === "" ? "" : base.replace(/[^A-Za-z0-9._-]/g, "_")
}

// ---- llama.cpp builds ----
//
// llama_builds.py lists every llama-server on the machine as
// {path, real, fork, repo, version, build, commit, date, gpu, cacheTypes}.
// A model runs on the build its profile names, or on "auto": the first build,
// in the probe's order (configured binaries first), that accepts the model's
// KV cache types. Auto is what keeps a profile using a fork-only cache type
// launchable without anyone having to know which binary carries it.

function findBuild(builds, path) {
  if (!path) return null
  for (var i = 0; i < (builds || []).length; i++)
    if (builds[i].path === path || builds[i].real === path) return builds[i]
  return null
}

function buildSupports(build, cacheTypes) {
  // A build whose --help could not be read is not ruled out.
  if (!build || !build.cacheTypes || build.cacheTypes.length === 0) return true
  for (var i = 0; i < cacheTypes.length; i++)
    if (cacheTypes[i] && build.cacheTypes.indexOf(cacheTypes[i]) === -1) return false
  return true
}

function resolveBuild(builds, chosen, cacheTypeK, cacheTypeV) {
  builds = builds || []
  var explicit = findBuild(builds, chosen)
  if (explicit) return explicit
  for (var i = 0; i < builds.length; i++)
    if (buildSupports(builds[i], [cacheTypeK, cacheTypeV])) return builds[i]
  return builds.length > 0 ? builds[0] : null
}

// Cache types a model can pick: its build's own, or on auto every type any
// build accepts -- auto then lands on a build that takes the one picked.
function buildCacheTypes(builds, chosen) {
  var explicit = findBuild(builds, chosen)
  if (explicit) return explicit.cacheTypes || []
  var out = []
  for (var i = 0; i < (builds || []).length; i++) {
    var types = builds[i].cacheTypes || []
    for (var j = 0; j < types.length; j++) if (out.indexOf(types[j]) === -1) out.push(types[j])
  }
  return out
}

// "llama-cpp-turboquant-cuda · 424c336 · 2026-09-02 · CUDA"
function buildLabel(build) {
  if (!build) return ""
  var parts = [build.fork || "llama-server"]
  if (build.commit) parts.push(String(build.commit).slice(0, 7))
  if (build.date) parts.push(build.date)
  if (build.gpu) parts.push(build.gpu)
  return parts.join(" · ")
}

// ---- Installed backends ----

// The backends worth offering, given which binaries were found. A backend with
// nothing installed cannot be started, so listing it only invites a dead end.
//
// Until detection has finished nothing is known, so everything is offered; and
// when nothing at all is installed everything stays, so the settings pointing
// at a binary remain reachable.
function installedBackends(found, probed) {
  if (!probed) return BACKENDS.slice()
  var out = BACKENDS.filter(function(b) { return !!(found && found[b.id]) })
  return out.length > 0 ? out : BACKENDS.slice()
}

// Process-name marker used by pgrep/pkill when systemd is unavailable.
// Namespaced for the same reason as unitName -- the original plugin used a
// single global "Tray-llama-server", so a second widget would kill the
// first one's server.
function procMarker(pluginId, backendId) {
  return unitName(pluginId, backendId) + "-proc"
}

if (typeof module !== "undefined") {
  module.exports = {
    LLAMA_CPP: LLAMA_CPP,
    OLLAMA: OLLAMA,
    all: all,
    get: get,
    ids: ids,
    labels: labels,
    supports: supports,
    baseUrl: baseUrl,
    healthUrl: healthUrl,
    loadedModelsUrl: loadedModelsUrl,
    tagsUrl: tagsUrl,
    llamaBinaryCandidates: llamaBinaryCandidates,
    ollamaBinaryCandidates: ollamaBinaryCandidates,
    ggufSearchDirs: ggufSearchDirs,
    ollamaStoreCandidates: ollamaStoreCandidates,
    OLLAMA_KV_CACHE_TYPES: OLLAMA_KV_CACHE_TYPES,
    ollamaLaunch: ollamaLaunch,
    envPrefix: envPrefix,
    detachedCommand: detachedCommand,
    stopCommand: stopCommand,
    takeoverStopCommand: takeoverStopCommand,
    modelsDirFromUnitEnvironment: modelsDirFromUnitEnvironment,
    unitName: unitName,
    procMarker: procMarker,
    journalCommand: journalCommand,
    slotPrefix: slotPrefix,
    findBuild: findBuild,
    buildSupports: buildSupports,
    resolveBuild: resolveBuild,
    buildCacheTypes: buildCacheTypes,
    buildLabel: buildLabel,
    installedBackends: installedBackends
  }
}
