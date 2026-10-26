// One-shot migration from the per-model launcher to llama-swap routers.
//
// Older settings held a tuning profile per model and one flat copy of the last
// live tuning. The router holds the same thing in each model's `cmd`, so this
// module writes those commands and reports what it could not carry over.
//
// Pure logic: the old settings object and the scan go in, YAML text and a
// report come out. Panel.qml backs up, validates and writes the files.
//
// Migration reuses the same block writer and argv builder the Tuning page uses,
// so a migrated model and an edited one cannot drift apart.

var _req = (function() {
  try { return eval("require") } catch (e) { return null }
})()
var LS = _req ? _req("./LlamaSwap.js") : null
var Profiles = _req ? _req("./Profiles.js") : null
var Backends = _req ? _req("./Backends.js") : null

var CONFIG_VERSION = 4
var MAIN_START_PORT = 5800
var SYSTEMONE_START_PORT = 5900

// A settings file written by this version is already migrated. Nothing else
// counts: an install that never had settings has nothing to migrate either.
function needsMigration(settings) {
  if (!settings || typeof settings !== "object") return false
  return Number(settings.configVersion || 0) < CONFIG_VERSION
}

// The settings file also carries flat tuning that older versions launched
// with. Profiles.fromSettings turns that into the selected model's profile.
function profileStore(settings) {
  return Profiles.fromSettings(settings || {}, Profiles.snapshot(settings || {})).profiles
}

function backendPath(key) {
  var text = String(key || "")
  var idx = text.indexOf("::")
  if (idx === -1) return { backend: "", path: "" }
  return { backend: text.slice(0, idx), path: text.slice(idx + 2) }
}

// svc: { backend, selected, profileKeyFallback, store, scan, fallbackBinary,
//        builds, catalogue, systemone, selectedSystemoneCtx }
function modelPaths(opts) {
  var out = []
  function add(path) {
    var p = String(path || "")
    if (p === "" || out.indexOf(p) !== -1) return
    out.push(p)
  }

  if (opts.selected && /\.gguf$/i.test(opts.selected)) add(opts.selected)
  for (var key in opts.store) {
    var entry = backendPath(key)
    if (entry.backend === opts.backend) add(entry.path)
  }
  if (opts.scan && Array.isArray(opts.scan.models)) {
    for (var i = 0; i < opts.scan.models.length; i++) add(opts.scan.models[i])
  }
  return out
}

function unmanagedPaths(text) {
  var out = {}
  var parsed = LS.parseConfig(text || "")
  for (var i = 0; i < parsed.models.length; i++) {
    var model = parsed.models[i]
    if (model.managedPath === "" && model.modelPath !== "") out[model.modelPath] = true
  }
  return out
}

function buildFor(profile, fallbackBinary, builds) {
  var pinned = String(profile.llamaBuild || "")
  if (pinned !== "") {
    var found = Backends.findBuild(builds, pinned)
    return { binary: found ? found.path : pinned, build: found, pinned: true, missing: found === null }
  }
  if (fallbackBinary !== "") {
    var configured = Backends.findBuild(builds, fallbackBinary)
    return { binary: configured ? configured.path : fallbackBinary, build: configured, pinned: false, missing: false }
  }
  var auto = Backends.resolveBuild(builds, "", profile.cacheTypeK, profile.cacheTypeV)
  return { binary: auto ? auto.path : "llama-server", build: auto, pinned: false, missing: false }
}

function label(build, binary) {
  if (build) return Backends.buildLabel(build)
  return String(binary || "llama-server")
}

