// llama-swap config generation, parsing and API helpers.
//
// The plugin no longer launches one llama-server per model. llama-swap does it:
// one process, one port, one config file, and a `cmd` per model. That `cmd` is
// also the tuning store -- there is no profile file any more -- so this module
// owns the two directions:
//
//   tuning  ->  cmd line  ->  YAML block
//   YAML block  ->  cmd line  ->  tuning
//
// Only blocks carrying "# managed: <absolute model path>" belong to the plugin.
// Everything else in the file is the user's: hand-written models, ttl, routing,
// comments. Rewriting a managed block keeps that promise; nothing here touches
// the rest of the file.
//
// Pure logic: no QML, no I/O. Panel.qml writes the files and talks to the API.

var Model = require("./Model.js")
var Params = require("./Params.js")
var Backends = require("./Backends.js")

// ---- Defaults ----

// A tuning object, in the same shape the Tuning page holds. Anything absent is
// the value a model gets when it is first added to the config.
var DEFAULTS = {
  gpuLayers: "-1", threads: "0",
  contextSize: "0", batchSize: "0", ubatchSize: "0",
  cacheTypeK: "f16", cacheTypeV: "f16", cacheRam: "", temperature: "",
  cpuMoe: false, nCpuMoe: "", noRepack: false,
  loadMode: "auto", flashAttn: "auto", specType: "none",
  parallel: "", reasoningPreserve: "default",
  mmprojMode: "auto", mmprojPath: "", mmprojOffload: "off",
  draftPath: "",
  extraArgs: "", extraEnv: "", llamaBuild: "",
  // System One keeps its context in its own field, like the old launcher.
  systemoneCtx: "0"
}

function clone(value) {
  return JSON.parse(JSON.stringify(value))
}

function defaults() {
  return clone(DEFAULTS)
}

function tuningFrom(source) {
  var out = defaults()
  var src = source || {}
  for (var key in DEFAULTS) {
    if (src[key] !== undefined && src[key] !== null) out[key] = src[key]
  }
  return out
}

// ---- Shell words ----

