// ModelsIni.js — Parser, serializer, and model profile manager using models.ini.
//
// Structure in models.ini:
//
// [models."/path/to/model.gguf"]
// alias = qwen-3.8-35b
// preferred_build = /path/to/llama-server
// gpu_layers = -1
// threads = 4
//
// [models."/path/to/model.gguf"::turboquant]
// cache_type_k = turbo4
// cache_type_v = turbo3
// ctx_size = 95000
//

var Profiles = (typeof require !== "undefined") ? require("./Profiles.js") : null

// Derives a clean default model alias from a filename or path.
// Examples:
//   "Qwen3.8-35B-A3B-Q4_K_M.gguf" -> "qwen3.8-35b-a3b"
//   "LFM3-Omni-2B-Q8_0.gguf" -> "lfm3-omni-2b"
//   "DeepSeek-R1-Distill-Qwen-14B-IQ4_NL.gguf" -> "deepseek-r1-distill-qwen-14b"
function deriveDefaultAlias(pathOrName) {
  var str = String(pathOrName || "").trim()
  if (!str) return ""
  var idx = str.lastIndexOf("/")
  if (idx >= 0) str = str.slice(idx + 1)
  // Strip .gguf or other extension
  str = str.replace(/\.gguf$/i, "").replace(/\.[a-z0-9]+$/i, "")
  // Strip common quantization suffixes
  str = str.replace(/[-_](?:(?:Q[0-9]_[K0-9A-Z_]+)|(?:IQ[0-9]_[A-Z0-9_]+)|(?:BF16)|(?:F16)|(?:F32))$/i, "")
  // Convert to clean lower-case identifier
  var cleaned = str.toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
  return cleaned || str
}

// Convert camelCase key to snake_case for INI
function toSnakeCase(str) {
  return String(str || "").replace(/[A-Z]/g, function(letter) {
    return "_" + letter.toLowerCase()
  })
}

// Convert snake_case key to camelCase for JS
function toCamelCase(str) {
  return String(str || "").replace(/_([a-z0-9])/g, function(g) {
    return g[1].toUpperCase()
  })
}

// Parse models.ini content into an object structure
function parse(content) {
  var lines = String(content || "").split(/\r?\n/)
  var result = {
    models: {}
  }
  var currentSection = null
  var currentModel = null
  var currentFork = null

  for (var i = 0; i < lines.length; i++) {
    var rawLine = lines[i]
    var line = rawLine.trim()
    if (!line || line.startsWith("#") || line.startsWith(";")) continue

    // Section header: [models."/path/to/model.gguf"] or [models."/path/to/model.gguf"::fork]
    var secMatch = line.match(/^\[models\."([^"]+)"(?:::([a-zA-Z0-9._\-\/]+))?\]$/)
    if (secMatch) {
      currentModel = secMatch[1]
      currentFork = secMatch[2] || ""
      if (!result.models[currentModel]) {
        result.models[currentModel] = {
          common: {},
          forks: {}
        }
      }
      continue
    }

    // Key-value pair
    if (currentModel) {
      var eqIdx = line.indexOf("=")
      if (eqIdx !== -1) {
        var key = line.slice(0, eqIdx).trim()
        var val = line.slice(eqIdx + 1).trim()

        // Unquote string if quoted
        if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
          val = val.slice(1, -1)
        }

        // Convert value type
        var parsedVal = val
        if (val === "true") parsedVal = true
        else if (val === "false") parsedVal = false
        else if (val.startsWith("[") && val.endsWith("]")) {
          try {
            parsedVal = JSON.parse(val)
          } catch (e) {
            parsedVal = val
          }
        }

        var propName = toCamelCase(key)
        var target = currentFork ? (result.models[currentModel].forks[currentFork] = result.models[currentModel].forks[currentFork] || {})
                                 : result.models[currentModel].common
        target[propName] = parsedVal
      }
    }
  }

  return result
}