// One service's entries. Returns {entries, skipped, conflicts, warnings}.
function planService(opts) {
  var entries = []
  var skipped = []
  var conflicts = []
  var warnings = []
  var paths = modelPaths(opts)
  var haveScan = !!(opts.scan && Array.isArray(opts.scan.models))
  var unmanaged = opts.existing ? unmanagedPaths(opts.existing) : {}

  for (var i = 0; i < paths.length; i++) {
    var path = paths[i]

    if (opts.selectedOnlyGguf && !/\.gguf$/i.test(path)) {
      skipped.push({ path: path, reason: "not a llama.cpp model file" })
      continue
    }
    if (haveScan && opts.scan.models.indexOf(path) === -1) {
      skipped.push({ path: path, reason: "model file not found" })
      continue
    }
    if (unmanaged[path]) {
      conflicts.push({ path: path, reason: "already a hand-written model in the config" })
      continue
    }

    var profile = Profiles.get(opts.store, opts.backend, path)
    if (profile === null && opts.profileFallback && path === opts.selected) {
      profile = Profiles.get(opts.store, opts.backend, opts.profileFallback)
    }
    var tuned = profile !== null
    var tuning = LS.tuningFrom(profile || {})

    if (opts.systemone) {
      tuning.systemoneCtx = (path === opts.selected && String(opts.systemoneCtx || "").trim() !== "")
        ? String(opts.systemoneCtx).trim()
        : "0"
    }

    var resolved = buildFor(tuning, opts.fallbackBinary, opts.builds)
    var command = LS.modelCommand(resolved.binary, {
      modelPath: path,
      tuning: tuning,
      build: resolved.build,
      visionDirs: opts.systemone ? {} : (opts.scan && opts.scan.visionDirs),
      mtpDirs: opts.systemone ? {} : (opts.scan && opts.scan.mtpDirs),
      catalogue: opts.catalogue,
      systemone: !!opts.systemone,
      customParams: (profile && profile.customParams) || []
    })

    entries.push({
      path: path,
      cmd: command.cmd,
      env: command.env,
      tuned: tuned,
      pinned: resolved.pinned,
      build: label(resolved.build, resolved.binary)
    })

    if (resolved.missing) {
      warnings.push(path + ": pinned build " + tuning.llamaBuild +
        " was not detected; the path is used anyway")
    }
    if (command.ignored.length > 0) {
      warnings.push(path + ": " + command.ignored.join(", ") +
        " is not in " + label(resolved.build, resolved.binary) + ", so it was left out")
    }
    if (command.invalidEnv.length > 0) {
      warnings.push(path + ": ignored malformed env " + command.invalidEnv.join(", "))
    }
  }

  return { entries: entries, skipped: skipped, conflicts: conflicts, warnings: warnings }
}

// Writes one service's models into its config. An existing file is edited in
// place: user blocks and settings stay, managed blocks are replaced, missing
// models are appended.
function writeService(existing, plan, startPort, preloadPath) {
  var text = existing || LS.createConfig({ startPort: startPort })
  var used = {}
  if (!existing) {
    // A new file: assign ids up front so the preload list can name one.
    for (var i = 0; i < plan.entries.length; i++) {
      plan.entries[i].id = LS.modelId(plan.entries[i].path, used)
      used[plan.entries[i].id] = true
    }
    text = LS.createConfig({ startPort: startPort, models: plan.entries, preload: [] })
  } else {
    for (var j = 0; j < plan.entries.length; j++) {
      var entry = plan.entries[j]
      var written = LS.setManagedModel(text, {
        path: entry.path,
        id: LS.modelId(entry.path, {}),
        cmd: entry.cmd,
        env: entry.env
      })
      text = written.text
      entry.id = written.id
      used[written.id] = true
    }
  }

  var preload = []
  var found = false
  if (preloadPath !== "") {
    for (var k = 0; k < plan.entries.length; k++) {
      if (plan.entries[k].path === preloadPath) {
        preload = [plan.entries[k].id]
        found = true
        break
      }
    }
  }
  // An existing config keeps its preload when this run cannot place the
  // selected model: the model may still be a managed block from before, and
  // clearing the list would silently disable the auto-load.
  if (existing && preloadPath !== "" && !found) return { text: text, preload: [] }
  text = LS.setPreload(text, preload)
  return { text: text, preload: preload }
}

function report(opts, main, systemone) {
  var lines = []
  lines.push("Local AI Server migration report")
  lines.push("===============================")
  lines.push("")
  lines.push("Old settings version: " + (opts.settings && opts.settings.version ? opts.settings.version : "unknown"))
  lines.push("")

  function section(title, path, service, router) {
    lines.push(title + ": " + router.host + ":" + router.port)
    if (path) lines.push("  config: " + path)
    lines.push("  models: " + service.entries.length +
      " (" + service.entries.filter(function(e) { return e.tuned }).length + " tuned, " +
      service.entries.filter(function(e) { return !e.tuned }).length + " defaults)")
    lines.push("  preload: " + (router.preload.length > 0 ? router.preload.join(", ") : "none"))
    for (var i = 0; i < service.entries.length; i++) {
      var e = service.entries[i]
      lines.push("  - " + e.id + "  " + e.path + (e.tuned ? "" : "  [defaults]") +
        (e.pinned ? "  [build: " + e.build + "]" : ""))
    }
    lines.push("")
  }

  section("Main router", opts.paths && opts.paths.main, main, opts.listen.main)
  section("System One router", opts.paths && opts.paths.systemone, systemone, opts.listen.systemone)

  var all = [
    { title: "Skipped", items: main.skipped.concat(systemone.skipped) },
    { title: "Conflicts (left untouched)", items: main.conflicts.concat(systemone.conflicts) },
    { title: "Warnings", items: main.warnings.concat(systemone.warnings).map(function(w) {
      return { path: w, reason: "" }
    }) }
  ]
  for (var s = 0; s < all.length; s++) {
    if (all[s].items.length === 0) continue
    lines.push(all[s].title + ":")
    for (var i = 0; i < all[s].items.length; i++) {
      var item = all[s].items[i]
      lines.push("  - " + item.path + (item.reason ? "  (" + item.reason + ")" : ""))
    }
    lines.push("")
  }

  lines.push("Not migrated:")
  lines.push("  - ollama settings are unchanged; it keeps its own backend.")
  if (opts.slotsDir) {
    lines.push("  - prompt caches under " + opts.slotsDir + " are orphaned: the")
    lines.push("    router stops the child process on unload, which clears them.")
    lines.push("    The files are left on disk and can be deleted.")
  }
  lines.push("  - the Tuning page's row layout (removed/added rows) is not kept;")
  lines.push("    the generated cmd is the tuning now, and flags it carries survive.")
  lines.push("")
  lines.push("Ports: main " + opts.listen.main.port + ", System One " +
    opts.listen.systemone.port + ", ollama " + opts.listen.ollama.port)
  if (opts.listen.main.port === opts.listen.systemone.port) {
    lines.push("WARNING: the two routers share a port; give one of them a different one.")
  }
  return lines.join("\n") + "\n"
}

