// Per-model tuning profiles.
//
// The same numbers do not suit two models: a 35B MoE wants layers on the CPU,
// a small dense 2B wants none of that, and a context that fits one spills the
// other out of VRAM. So the whole Tuning page is stored per model rather than
// once for the machine.
//
// A profile appears the first time a model's tuning is edited -- there is no
// switch to arm first. Until then the model runs on `defaultTuning`, the set a
// new profile is seeded from, which is what makes a profile optional: pick a
// model, start it, never open Tuning, and nothing is ever written for it.
//
// Pure logic: plain objects in, plain objects out. Panel.qml owns the live
// properties and the file.

// Simple scalar settings: copied by value.
var FIELDS = [
  "gpuLayers", "threads", "contextSize", "batchSize", "ubatchSize",
  "cacheTypeK", "cacheTypeV", "cacheRam", "temperature",
  "cpuMoe", "nCpuMoe", "noRepack",
  "loadMode", "flashAttn", "specType", "specTypeUserSet",
  // Flags the plugin used to decide on its own, or that had to be hand-written
  // into extra args to be set at all. Per model like everything else here: a
  // vision projector belongs to one model, and the slot count that suits a 35B
  // MoE is not the one a 2B dense model wants.
  "parallel", "reasoningPreserve",
  "mmprojMode", "mmprojPath", "mmprojOffload",
  "extraArgs", "keepAlive",
  // Environment for the server process -- GGML tuning knobs have no flag.
  "extraEnv",
  // Which llama-server build runs the model ("" = auto). Per model because a
  // fork is usually there for one model's sake -- its cache types, its
  // speculative decoding -- and the rest are happier on upstream.
  "llamaBuild"
]

// Page state: the rows removed from Tuning, the optional rows added to it, the
// values a removed row held, and the parameters added. Structured, so copied deeply -- a shared
// array reference would let an edit under one model reach into another's
// profile.
var STRUCTURED = ["hiddenBuiltins", "shownOptionals", "builtinStash", "customParams"]

// What a field holds when nothing has set it. Also what a profile missing a
// field falls back to, which is how a profile written by an older build gains
// a field this one added without carrying the previous model's value into it.
var DEFAULTS = {
  gpuLayers: "-1", threads: "0",
  contextSize: "0", batchSize: "0", ubatchSize: "0",
  cacheTypeK: "f16", cacheTypeV: "f16", cacheRam: "", temperature: "",
  cpuMoe: false, nCpuMoe: "", noRepack: false,
  loadMode: "auto", flashAttn: "auto", specType: "none", specTypeUserSet: false,
  parallel: "", reasoningPreserve: "default",
  mmprojMode: "auto", mmprojPath: "", mmprojOffload: "off",
  extraArgs: "", keepAlive: "", extraEnv: "", llamaBuild: "",
  hiddenBuiltins: [], shownOptionals: [], builtinStash: {}, customParams: []
}

function clone(value) {
  return JSON.parse(JSON.stringify(value))
}

// Profiles are keyed by backend as well as model.
//
// ollama names a model ("qwen3:8b") where llama.cpp takes a path, so the two
// namespaces cannot collide -- but the tuning cannot be shared even where they
// name the same weights: llama.cpp's profile is argv flags and ollama's is
// environment variables, and the added parameters in one are meaningless to
// the other.
function key(backend, model) {
  var m = String(model || "")
  if (m === "") return ""
  return String(backend || "") + "::" + m
}

// The live values as a storable object.
function snapshot(source) {
  var out = {}
  var i
  for (i = 0; i < FIELDS.length; i++) {
    var f = FIELDS[i]
    out[f] = source[f] === undefined ? DEFAULTS[f] : source[f]
  }
  for (i = 0; i < STRUCTURED.length; i++) {
    var s = STRUCTURED[i]
    out[s] = clone(source[s] === undefined ? DEFAULTS[s] : source[s])
  }
  return out
}

// A complete set of values from a partial (or absent) profile, ready to be
// written onto the live properties.
function resolve(profile) {
  var p = (profile && typeof profile === "object") ? profile : {}
  return snapshot(p)
}

// The stored profile for a model, or null when it has none. A model with no
// profile is the normal case, not a missing one: the caller falls back to the
// defaults rather than treating it as an error.
function get(profiles, backend, model) {
  var k = key(backend, model)
  if (k === "") return null
  var store = profiles || {}
  var found = store[k]
  return (found && typeof found === "object") ? found : null
}

function has(profiles, backend, model) {
  return get(profiles, backend, model) !== null
}

// Stores are replaced rather than mutated: QML only re-evaluates bindings on a
// property assignment, so an in-place edit of the object would leave the page
// showing the previous state.
function set(profiles, backend, model, values) {
  var k = key(backend, model)
  var out = {}
  var store = profiles || {}
  for (var existing in store) out[existing] = store[existing]
  if (k !== "") out[k] = snapshot(values)
  return out
}

function remove(profiles, backend, model) {
  var k = key(backend, model)
  var out = {}
  var store = profiles || {}
  for (var existing in store) if (existing !== k) out[existing] = store[existing]
  return out
}

// The seed a model with no profile of its own runs on, kept per backend: a
// llama.cpp default set is argv flags and an ollama one is environment
// variables, so one shared set would hand each backend the other's.
function defaultsFor(defaults, backend) {
  var store = defaults || {}
  var found = store[String(backend || "")]
  return (found && typeof found === "object") ? found : null
}

function setDefaults(defaults, backend, values) {
  var out = {}
  var store = defaults || {}
  for (var existing in store) out[existing] = store[existing]
  out[String(backend || "")] = snapshot(values)
  return out
}

// Reads the profile store out of a settings file.
//
// A file written before profiles existed carries one flat tuning set, which
// was tuned for whichever model it names. Dropping it into `defaultTuning`
// alone would hand those values to every model; also seeding the selected
// model's own profile with them keeps that one model launching exactly as it
// did, and leaves the rest inheriting the same values only until they are
// first edited.
function fromSettings(parsed, flatValues) {
  var p = (parsed && typeof parsed === "object") ? parsed : {}
  var fallback = snapshot(flatValues || {})

  var backend = String(p.backend || "")

  if (p.profiles && typeof p.profiles === "object") {
    var store = {}
    for (var k in p.profiles) {
      var entry = p.profiles[k]
      if (entry && typeof entry === "object") store[k] = snapshot(entry)
    }
    var defaults = {}
    if (p.defaultTuning && typeof p.defaultTuning === "object") {
      for (var b in p.defaultTuning) {
        var d = p.defaultTuning[b]
        if (d && typeof d === "object") defaults[b] = snapshot(d)
      }
    }
    if (!defaultsFor(defaults, backend)) defaults[backend] = fallback
    return { profiles: store, defaultTuning: defaults }
  }

  var migrated = {}
  var seeded = key(backend, p.selectedModel)
  if (seeded !== "") migrated[seeded] = clone(fallback)
  var migratedDefaults = {}
  migratedDefaults[backend] = fallback
  return { profiles: migrated, defaultTuning: migratedDefaults }
}

if (typeof module !== "undefined") {
  module.exports = {
    FIELDS: FIELDS,
    STRUCTURED: STRUCTURED,
    DEFAULTS: DEFAULTS,
    key: key,
    snapshot: snapshot,
    resolve: resolve,
    get: get,
    has: has,
    set: set,
    remove: remove,
    defaultsFor: defaultsFor,
    setDefaults: setDefaults,
    fromSettings: fromSettings
  }
}