// Serialize models object structure into INI content
function serialize(data) {
  var lines = [
    "# Local AI Server — Models and Fork Tuning Configuration",
    "# Auto-generated & editable by hand. Supports per-model and per-fork tuning.",
    ""
  ]

  var models = (data && data.models) ? data.models : {}
  var modelPaths = Object.keys(models).sort()

  for (var i = 0; i < modelPaths.length; i++) {
    var modelPath = modelPaths[i]
    var item = models[modelPath]
    lines.push("[models.\"" + modelPath + "\"]")

    // Write common properties
    var common = item.common || {}
    var commonKeys = Object.keys(common).sort()
    for (var k = 0; k < commonKeys.length; k++) {
      var key = commonKeys[k]
      var val = common[key]
      lines.push(toSnakeCase(key) + " = " + serializeValue(val))
    }
    lines.push("")

    // Write fork-specific sections
    var forks = item.forks || {}
    var forkNames = Object.keys(forks).sort()
    for (var f = 0; f < forkNames.length; f++) {
      var forkName = forkNames[f]
      var forkObj = forks[forkName]
      lines.push("[models.\"" + modelPath + "\"::" + forkName + "]")
      var forkKeys = Object.keys(forkObj).sort()
      for (var fk = 0; fk < forkKeys.length; fk++) {
        var fKey = forkKeys[fk]
        var fVal = forkObj[fKey]
        lines.push(toSnakeCase(fKey) + " = " + serializeValue(fVal))
      }
      lines.push("")
    }
  }

  return lines.join("\n")
}

function serializeValue(val) {
  if (typeof val === "boolean") return val ? "true" : "false"
  if (Array.isArray(val) || (val && typeof val === "object")) return JSON.stringify(val)
  var s = String(val === undefined || val === null ? "" : val)
  // If string contains special characters, quote it
  if (s.indexOf("=") !== -1 || s.indexOf("#") !== -1 || s.indexOf(";") !== -1 || s.startsWith(" ") || s.endsWith(" ")) {
    return JSON.stringify(s)
  }
  return s
}

// Convert existing profiles (from settings.json) into models.ini structure
function fromProfiles(profilesStore, defaultModel) {
  var res = { models: {} }
  if (!profilesStore || typeof profilesStore !== "object") return res

  for (var rawKey in profilesStore) {
    var val = profilesStore[rawKey]
    if (!val || typeof val !== "object") continue

    // Key formats:
    // llamacpp::<modelPath>
    // llamacpp::<modelPath>::build::<buildPath>
    var parts = rawKey.split("::")
    if (parts.length < 2) continue
    var backend = parts[0]
    if (backend !== "llamacpp") continue // currently models.ini targets llamacpp models
    var modelPath = parts[1]

    if (!res.models[modelPath]) {
      res.models[modelPath] = {
        common: {
          alias: deriveDefaultAlias(modelPath)
        },
        forks: {}
      }
    }

    if (parts.length === 2) {
      // Common profile
      for (var prop in val) {
        if (prop === "llamaBuild") {
          if (val[prop]) res.models[modelPath].common.preferredBuild = val[prop]
        } else {
          res.models[modelPath].common[prop] = val[prop]
        }
      }
    } else if (parts.length === 4 && parts[2] === "build") {
      var buildPath = parts[3]
      // Use fork name or short build identifier
      var forkKey = buildPath
      var forkObj = res.models[modelPath].forks[forkKey] || {}
      for (var fProp in val) {
        forkObj[fProp] = val[fProp]
      }
      res.models[modelPath].forks[forkKey] = forkObj
    }
  }

  return res
}