// One argv token as a shell word. Single quotes keep every character literal
// except the quote itself, which closes, escapes, and reopens. "${PORT}" is
// deliberately left bare: llama-swap substitutes it before running the command.
function shellQuote(value) {
  var s = String(value == null ? "" : value)
  if (s === "${PORT}") return s
  if (s !== "" && !/[\s"'\\$`;&|<>()*?{}\[\]#~]/.test(s)) return s
  return "'" + s.replace(/'/g, "'\\''") + "'"
}

function joinArgs(args) {
  var out = []
  for (var i = 0; i < (args || []).length; i++) out.push(shellQuote(args[i]))
  return out.join(" ")
}

// The inverse of shellQuote. Model.parseArgs is deliberately simple and is
// right for the semicolon-separated extra-args field, but it cannot read the
// '\'' escape this module writes. This is the small real shell-word reader the
// config needs; it does not expand variables or globs.
function shellSplit(command) {
  var out = []
  var current = ""
  var quote = null
  var started = false
  var src = String(command || "")

  function flush() {
    if (started) out.push(current)
    current = ""
    started = false
  }

  for (var i = 0; i < src.length; i++) {
    var ch = src[i]
    if (quote === "'") {
      if (ch === "'") quote = null
      else current += ch
      continue
    }
    if (quote === '"') {
      if (ch === "\\" && i + 1 < src.length) { current += src[++i]; continue }
      if (ch === '"') { quote = null; continue }
      current += ch
      continue
    }
    if (ch === "'") { quote = "'"; started = true; continue }
    if (ch === '"') { quote = '"'; started = true; continue }
    if (ch === "\\" && i + 1 < src.length) { current += src[++i]; started = true; continue }
    if (/\s/.test(ch)) { flush(); continue }
    current += ch
    started = true
  }
  flush()
  return out
}

// ---- YAML scalars (the subset this file generates) ----

function yamlQuote(value) {
  return JSON.stringify(String(value == null ? "" : value))
}

// A flow sequence of strings. JSON is valid YAML, so one line is enough.
function yamlList(values) {
  var out = []
  for (var i = 0; i < (values || []).length; i++) out.push(yamlQuote(values[i]))
  return "[" + out.join(", ") + "]"
}

function unquoteYaml(value) {
  var s = String(value == null ? "" : value).trim()
  if (s === "") return ""
  if (s.charAt(0) === '"') {
    try { return JSON.parse(s) } catch (e) { return s.slice(1, -1) }
  }
  if (s.charAt(0) === "'") {
    // YAML single quotes escape a quote by doubling it.
    return s.slice(1, -1).replace(/''/g, "'")
  }
  return s
}

// ---- Model ids ----

// A stable, readable API id for a model file. llama-swap routes by this, and
// users type it in clients, so it is the file stem rather than a hash.
function modelId(path, used) {
  var base = Model.baseName(String(path || "")).replace(/\.gguf$/i, "")
  var id = base.replace(/[^A-Za-z0-9._-]+/g, "_").replace(/^_+|_+$/g, "")
  if (id === "") id = "model"
  var taken = used || {}
  var candidate = id
  var n = 2
  while (taken[candidate]) {
    candidate = id + "-" + n
    n++
  }
  return candidate
}

// ---- Tuning -> cmd ----

// Emits one flag, but only when the build's --help describes it. A flag the
// build does not know would abort every model load, so it is dropped and
// reported for the Tuning page's warning row.
function pushFlag(args, ignored, build, flag, value) {
  if (!Backends.supportsFlag(build, flag)) {
    if (ignored.indexOf(flag) === -1) ignored.push(flag)
    return false
  }
  args.push(flag)
  if (String(value) !== "") args.push(String(value))
  return true
}

function positiveInt(value) {
  var n = parseInt(value, 10)
  return isFinite(n) && n > 0 ? n : 0
}

function resolveMmproj(modelPath, tuning, visionDirs) {
  var mode = String(tuning.mmprojMode || "auto")
  if (mode === "off") return ""
  if (mode === "custom") return String(tuning.mmprojPath || "")
  return String((visionDirs || {})[Model.dirName(String(modelPath || ""))] || "")
}

function resolveDraft(modelPath, tuning, mtpDirs) {
  if (String(tuning.specType || "none") !== "draft-mtp") return ""
  // A path the Tuning page parsed back from the cmd wins: the sibling match is
  // only the first guess, and the user may point it elsewhere.
  if (String(tuning.draftPath || "") !== "") return String(tuning.draftPath)
  return String((mtpDirs || {})[Model.dirName(String(modelPath || ""))] || "")
}

// Builds the argv (without the binary) for one model. This is the same flag set
// the old Tuning page produced, minus the process-level ones llama-swap owns:
// host, port, slot-save-path and --metrics. The port is the ${PORT} macro.
//
// `opts`:
//   modelPath, tuning, build, visionDirs, mtpDirs, catalogue, systemone
//
// Returns {args, env, ignored, invalidEnv}. `args` still needs the binary
// prepended to become a command.
function buildArgs(opts) {
  opts = opts || {}
  var tuning = tuningFrom(opts.tuning)
  var build = opts.build || null
  var args = []
  var ignored = []
  var modelPath = String(opts.modelPath || "")

  args.push("--port", "${PORT}")
  args.push("--model", modelPath)

  // A custom parameter owns its flag: emitting the built-in value as well would
  // put the same flag on the line twice, and the last one silently wins.
  var owned = {}
  var custom = opts.customParams || []
  for (var c = 0; c < custom.length; c++) owned[String(custom[c].key || "")] = true

  var ngl = parseInt(tuning.gpuLayers, 10)
  if (!isFinite(ngl)) ngl = 0
  if (ngl !== -1) ngl = Math.max(0, Math.min(999, ngl))
  if (!owned["--gpu-layers"] && !owned["-ngl"] && !owned["--n-gpu-layers"])
    pushFlag(args, ignored, build, "--gpu-layers", String(ngl))

  if (!owned["--cache-type-k"] && tuning.cacheTypeK)
    pushFlag(args, ignored, build, "--cache-type-k", tuning.cacheTypeK)
  if (!owned["--cache-type-v"] && tuning.cacheTypeV)
    pushFlag(args, ignored, build, "--cache-type-v", tuning.cacheTypeV)
  if (!owned["--flash-attn"] && tuning.flashAttn)
    pushFlag(args, ignored, build, "--flash-attn", tuning.flashAttn)
  if (!owned["--load-mode"] && tuning.loadMode)
    pushFlag(args, ignored, build, "--load-mode", tuning.loadMode)

  if (!opts.systemone) {
    // Vision projector: same three modes the Tuning page had. The path is
    // resolved by the caller so a sibling projector is found the same way the
    // rest of the plugin finds it.
    var mmproj = resolveMmproj(modelPath, tuning, opts.visionDirs)
    if (!owned["--mmproj"] && !owned["--no-mmproj"]) {
      if (tuning.mmprojMode === "off") pushFlag(args, ignored, build, "--no-mmproj", "")
      else if (mmproj !== "") {
        pushFlag(args, ignored, build, "--mmproj", mmproj)
        if (tuning.mmprojOffload === "on") pushFlag(args, ignored, build, "--mmproj-offload", "")
        else pushFlag(args, ignored, build, "--no-mmproj-offload", "")
      }
    }

    // An external MTP draft is only useful while the spec type uses it.
    var draft = resolveDraft(modelPath, tuning, opts.mtpDirs)
    if (!owned["--model-draft"] && draft !== "")
      pushFlag(args, ignored, build, "--model-draft", draft)
  }

  if (!owned["--parallel"] && String(tuning.parallel).trim() !== "")
    pushFlag(args, ignored, build, "--parallel", String(tuning.parallel).trim())

  if (!opts.systemone && !owned["--reasoning-preserve"] && !owned["--no-reasoning-preserve"]) {
    if (tuning.reasoningPreserve === "on") pushFlag(args, ignored, build, "--reasoning-preserve", "")
    else if (tuning.reasoningPreserve === "off") pushFlag(args, ignored, build, "--no-reasoning-preserve", "")
  }

  var threads = positiveInt(tuning.threads)
  if (!owned["--threads"] && threads > 0) pushFlag(args, ignored, build, "--threads", String(threads))

  if (!opts.systemone) {
    if (!owned["--n-cpu-moe"] && !owned["--cpu-moe"]) {
      var nCpuMoe = String(tuning.nCpuMoe).trim()
      if (nCpuMoe !== "") pushFlag(args, ignored, build, "--n-cpu-moe", nCpuMoe)
      else if (tuning.cpuMoe) pushFlag(args, ignored, build, "--cpu-moe", "")
    }
    if (!owned["--no-repack"] && tuning.noRepack) pushFlag(args, ignored, build, "--no-repack", "")
    if (!owned["--spec-type"] && tuning.specType !== "none")
      pushFlag(args, ignored, build, "--spec-type", tuning.specType)
  } else if (!owned["--n-cpu-moe"] && !owned["--cpu-moe"]) {
    var snCpuMoe = String(tuning.nCpuMoe).trim()
    if (snCpuMoe !== "") pushFlag(args, ignored, build, "--n-cpu-moe", snCpuMoe)
    else if (tuning.cpuMoe) pushFlag(args, ignored, build, "--cpu-moe", "")
  }

  // Context is the one field System One keeps under its own name.
  var ctx = positiveInt(opts.systemone ? tuning.systemoneCtx : tuning.contextSize)
  if (!owned["--ctx-size"] && ctx > 0) pushFlag(args, ignored, build, "--ctx-size", String(ctx))

  if (!opts.systemone) {
    var batch = positiveInt(tuning.batchSize)
    if (!owned["--batch-size"] && batch > 0) pushFlag(args, ignored, build, "--batch-size", String(batch))
    var ubatch = positiveInt(tuning.ubatchSize)
    if (!owned["--ubatch-size"] && ubatch > 0) pushFlag(args, ignored, build, "--ubatch-size", String(ubatch))
    if (!owned["--cache-ram"] && String(tuning.cacheRam).trim() !== "")
      pushFlag(args, ignored, build, "--cache-ram", String(tuning.cacheRam).trim())
    if (!owned["--temp"] && String(tuning.temperature).trim() !== "")
      pushFlag(args, ignored, build, "--temp", String(tuning.temperature).trim())
  }

  // User-added parameters. A custom parameter owns its flag: the built-in
  // checks above skipped it, so it is emitted exactly once here.
  for (var p = 0; p < custom.length; p++) {
    var entry = custom[p]
    var spec = Params.find(opts.catalogue || [], entry.key) ||
               Params.fallbackSpec(entry.key, entry.type)
    var argv = Params.toArgv(spec, entry.value)
    for (var a = 0; a < argv.length; a++) args.push(argv[a])
  }

  // Free-form extra args keep the last word on a duplicate.
  var pieces = Model.splitExtraArgs(tuning.extraArgs)
  for (var i = 0; i < pieces.length; i++) {
    var tokens = Model.parseArgs(pieces[i])
    for (var t = 0; t < tokens.length; t++) args.push(tokens[t])
  }

  var parsedEnv = Model.parseEnvAssignments(tuning.extraEnv)
  var env = []
  for (var e = 0; e < parsedEnv.env.length; e++)
    env.push(parsedEnv.env[e].name + "=" + parsedEnv.env[e].value)

  return { args: args, env: env, ignored: ignored, invalidEnv: parsedEnv.invalid }
}

// ---- cmd -> tuning ----

// Long and short spellings of every flag the Tuning page owns. The value is
// the tuning field it fills; `true` means a bare boolean flag.
var FLAG_FIELDS = {
  "-ngl": "gpuLayers", "--gpu-layers": "gpuLayers", "--n-gpu-layers": "gpuLayers",
  "-ctk": "cacheTypeK", "--cache-type-k": "cacheTypeK",
  "-ctv": "cacheTypeV", "--cache-type-v": "cacheTypeV",
  "-fa": "flashAttn", "--flash-attn": "flashAttn",
  "-lm": "loadMode", "--load-mode": "loadMode",
  "-np": "parallel", "--parallel": "parallel",
  "-t": "threads", "--threads": "threads",
  "-c": "contextSize", "--ctx-size": "contextSize",
  "-b": "batchSize", "--batch-size": "batchSize",
  "-ub": "ubatchSize", "--ubatch-size": "ubatchSize",
  "-cram": "cacheRam", "--cache-ram": "cacheRam",
  "--temp": "temperature", "--temperature": "temperature",
  "--spec-type": "specType",
  "--n-cpu-moe": "nCpuMoe", "-ncmoe": "nCpuMoe",
  "-mm": "mmprojPath", "--mmproj": "mmprojPath",
  "--model-draft": "draftPath", "-md": "draftPath", "--spec-draft-model": "draftPath"
}

var BOOLEAN_FIELDS = {
  "-cmoe": "cpuMoe", "--cpu-moe": "cpuMoe",
  "-nr": "noRepack", "--no-repack": "noRepack",
  "--no-mmproj": "noMmproj",
  "--mmproj-offload": "mmprojOffloadOn",
  "--no-mmproj-offload": "mmprojOffloadOff",
  "--reasoning-preserve": "reasoningOn",
  "--no-reasoning-preserve": "reasoningOff"
}

// Flags llama-swap owns, or the old launcher added for itself. Dropped from a
// parsed tuning so a later save does not put them back. --port and --model are
// read into fields below, not dropped with their values.
var DROP_FLAGS = ["--host", "--slot-save-path", "--metrics", "-h", "--help"]

// Splits a command string into tokens with the shell-word reader, so the
// quoting this module writes (including the '\'' escape) parses back exactly.
function cmdTokens(cmd) {
  return shellSplit(String(cmd || ""))
}

// True when a token looks like a flag. A negative number ("-1") is a value.
function isFlag(token) {
  return /^--?[A-Za-z]/.test(String(token || ""))
}

// Parses one model's cmd back into {binary, modelPath, tuning, custom?}.
//
// Unknown flags keep their value and are put back into extraArgs, so a
// hand-written flag survives a round trip through the Tuning page even though
// no control owns it. The port is always rewritten as ${PORT}.
function parseCmd(cmd) {
  var tokens = cmdTokens(cmd)
  var tuning = defaults()
  var binary = ""
  var modelPath = ""
  var extra = []
  var portSeen = false

  for (var i = 0; i < tokens.length; i++) {
    var token = tokens[i]
    if (i === 0 && !/^-/.test(token)) { binary = token; continue }

    var flag = token
    var inline = null
    var eq = token.indexOf("=")
    if (eq > 0 && token.indexOf("--") === 0) {
      flag = token.slice(0, eq)
      inline = token.slice(eq + 1)
    }

    if (DROP_FLAGS.indexOf(flag) !== -1) {
      // Skip the value of a dropped flag.
      if (inline === null && i + 1 < tokens.length && !isFlag(tokens[i + 1])) i++
      continue
    }
    if (flag === "--port" || flag === "-p") {
      portSeen = true
      if (inline === null && i + 1 < tokens.length && !isFlag(tokens[i + 1])) i++
      continue
    }
    if (flag === "--model" || flag === "-m") {
      if (inline !== null) modelPath = inline
      else if (i + 1 < tokens.length) modelPath = tokens[++i]
      continue
    }

    if (BOOLEAN_FIELDS[flag] !== undefined) {
      var field = BOOLEAN_FIELDS[flag]
      if (field === "cpuMoe") tuning.cpuMoe = true
      else if (field === "noRepack") tuning.noRepack = true
      else if (field === "noMmproj") tuning.mmprojMode = "off"
      else if (field === "mmprojOffloadOn") tuning.mmprojOffload = "on"
      else if (field === "mmprojOffloadOff") tuning.mmprojOffload = "off"
      else if (field === "reasoningOn") tuning.reasoningPreserve = "on"
      else if (field === "reasoningOff") tuning.reasoningPreserve = "off"
      continue
    }

    if (FLAG_FIELDS[flag] !== undefined) {
      var target = FLAG_FIELDS[flag]
      var value = inline
      if (value === null) {
        if (i + 1 < tokens.length && !isFlag(tokens[i + 1])) value = tokens[++i]
        else value = ""
      }
      if (target === "draftPath") {
        tuning.draftPath = value
        tuning.specType = tuning.specType === "none" ? "draft-mtp" : tuning.specType
      } else if (target === "mmprojPath") {
        tuning.mmprojPath = value
        tuning.mmprojMode = "custom"
      } else {
        tuning[target] = value
      }
      continue
    }

    // Anything else is a user flag. Collect it as one semicolon-separated
    // piece; a following value that is not itself a flag belongs with it.
    var piece = token
    if (inline === null && i + 1 < tokens.length && !isFlag(tokens[i + 1]) &&
        tokens[i + 1] !== "${PORT}") {
      piece += " " + shellQuote(tokens[++i])
    }
    extra.push(piece)
  }

  tuning.extraArgs = extra.join(";")
  // A parsed config always has a port; keep it out of extra args. The caller
  // regenerates it from ${PORT}.
  return { binary: binary, modelPath: modelPath, tuning: tuning, portSeen: portSeen }
}

// ---- YAML config ----

// Builds one managed model block. `cmd` is the full command string without a
// trailing newline. The marker is what makes the block ours; a block without
// it is never rewritten.
function managedBlock(entry) {
  var lines = []
  lines.push("  # managed: " + entry.path)
  lines.push("  " + yamlQuote(entry.id) + ":")
  // A literal block scalar keeps the command readable and needs no escaping.
  lines.push("    cmd: |-")
  var cmd = String(entry.cmd || "").replace(/\r/g, "")
  var parts = cmd.split("\n")
  for (var i = 0; i < parts.length; i++) lines.push("      " + parts[i])
  if (entry.env && entry.env.length > 0) lines.push("    env: " + yamlList(entry.env))
  return lines
}

// Creates a config with the shared settings this plugin relies on. Only called
// when there is no file yet; an existing file is never reset.
function createConfig(opts) {
  opts = opts || {}
  var lines = [
    "# Managed by Local AI Server. Edits inside a '# managed:' block are",
    "# replaced by the Tuning page; everything else is yours.",
    "healthCheckTimeout: " + (opts.healthCheckTimeout || 600),
    "unloadTimeout: 10",
    "startPort: " + (opts.startPort || 5800),
    "globalTTL: " + (opts.globalTTL || 0),
    "logToStdout: proxy",
    "models:"
  ]
  var models = opts.models || []
  for (var i = 0; i < models.length; i++) {
    if (i > 0) lines.push("")
    var block = managedBlock(models[i])
    for (var b = 0; b < block.length; b++) lines.push(block[b])
  }
  var text = lines.join("\n") + "\n"
  return setPreload(text, opts.preload || [])
}

// Finds the models: section and each model block, with line numbers so the
// writers below can replace one block without a YAML round trip.
function parseConfig(text) {
  var source = String(text || "").replace(/\r\n/g, "\n")
  var lines = source.split("\n")
  var models = []
  var modelsLine = -1
  var preload = []

  for (var i = 0; i < lines.length; i++) {
    if (/^models:\s*(#.*)?$/.test(lines[i])) { modelsLine = i; break }
  }

  function indentOf(line) {
    var m = String(line).match(/^( *)/)
    return m ? m[1].length : 0
  }
  function isBlank(line) {
    return String(line).trim() === ""
  }
  function isComment(line) {
    return /^\s*#/.test(line)
  }

  if (modelsLine !== -1) {
    var i = modelsLine + 1
    while (i < lines.length) {
      var line = lines[i]
      if (isBlank(line) || isComment(line)) { i++; continue }
      if (indentOf(line) === 0) break
      if (indentOf(line) !== 2) { i++; continue }

      // A model key: two spaces, a key, a colon, nothing after it.
      var keyMatch = line.match(/^  (?:"([^"]*)"|'([^']*)'|([^:#][^:]*?)):\s*(#.*)?$/)
      if (!keyMatch) { i++; continue }

      var keyLine = i
      var id = keyMatch[1] !== undefined ? keyMatch[1]
             : keyMatch[2] !== undefined ? keyMatch[2]
             : String(keyMatch[3]).trim()
      var start = keyLine
      // The managed marker sits immediately above the key, possibly after
      // blank lines or another comment.
      var back = keyLine - 1
      while (back >= 0 && isBlank(lines[back])) back--
      var managed = ""
      while (back >= 0 && isComment(lines[back])) {
        var marker = lines[back].match(/^\s*#\s*managed:\s*(.+?)\s*$/)
        if (marker) { managed = marker[1]; start = back; break }
        back--
      }

      var end = keyLine + 1
      var cmd = ""
      var env = []
      while (end < lines.length) {
        var child = lines[end]
        if (isBlank(child)) { end++; continue }
        if (indentOf(child) <= 2) break
        var cmdMatch = child.match(/^\s{4,}cmd:\s*(.*)$/)
        if (cmdMatch) {
          var rest = cmdMatch[1]
          if (/^\|[-+]?\s*$/.test(rest) || /^>[-+]?\s*$/.test(rest)) {
            var blockLines = []
            var j = end + 1
            var blockIndent = -1
            while (j < lines.length) {
              var bl = lines[j]
              if (isBlank(bl)) { blockLines.push(""); j++; continue }
              var bi = indentOf(bl)
              if (bi <= 4) break
              if (blockIndent === -1) blockIndent = bi
              // A line less indented than the first ends the scalar.
              if (bi < blockIndent) break
              blockLines.push(bl.slice(blockIndent))
              j++
            }
            cmd = blockLines.join("\n").replace(/\n+$/, "")
            end = j
            continue
          }
          cmd = unquoteYaml(rest)
        }
        var envMatch = child.match(/^\s{4,}env:\s*(.*)$/)
        if (envMatch) {
          var envRest = String(envMatch[1]).trim()
          if (envRest.charAt(0) === "[") {
            try {
              var parsed = JSON.parse(envRest)
              if (Array.isArray(parsed)) env = parsed.map(String)
            } catch (e) { env = [] }
          } else {
            // Block list: "  - NAME=value"
            var k = end + 1
            var envIndent = -1
            while (k < lines.length) {
              var item = lines[k].match(/^(\s+)-\s*(.*)$/)
              if (!item) break
              if (envIndent === -1) envIndent = item[1].length
              if (item[1].length < envIndent) break
              env.push(unquoteYaml(item[2]))
              k++
            }
            end = k
            continue
          }
        }
        end++
      }

      var parsedCmd = cmd !== "" ? parseCmd(cmd) : { binary: "", modelPath: "", tuning: defaults() }
      models.push({
        id: id,
        cmd: cmd,
        env: env,
        managedPath: managed,
        modelPath: parsedCmd.modelPath,
        binary: parsedCmd.binary,
        tuning: parsedCmd.tuning,
        startLine: start,
        endLine: end
      })
      i = end
    }
  }

  preload = parsePreload(lines)
  return { text: source, lines: lines, modelsLine: modelsLine, models: models, preload: preload }
}

function parsePreload(lines) {
  var hooks = -1, onStartup = -1, preloadLine = -1
  for (var i = 0; i < lines.length; i++) {
    if (/^hooks:\s*(#.*)?$/.test(lines[i])) { hooks = i; continue }
    if (hooks !== -1 && /^  on_startup:\s*(#.*)?$/.test(lines[i])) { onStartup = i; continue }
    if (onStartup !== -1 && /^    preload:\s*(.*)$/.test(lines[i])) {
      preloadLine = i
      break
    }
  }
  if (preloadLine === -1) return []

  var rest = String(lines[preloadLine].replace(/^\s*preload:\s*/, "")).trim()
  if (rest.charAt(0) === "[") {
    try { return JSON.parse(rest).map(String) } catch (e) { return [] }
  }
  var out = []
  var itemIndent = -1
  for (var k = preloadLine + 1; k < lines.length; k++) {
    var m = lines[k].match(/^(\s+)-\s*(.*)$/)
    if (!m) break
    if (itemIndent === -1) itemIndent = m[1].length
    if (m[1].length < itemIndent) break
    out.push(unquoteYaml(m[2]))
  }
  return out
}

// Replaces or adds one managed block. Returns {text, action, id}.
//
// A block is only replaced when its own marker names this model. A model id
// already used by a hand-written block is never overwritten: the new block
// gets a suffixed id instead, because two keys with one name would not parse.
function setManagedModel(text, entry) {
  var parsed = parseConfig(text)
  var lines = parsed.lines.slice()
  var found = null
  for (var i = 0; i < parsed.models.length; i++) {
    if (entry.path && parsed.models[i].managedPath === entry.path) { found = parsed.models[i]; break }
  }

  var used = {}
  for (var u = 0; u < parsed.models.length; u++) used[parsed.models[u].id] = true
  var id = String(entry.id || "")
  if (!found) id = uniqueId(id, used)
  else if (id !== found.id && used[id]) id = uniqueId(id, used)
  entry = { path: entry.path, id: id, cmd: entry.cmd, env: entry.env }

  var block = managedBlock(entry)
  if (found) {
    // Replace the whole block, including the managed marker. Keep one blank
    // line after it so the file stays readable.
    var replace = lines.slice(0, found.startLine).concat(block)
    var tail = lines.slice(found.endLine)
    while (tail.length > 0 && tail[0].trim() === "") tail.shift()
    if (tail.length > 0) replace.push("")
    var out = replace.concat(tail).join("\n")
    return { text: normalizeEnd(out), action: "updated", id: id }
  }

  // Append after the last model, before the next top-level section.
  var insertAt = parsed.models.length > 0
    ? Math.max.apply(null, parsed.models.map(function(m) { return m.endLine }))
    : (parsed.modelsLine !== -1 ? parsed.modelsLine + 1 : lines.length)
  // Walk back over blank lines so the new block sits with the others.
  while (insertAt > 0 && lines[insertAt - 1] !== undefined && lines[insertAt - 1].trim() === "") insertAt--
  var head = lines.slice(0, insertAt)
  var rest = lines.slice(insertAt)
  while (rest.length > 0 && rest[0].trim() === "") rest.shift()
  if (head.length > 0 && head[head.length - 1].trim() !== "") head.push("")
  // A file without a models: section needs one before its first model.
  if (parsed.modelsLine === -1) head.push("models:")
  var outLines = head.concat(block)
  if (rest.length > 0) {
    outLines.push("")
    outLines = outLines.concat(rest)
  }
  return { text: normalizeEnd(outLines.join("\n")), action: "added", id: id }
}

function uniqueId(id, used) {
  var base = String(id || "model")
  var candidate = base
  var n = 2
  while (used[candidate]) { candidate = base + "-" + n; n++ }
  return candidate
}

function removeManagedModel(text, pathOrId) {
  var parsed = parseConfig(text)
  var found = null
  for (var i = 0; i < parsed.models.length; i++) {
    var m = parsed.models[i]
    if (m.managedPath === "" || m.managedPath === undefined) continue
    if (m.managedPath === pathOrId || m.id === pathOrId) { found = m; break }
  }
  if (!found) return { text: text, action: "missing" }
  var lines = parsed.lines.slice()
  var out = lines.slice(0, found.startLine).concat(lines.slice(found.endLine))
  return { text: normalizeEnd(out.join("\n")), action: "removed", id: found.id }
}

// Rewrites hooks.on_startup.preload. This is the one setting the plugin keeps
// in the file itself: the router starts before the widget at login, so the
// last model has to be written down somewhere the router can see.
function setPreload(text, ids) {
  var source = String(text || "").replace(/\r\n/g, "\n")
  var lines = source.split("\n")
  var list = (ids || []).map(String)

  // Locate hooks: / on_startup: / preload: by indentation, preserving every
  // other key the user has.
  var hooks = -1, onStartup = -1, preloadLine = -1
  for (var i = 0; i < lines.length; i++) {
    if (/^hooks:\s*(#.*)?$/.test(lines[i])) { hooks = i; continue }
    if (hooks !== -1 && /^  on_startup:\s*(#.*)?$/.test(lines[i])) { onStartup = i; continue }
    if (onStartup !== -1 && /^    preload:\s*.*$/.test(lines[i])) { preloadLine = i; break }
  }

  function listLines() {
    var out = ["    preload:"]
    if (list.length === 0) { out[0] = "    preload: []"; return out }
    for (var k = 0; k < list.length; k++) out.push("      - " + yamlQuote(list[k]))
    return out
  }

  if (preloadLine !== -1) {
    // Replace a flow list on the same line, or the block list below it.
    var end = preloadLine + 1
    var itemIndent = -1
    while (end < lines.length) {
      var item = lines[end].match(/^(\s+)-\s*/)
      if (!item) break
      if (itemIndent === -1) itemIndent = item[1].length
      if (item[1].length < itemIndent) break
      end++
    }
    var next = lines.slice(0, preloadLine).concat(listLines()).concat(lines.slice(end))
    return normalizeEnd(next.join("\n"))
  }

  if (onStartup !== -1) {
    var insert = onStartup + 1
    // Insert after any existing on_startup children, before the next section.
    while (insert < lines.length && /^\s{4,}\S/.test(lines[insert])) insert++
    var next2 = lines.slice(0, insert).concat(listLines()).concat(lines.slice(insert))
    return normalizeEnd(next2.join("\n"))
  }

  if (hooks !== -1) {
    var hInsert = hooks + 1
    while (hInsert < lines.length && /^\s{2,}\S/.test(lines[hInsert])) hInsert++
    var hooksBlock = ["  on_startup:"].concat(listLines())
    var next3 = lines.slice(0, hInsert).concat(hooksBlock).concat(lines.slice(hInsert))
    return normalizeEnd(next3.join("\n"))
  }

  var base = source.replace(/\n+$/, "")
  if (base !== "") base += "\n\n"
  return normalizeEnd(base + "hooks:\n  on_startup:\n" + listLines().join("\n") + "\n")
}

function normalizeEnd(text) {
  return String(text || "").replace(/\n+$/, "") + "\n"
}

// ---- Commands / units ----

// Full command for one model: the router's binary, then the argv with ${PORT}.
// `binary` is the llama-server build, not llama-swap.
function modelCommand(binary, opts) {
  var built = buildArgs(opts)
  var args = [String(binary || "llama-server")].concat(built.args)
  return {
    cmd: joinArgs(args),
    env: built.env,
    ignored: built.ignored,
    invalidEnv: built.invalidEnv
  }
}

// systemd user unit for one router. A persistent unit is what makes "start on
// login" possible; the old transient systemd-run unit could not be enabled.
//
// systemd's own quoting: double quotes protect spaces, and backslashes and
// quotes are escaped.
function systemdQuote(value) {
  return '"' + String(value || "").replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/%/g, "%%") + '"'
}

function unitFile(opts) {
  opts = opts || {}
  var exec = [systemdQuote(opts.binary || "llama-swap"),
              "-config", systemdQuote(opts.configPath),
              "-listen", String(opts.host || "127.0.0.1") + ":" + String(opts.port || 8080)]
  var lines = [
    "[Unit]",
    "Description=Local AI Server router (" + String(opts.label || opts.unitName || "llama-swap") + ")",
    "After=network.target",
    "",
    "[Service]",
    "Type=simple",
    "ExecStart=" + exec.join(" "),
    "Restart=on-failure",
    "RestartSec=5",
    "WorkingDirectory=" + systemdQuote(opts.workDir || "/")
  ]
  var env = opts.env || []
  for (var i = 0; i < env.length; i++) lines.push("Environment=" + systemdQuote(env[i]))
  lines.push("", "[Install]", "WantedBy=default.target")
  return lines.join("\n") + "\n"
}

// ---- API ----

function baseUrl(host, port) {
  return "http://" + String(host || "127.0.0.1") + ":" + String(port || 8080)
}

function healthUrl(host, port) { return baseUrl(host, port) + "/health" }
function runningUrl(host, port) { return baseUrl(host, port) + "/running" }
function modelsUrl(host, port) { return baseUrl(host, port) + "/v1/models" }
function versionUrl(host, port) { return baseUrl(host, port) + "/api/version" }
function logsUrl(host, port, id, history) {
  return baseUrl(host, port) + "/logs/stream/" + encodeModel(id) + (history ? "" : "?no-history")
}
function proxyLogsUrl(host, port, history) {
  return baseUrl(host, port) + "/logs/stream/proxy" + (history ? "" : "?no-history")
}

// Model ids can carry a slash (author/model). Encode each segment, leave the
// separators alone so llama-swap's {model...} route still matches.
function encodeModel(id) {
  return String(id || "").split("/").map(encodeURIComponent).join("/")
}

function loadUrl(host, port, id) {
  return baseUrl(host, port) + "/upstream/" + encodeModel(id) + "/"
}

function unloadUrl(host, port, id) {
  return baseUrl(host, port) + "/api/models/unload/" + encodeModel(id)
}

function unloadAllUrl(host, port) {
  return baseUrl(host, port) + "/api/models/unload"
}

// /running lists only non-stopped processes. `ready` is a loaded model;
// `starting` is one still loading. Everything else is idle.
function parseRunning(text) {
  var out = []
  var data
  try { data = JSON.parse(text || "{}") } catch (e) { return out }
  var list = data && data.running ? data.running : []
  for (var i = 0; i < list.length; i++) {
    var entry = list[i] || {}
    out.push({
      model: String(entry.model || ""),
      state: String(entry.state || ""),
      cmd: String(entry.cmd || ""),
      proxy: String(entry.proxy || ""),
      ttl: entry.ttl || 0
    })
  }
  return out
}

function runningModel(text) {
  var list = parseRunning(text)
  for (var i = 0; i < list.length; i++) {
    if (list[i].state === "ready") return list[i]
  }
  // Still loading: report it so the UI can say what is coming rather than
  // looking idle.
  return list.length > 0 ? list[0] : null
}

// ---- llama-swap version ----

// Reads either the CLI's "version: v262 (...)" line or /api/version's
// {"version":"v262",...}. Returns 0 when unknown (a `devel` build).
function versionNumber(text) {
  var s = String(text || "")
  var field = s.match(/"version"\s*:\s*"([^"]*)"/)
  if (field) s = field[1]
  var match = s.match(/v?(\d+)/i)
  return match ? parseInt(match[1], 10) : 0
}

function versionAtLeast(text, minimum) {
  var n = versionNumber(text)
  return n > 0 && n >= Number(minimum || 0)
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULTS: DEFAULTS,
    defaults: defaults,
    tuningFrom: tuningFrom,
    shellQuote: shellQuote,
    joinArgs: joinArgs,
    shellSplit: shellSplit,
    yamlQuote: yamlQuote,
    yamlList: yamlList,
    modelId: modelId,
    buildArgs: buildArgs,
    parseCmd: parseCmd,
    managedBlock: managedBlock,
    createConfig: createConfig,
    parseConfig: parseConfig,
    setManagedModel: setManagedModel,
    removeManagedModel: removeManagedModel,
    setPreload: setPreload,
    parsePreload: parsePreload,
    modelCommand: modelCommand,
    unitFile: unitFile,
    systemdQuote: systemdQuote,
    baseUrl: baseUrl,
    healthUrl: healthUrl,
    runningUrl: runningUrl,
    modelsUrl: modelsUrl,
    versionUrl: versionUrl,
    logsUrl: logsUrl,
    proxyLogsUrl: proxyLogsUrl,
    loadUrl: loadUrl,
    unloadUrl: unloadUrl,
    unloadAllUrl: unloadAllUrl,
    encodeModel: encodeModel,
    parseRunning: parseRunning,
    runningModel: runningModel,
    versionNumber: versionNumber,
    versionAtLeast: versionAtLeast
  }
}