// The whole plan. `opts`:
//
//   settings         parsed old settings.json (or null)
//   builds           llama.cpp builds from the probe
//   catalogue        parameter catalogue, for added parameters
//   scan             { models, visionDirs, mtpDirs } for chat models
//   systemoneScan    the same for the System One model directory
//   existingMain     current main config text, or null
//   existingSystemone
//   mainBinary       configured chat binary ("" = auto)
//   systemoneBinary  configured System One binary ("" = chat binary)
//   systemoneModelsDir
//   host, ports      ports: { main, systemone, ollama }
//   paths            where the configs will be written, for the report
//   slotsDir         the old prompt-cache directory, for the report
function plan(opts) {
  opts = opts || {}
  var settings = (opts.settings && typeof opts.settings === "object") ? opts.settings : {}
  var store = profileStore(settings)
  var ports = opts.ports || {}
  var oldPorts = settings.backendPorts || {}
  var host = opts.host || settings.host || "127.0.0.1"

  // New callers name the routers; an old settings file names backends.
  function portFor(name, backend, fallback) {
    var value = ports[name] !== undefined ? ports[name] : oldPorts[backend]
    return String(value !== undefined && String(value).trim() !== "" ? value : fallback)
  }

  var listen = {
    main: { host: host, port: portFor("main", "llamacpp", "8080"), preload: [] },
    systemone: { host: host, port: portFor("systemone", "systemone", "8081"), preload: [] },
    ollama: { host: host, port: portFor("ollama", "ollama", "11434"), preload: [] }
  }

  var mainPlan = planService({
    store: store,
    backend: "llamacpp",
    selected: String(settings.selectedModel || ""),
    scan: opts.scan,
    builds: opts.builds || [],
    catalogue: opts.catalogue || [],
    fallbackBinary: String(opts.mainBinary || ""),
    existing: opts.existingMain || "",
    systemone: false,
    selectedOnlyGguf: true
  })

  var systemoneBits = {
    store: store,
    backend: "systemone",
    selected: String(settings.systemoneModel || ""),
    profileFallback: String(settings.selectedModel || ""),
    scan: opts.systemoneScan,
    builds: opts.builds || [],
    catalogue: opts.catalogue || [],
    fallbackBinary: String(opts.systemoneBinary || opts.mainBinary || ""),
    existing: opts.existingSystemone || "",
    systemone: true,
    systemoneCtx: String(settings.systemoneCtx || "0")
  }
  // System One only gets models the old backend could actually serve: its own
  // profiles, the selected decision model, and a dedicated model directory.
  // The shared scan would put every chat model on /v1/systemone. Without a
  // dedicated scan there is nothing to check the profiles against, so their
  // paths are trusted rather than reported as missing.
  if (!opts.systemoneScan || !Array.isArray(opts.systemoneScan.models)) {
    systemoneBits.scan = null
  }
  var systemonePlan = planService(systemoneBits)

  var main = writeService(opts.existingMain || "", mainPlan, MAIN_START_PORT,
    String(settings.selectedModel || ""))
  var systemone = writeService(opts.existingSystemone || "", systemonePlan, SYSTEMONE_START_PORT,
    String(settings.systemoneModel || ""))

  listen.main.preload = main.preload
  listen.systemone.preload = systemone.preload

  var out = {
    configVersion: CONFIG_VERSION,
    main: { text: main.text, entries: mainPlan.entries, preload: main.preload },
    systemone: { text: systemone.text, entries: systemonePlan.entries, preload: systemone.preload },
    listen: listen
  }
  out.report = report({
    settings: settings,
    paths: opts.paths || {},
    listen: listen,
    slotsDir: opts.slotsDir || ""
  }, mainPlan, systemonePlan)

  // The report has the applied ids only after writeService, so re-render the
  // counts against entries; ids are filled in by then.
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    CONFIG_VERSION: CONFIG_VERSION,
    needsMigration: needsMigration,
    plan: plan
  }
}