// Convert models.ini structure back into profiles store for compatibility
function toProfiles(iniData) {
  var store = {}
  if (!iniData || !iniData.models) return store

  for (var modelPath in iniData.models) {
    var item = iniData.models[modelPath]
    var commonKey = "llamacpp::" + modelPath
    var commonObj = {}
    if (item.common) {
      for (var k in item.common) {
        if (k === "preferredBuild") {
          commonObj.llamaBuild = item.common[k]
        } else {
          commonObj[k] = item.common[k]
        }
      }
    }
    store[commonKey] = commonObj

    if (item.forks) {
      for (var forkKey in item.forks) {
        var specKey = commonKey + "::build::" + forkKey
        store[specKey] = Object.assign({}, item.forks[forkKey])
      }
    }
  }

  return store
}

// Get the resolved tuning for a model, considering preferred_build and fork override
function resolveModelTuning(iniData, modelPath, chosenBuild) {
  var modelEntry = (iniData && iniData.models && iniData.models[modelPath]) ? iniData.models[modelPath] : null
  if (!modelEntry) return null

  var common = Object.assign({}, modelEntry.common || {})
  var build = chosenBuild || common.preferredBuild || ""
  var forkTuning = null

  if (build && modelEntry.forks) {
    // Try exact build path match
    if (modelEntry.forks[build]) {
      forkTuning = modelEntry.forks[build]
    } else {
      // Try matching by base name / keyword (e.g. "turboquant")
      for (var f in modelEntry.forks) {
        if (build.indexOf(f) !== -1 || f.indexOf(build) !== -1) {
          forkTuning = modelEntry.forks[f]
          break
        }
      }
    }
  }

  var merged = Object.assign({}, common)
  if (forkTuning) {
    for (var key in forkTuning) {
      merged[key] = forkTuning[key]
    }
  }

  // Ensure alias exists
  if (!merged.alias) {
    merged.alias = deriveDefaultAlias(modelPath)
  }

  return {
    tuning: merged,
    preferredBuild: common.preferredBuild || "",
    alias: merged.alias
  }
}

// ---- llama-server native router (--models-preset) ----
//
// llama.cpp's own INI format differs from this plugin's models.ini: keys are
// long flags without leading dashes ("gpu-layers = 8"), and an unknown key
// aborts the launch. The data handed in here comes from fromProfiles(), whose
// keys are camelCase (the serialized models.ini snake_case is a file-only
// spelling). Section names become the model ids clients see: the alias.

// Router argv: the preset INI is the entire model catalogue; the binary acts
// as the router when it gets --models-preset and no --model.
function routerLaunchArgs(binary, host, port, presetPath, cfg) {
  cfg = cfg || {}
  var args = [
    binary,
    "--host", host,
    "--port", String(port),
    "--models-preset", presetPath,
    // Prometheus endpoint, so Stats keeps working as in single-model mode.
    "--metrics"
  ]
  if (cfg.modelsMax > 0) args.push("--models-max", String(cfg.modelsMax))
  if (cfg.extraPieces) args = args.concat(cfg.extraPieces)
  return args
}

// camelCase tuning field -> llama.cpp INI key (see `llama-server --help`).
var ROUTER_KEY_MAP = {
  contextSize: "ctx-size",
  gpuLayers: "gpu-layers",
  threads: "threads",
  batchSize: "batch-size",
  ubatchSize: "ubatch-size",
  cacheRam: "cache-ram",
  cacheTypeK: "cache-type-k",
  cacheTypeV: "cache-type-v",
  loadMode: "load-mode",
  parallel: "parallel",
  nCpuMoe: "n-cpu-moe",
  keepAlive: "keep-alive",
  mmprojPath: "mmproj",
  temperature: "temperature",
  flashAttn: "flash-attn"
}

// Flags with no value. Only emitted when true: llama.cpp rejects a bare
// "--cpu-moe"-style key without a negation existing.
var ROUTER_BOOL_KEYS = {
  cpuMoe: "cpu-moe",
  noRepack: "no-repack"
}

// Tri-state defaults that mean "let llama.cpp decide".
var ROUTER_SKIP_VALUES = ["", "auto", "none", "default"]
// Numeric "auto" sentinels: 0/"" leave the flag out.
var ROUTER_ZERO_IS_DEFAULT = {
  threads: true, batchSize: true, ubatchSize: true, contextSize: true,
  nCpuMoe: true, cacheRam: true, parallel: true
}

// Renders the plugin data ("fromProfiles" output shape) as a llama.cpp router
// preset INI, one section per model keyed by its alias.
function toRouterIni(iniData) {
  var out = "version = 1\n"
  if (!iniData || !iniData.models) return out

  var seenAliases = {}
  for (var modelPath in iniData.models) {
    var entry = iniData.models[modelPath]
    var tuning = entry.common || {}
    var alias = String(tuning.alias || "").trim() || deriveDefaultAlias(modelPath)
    // Stale duplicate aliases point at moved/renamed models; the first (live)
    // profile wins, matching the model list order.
    if (seenAliases[alias]) continue
    seenAliases[alias] = true
    out += "\n[" + alias + "]\n"
    out += "model = " + modelPath + "\n"

    // Projector: off means never load one; otherwise the paths the tuning
    // page recorded decide, and GPU offload of the projector stays opt-in.
    if (String(tuning.mmprojMode) === "off") out += "no-mmproj = true\n"
    if (String(tuning.mmprojOffload) === "on") out += "mmproj-offload = true\n"
    else if (tuning.mmprojPath) out += "no-mmproj-offload = true\n"

    // INI booleans take true/false, so the tri-state on/off flags become the
    // flag itself or its --no- counterpart.
    if (String(tuning.reasoningPreserve) === "on") out += "reasoning-preserve = true\n"
    else if (String(tuning.reasoningPreserve) === "off") out += "no-reasoning-preserve = true\n"

    for (var field in ROUTER_KEY_MAP) {
      var value = tuning[field]
      if (value === undefined || value === null) continue
      var str = String(value).trim()
      if (ROUTER_SKIP_VALUES.indexOf(str) !== -1) continue
      if (ROUTER_ZERO_IS_DEFAULT[field] && (str === "0" || str === "-1")) continue
      if (field === "gpuLayers" && str === "auto") continue
      out += ROUTER_KEY_MAP[field] + " = " + str + "\n"
    }

    for (var boolField in ROUTER_BOOL_KEYS) {
      if (tuning[boolField] === true) out += ROUTER_BOOL_KEYS[boolField] + " = true\n"
    }

    // Extra args are stored as raw llama.cpp tokens ("--flag value"); re-emit
    // them as INI pairs so a value still lands on the right flag.
    var pieces = String(tuning.extraArgs || "").split(/[\t ]+/).filter(Boolean)
    for (var i = 0; i < pieces.length; i++) {
      var token = String(pieces[i])
      if (token === "--") continue
      if (token.slice(0, 2) === "--") {
        var next = pieces[i + 1]
        if (next !== undefined && String(next).slice(0, 2) !== "--") {
          out += token.slice(2) + " = " + next + "\n"
          i++
        } else
          out += token.slice(2) + " = true\n"
      } else if (token.slice(0, 1) === "-") {
        // Short flag without a long form: cannot be expressed as an INI key.
        continue
      } else {
        out += token + " = true\n"
      }
    }

    // shortcut: fork-specific (per-build) tuning is not emitted -- the router
    // runs one binary for every model. Upgrade if the router learns per-model
    // binaries.
  }

  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    deriveDefaultAlias: deriveDefaultAlias,
    toSnakeCase: toSnakeCase,
    toCamelCase: toCamelCase,
    parse: parse,
    serialize: serialize,
    fromProfiles: fromProfiles,
    toProfiles: toProfiles,
    resolveModelTuning: resolveModelTuning,
    routerLaunchArgs: routerLaunchArgs,
    toRouterIni: toRouterIni
  }
}
