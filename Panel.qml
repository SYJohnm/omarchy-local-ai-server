import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model
import "Backends.js" as Backends
import "Hardware.js" as Hardware
import "Params.js" as Params
import "Profiles.js" as Profiles

// Local AI server manager.
//
// Starts, stops and monitors a local inference server -- llama.cpp's
// llama-server or ollama -- and reports prompt-processing (pp) and
// token-generation (tg) throughput while it works.
//
// Both backends run llama.cpp underneath, so they emit the same timing lines
// and share one parser (Model.parseTimingLine). They differ in how live the
// numbers can be: llama.cpp exposes /slots, which is polled for a running
// pp% sweep, while ollama only reports totals once a request completes.
Panel {
  id: root
  moduleName: "sxy.local-ai-server"
  ipcTarget: "sxy.local-ai-server"

  // ---- Configuration (manifest settings) ----

  property string backend: setting("backend", "llamacpp")
  readonly property var backendSpec: Backends.get(root.backend)

  // Empty means "auto-detect": binaryProbe fills these in from the
  // candidate lists, so a fresh install works with no configuration.
  readonly property string configuredLlamaBinary: setting("binary", "")
  readonly property string configuredOllamaBinary: setting("ollamaBinary", "")
  // Optional second llama.cpp build understanding extra --cache-type values
  // (the TurboQuant fork's vbr/turboN tiers). Left blank on a normal install;
  // when unset, those cache types are hidden entirely rather than offered and
  // then rejected at launch by a binary that does not understand them.
  readonly property string altBinary: setting("altBinary", "")
  readonly property string configuredModelsDir: setting("modelsDir", "")

  property string detectedLlamaBinary: ""
  property string detectedOllamaBinary: ""
  property var detectedModelDirs: []

  readonly property string llamaBinary: configuredLlamaBinary !== "" ? expandPath(configuredLlamaBinary) : detectedLlamaBinary
  readonly property string ollamaBinary: configuredOllamaBinary !== "" ? expandPath(configuredOllamaBinary) : detectedOllamaBinary
  readonly property string activeBinary: root.backend === "ollama" ? root.ollamaBinary : root.launchLlamaBinary

  // ---- llama.cpp builds ----
  //
  // Every llama-server on the machine, identified by llama_builds.py (fork,
  // commit, GPU backend, the KV cache types its --help accepts). The model's
  // profile names the build it runs on; "" means auto -- the first build that
  // accepts the model's cache types. That is what the altBinary setting used
  // to do by hand for one hard-coded family of cache types.
  property var llamaBuilds: []
  property bool buildsProbed: false
  property string llamaBuild: ""
  readonly property var resolvedBuild:
    Backends.resolveBuild(root.llamaBuilds, root.llamaBuild, root.cacheTypeK, root.cacheTypeV)
  // What auto would pick, shown on the Auto entry so it is not a mystery.
  readonly property var autoBuild:
    Backends.resolveBuild(root.llamaBuilds, "", root.cacheTypeK, root.cacheTypeV)
  // Until the probe answers, the pre-probe rule: the alternate binary for its
  // own cache types, the primary one otherwise.
  readonly property string launchLlamaBinary: {
    if (root.resolvedBuild) return root.resolvedBuild.path
    var useAlt = root.altBinary !== "" &&
      (Model.isTurboQuantCacheType(root.cacheTypeK) || Model.isTurboQuantCacheType(root.cacheTypeV))
    return useAlt ? expandPath(root.altBinary) : root.llamaBinary
  }

  // Resolved from the directory this plugin was loaded from, so renaming or
  // relocating the plugin never breaks the probe path.
  readonly property string pluginDir: {
    var dir = String(root.settings && root.settings.sourceDir ? root.settings.sourceDir : "")
    if (dir === "") dir = expandPath("~/.config/omarchy/plugins/sxy.local-ai-server")
    return dir.replace(/^file:\/\//, "").replace(/\/$/, "")
  }
  readonly property string probeScript: pluginDir + "/gguf_probe.py"
  readonly property string hwProbeScript: pluginDir + "/hw_probe.sh"
  readonly property string blobScript: pluginDir + "/ollama_blobs.py"

  // Serve ollama's already-pulled models with llama.cpp instead of keeping a
  // second copy of the same weights. ollama's model layer is a plain GGUF, so
  // llama-server opens it directly -- no conversion, no duplication.
  property bool shareOllamaModels: true
  // name -> {path, size, store}, resolved from ollama's manifests.
  property var ollamaBlobs: ({})
  // The store the resolved models actually live in. Needed at launch: without
  // OLLAMA_MODELS the server falls back to the per-user default, which on a
  // system-package install is empty -- so every model 404s.
  readonly property string resolvedOllamaStore: {
    for (var name in root.ollamaBlobs) {
      var store = root.ollamaBlobs[name].store
      if (store) return String(store)
    }
    return ""
  }

  // Whether a launched server outlives this widget. `omarchy restart shell`
  // runs `quickshell kill`, which tears this panel down; with this on, the
  // server is left running and re-adopted by the next instance.
  property bool surviveRestart: true

  // ---- Hardware ----

  property var hardware: null
  readonly property string hardwareSummary: root.hardware ? Hardware.summary(root.hardware) : ""

  // Attention geometry of the selected model, from gguf_probe.py. What one
  // token of KV cache costs depends on it, so the context suggestion is only
  // a real calculation once a model is picked.
  property var modelGeometry: ({})
  readonly property var selectedGeometry: root.modelGeometry[root.selectedModel] || null

  // Recomputed as the inputs change, so the suggestion tracks the settings
  // that actually determine what fits -- cache type and MoE offload move it
  // by an order of magnitude on a small card.
  readonly property var suggestions: {
    if (!root.hardware) return null
    return Hardware.suggestAll(root.hardware, {
      geometry: root.selectedGeometry,
      cacheTypeK: root.cacheTypeK,
      cacheTypeV: root.cacheTypeV,
      cpuMoeActive: root.cpuMoe || String(root.nCpuMoe).trim() !== "",
      cacheRamMb: parseInt(root.cacheRam, 10) || 0
    })
  }

  // ---- Discovered models ----

  property var modelOptions: []
  property var pendingModelFiles: []
  property var visionDirs: ({})
  property string selectedModel: ""
  property bool scanning: false

  // ---- Launch parameters ----

  property string host: "127.0.0.1"

  // Port is stored per backend rather than as one value rewritten on every
  // switch.
  //
  // A single shared port had to be reassigned by the backend-change handler,
  // so it was only ever correct if that handler happened to run: switching
  // backend by editing the settings file, or loading a file written before a
  // switch, left one backend holding the other's port. Keyed by backend, each
  // is independently correct, and the backend's own default fills in for one
  // that has never been set.
  property var backendPorts: ({})
  readonly property string port: {
    var stored = root.backendPorts[root.backend]
    if (stored !== undefined && String(stored).trim() !== "") return String(stored)
    return String(root.backendSpec.defaultPort)
  }

  function setPort(value) {
    var trimmed = String(value).trim()
    if (trimmed === root.port) return
    var next = {}
    for (var key in root.backendPorts) next[key] = root.backendPorts[key]
    next[root.backend] = trimmed
    root.backendPorts = next
  }

  property string gpuLayers: "-1"
  property string contextSize: "0"
  property string batchSize: "0"
  property string ubatchSize: "0"
  property string threads: "0"

  readonly property var cacheQuantTypes: ["f16", "f32", "bf16", "q8_0", "q4_0", "q4_1", "iq4_nl", "q5_0", "q5_1"]
  // Only understood by the alternate binary; offered only when one is set.
  readonly property var altCacheQuantTypes: ["vbr", "turbo8", "turbo4", "turbo3", "turbo2", "turbo3_tcq", "turbo2_tcq", "turbo1_tcq"]
  readonly property var availableCacheTypes: root.backend === "llamacpp" && root.llamaBuilds.length > 0 &&
      Backends.buildCacheTypes(root.llamaBuilds, root.llamaBuild).length > 0
    ? Backends.buildCacheTypes(root.llamaBuilds, root.llamaBuild)
    : root.altBinary !== ""
    ? root.cacheQuantTypes.concat(root.altCacheQuantTypes)
    : root.cacheQuantTypes

  property string cacheTypeK: "f16"
  property string cacheTypeV: "f16"
  property string cacheRam: ""
  property string temperature: ""

  property bool cpuMoe: false
  property string nCpuMoe: ""
  property bool noRepack: false

  readonly property var loadModeValues: ["auto", "none", "mmap", "mlock", "mmap+mlock", "dio"]
  property string loadMode: "auto"
  readonly property var flashAttnValues: ["auto", "on", "off"]
  property string flashAttn: "auto"
  // Draft/n-gram strategies, read from the binary rather than listed here: the
  // set grows with llama.cpp (this build offers eleven, the two hard-coded
  // here were what an older one had), and a value this build does not know is
  // a server that refuses to start.
  readonly property var specTypeValues: {
    var spec = Params.find(root.paramCatalogue, "--spec-type")
    if (spec && spec.options.length > 0) return spec.options
    return ["none", "draft-mtp"]
  }
  property string specType: "none"
  property bool specTypeUserSet: false

  // Number of server slots (-np). Blank leaves llama.cpp on its own auto.
  property string parallel: ""

  // Whether the reasoning trace is kept across the whole history rather than
  // the last assistant message. Tri-state: the flag and its negation mean
  // different things, and passing neither leaves the chat template's own
  // choice in place, which is the only correct default for a template that
  // does not support it at all.
  readonly property var tristateValues: ["default", "on", "off"]
  property string reasoningPreserve: "default"

  // ---- Vision projector ----
  //
  // A projector sitting next to the model used to be passed silently, together
  // with --no-mmproj-offload, on the reasoning that a vision tower rarely fits
  // beside the model's own layers. Both remain the default, but they are now a
  // control: "auto" is only a good guess, a directory can hold a projector
  // that belongs to a different model, and on a card with room to spare
  // keeping the tower on the CPU costs image throughput for nothing.
  //
  // auto: use the projector found next to the model, if any
  // off:  --no-mmproj, even where one was found
  // custom: use mmprojPath
  readonly property var mmprojModes: ["auto", "off", "custom"]
  property string mmprojMode: "auto"
  property string mmprojPath: ""
  property string mmprojOffload: "off"

  // The projector found beside the selected model, if any.
  readonly property string detectedMmproj: {
    if (root.selectedModel === "") return ""
    var found = root.visionDirs[Model.dirName(root.selectedModel)]
    return found ? String(found) : ""
  }
  readonly property string resolvedMmproj: {
    if (root.mmprojMode === "off") return ""
    if (root.mmprojMode === "custom") return String(root.mmprojPath).trim()
    return root.detectedMmproj
  }
  readonly property bool mmprojActive: root.resolvedMmproj !== ""

  property string extraArgs: ""
  // Environment for the server process, "NAME=value ..." -- for knobs llama.cpp
  // only reads from the environment (GGML_OP_OFFLOAD_MIN_BATCH and friends).
  property string extraEnv: ""
  readonly property var parsedEnv: Model.parseEnvAssignments(root.extraEnv)
  function envScriptPrefix() {
    return root.parsedEnv.env.map(function(e) { return e.name + "=" + root.shellQuote(e.value) }).join(" ")
  }

  // ollama-only
  property string keepAlive: ""

  // ---- Custom parameters ----
  //
  // Rather than exposing every flag a backend has (llama-server alone has
  // ~250), the page carries a small set of common controls and lets the user
  // add any other parameter on demand. The catalogue is generated from the
  // binary's own --help, so it matches the build actually installed.

  // Catalogue for the active backend, parsed from --help.
  property var paramCatalogue: []
  property bool catalogueLoading: false
  // Added parameters, in display order: [{ key, value }]. Persisted.
  property var customParams: []
  // Flags the page already has dedicated controls for; excluded from the
  // picker so the same setting cannot be driven from two places.
  // Flags the plugin owns outright: identity and plumbing, not tuning. They
  // are never offered, because an added copy would not override anything --
  // the model, host, port, slot path and metrics endpoint are how the panel
  // finds and watches the server it started. "--cache-type" is the shorthand
  // setting both K and V at once, so a picker entry for it would quietly
  // countermand two visible controls rather than replace one.
  readonly property var structuralFlags: [
    "--model", "--host", "--port", "--slot-save-path", "--metrics",
    "--cache-type",
    "OLLAMA_HOST", "OLLAMA_MODELS"
  ]

  // Flag -> the property a built-in control drives with it.
  //
  // These are offered by the picker like any other parameter, marked with the
  // control they belong to. Adding one takes that setting over: the built-in
  // stops emitting its flag (otherwise the launch line carries both and
  // llama.cpp silently keeps the last), and the control it replaces steps
  // aside. Remove the added row and the control comes back at its default.
  readonly property var ownedFlags: ({
    "--gpu-layers": "gpuLayers", "--n-gpu-layers": "gpuLayers",
    "--ctx-size": "contextSize",
    "--threads": "threads",
    "--batch-size": "batchSize", "--ubatch-size": "ubatchSize",
    "--cache-type-k": "cacheTypeK", "--cache-type-v": "cacheTypeV",
    "--flash-attn": "flashAttn",
    "--n-cpu-moe": "nCpuMoe", "--cpu-moe": "cpuMoe",
    "--load-mode": "loadMode", "--cache-ram": "cacheRam", "--temp": "temperature",
    "--spec-type": "specType", "--no-repack": "noRepack",
    "--parallel": "parallel", "--reasoning-preserve": "reasoningPreserve",
    "--mmproj": "mmprojPath", "--mmproj-auto": "mmprojMode",
    "--mmproj-offload": "mmprojOffload",
    "OLLAMA_CONTEXT_LENGTH": "contextSize", "OLLAMA_KV_CACHE_TYPE": "cacheTypeK",
    "OLLAMA_FLASH_ATTENTION": "flashAttn", "OLLAMA_KEEP_ALIVE": "keepAlive",
    "OLLAMA_NUM_PARALLEL": "parallel"
  })

  // What to call the displaced control in the picker.
  readonly property var ownedLabels: ({
    gpuLayers: "GPU layers", contextSize: "Context", threads: "Threads",
    batchSize: "Batch", ubatchSize: "ubatch",
    cacheTypeK: "KV cache k", cacheTypeV: "KV cache v",
    flashAttn: "Flash attn", nCpuMoe: "MoE on CPU", cpuMoe: "MoE on CPU",
    loadMode: "load mode", cacheRam: "prompt cache RAM", temperature: "temperature",
    specType: "speculative decoding", noRepack: "no-repack", keepAlive: "keep-alive",
    parallel: "slots", reasoningPreserve: "reasoning trace", extraArgs: "pasted args",
    mmprojMode: "vision projector", mmprojPath: "vision projector",
    mmprojOffload: "vision projector"
  })

  // ---- A pasted command line becomes rows ----
  //
  // A free-text argument string was the one setting on this page that could
  // not be read: appended last and kept by llama.cpp over any earlier
  // occurrence, so it silently won over the control showing the same flag,
  // while itself having no control at all. Anything landing in it is split
  // into one row per parameter instead -- filling a built-in control where the
  // flag has one, and adding a parameter row where it does not.
  //
  // The field stays, as the way to paste a command line in. It just no longer
  // stores anything: what it holds is consumed the moment it is committed.
  property bool migratingArgs: false

  function splitPastedArgs() {
    if (root.migratingArgs) return
    // Not while a profile is being written onto the live properties: the split
    // would edit rows the apply is still filling in, and every one of those
    // edits is guarded out of being saved -- leaving the page holding values
    // the profile does not have. applyTuningForSelection splits afterwards,
    // once the apply has finished and an edit can be recorded again.
    if (root.applyingTuning) return
    if (!root.settingsLoaded) return
    if (String(root.extraArgs).trim() === "") return
    // Splitting needs the catalogue to know which flags take a value; without
    // it every guess comes from token shape, and "--gpu-layers -1" guesses
    // wrong. The text is left alone until it arrives.
    if (root.paramCatalogue.length === 0) return

    var pieces = Model.splitExtraArgs(root.extraArgs)
    var tokens = []
    var i
    for (i = 0; i < pieces.length; i++) tokens = tokens.concat(Model.parseArgs(pieces[i]))

    var split = Params.fromTokens(root.paramCatalogue, tokens)
    if (split.params.length === 0) return

    root.migratingArgs = true
    try {
      for (i = 0; i < split.params.length; i++) {
        var entry = split.params[i]
        var prop = root.ownedFlags[entry.key]
        var row = prop ? root.builtinRowForProp(prop) : null
        // A flag with a control of its own fills that control rather than
        // adding a row beside it -- an added parameter would take the row over
        // and hide it, which is the opposite of making the value visible.
        //
        // Only where a control actually exists, though: several owned
        // properties have no row (--temp, --cache-ram, --load-mode), and
        // writing one of those would put the value exactly where it could not
        // be seen. Those become parameter rows like any other flag.
        if (row) {
          // Revealed first: restoring a row hands back the value it was
          // removed at, which would overwrite the one just parsed.
          root.restoreBuiltin(row.id)
          root[prop] = (typeof root[prop] === "boolean")
            ? (entry.value === "true" || entry.value === "on" || entry.value === "1")
            : String(entry.value)
        } else {
          root.addCustomParam(entry.key, entry.value, entry.type)
        }
      }
      // Only what could not be attributed to a flag stays behind, and it stays
      // rather than being dropped: a stray token is still something the user
      // typed, and it is still passed verbatim at launch.
      root.extraArgs = split.leftover.join(" ")
    } finally {
      root.migratingArgs = false
    }
    root.touchTuning()
  }

  // The row a built-in property is edited in, or null where it has none.
  function builtinRowForProp(prop) {
    for (var i = 0; i < root.builtinRows.length; i++) {
      var row = root.builtinRows[i]
      if (row.props.indexOf(prop) === -1) continue
      return root.builtinAvailable(row.id) ? row : null
    }
    return null
  }

  // Whether an added parameter has taken over a built-in property.
  function propOverridden(prop) {
    for (var i = 0; i < root.customParams.length; i++)
      if (root.ownedFlags[root.customParams[i].key] === prop) return true
    return false
  }

  // ---- Built-in tuning rows ----
  //
  // The common flags keep dedicated rows and dedicated properties: the
  // hardware suggestion, the ollama environment mapping and buildLlamaArgs all
  // read them by name, and a two-control row (cache k/v, batch/ubatch, MoE)
  // has no equivalent in the one-flag-per-row catalogue. What is removable is
  // the row -- a page that starts full leaves no room for what the user
  // actually tunes, and the picker hands any of them back.
  //
  // Removing a row also returns its setting to the plugin default: a hidden
  // row still shaping the launch line is invisible state, and the whole point
  // of a visible control is that it says what the next start will do. The
  // value is not lost -- it goes to builtinStash and comes back with the row.
  readonly property var builtinRows: [
    { id: "cacheType", label: "KV cache k/v",   feature: "cacheType", props: ["cacheTypeK", "cacheTypeV"] },
    { id: "flashAttn", label: "Flash attn",     feature: "flashAttn", props: ["flashAttn"] },
    { id: "ngl",       label: "GPU layers",     feature: "ngl",       props: ["gpuLayers"] },
    { id: "cpuMoe",    label: "MoE on CPU",     feature: "cpuMoe",    props: ["cpuMoe", "nCpuMoe"] },
    // No feature gate: every backend has some notion of context length.
    { id: "ctxSize",   label: "Context",        feature: "",          props: ["contextSize"] },
    { id: "threads",   label: "Threads",        feature: "threads",   props: ["threads"] },
    { id: "batchSize", label: "Batch / ubatch", feature: "batchSize", props: ["batchSize", "ubatchSize"] },

    // Optional rows: off the page until asked for, because their default is to
    // leave the backend alone and a control that says "default" in every
    // position is just a row taking up space.
    //
    // The two exceptions add themselves. A projector found beside the model
    // and an MTP draft picked from the model's own metadata are decisions the
    // plugin makes for you, and a decision made for you has to be visible
    // where it can be changed -- which is what these rows are for.
    { id: "parallel",  label: "Slots (-np)",    feature: "parallel",  props: ["parallel"],  optional: true },
    { id: "reasoning", label: "Reasoning trace", feature: "reasoning", props: ["reasoningPreserve"], optional: true },
    { id: "specType",  label: "Speculative",     feature: "specType",  props: ["specType"],  optional: true },
    { id: "vision",    label: "Vision projector", feature: "vision",   props: ["mmprojMode", "mmprojPath", "mmprojOffload"], optional: true },
    { id: "extraArgs", label: "Paste args",      feature: "extraArgs", props: ["extraArgs"], optional: true },
    { id: "envVars",   label: "Environment",     feature: "envVars",   props: ["extraEnv"],  optional: true }
  ]

  // The value each built-in property carries when nothing has set it. Also
  // what a restored row falls back to when it was never given one.
  readonly property var builtinDefaults: ({
    cacheTypeK: "f16", cacheTypeV: "f16",
    flashAttn: "auto",
    gpuLayers: "-1",
    cpuMoe: false, nCpuMoe: "",
    contextSize: "0",
    threads: "0",
    batchSize: "0", ubatchSize: "0",
    // No row of their own, but an added parameter can still take them over,
    // and giving one back has to land somewhere.
    loadMode: "auto", cacheRam: "", temperature: "", specType: "none",
    noRepack: false, keepAlive: "",
    parallel: "", reasoningPreserve: "default",
    mmprojMode: "auto", mmprojPath: "", mmprojOffload: "off",
    extraEnv: ""
  })

  // Row ids the user has removed from the page. Persisted.
  property var hiddenBuiltins: []
  // Optional row ids the user (or an automatic choice) has put on it. The
  // opposite list, and a separate one on purpose: an optional row is absent
  // until something asks for it, so a profile written before the row existed
  // must not show it -- which an "is it in hiddenBuiltins" test cannot tell
  // apart from a row the user deliberately kept.
  property var shownOptionals: []

  // Optional rows the plugin puts on the page by itself, because it is about
  // to act on them: a projector was found next to this model, or a draft
  // strategy was picked from its metadata. Derived rather than stored -- being
  // shown is not a decision worth writing a profile for, and the row goes away
  // again on a model it does not apply to.
  readonly property var autoOptionals: {
    var out = []
    if (root.detectedMmproj !== "") out.push("vision")
    if (root.specType !== "none") out.push("specType")
    // Anything still sitting unsplit -- a line from a profile written before
    // splitting existed, or a token the catalogue could not attribute -- shows
    // the field it is sitting in.
    if (String(root.extraArgs).trim() !== "") out.push("extraArgs")
    // Environment is invisible on the launch line's flags, so a value in it
    // always shows its row.
    if (String(root.extraEnv).trim() !== "") out.push("envVars")
    return out
  }
  // prop -> value held when its row was removed. Persisted, so a restore
  // survives a shell restart rather than only lasting the session.
  property var builtinStash: ({})

  function builtinRowSpec(id) {
    for (var i = 0; i < root.builtinRows.length; i++)
      if (root.builtinRows[i].id === id) return root.builtinRows[i]
    return null
  }

  // Whether this backend has the setting at all, removed or not.
  function builtinAvailable(id) {
    var row = root.builtinRowSpec(id)
    if (!row) return false
    return row.feature === "" || Backends.supports(root.backend, row.feature)
  }

  function builtinVisible(id) {
    if (!root.builtinAvailable(id)) return false
    var spec = root.builtinRowSpec(id)
    if (spec.optional) {
      // Removing an auto-shown row has to stick, so the removal list wins over
      // the reveal -- otherwise the row would come straight back on the next
      // model that triggers it.
      if (root.hiddenBuiltins.indexOf(id) !== -1) return false
      if (root.shownOptionals.indexOf(id) === -1 && root.autoOptionals.indexOf(id) === -1) return false
    } else if (root.hiddenBuiltins.indexOf(id) !== -1) return false
    // An added parameter driving any of the row's properties replaces the row:
    // two controls for one setting, one of which does not reach the server, is
    // worse than none.
    var row = root.builtinRowSpec(id)
    for (var i = 0; i < row.props.length; i++)
      if (root.propOverridden(row.props[i])) return false
    return true
  }

  function removeBuiltin(id) {
    var row = root.builtinRowSpec(id)
    if (!row || !root.builtinVisible(id)) return
    var stash = {}
    for (var key in root.builtinStash) stash[key] = root.builtinStash[key]
    for (var i = 0; i < row.props.length; i++) {
      var prop = row.props[i]
      stash[prop] = root[prop]
      root[prop] = root.builtinDefaults[prop]
    }
    root.builtinStash = stash
    if (row.optional) {
      var kept = []
      for (var k = 0; k < root.shownOptionals.length; k++)
        if (root.shownOptionals[k] !== id) kept.push(root.shownOptionals[k])
      root.shownOptionals = kept
    }
    if (root.hiddenBuiltins.indexOf(id) === -1)
      root.hiddenBuiltins = root.hiddenBuiltins.concat([id])
    root.touchTuning()
  }

  // Brings the row back at the value it was removed with -- the point of the
  // stash. A row never customised, or one whose stash a settings file predates,
  // comes back at the plugin default rather than empty.
  function restoreBuiltin(id) {
    var row = root.builtinRowSpec(id)
    if (!row) return
    if (row.optional && root.shownOptionals.indexOf(id) === -1)
      root.shownOptionals = root.shownOptionals.concat([id])
    var hidden = []
    for (var i = 0; i < root.hiddenBuiltins.length; i++)
      if (root.hiddenBuiltins[i] !== id) hidden.push(root.hiddenBuiltins[i])
    root.hiddenBuiltins = hidden
    var stash = {}
    for (var key in root.builtinStash) stash[key] = root.builtinStash[key]
    for (var j = 0; j < row.props.length; j++) {
      var prop = row.props[j]
      root[prop] = stash[prop] !== undefined ? stash[prop] : root.builtinDefaults[prop]
      delete stash[prop]
    }
    root.builtinStash = stash
    root.touchTuning()
  }

  // What the picker can currently offer: removed rows first -- they are what a
  // user is most likely looking for here, and there are never more than a
  // handful -- then catalogue flags not already added or reserved.
  //
  // One property rather than one per consumer: the button's count and the
  // list behind it are the same question, and computing it twice let them
  // disagree while ~250 catalogue entries were filtered on every keystroke.
  readonly property var addableOptions: {
    var added = root.customParams.map(function(p) { return p.key })
    var out = root.builtinPickerOptions.slice()
    var listed = Params.availableOptions(root.paramCatalogue, added, root.structuralFlags)
    for (var i = 0; i < listed.length; i++) {
      var opt = listed[i]
      var prop = root.ownedFlags[opt.value]
      // Shown, not hidden -- but named for the control it would displace, so
      // adding one is a decision rather than a surprise.
      if (prop) {
        out.push({
          value: opt.value,
          label: opt.label + "  ·  " + root.ownedLabels[prop],
          description: "Takes over the " + root.ownedLabels[prop] +
                       " control — remove it to hand that back"
        })
      } else {
        out.push(opt)
      }
    }
    return out
  }
  readonly property int addableCount: root.addableOptions.length

  // Removed rows, offered back through the same picker that adds parameters.
  // Prefixed so the handler can tell a row from a catalogue flag: the two are
  // added by different mechanisms.
  readonly property var builtinPickerOptions: {
    var out = []
    for (var i = 0; i < root.builtinRows.length; i++) {
      var row = root.builtinRows[i]
      if (!root.builtinAvailable(row.id)) continue
      if (root.builtinVisible(row.id)) continue
      // Removed *and* overridden: restoring it would put back a row the added
      // parameter immediately hides again.
      var taken = false
      for (var j = 0; j < row.props.length; j++)
        if (root.propOverridden(row.props[j])) taken = true
      if (taken) continue
      out.push({
        value: "builtin:" + row.id,
        label: row.label,
        description: row.optional
          ? "Built-in control — sets a flag the backend otherwise decides itself"
          : "Built-in control — restored with the value it was removed at"
      })
    }
    return out
  }

  function customParamValue(key) {
    for (var i = 0; i < root.customParams.length; i++)
      if (root.customParams[i].key === key) return root.customParams[i].value
    return ""
  }

  // `value` and `type` are given only when the parameter came from a parsed
  // command line, where both are already known. From the picker they are
  // absent and the seeding below applies.
  function addCustomParam(key, value, type) {
    if (key === "") return
    for (var i = 0; i < root.customParams.length; i++)
      if (root.customParams[i].key === key) {
        // Already on the page: a pasted line still gets to set it, since
        // naming a flag is a request for that value, not for the row.
        if (value !== undefined) root.setCustomParam(key, value)
        return
      }
    if (value !== undefined) {
      var parsed = { key: key, value: String(value) }
      // Carried only for a flag this build's --help does not describe, so the
      // launch line does not have to re-guess whether it takes a value.
      if (type !== undefined && !Params.find(root.paramCatalogue, key)) parsed.type = type
      root.customParams = root.customParams.concat([parsed])
      root.touchTuning()
      return
    }
    var spec = Params.find(root.paramCatalogue, key)
    // Seed with the backend's own default so an added parameter starts at the
    // value it would have had anyway, rather than empty or arbitrary.
    var seed = spec ? spec.defaultValue : ""
    if (spec && spec.type === "bool") seed = "true"
    // Same reasoning as a bool: an added flag sitting on "default" passes
    // nothing at all, which reads as the row being broken.
    if (spec && spec.type === "tristate") seed = "on"
    // One taking over a built-in starts at that control's default, the same
    // value removing it hands back -- so ownership moves in both directions
    // through one known state instead of carrying whatever happened to be in
    // the row. A bool still starts on: an added flag that does nothing reads
    // as broken.
    var owned = root.ownedFlags[key]
    if (owned && !(spec && spec.type === "bool")) {
      var fallback = root.builtinDefaults[owned]
      seed = (typeof fallback === "boolean") ? (fallback ? "true" : "false") : String(fallback)
    }
    // An enum must start on one of its own values. The documented default is
    // not always one of them -- it can be absent, or described rather than
    // spelled ("(default: vbr (implicit t4 floor))") -- and seeding a value
    // the dropdown cannot represent leaves the row showing an empty control
    // while the server is launched with something else.
    if (spec && (spec.type === "enum" || spec.type === "tristate") &&
        spec.options.length > 0 && spec.options.indexOf(seed) === -1) {
      seed = spec.options[0]
    }
    root.customParams = root.customParams.concat([{ key: key, value: seed }])
    root.touchTuning()
  }

  function setCustomParam(key, value) {
    var next = []
    for (var i = 0; i < root.customParams.length; i++) {
      var p = root.customParams[i]
      next.push(p.key === key ? { key: p.key, value: String(value), type: p.type } : p)
    }
    root.customParams = next
    root.touchTuning()
  }

  function removeCustomParam(key) {
    var next = []
    for (var i = 0; i < root.customParams.length; i++)
      if (root.customParams[i].key !== key) next.push(root.customParams[i])
    root.customParams = next
    // The control this was driving comes back, and comes back at its default
    // rather than at whatever it held before being taken over: the row is
    // visible again, so what the next launch does has to be readable in it.
    // Checked after the removal -- another added parameter may still own the
    // same property, as --cache-type-k and --cache-type-v each own one.
    var owned = root.ownedFlags[key]
    if (owned && !root.propOverridden(owned)) root[owned] = root.builtinDefaults[owned]
    root.touchTuning()
  }

  function refreshCatalogue() {
    var binary = root.activeBinary
    if (binary === "") { root.paramCatalogue = []; return }
    root.catalogueLoading = true
    // ollama documents its tunables as environment variables under
    // `serve --help`; llama-server lists flags under a bare --help.
    catalogueProc.command = root.backend === "ollama"
      ? ["bash", "-lc", root.shellQuote(binary) + " serve --help 2>&1"]
      : ["bash", "-lc", root.shellQuote(binary) + " --help 2>&1"]
    catalogueProc.running = false
    catalogueProc.running = true
  }

  Process {
    id: catalogueProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.paramCatalogue = Params.parse(root.backend, text)
        root.catalogueLoading = false
      }
    }
  }

  // ---- Runtime state ----

  property bool running: false
  property bool starting: false
  property bool stopping: false
  property bool expectedStop: false
  property string lastError: ""
  property string healthUrl: ""
  property int startingElapsed: 0

  // True when the server was found already listening rather than launched
  // here.
  property bool adopted: false
  property bool ownsUnit: false

  // The distribution's system unit is active and holding the port. It runs as
  // root under its own user, so it can be neither adopted as a process nor
  // stopped unauthenticated -- taking control means stopping it and starting
  // our own in its place.
  property bool systemUnitActive: false
  // Model store the system unit uses, read from its own environment so the
  // path is discovered rather than assumed. A taken-over instance points at
  // it to serve the models already on disk instead of an empty store.
  property string systemModelsDir: ""
  property bool takingOver: false

  // Stopping is ours to do whenever we launched the process; an externally
  // managed one is not.
  readonly property bool canStop: root.running && !(root.adopted && !root.ownsUnit)
  // Takeover is only meaningful when something we do not control is in the way.
  readonly property bool canTakeOver: root.running && root.adopted && !root.ownsUnit &&
                                      root.backendSpec.systemUnit !== undefined

  property bool hasSystemdRun: false
  readonly property string unitName: Backends.unitName(root.moduleName, root.backend)
  readonly property string procMarker: Backends.procMarker(root.moduleName, root.backend)

  // Set once the capability probe has reported, so the backend list and the
  // restart comparison never act on binaries that simply are not known yet.
  property bool capabilitiesProbed: false

  // Backends with a binary on this machine; the only ones the Backend
  // dropdown offers.
  readonly property var installedBackends: Backends.installedBackends({
    llamacpp: root.llamaBinary !== "" || root.altBinary !== "" || root.llamaBuilds.length > 0,
    ollama: root.ollamaBinary !== ""
  }, root.capabilitiesProbed)

  // A saved backend that is not installed here (settings copied from another
  // machine, or ollama since removed) moves to one that is. Never while a
  // server is up -- that server is still the one being watched.
  function ensureInstalledBackend() {
    if (!root.capabilitiesProbed || !root.settingsLoaded) return
    if (root.running || root.starting) return
    var ids = root.installedBackends.map(function(b) { return b.id })
    if (ids.indexOf(root.backend) === -1) root.backend = ids[0]
  }

  // ---- Restart on change ----
  //
  // Model and tuning are launch flags, so applying a change means restarting
  // the server -- nothing runs alongside it. A changed page turns Stop into
  // Restart: it waits until no slot is processing (Force skips the wait),
  // saves the prompt cache, stops the unit, starts it with the new flags and
  // restores the cache. Clients get refused connections while the model
  // loads.
  //
  // With kvPersistence on, the KV cache is saved on stop, on restart and once
  // the server goes idle after a generation, and restored as soon as a start
  // answers /health: re-reading a long prompt is what makes a restart cost
  // minutes, not loading the weights. llama.cpp only.
  property bool kvPersistence: true
  readonly property string slotKvScript: pluginDir + "/slot_kv.py"
  function kvPrefix(model) {
    return Backends.supports(root.backend, "slotKv") ? Backends.slotPrefix(model) : ""
  }

  // argv of the running server, read from /proc -- the only place its launch
  // line survives a shell restart -- and compared with what the page would
  // launch now.
  property var runningArgs: []
  // Resolved path of the running binary, so a change of build restarts too --
  // argv[0] is the process marker, not the binary.
  property string runningExe: ""
  // "draining" while a restart waits for running requests, "" otherwise.
  property string restartPhase: ""
  property int restartIdleTicks: 0
  // Set by a restart so the stop it goes through starts the server again.
  property bool restartAfterStop: false
  property bool slotsBusy: false
  property int slotsProcessing: 0
  property real slotsSeenAtMs: 0
  readonly property bool switching: root.running && root.restartPhase !== ""
  readonly property string switchPhase: root.switching ? root.restartPhase : ""
  // Waits for everything the argv depends on to be detected -- otherwise an
  // adopted server reads as changed until the hardware probe lands.
  readonly property bool configChanged: root.running && root.ownsUnit && !root.switching &&
    root.backend === "llamacpp" && root.runningArgs.length > 1 &&
    root.capabilitiesProbed && root.buildsProbed && root.hardware !== null &&
    root.settingsLoaded && !root.catalogueLoading &&
    (JSON.stringify(root.buildLlamaArgs().slice(1)) !== JSON.stringify(root.runningArgs.slice(1)) ||
     (root.runningExe !== "" && root.resolvedBuild !== null && root.resolvedBuild.real !== root.runningExe))

  // ---- Metrics ----

  property real tokensPerSec: 0
  property real ppPercent: 0
  property real ppTokensPerSec: 0
  // Set once a logged ingestion progress line arrives for the current prompt,
  // cleared when that prompt finishes. While set, the /slots poll leaves pp
  // numbers alone: the log's are measured, the poll's are derived from a
  // counter that sits still for a whole batch. A time window used to decide
  // this, but at ubatch 2048 a batch takes longer than the window, so the
  // bar fell back to a rateless poll percentage between log lines.
  property bool ppFromLog: false
  property bool ppActive: false
  property var lastDecodeSample: null
  property var lastPromptSample: null
  property bool showMetric: true
  property string loadedModelInfo: ""

  property string lastLogLine: ""
  property var logLines: []
  readonly property int logLinesMax: 400
  // "" not attached yet | "user" transient unit | "system" distribution unit |
  // "none" foreign server whose output no journal holds.
  property string logsSource: ""
  property bool showingLogs: false

  property int currentPage: 0
  readonly property var pageNames: ["Server", "Model", "Tuning", "Stats"]

  // ---- First-run setup ----
  //
  // A fresh install has no settings file, and auto-detection alone leaves a
  // new user with nothing but an error line when it guesses wrong or finds
  // nothing. Setup walks through the three things that decide whether a first
  // start works: a backend binary, where the models are, and starting tuning.
  // Binary and models choices go to the widget's shell.json entry via
  // `omarchy bar set` -- the same place a user would edit them by hand -- so
  // setup never becomes a second, competing source of configuration.
  property bool setupDone: false
  property int setupStep: 0
  readonly property var setupSteps: ["Backend", "Models", "Tuning"]
  property string setupTuning: "recommended"
  // .gguf count per candidate directory, filled when the Models step opens.
  property var modelDirCounts: ({})
  // Waits for detection so the first step never flashes "not installed" for
  // a binary the probe simply has not reported yet.
  readonly property bool showingSetup: root.settingsLoaded && root.capabilitiesProbed && !root.setupDone

  // Tuning sub-pagination. Page 0 carries the built-in controls; added
  // parameters flow onto further pages so the section never scrolls.
  //
  // The per-page count is deliberately small: a page must stay short enough
  // that a row's enum dropdown can open downward without running off the
  // panel, which is what silently clipped popups placed low on a page.
  property int tuningPage: 0
  // True while the parameter search replaces the add button. Lives on the
  // root: a bare identifier resolves against the object itself and the file's
  // root component, not against intermediate ancestors, so declaring this on
  // a nested item leaves it undefined at the point of use.
  property bool addParamOpen: false
  // Row slots a tuning page can show without the section needing to scroll.
  //
  // Seven is the default set of built-in rows -- cache k/v, flash attn, GPU
  // layers, MoE, context, threads, batch -- counted exactly, on the
  // assumption that a full page clears the panel's shared chrome. That
  // assumption held only as long as the panel's contentHeight did: at the old
  // 460 the seventh row rendered under the "Show log" button, so the row that
  // exists and holds a value the next launch uses was the one you could not
  // read, and the cap was dropped to five to compensate. The panel is 520 now
  // (see contentHeight above), so the built-in set fits on one page again
  // without borrowing that headroom from the row cap.
  //
  // It stays capped for the original reason: a row's enum dropdown opens
  // downward with no flip-up fallback, so a page deep enough to push one near
  // the bottom edge is a page whose popup is clipped.
  readonly property int tuningRowCapacity: 7

  // Built-in control rows on the first page. Both backend- and user-dependent:
  // ollama exposes only context and KV cache where llama.cpp adds threads,
  // GPU layers, batch sizes and MoE offload, and any of those rows can be
  // removed -- so the space left over for added parameters has to be counted
  // from what is actually on the page, not assumed.
  // Every row the page shows, in order, chunked into sub-pages.
  //
  // Built-in controls used to be pinned to the first page and only added
  // parameters flowed onto further ones, on the assumption that the built-ins
  // always fit. They no longer do: the optional rows can put five more on the
  // page, and two of them arrive on their own when a model brings a projector
  // or a draft type. Past the capacity the surplus ran off the bottom of the
  // panel -- rows that exist, hold values the next launch uses, and cannot be
  // seen or reached.
  //
  // So one list of rows, one chunker, and a tab whenever it does not fit. A
  // row is never split across pages: the projector's path field belongs with
  // the mode that reveals it, so that row takes two slots and moves as one.
  readonly property var tuningPages: {
    var slots = []
    var i

    for (i = 0; i < root.builtinRows.length; i++) {
      var row = root.builtinRows[i]
      if (!root.builtinVisible(row.id)) continue
      var weight = (row.id === "vision" && root.mmprojMode === "custom") ? 2 : 1
      slots.push({ kind: "builtin", id: row.id, param: null, weight: weight })
    }
    for (i = 0; i < root.customParams.length; i++)
      slots.push({ kind: "param", id: root.customParams[i].key, param: root.customParams[i], weight: 1 })

    // The unsplit-arguments note sits under the rows on the first page.
    var firstPageReserved = (String(root.extraArgs).trim() !== "" && root.paramCatalogue.length > 0) ? 1 : 0
    return Model.paginateRows(slots, root.tuningRowCapacity, firstPageReserved)
  }

  readonly property int tuningPageCount: root.tuningPages.length
  readonly property var tuningPageLabels: {
    var out = []
    for (var i = 0; i < root.tuningPageCount; i++) out.push(String(i + 1))
    return out
  }

  // The sub-page actually shown, clamped to what exists.
  //
  // Derived rather than corrected after the fact: removing the last parameter
  // on a page leaves tuningPage pointing past the end, and an imperative clamp
  // fixes the tab strip while the content is read from the stale value -- so
  // the tab highlights correctly and the page renders empty. Clamping once,
  // here, means every reader sees the same valid page.
  readonly property int effectiveTuningPage: Math.max(0, Math.min(root.tuningPage, root.tuningPageCount - 1))

  // Whether a built-in row is both shown and on the page being looked at.
  // Every built-in control's `visible` reads this rather than builtinVisible,
  // which answers only the first half.
  function builtinOnPage(id) {
    var page = root.tuningPages[root.effectiveTuningPage] || []
    for (var i = 0; i < page.length; i++)
      if (page[i].kind === "builtin" && page[i].id === id) return true
    return false
  }

  // Whether the page being looked at carries any built-in row at all.
  //
  // A page made entirely of added parameters -- the common case once the
  // built-ins fill their own page and later ones hold nothing but custom
  // params -- leaves every row in the built-ins grid hidden. GridLayout does
  // not collapse to zero height in that all-hidden case the way a single
  // hidden item does; it keeps a nonzero size hint, so the grid still eats
  // room above the added-parameter rows and shoves them down the page. The
  // grid is hidden outright instead of leaving that to its children.
  readonly property bool tuningPageHasBuiltins: {
    var page = root.tuningPages[root.effectiveTuningPage] || []
    for (var i = 0; i < page.length; i++)
      if (page[i].kind === "builtin") return true
    return false
  }

  // The page a row is on, so adding one can land the user where it went.
  function tuningPageOfBuiltin(id) {
    for (var p = 0; p < root.tuningPages.length; p++) {
      var page = root.tuningPages[p]
      for (var i = 0; i < page.length; i++)
        if (page[i].kind === "builtin" && page[i].id === id) return p
    }
    return 0
  }

  function tuningPageOfParam(key) {
    for (var p = 0; p < root.tuningPages.length; p++) {
      var page = root.tuningPages[p]
      for (var i = 0; i < page.length; i++)
        if (page[i].kind === "param" && page[i].id === key) return p
    }
    return 0
  }

  function customParamsForPage(page) {
    var slots = root.tuningPages[page] || []
    var out = []
    for (var i = 0; i < slots.length; i++)
      if (slots[i].kind === "param") out.push(slots[i].param)
    return out
  }

  // PanelKeyCatcher swallows every key before a focused child sees it unless
  // told otherwise, which would make the text fields unconfirmable.
  readonly property bool editingField: {
    var f = Window.activeFocusItem
    return f !== null && f !== undefined && typeof f.cursorPosition === "number"
  }

  // Numeric field that also accepts the numpad.
  //
  // Numpad digits arrive as navigation keys -- KP_1 as End, KP_2 as Down, KP_0
  // as Insert -- carrying no text, whenever the keyboard state handed to this
  // surface has NumLock cleared while the key itself is NumLock-on. That is
  // what makes toggling NumLock off and back on "fix" typing here: the toggle
  // resyncs the modifier state the panel was given.
  //
  // The translation lives on the field rather than on a common ancestor: key
  // delivery starts at the focused item, and an ancestor only ever sees what
  // that item did not accept -- a single-line TextInput swallows Home/End/
  // Left/Right and passes Up/Down through, so a panel-level handler catches
  // some keypad digits and never sees the rest.
  //
  // DEBUG: every key reaching a numeric field is logged while the numpad
  // behaviour is being diagnosed. Remove once confirmed.
  component NumField: TextField {
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      console.log("[local-ai-server] key=" + event.key +
                  " text=" + JSON.stringify(event.text) +
                  " mods=" + event.modifiers +
                  " keypad=" + ((event.modifiers & Qt.KeypadModifier) ? 1 : 0))
      if (event.text && event.text.length > 0) return
      var digit = ""
      switch (event.key) {
        case Qt.Key_Insert:   digit = "0"; break
        case Qt.Key_End:      digit = "1"; break
        case Qt.Key_Down:     digit = "2"; break
        case Qt.Key_PageDown: digit = "3"; break
        case Qt.Key_Left:     digit = "4"; break
        case Qt.Key_Clear:    digit = "5"; break
        case Qt.Key_Right:    digit = "6"; break
        case Qt.Key_Home:     digit = "7"; break
        case Qt.Key_Up:       digit = "8"; break
        case Qt.Key_PageUp:   digit = "9"; break
      }
      if (digit === "") return
      // Only a keypad-flagged event becomes a digit: the same keys pressed on
      // the main block are real cursor moves and must stay that way.
      if (!(event.modifiers & Qt.KeypadModifier)) return
      insert(cursorPosition, digit)
      event.accepted = true
    }
  }

  function expandPath(p) {
    var s = String(p || "")
    if (s.indexOf("~") === 0) return Quickshell.env("HOME") + s.slice(1)
    return s
  }

  function shellQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  // ---- Per-model tuning profiles ----
  //
  // Everything on the Tuning page is stored per model. A profile is created
  // the first time that model's tuning is edited, so a model that is only ever
  // picked and started never gets one and runs on defaultTuning -- the set a
  // new profile is seeded from.
  //
  // The live properties above stay the single source of truth for a launch:
  // selecting a model writes its profile onto them, and editing them writes
  // back. Nothing reads a profile at launch time, so there is no second path
  // the launch line could come from.
  property var profiles: ({})
  property var defaultTuning: ({})

  // Set while a profile is being written onto the live properties. Every
  // change handler fires during that, and without the guard the apply would be
  // read as an edit -- creating a profile for a model merely selected, and
  // capturing the outgoing model's values into it.
  property bool applyingTuning: false

  // The picker, with the models carrying their own tuning marked.
  //
  // Which models have been tuned is otherwise invisible from the page where
  // models are chosen, and switching to one silently changes every value on
  // Tuning -- so the switch has to be announced before it is made, not
  // discovered afterwards.
  readonly property var modelOptionsWithProfile: {
    var out = []
    for (var i = 0; i < root.modelOptions.length; i++) {
      var opt = root.modelOptions[i]
      if (!Profiles.has(root.profiles, root.backend, opt.value)) { out.push(opt); continue }
      var marked = {}
      for (var k in opt) marked[k] = opt[k]
      marked.description = (opt.description ? opt.description + " · " : "") + "tuned"
      out.push(marked)
    }
    return out
  }

  readonly property bool hasProfile: Profiles.has(root.profiles, root.backend, root.selectedModel)

  // A user edit to any tuning value: stores it against the selected model,
  // creating that model's profile if this is its first.
  //
  // With no model selected there is nothing to key on, so the edit lands in
  // defaultTuning and becomes the seed for the next model that gets one.
  function touchTuning() {
    if (!root.settingsLoaded || root.applyingTuning) return
    var values = Profiles.snapshot(root)
    if (root.selectedModel !== "")
      root.profiles = Profiles.set(root.profiles, root.backend, root.selectedModel, values)
    else
      root.defaultTuning = Profiles.setDefaults(root.defaultTuning, root.backend, values)
    root.scheduleSettingsSave()
  }

  function applyTuning(values) {
    var resolved = Profiles.resolve(values)
    root.applyingTuning = true
    try {
      for (var i = 0; i < Profiles.FIELDS.length; i++) {
        var f = Profiles.FIELDS[i]
        root[f] = resolved[f]
      }
      root.hiddenBuiltins = resolved.hiddenBuiltins
      root.shownOptionals = resolved.shownOptionals
      root.builtinStash = resolved.builtinStash
      root.customParams = resolved.customParams
      // A page that no longer has the sub-tab the previous model's parameters
      // reached would otherwise render blank.
      root.tuningPage = 0
      root.addParamOpen = false
      // A profile can name a cache type this binary cannot honour -- it may
      // have been tuned while the alternate binary was configured, or copied
      // from another machine.
      root.sanitizeSettings()
    } finally {
      root.applyingTuning = false
    }
  }

  // Called when the selection changes, including when the model scan replaces
  // a selection that no longer exists.
  function applyTuningForSelection() {
    if (!root.settingsLoaded || root.applyingTuning) return
    var profile = Profiles.get(root.profiles, root.backend, root.selectedModel)
    root.applyTuning(profile !== null ? profile : Profiles.defaultsFor(root.defaultTuning, root.backend))
    // A profile written before arguments were split still carries a line.
    root.splitPastedArgs()
  }

  // Drops this model's profile and puts it back on the shared defaults. The
  // next edit starts a fresh profile from them.
  function clearProfile() {
    if (!root.hasProfile) return
    root.profiles = Profiles.remove(root.profiles, root.backend, root.selectedModel)
    root.applyTuning(Profiles.defaultsFor(root.defaultTuning, root.backend))
    root.scheduleSettingsSave()
  }

  // Makes the values on screen the seed for models that have no profile yet.
  // Leaves existing profiles alone -- they were tuned deliberately.
  function saveAsDefaultTuning() {
    root.defaultTuning = Profiles.setDefaults(root.defaultTuning, root.backend, Profiles.snapshot(root))
    root.scheduleSettingsSave()
  }

  // ---- Settings persistence ----
  // Plain properties survive a hot-reload (Quickshell patches this object in
  // place) but not a real restart, so config is mirrored to disk.
  readonly property string settingsDir: expandPath("~/.local/state/omarchy/sxy.local-ai-server/")
  readonly property string settingsPath: settingsDir + "settings.json"
  property bool settingsLoaded: false

  readonly property string slotSaveDir: settingsDir + "slots/"

  // The model the running server actually loaded, captured at launch.
  //
  // Kept separate from selectedModel so the picker stays usable while a server
  // is up: a new selection is queued for the next start, and KV-cache saves
  // keep keying on what is really loaded. Without this, changing the selection
  // mid-run would autosave the live cache under the newly picked model's name,
  // which the next launch would then restore into a mismatched model.
  property string runningModel: ""

  function loadSettings(raw) {
    if (root.settingsLoaded) return
    var parsed = null
    try { parsed = JSON.parse(raw || "") } catch (e) { parsed = null }
    if (parsed && typeof parsed === "object") {
      if (typeof parsed.backend === "string" && Backends.ids().indexOf(parsed.backend) !== -1) root.backend = parsed.backend
      // A file without the flag was written before setup existed, by an
      // install that is configured already.
      root.setupDone = typeof parsed.setupDone === "boolean" ? parsed.setupDone : true
      if (typeof parsed.host === "string") root.host = parsed.host
      // Per-backend ports; a file written by an older version carries a
      // single "port" string, which belonged to whichever backend was active
      // when it was saved.
      if (parsed.backendPorts && typeof parsed.backendPorts === "object") {
        var ports = {}
        for (var bk in parsed.backendPorts) ports[bk] = String(parsed.backendPorts[bk])
        root.backendPorts = ports
      } else if (typeof parsed.port === "string" && parsed.port !== "") {
        var seeded = {}
        seeded[root.backend] = parsed.port
        root.backendPorts = seeded
      }
      if (typeof parsed.gpuLayers === "string") root.gpuLayers = parsed.gpuLayers
      if (typeof parsed.contextSize === "string") root.contextSize = parsed.contextSize
      if (typeof parsed.batchSize === "string") root.batchSize = parsed.batchSize
      if (typeof parsed.ubatchSize === "string") root.ubatchSize = parsed.ubatchSize
      if (typeof parsed.threads === "string") root.threads = parsed.threads
      if (typeof parsed.cacheTypeK === "string") root.cacheTypeK = parsed.cacheTypeK
      if (typeof parsed.cacheTypeV === "string") root.cacheTypeV = parsed.cacheTypeV
      if (typeof parsed.cacheRam === "string") root.cacheRam = parsed.cacheRam
      if (typeof parsed.temperature === "string") root.temperature = parsed.temperature
      if (typeof parsed.cpuMoe === "boolean") root.cpuMoe = parsed.cpuMoe
      if (typeof parsed.nCpuMoe === "string") root.nCpuMoe = parsed.nCpuMoe
      if (typeof parsed.noRepack === "boolean") root.noRepack = parsed.noRepack
      if (typeof parsed.mmapEnabled === "boolean") root.loadMode = parsed.mmapEnabled ? "mmap" : "none"
      if (typeof parsed.loadMode === "string" && root.loadModeValues.indexOf(parsed.loadMode) !== -1) root.loadMode = parsed.loadMode
      if (typeof parsed.flashAttn === "string") root.flashAttn = parsed.flashAttn
      if (typeof parsed.specType === "string") root.specType = parsed.specType
      if (typeof parsed.specTypeUserSet === "boolean") root.specTypeUserSet = parsed.specTypeUserSet
      if (typeof parsed.parallel === "string") root.parallel = parsed.parallel
      if (typeof parsed.reasoningPreserve === "string" && root.tristateValues.indexOf(parsed.reasoningPreserve) !== -1)
        root.reasoningPreserve = parsed.reasoningPreserve
      if (typeof parsed.mmprojMode === "string" && root.mmprojModes.indexOf(parsed.mmprojMode) !== -1)
        root.mmprojMode = parsed.mmprojMode
      if (typeof parsed.mmprojPath === "string") root.mmprojPath = parsed.mmprojPath
      if (typeof parsed.mmprojOffload === "string" && root.tristateValues.indexOf(parsed.mmprojOffload) !== -1)
        root.mmprojOffload = parsed.mmprojOffload
      if (typeof parsed.selectedModel === "string") root.selectedModel = parsed.selectedModel
      if (typeof parsed.showMetric === "boolean") root.showMetric = parsed.showMetric
      if (typeof parsed.extraArgs === "string") root.extraArgs = parsed.extraArgs
      if (typeof parsed.extraEnv === "string") root.extraEnv = parsed.extraEnv
      if (typeof parsed.llamaBuild === "string") root.llamaBuild = parsed.llamaBuild
      if (typeof parsed.keepAlive === "string") root.keepAlive = parsed.keepAlive
      if (typeof parsed.surviveRestart === "boolean") root.surviveRestart = parsed.surviveRestart
      if (typeof parsed.kvPersistence === "boolean") root.kvPersistence = parsed.kvPersistence
      // Removed built-in rows, and what they held when removed. Filtered to
      // ids this build knows: a row renamed or dropped between versions would
      // otherwise stay hidden with nothing able to bring it back.
      if (Array.isArray(parsed.hiddenBuiltins)) {
        var hidden = []
        for (var h = 0; h < parsed.hiddenBuiltins.length; h++) {
          var id = parsed.hiddenBuiltins[h]
          if (typeof id === "string" && root.builtinRowSpec(id) && hidden.indexOf(id) === -1)
            hidden.push(id)
        }
        root.hiddenBuiltins = hidden
      }
      if (Array.isArray(parsed.shownOptionals)) {
        var shown = []
        for (var o = 0; o < parsed.shownOptionals.length; o++) {
          var optId = parsed.shownOptionals[o]
          var optRow = typeof optId === "string" ? root.builtinRowSpec(optId) : null
          if (optRow && optRow.optional && shown.indexOf(optId) === -1) shown.push(optId)
        }
        root.shownOptionals = shown
      }
      if (parsed.builtinStash && typeof parsed.builtinStash === "object") {
        var stash = {}
        for (var sk in parsed.builtinStash)
          if (root.builtinDefaults[sk] !== undefined) stash[sk] = parsed.builtinStash[sk]
        root.builtinStash = stash
      }
      // Stored as an ordered list rather than an object so the page renders
      // parameters in the order they were added.
      if (Array.isArray(parsed.customParams)) {
        var restored = []
        for (var i = 0; i < parsed.customParams.length; i++) {
          var entry = parsed.customParams[i]
          if (entry && typeof entry.key === "string") {
            var kept = { key: entry.key, value: String(entry.value === undefined ? "" : entry.value) }
            if (typeof entry.type === "string") kept.type = entry.type
            restored.push(kept)
          }
        }
        root.customParams = restored
      }
    }
    // Profiles are read after the flat values, which double as the migration
    // source: a settings file written before profiles existed carries one
    // tuning set, and it belongs to the model that file names.
    var restoredProfiles = Profiles.fromSettings(parsed, Profiles.snapshot(root))
    root.profiles = restoredProfiles.profiles
    root.defaultTuning = restoredProfiles.defaultTuning

    root.sanitizeSettings()
    root.settingsLoaded = true
    // The flat values on disk are the ones last live, which for a model with a
    // profile is that profile -- but not for a file hand-edited to name a
    // different model, so the selection has the last word.
    root.applyTuningForSelection()
    root.ensureInstalledBackend()
    root.adoptRunningServer()
  }

  // Drops values the current configuration cannot actually honour.
  //
  // Settings migrated from an older install (or copied between machines) can
  // name cache types only an alternate binary understands. Left in place they
  // fail at launch rather than at load: stock llama-server rejects the flag
  // and exits, which surfaces as a server that simply never starts. Falling
  // back to f16 keeps the plugin launchable, and the alternate binary setting
  // restores the original choice.
  function sanitizeSettings() {
    // A cache type may belong to a build the probe has not reported yet;
    // judged too early, a working fork-only choice would be thrown away.
    if (root.backend === "llamacpp" && !root.buildsProbed) return
    var available = root.availableCacheTypes
    var dropped = []
    if (available.indexOf(root.cacheTypeK) === -1) {
      dropped.push(root.cacheTypeK)
      root.cacheTypeK = "f16"
    }
    if (available.indexOf(root.cacheTypeV) === -1) {
      if (dropped.indexOf(root.cacheTypeV) === -1) dropped.push(root.cacheTypeV)
      root.cacheTypeV = "f16"
    }
    if (dropped.length > 0) {
      root.lastError = "Cache type " + dropped.join("/") + (root.llamaBuilds.length > 0
        ? " is not supported by " + (root.llamaBuild !== "" ? Backends.buildLabel(root.resolvedBuild) : "any detected build")
        : " needs a llama.cpp build that supports it") + " — reset to f16."
    }
  }

  function flushSettings() {
    settingsFile.setText(JSON.stringify({
      version: 3,
      setupDone: root.setupDone,
      backend: root.backend,
      host: root.host, backendPorts: root.backendPorts,
      gpuLayers: root.gpuLayers, threads: root.threads,
      contextSize: root.contextSize, batchSize: root.batchSize, ubatchSize: root.ubatchSize,
      cacheTypeK: root.cacheTypeK, cacheTypeV: root.cacheTypeV,
      cacheRam: root.cacheRam, temperature: root.temperature,
      cpuMoe: root.cpuMoe, nCpuMoe: root.nCpuMoe, noRepack: root.noRepack,
      loadMode: root.loadMode, flashAttn: root.flashAttn,
      specType: root.specType, specTypeUserSet: root.specTypeUserSet,
      parallel: root.parallel, reasoningPreserve: root.reasoningPreserve,
      mmprojMode: root.mmprojMode, mmprojPath: root.mmprojPath,
      mmprojOffload: root.mmprojOffload,
      selectedModel: root.selectedModel, showMetric: root.showMetric,
      extraArgs: root.extraArgs, keepAlive: root.keepAlive, extraEnv: root.extraEnv,
      llamaBuild: root.llamaBuild,
      surviveRestart: root.surviveRestart,
      kvPersistence: root.kvPersistence,
      hiddenBuiltins: root.hiddenBuiltins, shownOptionals: root.shownOptionals,
      builtinStash: root.builtinStash,
      customParams: root.customParams,
      // The tuning above is also what the selected model's profile holds; it
      // is written flat as well so a build without profiles still reads the
      // values the user last had live.
      profiles: root.profiles, defaultTuning: root.defaultTuning
    }, null, 2) + "\n")
  }

  // Applies the values derived from this machine's actual hardware, replacing
  // whatever was tuned for another one. Leaves host/port/model alone -- those
  // are environment choices, not tuning.
  function resetToDetectedDefaults() {
    var s = root.suggestions || Hardware.suggestAll(root.hardware || {})
    root.gpuLayers = String(s.gpuLayers)
    root.threads = String(s.threads)
    root.contextSize = String(s.contextSize)
    root.batchSize = String(s.batchSize)
    root.ubatchSize = String(s.ubatchSize)
    root.cacheTypeK = "f16"
    root.cacheTypeV = "f16"
    root.cacheRam = ""
    root.temperature = ""
    root.cpuMoe = false
    root.nCpuMoe = ""
    root.noRepack = false
    root.loadMode = "auto"
    root.flashAttn = "auto"
    root.specType = "none"
    root.specTypeUserSet = false
    root.extraArgs = ""
    root.extraEnv = ""
    // Every row comes back: these values have to be visible to be edited, and
    // writing a detected context into a row the user cannot see is the same
    // invisible state removing a row is careful to avoid.
    root.parallel = ""
    root.reasoningPreserve = "default"
    root.mmprojMode = "auto"
    root.mmprojPath = ""
    root.mmprojOffload = "off"
    root.hiddenBuiltins = []
    root.shownOptionals = []
    root.builtinStash = ({})
    // With a model selected these values are that model's, so they land in its
    // profile like any other edit -- "detected defaults" describes the
    // machine, but what fits on it depends on the model being loaded.
    root.touchTuning()
    root.flushSettings()
  }

  function scheduleSettingsSave() {
    if (!root.settingsLoaded) return
    settingsSaveTimer.restart()
  }

  onBackendChanged: {
    root.selectedModel = ""
    root.modelOptions = []
    // Parameters are backend-specific: llama.cpp flags mean nothing to ollama
    // and vice versa, so both the catalogue and the user's additions reset --
    // as does the rest of the tuning, which comes back from this backend's own
    // defaults rather than carrying the other backend's numbers across.
    root.applyTuning(Profiles.defaultsFor(root.defaultTuning, root.backend))
    root.paramCatalogue = []
    // An open picker would sit there listing the previous backend's flags
    // until the new catalogue arrived.
    root.addParamOpen = false
    root.scheduleSettingsSave()
    root.refreshModels()
    root.refreshCatalogue()
    root.adoptRunningServer()
  }

  // The catalogue describes one specific binary, so it is rebuilt whenever the
  // resolved binary changes -- including when detection finishes and fills it
  // in for the first time.
  onActiveBinaryChanged: root.refreshCatalogue()
  onHostChanged: root.scheduleSettingsSave()
  onBackendPortsChanged: root.scheduleSettingsSave()
  onGpuLayersChanged: root.touchTuning()
  onThreadsChanged: root.touchTuning()
  onContextSizeChanged: root.touchTuning()
  onBatchSizeChanged: root.touchTuning()
  onUbatchSizeChanged: root.touchTuning()
  onCacheTypeKChanged: {
    // One-directional K -> V pairing for the alternate binary's tiers, so it
    // cannot loop with the V handler; a manual V change afterwards sticks.
    //
    // Not while a profile is being applied: the pairing would overwrite the V
    // the profile actually stores, so a deliberately mismatched pair would not
    // survive being reselected.
    if (!root.applyingTuning) {
      var recommended = Model.recommendedCacheTypeV(root.cacheTypeK)
      if (recommended && root.cacheTypeV !== recommended) root.cacheTypeV = recommended
    }
    root.touchTuning()
  }
  onCacheTypeVChanged: root.touchTuning()
  onLlamaBuildChanged: {
    // A build picked by hand may not take the cache types the model had;
    // fall back rather than launch into a flag the binary rejects.
    if (!root.applyingTuning) root.sanitizeSettings()
    root.touchTuning()
  }
  onCacheRamChanged: root.touchTuning()
  onTemperatureChanged: root.touchTuning()
  onCpuMoeChanged: root.touchTuning()
  onNCpuMoeChanged: root.touchTuning()
  onNoRepackChanged: root.touchTuning()
  onLoadModeChanged: root.touchTuning()
  onFlashAttnChanged: root.touchTuning()
  onSpecTypeChanged: root.touchTuning()
  onSpecTypeUserSetChanged: root.touchTuning()
  onParallelChanged: root.touchTuning()
  onReasoningPreserveChanged: root.touchTuning()
  onMmprojModeChanged: root.touchTuning()
  onMmprojPathChanged: root.touchTuning()
  onMmprojOffloadChanged: root.touchTuning()
  onSelectedModelChanged: {
    root.applyTuningForSelection()
    root.scheduleSettingsSave()
  }
  onShowMetricChanged: root.scheduleSettingsSave()
  onExtraArgsChanged: {
    root.touchTuning()
    root.splitPastedArgs()
  }
  // The catalogue is what makes splitting reliable, so anything left waiting
  // for it is split the moment it lands.
  onParamCatalogueChanged: root.splitPastedArgs()
  onKeepAliveChanged: root.touchTuning()
  onExtraEnvChanged: root.touchTuning()
  onSurviveRestartChanged: root.scheduleSettingsSave()
  onKvPersistenceChanged: root.scheduleSettingsSave()

  Process {
    id: ensureSettingsDirProc
    command: ["mkdir", "-p", root.settingsDir]
    onExited: settingsFile.reload()
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadSettings(text())
    // First run: without this, settingsLoaded never flips and every save is
    // silently skipped.
    onLoadFailed: root.loadSettings("")
  }

  Timer {
    id: settingsSaveTimer
    interval: 200
    repeat: false
    onTriggered: root.flushSettings()
  }

  Component.onCompleted: {
    ensureSettingsDirProc.running = true
    hwProbe.running = true
    capabilityProbe.running = true
  }

  // ---- First-run setup actions ----

  // Writes one of this widget's manifest settings into shell.json. The bar
  // applies the change to the live widget in place, so setting() -- and every
  // binding on it -- updates without the panel closing.
  function setWidgetSetting(key, value) {
    Quickshell.execDetached(["omarchy-bar", "set", root.moduleName, key, String(value)])
  }

  function startSetup() {
    root.setupStep = 0
    root.setupDone = false
    root.showingLogs = false
  }

  function setupGoTo(step) {
    root.setupStep = Math.max(0, Math.min(root.setupSteps.length - 1, step))
  }

  function finishSetup() {
    if (root.setupTuning === "recommended") root.resetToDetectedDefaults()
    root.setupDone = true
    root.currentPage = 1
    root.scheduleSettingsSave()
  }

  function skipSetup() {
    root.setupDone = true
    root.scheduleSettingsSave()
  }

  function setupBinaryKey() {
    return root.backend === "ollama" ? "ollamaBinary" : "binary"
  }

  // A typed folder is created if missing: pointing setup at the folder you
  // intend to download into is the common case on a machine with no models.
  function useModelsDir(path) {
    var dir = String(path || "").trim()
    if (dir !== "") Quickshell.execDetached(["mkdir", "-p", expandPath(dir)])
    root.setWidgetSetting("modelsDir", dir)
  }

  readonly property var setupModelDirs: {
    var dirs = root.detectedModelDirs.slice()
    var configured = root.configuredModelsDir !== "" ? expandPath(root.configuredModelsDir) : ""
    if (configured !== "" && dirs.indexOf(configured) === -1) dirs.unshift(configured)
    return dirs
  }

  function countModelDirs() {
    if (modelDirCountProbe.running || root.setupModelDirs.length === 0) return
    modelDirCountProbe.command = ["bash", "-c",
      "for d in \"$@\"; do n=$(find -L \"$d\" -maxdepth 6 -type f -iname '*.gguf' 2>/dev/null | wc -l); " +
      "printf '%s\\t%s\\n' \"$n\" \"$d\"; done", "_"].concat(root.setupModelDirs)
    modelDirCountProbe.running = true
  }

  Process {
    id: modelDirCountProbe
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var counts = {}
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var tab = lines[i].indexOf("\t")
          if (tab > 0) counts[lines[i].slice(tab + 1)] = parseInt(lines[i].slice(0, tab), 10) || 0
        }
        root.modelDirCounts = counts
      }
    }
  }

  // Counted whenever setup is on screen, not only on reaching its Models
  // step, so the numbers are there by the time it is.
  onShowingSetupChanged: if (root.showingSetup) root.countModelDirs()
  onSetupModelDirsChanged: if (root.showingSetup) root.countModelDirs()

  // A models folder chosen in setup (or edited in shell.json) lands through
  // settings, not through a call here, so the list follows it.
  onConfiguredModelsDirChanged: if (root.capabilitiesProbed) root.refreshModels()

  // ---- Scripting ----
  //
  // The panel's own open/close/toggle live on the base Panel's handler (target
  // "sxy.local-ai-server"); server control gets its own target so keybindings
  // and scripts can drive it without the panel open:
  //   qs -p /usr/share/omarchy/shell ipc call local-ai-server status
  IpcHandler {
    target: "local-ai-server"

    function start(): void { if (!root.running && !root.starting && !root.stopping) root.startServer() }
    function stop(): void { if ((root.running || root.starting) && !root.stopping) root.stopServer() }
    // Applies a changed model or tuning the same way the Restart button does;
    // called again while it waits for running requests, it forces (Force).
    function restart(): void {
      if (root.switching) root.forceSwitch()
      else if (root.configChanged) root.switchServer()
    }
    function model(path: string): void { root.selectModel(path) }
    function page(name: string): void {
      var i = root.pageNames.map(function(n) { return n.toLowerCase() }).indexOf(String(name).toLowerCase())
      if (i === -1) return
      root.currentPage = i
      root.showingLogs = false
      root.open()
    }
    function setup(): void { root.startSetup(); root.open() }
    function status(): string {
      return JSON.stringify({
        running: root.running, starting: root.starting, stopping: root.stopping,
        restarting: root.switching, changesPending: root.configChanged,
        backend: root.backend, model: root.runningModel, selected: root.selectedModel,
        build: root.backend === "llamacpp" ? Backends.buildLabel(root.resolvedBuild) : "",
        endpoint: root.host + ":" + root.port,
        pp: root.ppTokensPerSec, tg: root.tokensPerSec
      })
    }
  }

  // ---- Environment detection ----

  // One shell round-trip resolving everything environment-dependent: whether
  // systemd-run exists, and the first binary and model directory that are
  // actually present. Emitted as key=value lines rather than JSON to keep the
  // script inline and dependency-free.
  Process {
    id: capabilityProbe
    command: ["bash", "-lc",
      "command -v systemd-run >/dev/null 2>&1 && echo 'systemd=1' || echo 'systemd=0'; " +
      "for b in " + Backends.llamaBinaryCandidates(Quickshell.env("HOME")).map(root.shellQuote).join(" ") + "; do " +
      "  [ -x \"$b\" ] && { echo \"llama=$b\"; break; }; done; " +
      "command -v llama-server >/dev/null 2>&1 && echo \"llamapath=$(command -v llama-server)\"; " +
      "for b in " + Backends.ollamaBinaryCandidates(Quickshell.env("HOME")).map(root.shellQuote).join(" ") + "; do " +
      "  [ -x \"$b\" ] && { echo \"ollama=$b\"; break; }; done; " +
      "command -v ollama >/dev/null 2>&1 && echo \"ollamapath=$(command -v ollama)\"; " +
      "for d in " + Backends.ggufSearchDirs(Quickshell.env("HOME")).map(root.shellQuote).join(" ") + "; do " +
      "  [ -d \"$d\" ] && echo \"dir=$d\"; done"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var dirs = []
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i].trim()
          var eq = line.indexOf("=")
          if (eq < 0) continue
          var key = line.slice(0, eq)
          var value = line.slice(eq + 1)
          if (key === "systemd") root.hasSystemdRun = value === "1"
          else if (key === "llama" && root.detectedLlamaBinary === "") root.detectedLlamaBinary = value
          else if (key === "llamapath" && root.detectedLlamaBinary === "") root.detectedLlamaBinary = value
          else if (key === "ollama" && root.detectedOllamaBinary === "") root.detectedOllamaBinary = value
          else if (key === "ollamapath" && root.detectedOllamaBinary === "") root.detectedOllamaBinary = value
          else if (key === "dir") dirs.push(value)
        }
        root.detectedModelDirs = dirs
        root.capabilitiesProbed = true
        root.ensureInstalledBackend()
        root.refreshModels()
        root.probeBuilds()
      }
    }
  }

  // Configured binaries go first, so auto prefers the build the user named.
  function probeBuilds() {
    if (buildsProbe.running) return
    var extra = []
    if (root.configuredLlamaBinary !== "") extra.push(expandPath(root.configuredLlamaBinary))
    if (root.altBinary !== "") extra.push(expandPath(root.altBinary))
    if (root.detectedLlamaBinary !== "") extra.push(root.detectedLlamaBinary)
    buildsProbe.command = ["python3", root.pluginDir + "/llama_builds.py"].concat(extra)
    buildsProbe.running = true
  }

  Process {
    id: buildsProbe
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var builds = []
        try { builds = JSON.parse(String(text || "").trim() || "[]") } catch (e) { builds = [] }
        root.llamaBuilds = Array.isArray(builds) ? builds : []
        root.buildsProbed = true
        if (root.settingsLoaded) root.sanitizeSettings()
      }
    }
  }

  // A binary set or changed in settings joins the list without a shell restart.
  onConfiguredLlamaBinaryChanged: if (root.capabilitiesProbed) root.probeBuilds()
  onAltBinaryChanged: if (root.capabilitiesProbed) root.probeBuilds()

  Process {
    id: hwProbe
    command: ["bash", root.hwProbeScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.hardware = Hardware.parseProbe(text)
    }
  }

  // ---- Model discovery ----

  readonly property var searchDirs: {
    if (root.configuredModelsDir !== "") return [expandPath(root.configuredModelsDir)]
    return root.detectedModelDirs
  }

  function refreshModels() {
    if (root.backend === "ollama") {
      root.scanning = true
      // Resolved from ollama's store on disk, not from /api/tags.
      //
      // The API needs the server running, but a model has to be pickable in
      // order to start it -- listing over HTTP meant an empty list whenever
      // ollama was stopped, which is exactly when the picker matters most.
      // The manifests on disk are authoritative and always readable; the API
      // is consulted afterwards only to enrich what is already listed.
      ollamaStoreScan.command = ["python3", root.blobScript].concat(root.ollamaStoreDirs())
      ollamaStoreScan.running = false
      ollamaStoreScan.running = true
      return
    }
    if (root.searchDirs.length === 0) { root.modelOptions = []; return }
    root.scanning = true
    var cmd = ["find"]
    for (var i = 0; i < root.searchDirs.length; i++) cmd.push(root.searchDirs[i])
    // -L so symlinked model collections are followed; findings are de-duped
    // by path in buildModelOptions.
    cmd = ["find", "-L"].concat(root.searchDirs).concat([
      "(", "-type", "f", "-iname", "*.gguf", "-printf", "F\t%p\n", ")"
    ])
    treeScan.command = cmd
    treeScan.running = false
    treeScan.running = true
  }

  Process {
    id: treeScan
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseFindOutput(text)
        var modelFiles = []
        var vision = {}
        for (var i = 0; i < parsed.files.length; i++) {
          var path = parsed.files[i]
          if (Model.isMmprojName(Model.baseName(path))) vision[Model.dirName(path)] = path
          else modelFiles.push(path)
        }
        root.pendingModelFiles = modelFiles
        root.visionDirs = vision
        // Resolve ollama's blobs before probing, so both sources go through
        // one gguf_probe pass and land in one list.
        blobScan.command = ["python3", root.blobScript].concat(root.ollamaStoreDirs())
        blobScan.running = false
        blobScan.running = true
      }
    }
  }

  // Stores worth resolving: whatever the system unit uses, plus the per-user
  // default. Duplicates are harmless -- the resolver keeps the first hit.
  function ollamaStoreDirs() {
    var dirs = []
    // The running service's own store first, when it happens to be known.
    if (root.systemModelsDir !== "") dirs.push(root.systemModelsDir)
    // Then the standard locations. This list is what makes the lookup work on
    // the llama.cpp backend, where the ollama service is never queried and
    // systemModelsDir therefore stays empty.
    var candidates = Backends.ollamaStoreCandidates(Quickshell.env("HOME"))
    for (var i = 0; i < candidates.length; i++)
      if (dirs.indexOf(candidates[i]) === -1) dirs.push(candidates[i])
    return dirs
  }

  Process {
    id: blobScan
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var blobs = {}
        if (root.shareOllamaModels) {
          try { blobs = JSON.parse(String(text || "").trim() || "{}") } catch (e) { blobs = {} }
        }
        root.ollamaBlobs = blobs

        // Probe both sets together. A blob is a GGUF like any other, so it
        // gets the same capability and geometry detection as a loose file.
        var all = root.pendingModelFiles.slice()
        for (var name in blobs) if (all.indexOf(blobs[name].path) === -1) all.push(blobs[name].path)

        if (all.length === 0) {
          root.modelOptions = []
          root.scanning = false
          return
        }
        root.pendingModelFiles = all
        probeScan.command = ["python3", root.probeScript].concat(all)
        probeScan.running = false
        probeScan.running = true
      }
    }
  }

  Process {
    id: probeScan
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var caps = Model.parseProbeCapabilities(text)
        root.modelGeometry = Model.parseProbeGeometry(text)
        root.modelOptions = root.buildModelOptions(root.pendingModelFiles, caps)
        root.scanning = false
        root.validateSelection()
      }
    }
  }

  // Flat, searchable option list. The previous tree view could not fit on a
  // fixed-height page for an arbitrary model collection; searching scales to
  // any number of models in constant height.
  function buildModelOptions(files, caps) {
    var out = []
    var seen = {}
    // path -> ollama model name, so a blob shows as "qwen3:8b" rather than a
    // content-addressed filename nobody can read.
    var blobNames = {}
    for (var n in root.ollamaBlobs) blobNames[root.ollamaBlobs[n].path] = n

    var sorted = files.slice().sort()
    for (var i = 0; i < sorted.length; i++) {
      var path = sorted[i]
      if (seen[path]) continue
      seen[path] = true
      var name = Model.baseName(path)
      var cap = (caps && caps[path]) || {}
      var badges = []
      var quant = Model.quantLabel(name)
      if (quant) badges.push(quant)
      if (root.visionDirs[Model.dirName(path)]) badges.push("vision")
      if (cap.tools) badges.push("tools")
      if (cap.thinking) badges.push("thinking")
      if (cap.mtp) badges.push("mtp")
      // A shared blob is labelled by its ollama name and marked, so it is
      // clear the same file is serving both backends rather than being a
      // second copy.
      var sharedName = blobNames[path]
      if (sharedName) badges.unshift("shared with ollama")

      out.push({
        value: path,
        label: sharedName ? sharedName : name.replace(/\.gguf$/i, ""),
        description: badges.join(" · ") || Model.dirName(path),
        mtp: !!cap.mtp
      })
    }
    return out
  }

  Process {
    id: ollamaStoreScan
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var found = {}
        try { found = JSON.parse(String(text || "").trim() || "{}") } catch (e) { found = {} }
        root.ollamaBlobs = found

        var out = []
        var names = Object.keys(found).sort()
        for (var i = 0; i < names.length; i++) {
          var info = found[names[i]] || {}
          var size = Number(info.size) || 0
          out.push({
            value: names[i],
            label: names[i],
            description: size > 0 ? (size / 1073741824).toFixed(1) + "GB" : "",
            mtp: false
          })
        }
        root.modelOptions = out
        root.scanning = false
        root.validateSelection()

        // Enrich with parameter size and quantization when the server happens
        // to be up. Failure is fine -- the list already stands without it.
        ollamaTags.command = ["curl", "-s", "-m", "2", Backends.tagsUrl(root.host, root.port)]
        ollamaTags.running = false
        ollamaTags.running = true
      }
    }
  }

  Process {
    id: ollamaTags
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.scanning = false
        var data
        try { data = JSON.parse(String(text || "").trim() || "{}") } catch (e) { data = {} }
        var models = (data && data.models) || []
        // Enrichment only. The list already came from disk, so a server that
        // is down (or an unparseable reply) must leave it exactly as it is
        // rather than replacing it with nothing.
        if (models.length === 0) return

        var detailFor = {}
        for (var i = 0; i < models.length; i++) {
          var m = models[i] || {}
          var details = m.details || {}
          var badges = []
          if (details.parameter_size) badges.push(details.parameter_size)
          if (details.quantization_level) badges.push(details.quantization_level)
          if (m.size) badges.push((m.size / 1073741824).toFixed(1) + "GB")
          detailFor[String(m.name || "")] = badges.join(" · ")
        }

        var merged = []
        var known = {}
        for (var j = 0; j < root.modelOptions.length; j++) {
          var opt = root.modelOptions[j]
          known[opt.value] = true
          merged.push({
            value: opt.value,
            label: opt.label,
            description: detailFor[opt.value] || opt.description,
            mtp: opt.mtp
          })
        }
        // A model the server knows about but that is not resolvable on disk
        // (a differently-located store) is still worth offering.
        for (var name in detailFor) {
          if (known[name]) continue
          merged.push({ value: name, label: name, description: detailFor[name], mtp: false })
        }
        root.modelOptions = merged
        root.validateSelection()
      }
    }
  }

  // Keeps selectedModel pointing at something that still exists, falling back
  // to the first entry rather than launching against a deleted path.
  function validateSelection() {
    var opts = root.modelOptions
    for (var i = 0; i < opts.length; i++)
      if (opts[i].value === root.selectedModel) return
    root.selectedModel = opts.length > 0 ? opts[0].value : ""
  }

  function selectModel(value) {
    root.selectedModel = value
    for (var i = 0; i < root.modelOptions.length; i++) {
      if (root.modelOptions[i].value === value && root.modelOptions[i].mtp && !root.specTypeUserSet)
        root.specType = "draft-mtp"
    }
  }

  // ---- Server lifecycle ----

  function toggleServer() {
    if (root.stopping) return
    if (root.running || root.starting) stopServer()
    else startServer()
  }

  // Best-effort cleanup of a server this widget started but lost track of.
  // Matched on the per-instance marker, so it never touches an unrelated
  // server or another widget's.
  function killOrphans() {
    if (root.hasSystemdRun && root.ownsUnit)
      Quickshell.execDetached(["systemctl", "--user", "stop", root.unitName])
    else
      Quickshell.execDetached(["pkill", "-f", root.procMarker])
  }

  // A detached server outlives this widget on purpose, so a fresh instance
  // must reclaim it rather than showing a stale "Stopped". Health is checked
  // before claiming, so a dead marker process never reads as running.
  function adoptRunningServer() {
    if (root.running || root.starting) return
    if (!root.host || !root.port) return
    adoptHealthProc.command = [
      "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "1",
      Backends.healthUrl(root.backend, root.host, root.port)
    ]
    adoptHealthProc.running = false
    adoptHealthProc.running = true
  }

  Process {
    id: adoptHealthProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.running || root.starting) return
        if (text.trim() !== "200") return
        root.running = true
        root.adopted = true
        root.healthUrl = Backends.healthUrl(root.backend, root.host, root.port)
        // Determine whether this is our own transient unit (stoppable) or an
        // externally managed server such as a root-owned ollama.service.
        //
        // Metrics deliberately wait for the answer: which journal to follow
        // depends on it, and starting first meant tailing the system unit --
        // inactive whenever the server is one we own -- so throughput silently
        // never appeared.
        unitOwnerProc.command = ["systemctl", "--user", "is-active", root.unitName]
        unitOwnerProc.running = false
        unitOwnerProc.running = true
      }
    }
  }

  Process {
    id: unitOwnerProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.ownsUnit = text.trim() === "active"
        // Not ours: find out whether the distribution's system unit is what
        // is holding the port, and where it keeps its models.
        if (!root.ownsUnit && root.backendSpec.systemUnit) root.probeSystemUnit()
        if (root.ownsUnit) root.readRunningArgs()
        // Ownership is now known, so the right journal can be followed.
        if (root.running) root.startMetrics()
      }
    }
  }

  function probeSystemUnit() {
    var unit = root.backendSpec.systemUnit
    if (!unit) return
    systemUnitProc.command = ["bash", "-lc",
      "systemctl is-active " + root.shellQuote(unit) + " 2>/dev/null; " +
      "systemctl show " + root.shellQuote(unit) + " -p Environment --no-pager 2>/dev/null"]
    systemUnitProc.running = false
    systemUnitProc.running = true
  }

  Process {
    id: systemUnitProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = String(text || "")
        root.systemUnitActive = /^\s*active\s*$/m.test(out)
        root.systemModelsDir = Backends.modelsDirFromUnitEnvironment(out)
      }
    }
  }

  // Replaces an externally managed server with one this widget controls.
  //
  // The system unit runs as root, so stopping it raises a polkit prompt --
  // that prompt is the user authorising the takeover, which is why this is a
  // deliberate action rather than something Start does silently.
  function takeOver() {
    if (root.takingOver) return
    var unit = root.backendSpec.systemUnit
    if (!unit) return
    root.takingOver = true
    root.lastError = ""
    root.stopMetrics()
    takeoverProc.command = Backends.takeoverStopCommand(unit)
    takeoverProc.running = false
    takeoverProc.running = true
  }

  Process {
    id: takeoverProc
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        // Authentication declined or unavailable: nothing was stopped, so the
        // existing server is still there. Fall back to watching it.
        root.takingOver = false
        root.lastError = "Could not stop the system service (authentication declined)."
        root.startMetrics()
        return
      }
      // The port does not free the instant systemctl returns; launching too
      // early fails to bind. Wait for it to actually go quiet.
      root.running = false
      root.adopted = false
      root.systemUnitActive = false
      portWaitProc.command = ["bash", "-lc",
        "for i in $(seq 1 40); do " +
        "  curl -s -o /dev/null -m 1 " + root.shellQuote(Backends.healthUrl(root.backend, root.host, root.port)) +
        " || exit 0; sleep 0.25; done; exit 1"]
      portWaitProc.running = false
      portWaitProc.running = true
    }
  }

  Process {
    id: portWaitProc
    onExited: function(exitCode) {
      root.takingOver = false
      if (exitCode !== 0) {
        root.lastError = "System service stopped but the port is still busy."
        return
      }
      root.startServer()
    }
  }

  function startServer() {
    if (root.backend !== "ollama" && !root.selectedModel) {
      root.lastError = "Pick a model first"
      return
    }
    if (root.activeBinary === "") {
      root.lastError = root.backendSpec.label + " binary not found — set it in plugin settings"
      return
    }
    if (serverProc.running || root.stopping) return
    root.lastError = ""
    // Sweep for a stale instance synchronously before launching. killOrphans
    // is fire-and-forget, and the new process carries the same marker the
    // sweep hunts for, so a late-arriving pkill could kill the process just
    // started. Chaining through onExited guarantees the sweep finished first.
    startSweepProc.command = root.hasSystemdRun
      ? ["systemctl", "--user", "stop", root.unitName]
      : ["pkill", "-f", root.procMarker]
    startSweepProc.running = false
    startSweepProc.running = true
  }

  Process {
    id: startSweepProc
    onExited: root.launchServerProcess()
  }

  // Builds the llama-server argv. Kept as a function returning the array so
  // the composition is testable by eye and the launch path stays one line.
  function buildLlamaArgs() {
    var ngl = parseInt(root.gpuLayers, 10)
    if (!isFinite(ngl)) ngl = 0
    // -1 is llama.cpp's "fit as many layers as VRAM allows" sentinel, not a
    // layer count, so it is passed through unclamped.
    if (ngl !== -1) ngl = Math.max(0, Math.min(999, ngl))

    var args = [
      root.launchLlamaBinary,
      "--model", root.selectedModel,
      "--host", root.host,
      "--port", String(root.port),
      "--slot-save-path", expandPath(root.slotSaveDir),
      // Prometheus endpoint, so Stats can read totals the /slots view does
      // not carry.
      "--metrics"
    ]

    // Every flag a built-in control owns is emitted only while no added
    // parameter has taken it over. Emitting both is how a launch line ended up
    // carrying two "--load-mode mmap": llama.cpp keeps the last occurrence, so
    // the duplicate is silent -- the control still shows its own value while
    // the server runs on the other one.
    if (!root.propOverridden("gpuLayers")) args.push("--gpu-layers", String(ngl))
    if (!root.propOverridden("cacheTypeK")) args.push("--cache-type-k", root.cacheTypeK)
    if (!root.propOverridden("cacheTypeV")) args.push("--cache-type-v", root.cacheTypeV)
    if (!root.propOverridden("flashAttn")) args.push("--flash-attn", root.flashAttn)
    if (!root.propOverridden("loadMode")) args.push("--load-mode", root.loadMode)

    // Vision projector. "auto" reproduces what the plugin always did -- use
    // the projector sitting next to the model -- but says so in a row instead
    // of only in the launch line, and the other two modes are what that guess
    // was missing: a directory holding a projector for a different model, and
    // a card with room to offload the tower after all.
    // An added parameter for any one of the three takes the whole row, the
    // same way the MoE pair works: which projector to load and whether to
    // offload it are one decision, and leaving half of it to a control the
    // page no longer shows is exactly the invisible state the row exists to
    // prevent.
    var visionOwned = root.propOverridden("mmprojMode") ||
                      root.propOverridden("mmprojPath") ||
                      root.propOverridden("mmprojOffload")
    if (!visionOwned) {
      if (root.mmprojMode === "off") {
        args.push("--no-mmproj")
      } else if (root.mmprojActive) {
        args.push("--mmproj", expandPath(root.resolvedMmproj))
        // GPU offload is llama.cpp's default but rarely fits alongside the
        // main model's layers, and the failure mode is an allocation abort
        // rather than a clean error -- so the plugin default stays "off".
        if (root.mmprojOffload === "on") args.push("--mmproj-offload")
        else if (root.mmprojOffload === "off") args.push("--no-mmproj-offload")
      }
    }

    if (!root.propOverridden("parallel") && String(root.parallel).trim() !== "")
      args.push("--parallel", String(root.parallel).trim())

    if (!root.propOverridden("reasoningPreserve")) {
      if (root.reasoningPreserve === "on") args.push("--reasoning-preserve")
      else if (root.reasoningPreserve === "off") args.push("--no-reasoning-preserve")
    }

    var threadCount = parseInt(root.threads, 10)
    if (!root.propOverridden("threads") && isFinite(threadCount) && threadCount > 0)
      args.push("--threads", String(threadCount))

    // The two MoE flags are mutually exclusive in llama.cpp and the explicit
    // count wins, so an added parameter for either one takes the whole pair:
    // leaving the other in place would put the exclusion back.
    if (!root.propOverridden("nCpuMoe") && !root.propOverridden("cpuMoe")) {
      var nCpuMoeTrimmed = String(root.nCpuMoe).trim()
      if (nCpuMoeTrimmed !== "") args.push("--n-cpu-moe", nCpuMoeTrimmed)
      else if (root.cpuMoe) args.push("--cpu-moe")
    }

    if (!root.propOverridden("noRepack") && root.noRepack) args.push("--no-repack")
    if (!root.propOverridden("specType") && root.specType !== "none")
      args.push("--spec-type", root.specType)

    var ctxSize = parseInt(root.contextSize, 10)
    if (!root.propOverridden("contextSize") && isFinite(ctxSize) && ctxSize > 0)
      args.push("--ctx-size", String(ctxSize))
    var batch = parseInt(root.batchSize, 10)
    if (!root.propOverridden("batchSize") && isFinite(batch) && batch > 0)
      args.push("--batch-size", String(batch))
    var ubatch = parseInt(root.ubatchSize, 10)
    if (!root.propOverridden("ubatchSize") && isFinite(ubatch) && ubatch > 0)
      args.push("--ubatch-size", String(ubatch))
    if (!root.propOverridden("cacheRam") && String(root.cacheRam).trim() !== "")
      args.push("--cache-ram", String(root.cacheRam).trim())
    if (!root.propOverridden("temperature") && String(root.temperature).trim() !== "")
      args.push("--temp", String(root.temperature).trim())

    // User-added parameters. Appended before the free-form extra args so a
    // hand-written flag still gets the last word on any duplicate.
    //
    // A flag a built-in still emitted is skipped rather than appended twice.
    // The override guards above are what normally prevent that; this stays as
    // the backstop for a flag no ownership entry covers -- an alias a future
    // llama.cpp build adds, or a settings file from a version that reserved
    // the flag instead of yielding it.
    for (var c = 0; c < root.customParams.length; c++) {
      var entry = root.customParams[c]
      if (args.indexOf(entry.key) !== -1) {
        console.warn("local-ai-server: skipping", entry.key,
                     "-- already set by a built-in control")
        continue
      }
      // A flag this build's --help does not describe still has to be passed:
      // it may come from an alternate binary, or from a line pasted before the
      // catalogue loaded. Without the stand-in the row rendered and the launch
      // line silently omitted it.
      var spec = Params.find(root.paramCatalogue, entry.key) ||
                 Params.fallbackSpec(entry.key, entry.type)
      args = args.concat(Params.toArgv(spec, entry.value))
    }

    var extraPieces = Model.splitExtraArgs(root.extraArgs)
    for (var p = 0; p < extraPieces.length; p++) args = args.concat(Model.parseArgs(extraPieces[p]))
    return args
  }

  // The shell script that starts the backend, listening on the public
  // endpoint.
  function buildBackendScript() {
    var script = ""
    if (root.backend === "ollama") {
      var launch = Backends.ollamaLaunch({
        binary: root.ollamaBinary,
        host: root.host,
        port: String(root.port),
        keepAlive: String(root.keepAlive).trim(),
        numParallel: root.propOverridden("parallel") ? "" : String(root.parallel).trim(),
        // The shared Tuning controls, so they actually reach ollama rather
        // than being rendered and silently ignored.
        contextSize: root.contextSize,
        cacheType: root.cacheTypeK,
        flashAttn: root.flashAttn,
        // Serve whatever the system service already had on disk. Without this
        // our instance would start from an empty per-user store and report no
        // models at all. The directory is typically readable but not writable,
        // so serving works while `ollama pull` does not -- surfaced in the UI.
        // An explicit setting wins; otherwise use the store the models were
        // actually resolved from, falling back to the system unit's own.
        // systemModelsDir alone is not enough -- it is only populated when an
        // ollama service is adopted, so starting a server directly left this
        // empty and ollama served an empty per-user store.
        modelsDir: root.configuredModelsDir !== ""
          ? expandPath(root.configuredModelsDir)
          : (root.resolvedOllamaStore !== "" ? root.resolvedOllamaStore : root.systemModelsDir)
      })
      // ollama is configured through the environment, so user-added
      // parameters become additional assignments rather than argv.
      for (var c = 0; c < root.customParams.length; c++) {
        var spec = Params.find(root.paramCatalogue, root.customParams[c].key) ||
                   Params.fallbackSpec(root.customParams[c].key, root.customParams[c].type)
        var entry = Params.toEnvEntry(spec, root.customParams[c].value)
        if (entry) launch.env[entry.name] = entry.value
      }
      for (var ev = 0; ev < root.parsedEnv.env.length; ev++)
        launch.env[root.parsedEnv.env[ev].name] = root.parsedEnv.env[ev].value
      script = Backends.envPrefix(launch.env, root.shellQuote) + " " +
        "exec -a " + root.procMarker + " " + launch.argv.map(root.shellQuote).join(" ")
    } else {
      var args = root.buildLlamaArgs()
      // These two work around NVIDIA-specific faults and mean nothing on
      // other backends, so they are applied only when an NVIDIA GPU was
      // actually detected rather than injected unconditionally:
      //   GGML_CUDA_REGISTER_HOST pins CPU-resident weights for DMA transfer.
      //   GGML_CUDA_DISABLE_GRAPHS avoids CUDA graph capture, which assumes
      //   stable tensor addresses that hybrid CPU/GPU offload can violate.
      var cudaEnv = Hardware.isCuda(root.hardware)
        ? "GGML_CUDA_REGISTER_HOST=1 GGML_CUDA_DISABLE_GRAPHS=1 " : ""
      var userEnv = root.envScriptPrefix()
      script = "mkdir -p " + root.shellQuote(expandPath(root.slotSaveDir)) + "; " +
        cudaEnv + (userEnv !== "" ? userEnv + " " : "") + "exec -a " + root.procMarker + " " + args.map(root.shellQuote).join(" ")
    }
    return script
  }

  function launchServerProcess() {
    var script = root.buildBackendScript()

    // Detach so the server outlives `omarchy restart shell`, which runs
    // `quickshell kill`. A systemd transient unit is preferred over bare
    // setsid because it also routes output to journald, which is what lets
    // throughput still be read after this widget is torn down and rebuilt.
    serverProc.command = Backends.detachedCommand(root.hasSystemdRun, root.unitName, script)
    root.ownsUnit = root.hasSystemdRun
    root.runningModel = root.selectedModel
    root.adopted = false
    root.starting = true
    root.expectedStop = false
    root.lastLogLine = ""
    root.logLines = []
    root.startingElapsed = 0
    root.healthUrl = Backends.healthUrl(root.backend, root.host, root.port)
    startingTimer.restart()
    healthPollTimer.restart()
    serverProc.running = true

    // Follow the unit's journal from launch, not from first health -- a
    // detached server writes there, while serverProc only ever carries
    // systemd-run's one-line confirmation. Without this a server that dies
    // during model load produces no visible log at all.
    if (root.hasSystemdRun) {
      // Zero backlog: the unit is starting now, so there is no history to
      // seed, and a tail would replay the previous run's shutdown.
      root.followJournal(0)
      unitWatchTimer.restart()
    }
  }

  // Tails whichever journal holds the running server's output into the log
  // view. One entry point for every path -- launch, adoption, metrics -- so
  // the log can no longer be attached on some of them and forgotten on the
  // others. Backends.journalCommand decides the source from ownership.
  function followJournal(tailLines) {
    var command = Backends.journalCommand(root.backend, root.unitName, root.ownsUnit, tailLines)
    if (!command) {
      // A server started by hand outside systemd: nothing to follow. Recorded
      // so the log view can say that instead of showing a blank page.
      root.logsSource = "none"
      journalProc.running = false
      return
    }
    root.logsSource = root.ownsUnit ? "user" : "system"
    journalProc.command = command
    journalProc.running = false
    journalProc.running = true
  }

  // systemd-run returns as soon as the unit is queued, so serverProc exiting
  // says nothing about the server. The unit's own state is the only thing that
  // reports a crash -- without watching it, a server that aborts during model
  // load leaves the panel showing "Starting…" until the user gives up.
  Timer {
    id: unitWatchTimer
    interval: 1500
    repeat: true
    onTriggered: if ((root.starting || root.running) && !unitStateProc.running)
                   unitStateProc.running = true
  }

  Process {
    id: unitStateProc
    command: ["systemctl", "--user", "is-active", root.unitName]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var state = String(text || "").trim()
        if (state === "active" || state === "activating" || state === "") return
        // "failed", "inactive": the unit is gone. Report why, using the last
        // meaningful line the journal produced.
        root.reportUnitStopped(state)
      }
    }
  }

  function reportUnitStopped(state) {
    if (root.expectedStop || root.stopping) return
    if (!root.starting && !root.running) return
    startingTimer.stop()
    healthPollTimer.stop()
    unitWatchTimer.stop()
    root.stopMetrics()
    var detail = root.lastErrorLine()
    root.lastError = (root.starting ? "Server failed to start" : "Server stopped") +
      (state === "failed" ? " (crashed)" : "") + (detail ? ": " + detail : "")
    root.starting = false
    root.running = false
    root.clearRestartState()
    root.resetMetrics()
  }

  function clearRestartState() {
    root.runningArgs = []
    root.runningExe = ""
    root.restartPhase = ""
    restartDrainTimer.stop()
  }

  // Log triage lives in Model.js so it can be tested against real captured
  // crash output; this is the one caller.
  function lifecycleErrorLine() {
    return Model.pickErrorLine(root.logLines, root.lastLogLine)
  }
  function lastErrorLine() { return root.lifecycleErrorLine() }

  // ---- Restart lifecycle ----

  // Waits for running requests to finish, then restarts with the page's
  // current flags. Returns at once; restartDrainTimer does the waiting.
  function switchServer() {
    if (!root.configChanged) return
    root.lastError = ""
    root.restartIdleTicks = 0
    root.restartPhase = "draining"
    root.handleServerLine("[restart] requested: " + Model.baseName(root.selectedModel) +
                          " — waiting for running requests to finish")
    restartDrainTimer.restart()
  }

  // Stops waiting for requests still running. They are cut off, which is the
  // point: a generation that never ends would otherwise block the restart.
  function forceSwitch() {
    if (root.restartPhase === "draining") root.finishRestart()
  }

  // Idle means two fresh /slots polls in a row with nothing processing; the
  // metrics poll already fetches /slots, so this only reads its result.
  Timer {
    id: restartDrainTimer
    interval: 500
    repeat: true
    onTriggered: {
      if (root.restartPhase !== "draining" || !root.running) { stop(); root.restartPhase = ""; return }
      var fresh = Date.now() - root.slotsSeenAtMs < 1500
      root.restartIdleTicks = fresh && !root.slotsBusy ? root.restartIdleTicks + 1 : 0
      if (root.restartIdleTicks >= 2) root.finishRestart()
    }
  }

  // Goes through the ordinary stop, so the prompt cache is saved exactly as
  // it is on Stop; finishStop starts the server again.
  function finishRestart() {
    restartDrainTimer.stop()
    root.restartPhase = ""
    root.handleServerLine("[restart] stopping, then starting with the new configuration")
    root.restartAfterStop = true
    root.stopServer()
  }

  function readRunningArgs() {
    if (root.backend !== "llamacpp") return
    runningArgsProc.running = false
    runningArgsProc.running = true
  }

  Process {
    id: runningArgsProc
    command: ["bash", "-c", "pid=$(systemctl --user show -p MainPID --value " + root.shellQuote(root.unitName) +
              ") && [ \"$pid\" != 0 ] && readlink /proc/$pid/exe && tr '\\0' '\\n' < /proc/$pid/cmdline"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.running) return
        var args = String(text || "").split("\n")
        if (args.length && args[args.length - 1] === "") args.pop()
        // First line is the binary; a build rebuilt since launch reads
        // "... (deleted)", which is still the same path.
        root.runningExe = args.length ? args.shift().replace(/ \(deleted\)$/, "") : ""
        root.runningArgs = args
        var i = args.indexOf("--model")
        if (root.runningModel === "" && i !== -1 && i + 1 < args.length) root.runningModel = args[i + 1]
      }
    }
  }

  // Saves every slot's KV cache under the running model's name. Always ends in
  // onDone, whether or not anything was saved -- a cache that cannot be written
  // only costs the next start a cold prompt.
  function slotKvCommand(action, model) {
    return ["python3", root.slotKvScript, action,
            "--url", Backends.baseUrl(root.host, root.port),
            "--dir", expandPath(root.slotSaveDir),
            "--prefix", root.kvPrefix(model)]
  }

  readonly property bool savesSlots: root.kvPersistence && Backends.supports(root.backend, "slotKv")

  function stopServer() {
    root.starting = false
    startingTimer.stop()
    healthPollTimer.stop()
    slotsPollTimer.stop()
    slotAutosaveTimer.stop()
    stopMetrics()

    var model = root.runningModel !== "" ? root.runningModel : root.selectedModel
    if (root.running && root.canStop && root.savesSlots && model !== "") {
      // Dump the KV cache before stopping, so the next start does not
      // reprocess the whole prompt. The stop itself runs from the save's
      // completion.
      root.expectedStop = true
      root.stopping = true
      slotSaveProc.command = root.slotKvCommand("save", model)
      slotSaveProc.running = false
      slotSaveProc.running = true
    } else if (serverProc.running || root.running) {
      root.expectedStop = true
      root.stopping = true
      root.finishStop()
    } else {
      root.restartAfterStop = false
    }
  }

  // A detached launch returns immediately, so serverProc exiting says nothing
  // about the server. Stopping the unit/marker explicitly is what actually
  // ends it.
  function finishStop() {
    serverProc.running = false
    root.killOrphans()
    root.clearRestartState()
    root.running = false
    root.stopping = false
    root.adopted = false
    root.resetMetrics()
    if (root.restartAfterStop) {
      root.restartAfterStop = false
      // startServer sweeps the old unit synchronously before launching.
      root.startServer()
    }
  }

  function resetMetrics() {
    root.runningModel = ""
    root.tokensPerSec = 0
    root.ppActive = false
    root.ppPercent = 0
    root.ppTokensPerSec = 0
    root.ppFromLog = false
    root.lastDecodeSample = null
    root.lastPromptSample = null
    root.loadedModelInfo = ""
  }

  // The shell tears this panel down on restart or plugin removal. Killing the
  // server here is what made it die on every `omarchy restart shell`; with
  // surviveRestart on, it is deliberately left running to be re-adopted.
  Component.onDestruction: {
    if (!root.surviveRestart && (serverProc.running || root.running)) root.killOrphans()
    journalProc.running = false
  }

  // Loading a large model over mmap from cold cache legitimately takes
  // minutes, so this is generous -- it exists to end an indefinite "Starting…"
  // when nothing is ever going to answer, not to bound normal startup.
  readonly property int startupTimeoutSec: 600

  Timer {
    id: startingTimer
    interval: 1000
    repeat: true
    onTriggered: {
      root.startingElapsed += 1
      if (root.starting && root.startingElapsed >= root.startupTimeoutSec) {
        startingTimer.stop()
        healthPollTimer.stop()
        unitWatchTimer.stop()
        root.stopMetrics()
        var detail = root.lifecycleErrorLine()
        root.lastError = "Gave up waiting after " + root.startupTimeoutSec + "s" +
          (detail ? ": " + detail : " — no response on " + root.healthUrl)
        root.starting = false
      }
    }
  }

  // Both servers open their port before the model is loaded, so liveness is
  // polled on the endpoint that only answers once it is ready to serve.
  Timer {
    id: healthPollTimer
    interval: 800
    repeat: true
    onTriggered: if (!healthProc.running) healthProc.running = true
  }

  Process {
    id: healthProc
    command: ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "1", root.healthUrl]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.starting && text.trim() === "200") {
          root.starting = false
          root.running = true
          startingTimer.stop()
          healthPollTimer.stop()
          root.restoreSlots()
          // What Restart compares the page against.
          root.readRunningArgs()
          root.lastDecodeSample = null
          root.startMetrics()
        }
      }
    }
  }

  // ---- Metrics ----

  // Two sources, chosen by backend:
  //   "slots" -- llama.cpp's /slots endpoint, polled for a live pp% sweep and
  //     a running tg rate derived from the decode-count delta.
  //   "log"   -- ollama, which exposes no equivalent endpoint, so the timing
  //     lines its embedded llama.cpp writes on request completion are
  //     followed in journald. Same parser, coarser resolution: totals per
  //     request instead of a live sweep.
  function startMetrics() {
    if (root.backendSpec.metricsMode === "slots") slotsPollTimer.restart()
    if (root.backendSpec.metricsMode === "log") psPollTimer.restart()
    // The journal is the log view's only source, so it is followed for every
    // backend -- not just the ones that also read throughput out of it. This
    // is the adoption path: a llama.cpp server adopted from a previous widget
    // instance takes metrics from /slots and used to attach nothing here, so
    // its log stayed empty for as long as the widget ran.
    if (!journalProc.running) root.followJournal(200)
  }

  function stopMetrics() {
    slotsPollTimer.stop()
    psPollTimer.stop()
    unitWatchTimer.stop()
    journalProc.running = false
    root.logsSource = ""
  }

  Timer {
    id: slotsPollTimer
    interval: 250
    repeat: true
    onTriggered: if (root.running && !slotsProc.running) slotsProc.running = true
  }

  Process {
    id: slotsProc
    command: ["curl", "-s", "-m", "1", Backends.loadedModelsUrl("llamacpp", root.host, root.port)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleSlotsResponse(text)
    }
  }

  // ollama has no live progress endpoint; /api/ps at a slow cadence is enough
  // to show which model is resident and how it is split across GPU and CPU.
  Timer {
    id: psPollTimer
    interval: 2000
    repeat: true
    onTriggered: if (root.running && !psProc.running) psProc.running = true
  }

  Process {
    id: psProc
    command: ["curl", "-s", "-m", "2", Backends.loadedModelsUrl("ollama", root.host, root.port)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data
        try { data = JSON.parse(String(text || "").trim() || "{}") } catch (e) { return }
        var models = (data && data.models) || []
        if (models.length === 0) { root.loadedModelInfo = ""; return }
        var m = models[0]
        var total = m.size || 0
        var gpu = m.size_vram || 0
        var pct = total > 0 ? Math.round((gpu / total) * 100) : 0
        root.loadedModelInfo = String(m.name || "") +
          (total > 0 ? "  " + (total / 1073741824).toFixed(1) + "GB · " + pct + "% GPU" : "")
      }
    }
  }

  Process {
    id: journalProc
    stdout: SplitParser { onRead: function(line) { root.handleServerLine(line) } }
    stderr: SplitParser { onRead: function(line) { root.handleServerLine(line) } }
  }

  function handleSlotsResponse(text) {
    var body = String(text || "").trim()
    if (body === "") return
    var data
    try { data = JSON.parse(body) } catch (e) { return }
    if (!Array.isArray(data) || data.length === 0) return

    var slot = data[0]
    for (var i = 0; i < data.length; i++) {
      if (data[i].is_processing) { slot = data[i]; break }
    }

    var processing = !!slot.is_processing
    var busy = 0
    for (var b = 0; b < data.length; b++) if (data[b].is_processing) busy++
    root.slotsProcessing = busy
    root.slotsBusy = processing
    root.slotsSeenAtMs = Date.now()
    var nPromptTotal = slot.n_prompt_tokens || 0
    var nPromptDone = (slot.n_prompt_tokens_processed || 0) + (slot.n_prompt_tokens_cache || 0)
    var nextTok = slot.next_token && slot.next_token[0]
    var nDecoded = (nextTok && nextTok.n_decoded) || 0

    if (processing && nDecoded === 0 && nPromptTotal > 0) {
      var ppNow = Date.now()
      if (root.ppFromLog) {
        // The log is driving these numbers; only the active flag is taken
        // from the poll, so ingestion still ends when the slot says so.
        root.ppActive = true
        root.lastDecodeSample = null
        return
      }
      // Keyed on total as well as count, so a new request with a different
      // prompt length never diffs against the tail of the previous one.
      if (root.lastPromptSample && root.lastPromptSample.total === nPromptTotal &&
          nPromptDone >= root.lastPromptSample.n) {
        var ppDtSec = (ppNow - root.lastPromptSample.t) / 1000
        var ppDn = nPromptDone - root.lastPromptSample.n
        if (ppDtSec > 0.05 && ppDn > 0) root.ppTokensPerSec = ppDn / ppDtSec
      } else {
        root.ppTokensPerSec = 0
      }
      root.lastPromptSample = { n: nPromptDone, t: ppNow, total: nPromptTotal }
      root.ppActive = true
      root.ppPercent = Math.min(100, (nPromptDone / nPromptTotal) * 100)
      root.lastDecodeSample = null
      return
    }

    root.ppActive = false
    root.ppFromLog = false
    root.lastPromptSample = null

    if (processing && nDecoded > 0) {
      var now = Date.now()
      if (root.lastDecodeSample && nDecoded >= root.lastDecodeSample.n) {
        var dtSec = (now - root.lastDecodeSample.t) / 1000
        var dn = nDecoded - root.lastDecodeSample.n
        if (dtSec > 0.05 && dn > 0) root.tokensPerSec = dn / dtSec
      }
      root.lastDecodeSample = { n: nDecoded, t: now }
    } else {
      root.lastDecodeSample = null
    }
  }

  function handleServerLine(line) {
    var text = String(line).trim()
    if (text !== "") {
      root.lastLogLine = text
      var next = root.logLines.concat([text])
      if (next.length > root.logLinesMax) next = next.slice(next.length - root.logLinesMax)
      root.logLines = next
    }

    // Live ingestion progress, when the build logs it. Both numbers come
    // measured, so they win over the /slots derivation, which reports a
    // percentage with no rate whenever n_prompt_tokens_processed sits still
    // between polls -- which is what a long prompt looks like on this build.
    var progress = Model.parsePromptProgressLine(text)
    if (progress) {
      root.ppActive = true
      root.ppPercent = progress.percent
      root.ppTokensPerSec = progress.tps
      root.ppFromLog = true
      root.lastPromptSample = null
      root.lastDecodeSample = null
      return
    }

    var timing = Model.parseTimingLine(text)
    if (!timing) return
    if (timing.kind === "pp") {
      // No live sweep is available from a log line -- the number arrives only
      // once the prompt is fully processed -- so the rate is shown without a
      // percentage. metricText renders that shape correctly.
      root.ppTokensPerSec = timing.tps
      root.ppActive = false
    } else {
      root.tokensPerSec = timing.tps
      // A completed generation means the KV cache grew a turn; save it once
      // the server goes quiet, so a crash loses at most the last turn.
      if (root.savesSlots) slotAutosaveTimer.restart()
    }
  }

  // ---- Slot KV persistence (llama.cpp only) ----

  // Runs as soon as a start answers /health. Requests arriving meanwhile are
  // served cold; a restore takes seconds, re-reading the prompt minutes.
  function restoreSlots() {
    if (!root.savesSlots || root.runningModel === "") return
    slotRestoreProc.command = root.slotKvCommand("restore", root.runningModel)
    slotRestoreProc.running = false
    slotRestoreProc.running = true
  }

  Process {
    id: slotRestoreProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleServerLine("[slot] " + (text.trim() || "restore: no output"))
    }
  }

  Process {
    id: slotSaveProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleServerLine("[slot] " + (text.trim() || "save: no output"))
    }
    // On exit rather than on output, so the stop goes ahead even when the
    // save printed nothing or python3 is missing.
    onExited: root.finishStop()
  }

  // Debounced: an agent loop finishes a generation every few seconds, and
  // each save writes the whole cache. Saving once things go quiet costs one
  // write per burst instead of one per turn.
  Timer {
    id: slotAutosaveTimer
    interval: 20000
    onTriggered: {
      if (!root.running || root.stopping || !root.savesSlots || root.runningModel === "") return
      if (root.slotsBusy) { restart(); return }
      if (slotSaveProc.running || slotAutosaveProc.running) return
      slotAutosaveProc.command = root.slotKvCommand("save", root.runningModel)
      slotAutosaveProc.running = true
    }
  }

  Process {
    id: slotAutosaveProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleServerLine("[slot] autosave: " + text.trim())
    }
  }

  Process {
    id: serverProc
    stdout: SplitParser { onRead: function(line) { root.handleServerLine(line) } }
    stderr: SplitParser { onRead: function(line) { root.handleServerLine(line) } }
    onExited: function(exitCode) {
      // With a detached launch this fires as soon as the wrapper returns, so
      // it reports the spawn's outcome, not the server's. A nonzero code here
      // means the server never started.
      if (!root.expectedStop && exitCode !== 0) {
        startingTimer.stop()
        healthPollTimer.stop()
        root.stopMetrics()
        root.lastError = root.backendSpec.label + " failed to start (code " + exitCode + ")" +
          (root.lastLogLine ? ": " + root.lastLogLine : "")
        root.starting = false
        root.running = false
        root.resetMetrics()
      }
      root.expectedStop = false
      root.stopping = false
    }
  }

  onOpenedChanged: if (opened) {
    root.showingLogs = false
    refreshModels()
    if (!root.running) root.adoptRunningServer()
    // A hot reload keeps `running` without adopting again, so the running
    // argv is looked up here as well.
    else if (root.ownsUnit && root.runningArgs.length === 0) root.readRunningArgs()
  }

  // ---- Bar widget ----

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    readonly property string switchState: root.switchPhase
    text: Model.barSwitchText(
      Model.barText(Model.BAR_ICON,
                    root.running, root.showMetric, root.ppActive,
                    root.ppPercent, root.tokensPerSec, root.ppTokensPerSec),
      switchState, root.configChanged)
    active: root.running || root.starting
    activeColor: Color.accent
    opacity: root.starting ? 0.6 : 1.0
    tooltipText: {
      if (switchState !== "") return Model.barSwitchTooltip(switchState, root.slotsProcessing)
      if (!root.running) return ""
      return root.backendSpec.label +
        (root.configChanged ? " · changes pending — open the panel and press Restart" : "") +
        " · " + (root.showMetric ? "Right-click: hide tokens/s" : "Right-click: show tokens/s")
    }
    onPressed: function(b) {
      if (b === Qt.RightButton) root.showMetric = !root.showMetric
      else root.toggle()
    }
  }

  // ---- Panel ----

  KeyboardPanel {
    id: panel
    bar: root.bar
    anchorItem: button
    owner: root
    open: root.opened
    focusTarget: keyCatcher
    // Sized so each category page fits without scrolling; the previous
    // 294x350 forced content to be paginated by height. Raised again for the
    // MoE row: at 430 a full Tuning page ran under the shared log button.
    // Raised again for "Keep prompt cache": at 460 the Server page's three
    // toggles plus the backend/host/port fields and the running banner ran
    // past the clip on the pages Item, so the toggle's own description got
    // cut instead of just its overflow.
    // fittedContentHeight caps it to the screen, so a short display still gets
    // a panel that fits.
    contentWidth: fittedContentWidth(Style.space(360))
    contentHeight: fittedContentHeight(Style.space(520), Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingField
      onCloseRequested: root.close()
      onTabRequested: function(direction) {
        var n = root.pageNames.length
        root.currentPage = (root.currentPage + direction + n) % n
      }

      readonly property int chrome: Style.space(96)
      readonly property int pageBudget: Math.max(Style.space(120), panel.contentHeight - chrome)

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(6)

        // ---- Hero: status at a glance ----
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Rectangle {
            width: Style.space(8)
            height: Style.space(8)
            radius: width / 2
            color: root.running ? Color.accent : (root.starting ? root.bar.foreground : "transparent")
            border.width: root.running || root.starting ? 0 : 1
            border.color: root.bar.foreground
            opacity: root.starting ? 0.6 : 1.0
            Layout.alignment: Qt.AlignVCenter
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Text {
              text: Model.statusLabel(root.running, root.starting, root.startingElapsed,
                                      root.switchPhase,
                                      root.slotsProcessing) +
                    " · " + root.backendSpec.label +
                    (root.adopted && !root.ownsUnit ? " · external" : "")
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.subtitle
              elide: Text.ElideRight
              Layout.fillWidth: true
            }
            Text {
              text: {
                var m = Model.metricText(true, root.ppActive, root.ppPercent,
                                         root.tokensPerSec, root.ppTokensPerSec)
                return m !== "" ? m : (root.running ? root.host + ":" + root.port : "")
              }
              color: root.bar.foreground
              opacity: 0.65
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              Layout.fillWidth: true
            }
          }

          Button {
            text: {
              if (root.takingOver) return "…"
              if (root.canTakeOver) return "Take over"
              if (root.switching) return "Force"
              if (root.configChanged) return "Restart"
              return root.starting || root.running ? "Stop" : "Start"
            }
            enabled: !root.stopping && !root.takingOver &&
                     (root.canTakeOver || root.starting || !root.running || root.canStop)
            tooltipText: {
              if (root.canTakeOver) return "Stop the system service and run an instance this widget controls"
              if (root.switching)
                return "Restart now, cutting off the requests still running"
              if (root.configChanged)
                return "Restart with the new model and tuning — running requests finish first" +
                       (root.savesSlots ? ", the prompt cache is kept" : "") +
                       "; clients are refused while it loads"
              return ""
            }
            onClicked: {
              if (root.canTakeOver) root.takeOver()
              else if (root.switching) root.forceSwitch()
              else if (root.configChanged) root.switchServer()
              else root.toggleServer()
            }
          }

          // Stop stays reachable while the main button is Restart or Force.
          Button {
            visible: root.configChanged || root.switching
            text: "■"
            tooltipText: "Stop the server"
            enabled: !root.stopping && root.canStop
            onClicked: root.stopServer()
          }
        }

        PanelSeparator { Layout.fillWidth: true }

        // ---- Category tabs ----
        ButtonGroup {
          Layout.fillWidth: true
          visible: !root.showingSetup
          options: root.pageNames
          value: root.pageNames[root.currentPage]
          onChanged: function(v) {
            root.currentPage = root.pageNames.indexOf(v)
            // Choosing a category means "show me that", so the log steps
            // aside rather than staying up over the selection.
            root.showingLogs = false
          }
        }

        // ---- First-run setup ----
        //
        // Replaces the tabs and pages until finished or skipped. Each step
        // shows what detection found before asking anything, so on a machine
        // where everything is already in the usual places setup is three
        // clicks of Next.
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: root.showingSetup && !root.showingLogs
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            text: "Setup · " + (root.setupStep + 1) + "/" + root.setupSteps.length +
                  " · " + root.setupSteps[root.setupStep]
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.subtitle
          }

          // Backend ------------------------------------------------------
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)
            visible: root.setupStep === 0

            Text {
              Layout.fillWidth: true
              text: "Which server should this widget run?"
              color: root.bar.foreground
              opacity: 0.65
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: Backends.ids()
              delegate: Button {
                required property string modelData
                readonly property string path: modelData === "ollama" ? root.ollamaBinary : root.launchLlamaBinary
                Layout.fillWidth: true
                leftAlign: true
                bordered: true
                selected: root.backend === modelData
                enabled: !root.running && !root.starting
                text: Backends.get(modelData).label + (path !== "" ? "  ✓" : "  —  not found")
                onClicked: root.backend = modelData
              }
            }

            Text {
              Layout.fillWidth: true
              visible: root.backend === "llamacpp" && root.llamaBuilds.length > 1
              text: root.llamaBuilds.length + " builds found: " +
                    root.llamaBuilds.map(function(b) { return b.fork }).join(", ") +
                    " — each model can pick its own on the Model tab (auto picks one that fits)."
              color: root.bar.foreground
              opacity: 0.65
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              Layout.fillWidth: true
              visible: root.activeBinary !== ""
              text: "Using " + root.activeBinary.replace(Quickshell.env("HOME"), "~")
              color: root.bar.foreground
              opacity: 0.5
              elide: Text.ElideMiddle
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              Layout.fillWidth: true
              visible: root.activeBinary === ""
              text: root.backend === "ollama"
                ? "Install it with: omarchy pkg add ollama  (or ollama-cuda / ollama-rocm / ollama-vulkan for GPU)"
                : "Install it with: omarchy pkg add llama-cpp  — or build llama.cpp and point to llama-server below."
              color: root.bar.urgent
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(4)

              TextField {
                id: setupBinaryField
                Layout.fillWidth: true
                placeholderText: "Custom " + root.backendSpec.label + " binary path"
                text: root.setupBinaryKey() === "binary" ? root.configuredLlamaBinary : root.configuredOllamaBinary
                onAccepted: root.setWidgetSetting(root.setupBinaryKey(), text.trim())
              }
              Button {
                text: "Set"
                tooltipText: "Use this binary instead of the detected one (leave empty to auto-detect)"
                onClicked: root.setWidgetSetting(root.setupBinaryKey(), setupBinaryField.text.trim())
              }
              Button {
                text: "⟳"
                tooltipText: "Detect again (after installing)"
                enabled: !capabilityProbe.running
                onClicked: {
                  root.detectedLlamaBinary = ""
                  root.detectedOllamaBinary = ""
                  capabilityProbe.running = true
                }
              }
            }
          }

          // Models -------------------------------------------------------
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)
            visible: root.setupStep === 1

            Text {
              Layout.fillWidth: true
              text: root.backend === "ollama"
                ? "ollama keeps its own model store. " + (root.modelOptions.length > 0
                    ? root.modelOptions.length + " model(s) found."
                    : "None pulled yet — run: ollama pull <model>  (e.g. qwen3:8b)")
                : "Where are your .gguf models? Pick a folder, or let the widget scan every detected one."
              color: root.bar.foreground
              opacity: 0.65
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Button {
              Layout.fillWidth: true
              visible: root.backend !== "ollama" && root.detectedModelDirs.length > 0
              leftAlign: true
              bordered: true
              selected: root.configuredModelsDir === ""
              text: "Scan all detected folders (auto)"
              onClicked: root.useModelsDir("")
            }

            Repeater {
              model: root.backend === "ollama" ? [] : root.setupModelDirs
              delegate: Button {
                required property string modelData
                readonly property var count: root.modelDirCounts[modelData]
                Layout.fillWidth: true
                leftAlign: true
                bordered: true
                selected: root.configuredModelsDir !== "" && expandPath(root.configuredModelsDir) === modelData
                text: modelData.replace(Quickshell.env("HOME"), "~") + "  —  " +
                      (count === undefined ? "counting…" : count + " model" + (count === 1 ? "" : "s"))
                onClicked: root.useModelsDir(modelData)
              }
            }

            RowLayout {
              Layout.fillWidth: true
              visible: root.backend !== "ollama"
              spacing: Style.space(4)

              TextField {
                id: setupModelsField
                Layout.fillWidth: true
                placeholderText: "Another folder (created if missing), e.g. ~/models"
                onAccepted: { root.useModelsDir(text); root.countModelDirs() }
              }
              Button {
                text: "Use"
                enabled: setupModelsField.text.trim() !== ""
                onClicked: { root.useModelsDir(setupModelsField.text); root.countModelDirs() }
              }
            }

            Text {
              Layout.fillWidth: true
              visible: root.backend !== "ollama"
              text: root.modelOptions.length > 0
                ? root.modelOptions.length + " model(s) will be listed."
                : "No models yet? Download a .gguf (e.g. from huggingface.co) into the folder above, then rescan on the Model tab."
              color: root.bar.foreground
              opacity: 0.65
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // Tuning -------------------------------------------------------
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)
            visible: root.setupStep === 2

            Text {
              Layout.fillWidth: true
              text: root.hardwareSummary !== "" ? "Detected: " + root.hardwareSummary : "Detecting hardware…"
              color: root.bar.foreground
              opacity: 0.65
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Button {
              Layout.fillWidth: true
              leftAlign: true
              bordered: true
              selected: root.setupTuning === "recommended"
              text: "Recommended for this machine"
              onClicked: root.setupTuning = "recommended"
            }

            Text {
              Layout.fillWidth: true
              visible: root.suggestions !== null
              text: root.suggestions
                ? "ngl " + root.suggestions.gpuLayers + " · ctx " + root.suggestions.contextSize +
                  " · " + root.suggestions.threads + " threads · batch " + root.suggestions.batchSize
                : ""
              color: root.bar.foreground
              opacity: 0.5
              elide: Text.ElideRight
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Button {
              Layout.fillWidth: true
              leftAlign: true
              bordered: true
              selected: root.setupTuning === "defaults"
              text: root.backendSpec.label + " built-in defaults"
              onClicked: root.setupTuning = "defaults"
            }

            Text {
              Layout.fillWidth: true
              text: "Everything stays editable on the Tuning tab, per model."
              color: root.bar.foreground
              opacity: 0.5
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Item { Layout.fillHeight: true }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(4)

            Button {
              text: "Skip"
              tooltipText: "Keep auto-detection and defaults; run setup later from the Server tab"
              onClicked: root.skipSetup()
            }
            Item { Layout.fillWidth: true }
            Button {
              text: "Back"
              visible: root.setupStep > 0
              onClicked: root.setupGoTo(root.setupStep - 1)
            }
            Button {
              readonly property bool last: root.setupStep === root.setupSteps.length - 1
              text: last ? "Finish" : "Next"
              bordered: true
              enabled: root.setupStep !== 0 || root.activeBinary !== ""
              tooltipText: enabled ? "" : "Install or point to a backend binary first"
              onClicked: last ? root.finishSetup() : root.setupGoTo(root.setupStep + 1)
            }
          }
        }

        // ---- Pages ----
        //
        // Clipped so a page's content overflowing its allotted height is cut
        // off instead of painting past this Item's bottom edge -- which,
        // unclipped, rendered under the "Show log" button below (a sibling
        // painted after it) and read as the two overlapping. A row that grows
        // too tall now disappears at the edge rather than colliding with
        // shared chrome, whatever changes later push a page's content past
        // its budget.
        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: !root.showingLogs && !root.showingSetup
          clip: true

          // Server ------------------------------------------------------
          ColumnLayout {
            anchors.fill: parent
            spacing: Style.space(8)
            visible: root.currentPage === 0

            GridLayout {
              Layout.fillWidth: true
              columns: 2
              columnSpacing: Style.space(8)
              rowSpacing: Style.space(6)

              Text {
                text: "Backend"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
              Dropdown {
                Layout.fillWidth: true
                showLabel: false
                options: root.installedBackends.map(function(b) { return { value: b.id, label: b.label } })
                value: root.backend
                // Switching backend would retarget the health and metrics
                // polling away from the server currently being watched.
                enabled: !root.running && !root.starting
                opacity: enabled ? 1.0 : 0.45
                onChanged: function(v) { root.backend = v }
              }

              Text {
                text: "Host"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
              TextField {
                Layout.fillWidth: true
                text: root.host
                // Typing severs the declarative `text` binding, so the field
                // would keep showing a stale value after the source changes
                // elsewhere. Restored whenever it is not being edited.
                Binding on text {
                  value: root.host
                  when: !activeFocus
                  restoreMode: Binding.RestoreNone
                }
                enabled: !root.running && !root.starting
                opacity: enabled ? 1.0 : 0.45
                onEditingFinished: root.host = text
              }

              Text {
                text: "Port"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
              NumField {
                Layout.fillWidth: true
                text: root.port
                // Typing severs the declarative `text` binding, so the field
                // would keep showing a stale value after the source changes
                // elsewhere (a backend switch, applying detected defaults).
                // Restored whenever the field is not being edited.
                Binding on text {
                  value: root.port
                  when: !activeFocus
                  restoreMode: Binding.RestoreNone
                }
                enabled: !root.running && !root.starting
                opacity: enabled ? 1.0 : 0.45
                validator: IntValidator { bottom: 1; top: 65535 }
                onEditingFinished: root.setPort(text)
              }
            }

            // llama-server runs without an API key here, so an endpoint off
            // loopback serves the model -- and its slot save/restore API -- to
            // anyone who can reach the port.
            Text {
              Layout.fillWidth: true
              visible: !/^(127\.|localhost$|::1$)/.test(String(root.host).trim())
              text: "⚠ " + root.host + " is reachable from other machines, and the server has no API key. " +
                    "Use 127.0.0.1 unless you mean to share it."
              color: root.bar.urgent
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              Layout.fillWidth: true
              visible: root.running || root.starting
              text: "Stop the server to change backend or endpoint."
              color: root.bar.foreground
              opacity: 0.5
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Toggle {
              Layout.fillWidth: true
              label: "Survive restart"
              checked: root.surviveRestart
              onClicked: root.surviveRestart = !root.surviveRestart
              HoverHandler { id: surviveHover }
              PanelToolTip {
                visible: surviveHover.hovered
                fontSize: Style.font.caption
                text: root.hasSystemdRun
                  ? "Keep serving through `omarchy restart shell`"
                  : "Keep serving through a shell restart (setsid; no systemd)"
              }
            }

            Toggle {
              Layout.fillWidth: true
              visible: Backends.supports(root.backend, "slotKv")
              label: "Keep prompt cache"
              checked: root.kvPersistence
              onClicked: root.kvPersistence = !root.kvPersistence
              HoverHandler { id: kvPersistenceHover }
              PanelToolTip {
                visible: kvPersistenceHover.hovered
                fontSize: Style.font.caption
                text: "Save the prompt (KV) cache on stop, restart and when idle; restore it at start"
              }
            }

            Text {
              Layout.fillWidth: true
              visible: root.canTakeOver
              text: "Watching the " + root.backendSpec.systemUnit + " system service. " +
                    "Take over to stop it and run an instance this widget controls " +
                    "(asks for authentication)."
              color: root.bar.foreground
              opacity: 0.65
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              Layout.fillWidth: true
              visible: root.ownsUnit && root.backend === "ollama" && root.systemModelsDir !== ""
              text: "Serving models from " + root.systemModelsDir +
                    " — read-only, so `ollama pull` needs the system service."
              color: root.bar.foreground
              opacity: 0.5
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Item { Layout.fillHeight: true }

            Text {
              Layout.fillWidth: true
              text: root.hardwareSummary !== "" ? root.hardwareSummary : "Detecting hardware…"
              color: root.bar.foreground
              opacity: 0.6
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              Layout.fillWidth: true
              visible: root.lastError !== ""
              text: root.lastError
              color: root.bar.urgent
              wrapMode: Text.WordWrap
              maximumLineCount: 3
              elide: Text.ElideRight
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // Model -------------------------------------------------------
          ColumnLayout {
            anchors.fill: parent
            spacing: Style.space(8)
            visible: root.currentPage === 1

            // Always selectable, even while a server is up: for llama.cpp the
            // model is a launch flag, so a new pick simply applies to the next
            // start (runningModel keeps KV saves pointed at what is actually
            // loaded); ollama loads models per request, so it is never a
            // restart at all.
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(4)

              SearchableDropdown {
                Layout.fillWidth: true
                label: "Model"
                showLabel: false
                options: root.modelOptionsWithProfile
                value: root.selectedModel
                placeholderText: "Search models…"
                emptyText: root.scanning ? "Scanning…" : "No models found"
                triggerLabel: root.selectedModel === "" ? "Select a model" : ""
                onChanged: function(v) { root.selectModel(v) }
              }

              Button {
                text: "⟳"
                tooltipText: root.scanning ? "Scanning…" : "Rescan for models"
                enabled: !root.scanning
                onClicked: root.refreshModels()
              }
            }

            // The build this model runs on. Only a choice when there is more
            // than one; a single build is just named, so it is never a mystery
            // which binary a launch will use.
            RowLayout {
              Layout.fillWidth: true
              visible: root.backend === "llamacpp" && root.llamaBuilds.length > 1
              spacing: Style.space(4)

              Text {
                text: "Build"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
              Dropdown {
                Layout.fillWidth: true
                label: "Build"
                showLabel: false
                options: [{ value: "", label: "Auto · " + Backends.buildLabel(root.autoBuild) }]
                  .concat(root.llamaBuilds.map(function(b) {
                    return { value: b.path, label: Backends.buildLabel(b) }
                  }))
                value: Backends.findBuild(root.llamaBuilds, root.llamaBuild) ? root.llamaBuild : ""
                onChanged: function(v) { root.llamaBuild = v }
              }
              Button {
                text: "⟳"
                tooltipText: buildsProbe.running ? "Detecting…" : "Detect llama.cpp builds again"
                enabled: !buildsProbe.running
                onClicked: root.probeBuilds()
              }
            }

            Text {
              Layout.fillWidth: true
              visible: root.backend === "llamacpp" && root.llamaBuilds.length === 1
              text: "Build: " + Backends.buildLabel(root.llamaBuilds[0])
              color: root.bar.foreground
              opacity: 0.6
              elide: Text.ElideRight
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              Layout.fillWidth: true
              visible: root.running && root.runningModel !== "" &&
                       root.selectedModel !== root.runningModel &&
                       Backends.supports(root.backend, "slotKv")
              text: "Running " + Model.baseName(root.runningModel) + " — press Restart to load this one."
              color: root.bar.foreground
              opacity: 0.6
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              Layout.fillWidth: true
              text: {
                if (root.scanning) return "Scanning…"
                var n = root.modelOptions.length
                if (n === 0) {
                  return root.backend === "ollama"
                    ? "No models pulled. Run: ollama pull <model>"
                    : "No .gguf files found. Set a models directory in plugin settings."
                }
                return n + " model" + (n === 1 ? "" : "s") + " available"
              }
              color: root.bar.foreground
              opacity: 0.65
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              Layout.fillWidth: true
              visible: root.selectedModel !== ""
              text: root.selectedModel
              color: root.bar.foreground
              opacity: 0.5
              wrapMode: Text.WrapAnywhere
              maximumLineCount: 3
              elide: Text.ElideRight
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Item { Layout.fillHeight: true }

            // What this machine can carry with the model above loaded. It
            // belongs here rather than on Tuning or Server: every number in it
            // is computed from the selected model's attention geometry, so it
            // changes with the pick made on this page and says nothing useful
            // until one is made.
            Text {
              Layout.fillWidth: true
              text: {
                if (!root.suggestions) return "Detecting hardware…"
                var s = "Suggested: ngl " + root.suggestions.gpuLayers +
                        " · ctx " + root.suggestions.contextSize +
                        " · " + root.suggestions.threads + " threads"
                if (root.selectedModel === "" || !root.selectedGeometry)
                  s += "  (estimated — pick a model to size it exactly)"
                else if (root.running || root.starting)
                  s += "  (applies on next start)"
                return s
              }
              color: root.bar.foreground
              opacity: 0.6
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Button {
              Layout.fillWidth: true
              text: "Apply detected defaults"
              tooltipText: "Replace the tuning values with the ones suggested above"
              enabled: root.suggestions !== null
              onClicked: resetConfirm.opened = true
            }
          }

          // Tuning ------------------------------------------------------
          ColumnLayout {
            anchors.fill: parent
            spacing: Style.space(6)
            visible: root.currentPage === 2

            // Whose values these are. Without it the page is ambiguous the
            // moment two models are tuned differently: the same controls show
            // different numbers depending on a selection made on another page.
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Text {
                Layout.fillWidth: true
                text: {
                  if (root.selectedModel === "")
                    return "Shared defaults — no model selected"
                  var name = Model.baseName(root.selectedModel).replace(/\.gguf$/i, "")
                  if (root.hasProfile) return "Profile · " + name
                  return "Defaults · " + name + " (edit to give it its own)"
                }
                color: root.bar.foreground
                opacity: root.hasProfile ? 0.85 : 0.55
                elide: Text.ElideMiddle
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                HoverHandler { id: profileHover }
                PanelToolTip {
                  visible: profileHover.hovered
                  text: root.selectedModel === ""
                    ? "These values seed the next model that gets a profile."
                    : (root.hasProfile
                       ? "This model has its own tuning. Changes here apply to it alone."
                       : "This model is running on the shared defaults. The first change you make here starts a profile for it, leaving other models untouched.")
                }
              }

              // Only where there is a profile to drop: an always-present button
              // that does nothing most of the time reads as broken.
              Button {
                visible: root.hasProfile
                text: "Reset"
                tooltipText: "Drop this model's profile and go back to the shared defaults"
                onClicked: clearProfileConfirm.opened = true
              }

              Button {
                visible: root.selectedModel !== ""
                text: "Set default"
                tooltipText: "Make these values the seed for models that have no profile yet. Existing profiles are left alone."
                onClicked: root.saveAsDefaultTuning()
              }
            }

            // Sub-tabs: the built-in controls sit on the first page, and
            // added parameters flow onto further ones rather than making the
            // page scroll. A page holds few enough rows that an enum's popup
            // still has room to open downward.
            ButtonGroup {
              Layout.fillWidth: true
              visible: root.tuningPageCount > 1
              options: root.tuningPageLabels
              value: root.tuningPageLabels[root.effectiveTuningPage]
              onChanged: function(v) { root.tuningPage = root.tuningPageLabels.indexOf(v) }
            }

            // Above the rows, not under them. SearchableDropdown opens its
            // popup downward from the trigger with no flip-up fallback and
            // asks for 220px of it, so the picker sitting at the end of a full
            // parameter list opened straight past the panel's bottom edge --
            // the same clipping the row order at the top of this page is
            // arranged to avoid, in the one control that most needs the room.
            Button {
              Layout.fillWidth: true
              visible: !addParamOpen
              // "Reading parameters…" only while there is nothing to offer:
              // a removed row can be restored without any catalogue at all,
              // and a refresh in the background should not disable the button.
              text: root.catalogueLoading && root.addableCount === 0
                ? "Reading parameters…"
                : "+  Add parameter" + (root.addableCount > 0 ? "  (" + root.addableCount + ")" : "")
              enabled: root.addableCount > 0
              onClicked: addParamOpen = true
            }

            // Replaces the button in place while choosing, so the rows below
            // do not shift.
            RowLayout {
              Layout.fillWidth: true
              visible: addParamOpen
              spacing: Style.space(4)

              SearchableDropdown {
                Layout.fillWidth: true
                showLabel: false
                placeholderText: "Search parameters…"
                emptyText: "No matching parameter"
                triggerLabel: "Select a parameter"
                options: root.addableOptions
                value: ""
                onChanged: function(v) {
                  addParamOpen = false
                  // A built-in row is restored, not added: it has its own
                  // property and its own control, and appending it to
                  // customParams would pass its flag twice.
                  if (String(v).indexOf("builtin:") === 0) {
                    var restored = String(v).slice("builtin:".length)
                    root.restoreBuiltin(restored)
                    // Built-in rows keep their order, so a restored one lands
                    // wherever that order puts it -- which is no longer always
                    // the first page.
                    root.tuningPage = root.tuningPageOfBuiltin(restored)
                    return
                  }
                  root.addCustomParam(v)
                  root.tuningPage = root.tuningPageOfParam(v)
                }
              }

              Button {
                text: "×"
                tooltipText: "Cancel"
                onClicked: addParamOpen = false
              }
            }

            GridLayout {
              Layout.fillWidth: true
              visible: root.tuningPageHasBuiltins
              columns: 2
              columnSpacing: Style.space(8)
              rowSpacing: Style.space(6)
              // Left editable while a server runs: these are launch flags, so
              // changing one only affects the next start, and the value is
              // persisted either way. The note below says so.
              //
              // Dropdown rows come first deliberately. Ui/Dropdown opens its
              // popup downward from the trigger with no flip-up fallback, so a
              // dropdown low on the page opens past the panel's bottom edge and
              // is clipped -- which reads as the control being dead. The
              // popup-less text fields are safe lower down.

              Text {
                text: "KV cache k/v"
                visible: root.builtinOnPage("cacheType")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                HoverHandler { id: cacheTypeHover }
                PanelToolTip {
                  visible: cacheTypeHover.hovered
                  text: "--cache-type-k / --cache-type-v — quantization of the K and V caches. Lower than f16 trades some accuracy for less VRAM per token of context."
                }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: root.builtinOnPage("cacheType")
                spacing: Style.space(4)
                Dropdown {
                  Layout.fillWidth: true
                  showLabel: false
                  options: root.availableCacheTypes
                  value: root.cacheTypeK
                  onChanged: function(v) { root.cacheTypeK = v }
                }
                Dropdown {
                  Layout.fillWidth: true
                  showLabel: false
                  options: root.availableCacheTypes
                  value: root.cacheTypeV
                  onChanged: function(v) { root.cacheTypeV = v }
                }
                Button {
                  text: "\u00d7"
                  tooltipText: "Remove this row — \"Add parameter\" brings it back with this value"
                  onClicked: root.removeBuiltin("cacheType")
                }
              }

              Text {
                text: "Flash attn"
                visible: root.builtinOnPage("flashAttn")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                HoverHandler { id: flashAttnHover }
                PanelToolTip {
                  visible: flashAttnHover.hovered
                  text: "--flash-attn — fused attention kernel. Faster and lighter on VRAM; auto leaves the backend to decide, off falls back to the unfused path."
                }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: root.builtinOnPage("flashAttn")
                spacing: Style.space(4)
                Dropdown {
                  Layout.fillWidth: true
                  showLabel: false
                  options: root.flashAttnValues
                  value: root.flashAttn
                  onChanged: function(v) { root.flashAttn = v }
                }
                Button {
                  text: "\u00d7"
                  tooltipText: "Remove this row — \"Add parameter\" brings it back with this value"
                  onClicked: root.removeBuiltin("flashAttn")
                }
              }

              Text {
                text: "GPU layers"
                visible: root.builtinOnPage("ngl")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                HoverHandler { id: nglHover }
                PanelToolTip {
                  visible: nglHover.hovered
                  text: "--n-gpu-layers — how many layers to offload to the GPU. -1 offloads every layer the backend can fit; 0 keeps the whole model on CPU."
                }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: root.builtinOnPage("ngl")
                spacing: Style.space(4)
                NumField {
                  Layout.fillWidth: true
                  text: root.gpuLayers
                  // Typing severs the declarative `text` binding, so the field
                  // would keep showing a stale value after the source changes
                  // elsewhere (a backend switch, applying detected defaults).
                  // Restored whenever the field is not being edited.
                  Binding on text {
                    value: root.gpuLayers
                    when: !activeFocus
                    restoreMode: Binding.RestoreNone
                  }
                  validator: IntValidator { bottom: -1; top: 999 }
                  onEditingFinished: root.gpuLayers = text
                }
                Button {
                  text: "\u00d7"
                  tooltipText: "Remove this row — \"Add parameter\" brings it back with this value"
                  onClicked: root.removeBuiltin("ngl")
                }
              }

              // MoE offload. Sparse models put most of their weights in expert
              // tensors, so moving those to system RAM is what makes a model
              // larger than VRAM run at all -- and it is the single setting the
              // context suggestion swings on. The two flags it drives are
              // mutually exclusive in llama.cpp (buildLlamaArgs lets the count
              // win), so the count field and the All button clear each other
              // rather than leaving a state the launch line ignores.
              Text {
                text: "MoE on CPU"
                visible: root.builtinOnPage("cpuMoe")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                HoverHandler { id: moeHover }
                PanelToolTip {
                  visible: moeHover.hovered
                  text: "--n-cpu-moe N — keep the first N layers' experts in system RAM\n" +
                        "All — --cpu-moe, every layer's experts on CPU\n" +
                        "Empty and All off — neither flag is passed"
                }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: root.builtinOnPage("cpuMoe")
                spacing: Style.space(4)
                NumField {
                  Layout.fillWidth: true
                  // A count is meaningless while All is on, and typing one
                  // there would silently override the button.
                  enabled: !root.cpuMoe
                  placeholderText: root.cpuMoe ? "all layers" : "off"
                  text: root.nCpuMoe
                  // Typing severs the declarative `text` binding, so the field
                  // would keep showing a stale value after the source changes
                  // elsewhere (a backend switch, applying detected defaults).
                  // Restored whenever the field is not being edited.
                  Binding on text {
                    value: root.nCpuMoe
                    when: !activeFocus
                    restoreMode: Binding.RestoreNone
                  }
                  validator: IntValidator { bottom: 0; top: 999 }
                  onEditingFinished: root.nCpuMoe = text
                }
                Button {
                  text: "All"
                  active: root.cpuMoe
                  tooltipText: "Offload every layer's experts to CPU (--cpu-moe)"
                  onClicked: {
                    root.cpuMoe = !root.cpuMoe
                    if (root.cpuMoe) root.nCpuMoe = ""
                  }
                }
                Button {
                  text: "\u00d7"
                  tooltipText: "Remove this row — \"Add parameter\" brings it back with this value"
                  onClicked: root.removeBuiltin("cpuMoe")
                }
              }

              Text {
                text: "Context"
                visible: root.builtinOnPage("ctxSize")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                HoverHandler { id: ctxSizeHover }
                PanelToolTip {
                  visible: ctxSizeHover.hovered
                  text: "--ctx-size — the context window in tokens, shared across every slot. 0 uses the model's own trained context."
                }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: root.builtinOnPage("ctxSize")
                spacing: Style.space(4)
                NumField {
                  Layout.fillWidth: true
                  text: root.contextSize
                  // Typing severs the declarative `text` binding, so the field
                  // would keep showing a stale value after the source changes
                  // elsewhere (a backend switch, applying detected defaults).
                  // Restored whenever the field is not being edited.
                  Binding on text {
                    value: root.contextSize
                    when: !activeFocus
                    restoreMode: Binding.RestoreNone
                  }
                  validator: IntValidator { bottom: 0; top: 10000000 }
                  onEditingFinished: root.contextSize = text
                }
                Button {
                  text: "\u00d7"
                  tooltipText: "Remove this row — \"Add parameter\" brings it back with this value"
                  onClicked: root.removeBuiltin("ctxSize")
                }
              }

              Text {
                text: "Threads"
                // Hidden on backends with no thread control: ollama exposes no
                // such variable, so the field would only look configurable.
                visible: root.builtinOnPage("threads")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                HoverHandler { id: threadsHover }
                PanelToolTip {
                  visible: threadsHover.hovered
                  text: "--threads — CPU threads for generation. Only matters for work not offloaded to the GPU, so it does little on a fully-offloaded model."
                }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: root.builtinOnPage("threads")
                spacing: Style.space(4)
                NumField {
                  Layout.fillWidth: true
                  text: root.threads
                  // Typing severs the declarative `text` binding, so the field
                  // would keep showing a stale value after the source changes
                  // elsewhere (a backend switch, applying detected defaults).
                  // Restored whenever the field is not being edited.
                  Binding on text {
                    value: root.threads
                    when: !activeFocus
                    restoreMode: Binding.RestoreNone
                  }
                  validator: IntValidator { bottom: 0; top: 512 }
                  onEditingFinished: root.threads = text
                }
                Button {
                  text: "\u00d7"
                  tooltipText: "Remove this row — \"Add parameter\" brings it back with this value"
                  onClicked: root.removeBuiltin("threads")
                }
              }

              Text {
                text: "Batch / ubatch"
                visible: root.builtinOnPage("batchSize")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                HoverHandler { id: batchSizeHover }
                PanelToolTip {
                  visible: batchSizeHover.hovered
                  text: "--batch-size / --ubatch-size — tokens processed per prompt-eval pass and per physical GPU batch. Higher trades VRAM for faster prompt processing."
                }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: root.builtinOnPage("batchSize")
                spacing: Style.space(4)
                NumField {
                  Layout.fillWidth: true
                  text: root.batchSize
                  // Typing severs the declarative `text` binding, so the field
                  // would keep showing a stale value after the source changes
                  // elsewhere (a backend switch, applying detected defaults).
                  // Restored whenever the field is not being edited.
                  Binding on text {
                    value: root.batchSize
                    when: !activeFocus
                    restoreMode: Binding.RestoreNone
                  }
                  validator: IntValidator { bottom: 0; top: 1000000 }
                  onEditingFinished: root.batchSize = text
                }
                NumField {
                  Layout.fillWidth: true
                  text: root.ubatchSize
                  // Typing severs the declarative `text` binding, so the field
                  // would keep showing a stale value after the source changes
                  // elsewhere (a backend switch, applying detected defaults).
                  // Restored whenever the field is not being edited.
                  Binding on text {
                    value: root.ubatchSize
                    when: !activeFocus
                    restoreMode: Binding.RestoreNone
                  }
                  validator: IntValidator { bottom: 0; top: 1000000 }
                  onEditingFinished: root.ubatchSize = text
                }
                Button {
                  text: "\u00d7"
                  tooltipText: "Remove this row — \"Add parameter\" brings it back with this value"
                  onClicked: root.removeBuiltin("batchSize")
                }
              }

              // ---- Optional rows ----
              //
              // Absent until asked for, or until the plugin is about to act on
              // one by itself. Placed after the always-on rows so adding one
              // never reshuffles the controls above it.

              Text {
                text: "Slots (-np)"
                visible: root.builtinOnPage("parallel")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                HoverHandler { id: parallelHover }
                PanelToolTip {
                  visible: parallelHover.hovered
                  text: "Number of server slots. Blank leaves the backend on auto.\nEach slot holds its own KV cache, so the context above is divided between them."
                }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: root.builtinOnPage("parallel")
                spacing: Style.space(6)

                NumField {
                  Layout.fillWidth: true
                  text: root.parallel
                  placeholderText: "auto"
                  Binding on text {
                    value: root.parallel
                    when: !activeFocus
                    restoreMode: Binding.RestoreNone
                  }
                  validator: IntValidator { bottom: 0; top: 256 }
                  onEditingFinished: root.parallel = text
                }
                Button {
                  text: "\u00d7"
                  tooltipText: "Remove this row — the backend goes back to deciding for itself"
                  onClicked: root.removeBuiltin("parallel")
                }
              }

              Text {
                text: "Reasoning trace"
                visible: root.builtinOnPage("reasoning")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                HoverHandler { id: reasoningHover }
                PanelToolTip {
                  visible: reasoningHover.hovered
                  text: "--reasoning-preserve: keep the thinking trace across the whole history rather than only the last reply.\n\"default\" passes neither the flag nor its negation, leaving the chat template's own choice — which is the only safe setting for a template that does not support it."
                }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: root.builtinOnPage("reasoning")
                spacing: Style.space(6)

                Dropdown {
                  Layout.fillWidth: true
                  showLabel: false
                  options: root.tristateValues
                  value: root.reasoningPreserve
                  onChanged: function(v) { root.reasoningPreserve = v }
                }
                Button {
                  text: "\u00d7"
                  tooltipText: "Remove this row"
                  onClicked: root.removeBuiltin("reasoning")
                }
              }

              Text {
                text: "Speculative"
                visible: root.builtinOnPage("specType")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                HoverHandler { id: specHover }
                PanelToolTip {
                  visible: specHover.hovered
                  text: root.specType !== "none" && !root.specTypeUserSet
                    ? "--spec-type, picked from this model's own metadata. Change it and the pick stops being automatic."
                    : "--spec-type: draft or n-gram strategy. Only some models carry the weights a draft mode needs."
                }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: root.builtinOnPage("specType")
                spacing: Style.space(6)

                SearchableDropdown {
                  Layout.fillWidth: true
                  showLabel: false
                  options: root.specTypeValues
                  value: root.specType
                  triggerLabel: root.specType
                  onChanged: function(v) {
                    root.specType = v
                    // Choosing here ends the automatic pick: the next MTP model
                    // selected must not quietly overwrite a deliberate choice.
                    root.specTypeUserSet = true
                  }
                }
                Button {
                  text: "\u00d7"
                  tooltipText: "Remove this row"
                  onClicked: root.removeBuiltin("specType")
                }
              }

              Text {
                text: "Vision projector"
                visible: root.builtinOnPage("vision")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                HoverHandler { id: visionHover }
                PanelToolTip {
                  visible: visionHover.hovered
                  text: root.detectedMmproj !== ""
                    ? "Found next to this model:\n" + root.detectedMmproj +
                      "\n\nauto: use it · off: --no-mmproj · custom: name another file"
                    : "auto: use a projector found next to the model — none was\noff: --no-mmproj · custom: name a file"
                }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: root.builtinOnPage("vision")
                spacing: Style.space(6)

                Dropdown {
                  Layout.preferredWidth: Style.space(78)
                  showLabel: false
                  options: root.mmprojModes
                  value: root.mmprojMode
                  onChanged: function(v) { root.mmprojMode = v }
                }
                // Offload is only a question while a projector is in play, so
                // it dims rather than disappearing -- a control that vanishes
                // reads as a bug, one that greys out reads as "not yet".
                Text {
                  text: "offload"
                  color: root.bar.foreground
                  opacity: root.mmprojActive ? 0.65 : 0.3
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Dropdown {
                  Layout.fillWidth: true
                  enabled: root.mmprojActive
                  opacity: root.mmprojActive ? 1 : 0.4
                  showLabel: false
                  options: root.tristateValues
                  value: root.mmprojOffload
                  onChanged: function(v) { root.mmprojOffload = v }
                }
                Button {
                  text: "\u00d7"
                  tooltipText: "Remove this row"
                  onClicked: root.removeBuiltin("vision")
                }
              }

              Text {
                text: "Paste args"
                visible: root.builtinOnPage("extraArgs")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                HoverHandler { id: extraHover }
                PanelToolTip {
                  visible: extraHover.hovered
                  text: "Paste a command line here and it splits into rows — one per flag, filling the controls above where a flag has one.\nThe field empties as it is consumed; it stores nothing of its own."
                }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: root.builtinOnPage("extraArgs")
                spacing: Style.space(6)

                TextField {
                  Layout.fillWidth: true
                  text: root.extraArgs
                  placeholderText: "-np 1 --reasoning-preserve …"
                  Binding on text {
                    value: root.extraArgs
                    when: !activeFocus
                    restoreMode: Binding.RestoreNone
                  }
                  onEditingFinished: root.extraArgs = text
                }
                Button {
                  text: "\u00d7"
                  tooltipText: "Remove this row — and anything left unsplit in it"
                  onClicked: root.removeBuiltin("extraArgs")
                }
              }

              Text {
                text: "Environment"
                visible: root.builtinOnPage("envVars")
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                HoverHandler { id: envHover }
                PanelToolTip {
                  visible: envHover.hovered
                  text: "Environment for the server, NAME=value separated by spaces — for settings llama.cpp only reads from the environment, such as GGML_OP_OFFLOAD_MIN_BATCH.\nPer model, like the rest of this page."
                }
              }
              RowLayout {
                Layout.fillWidth: true
                visible: root.builtinOnPage("envVars")
                spacing: Style.space(6)

                TextField {
                  Layout.fillWidth: true
                  text: root.extraEnv
                  placeholderText: "GGML_OP_OFFLOAD_MIN_BATCH=1024 …"
                  Binding on text {
                    value: root.extraEnv
                    when: !activeFocus
                    restoreMode: Binding.RestoreNone
                  }
                  onEditingFinished: root.extraEnv = text.trim()
                }
                Button {
                  text: "\u00d7"
                  tooltipText: "Remove this row and its variables"
                  onClicked: root.removeBuiltin("envVars")
                }
              }

              // The path gets its own full-width row: a projector path is far
              // too long to share one with two dropdowns.
              Item {
                visible: root.builtinOnPage("vision") && root.mmprojMode === "custom"
                Layout.preferredWidth: 1
                Layout.preferredHeight: 1
              }
              TextField {
                Layout.fillWidth: true
                visible: root.builtinOnPage("vision") && root.mmprojMode === "custom"
                text: root.mmprojPath
                placeholderText: "path to mmproj-*.gguf"
                Binding on text {
                  value: root.mmprojPath
                  when: !activeFocus
                  restoreMode: Binding.RestoreNone
                }
                onEditingFinished: root.mmprojPath = text
              }

            }

            // Added parameters for this sub-page, one row each.
            Repeater {
              model: root.customParamsForPage(root.effectiveTuningPage)

              RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: Style.space(6)

                readonly property var spec: Params.find(root.paramCatalogue, modelData.key)
                readonly property string ptype: spec
                  ? spec.type
                  : (modelData.type ? modelData.type : "string")
                readonly property bool longOptionList: spec && spec.options.length > 12

                Text {
                  Layout.preferredWidth: Style.space(96)
                  text: spec ? spec.label : modelData.key
                  color: root.bar.foreground
                  elide: Text.ElideRight
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  // The full flag and its help text, since the label alone is
                  // rarely enough to remember what a flag does.
                  HoverHandler { id: labelHover }
                  PanelToolTip {
                    visible: labelHover.hovered
                    text: modelData.key + (spec && spec.description ? "\n" + spec.description : "")
                  }
                }

                // Booleans are presence-only flags, so the control is on/off.
                Toggle {
                  visible: ptype === "bool"
                  checked: modelData.value === "true"
                  onClicked: root.setCustomParam(modelData.key, modelData.value === "true" ? "false" : "true")
                }

                // Enums are chosen, never typed: the value has to be one the
                // backend accepts, and a typo here only surfaces as a server
                // that refuses to start.
                Dropdown {
                  Layout.fillWidth: true
                  visible: (ptype === "enum" || ptype === "tristate") && !parent.longOptionList
                  showLabel: false
                  options: spec ? spec.options : []
                  value: modelData.value
                  onChanged: function(v) { root.setCustomParam(modelData.key, v) }
                }

                // Past a dozen entries a plain dropdown is a wall to scroll --
                // --cache-type-k offers 17 quant types -- so the same choice is
                // offered with a filter box. Still a closed set: the field
                // searches the options, it does not accept a new value.
                SearchableDropdown {
                  Layout.fillWidth: true
                  visible: ptype === "enum" && parent.longOptionList
                  options: spec ? spec.options : []
                  value: modelData.value
                  triggerLabel: modelData.value
                  onChanged: function(v) { root.setCustomParam(modelData.key, v) }
                }

                TextField {
                  Layout.fillWidth: true
                  visible: ptype !== "bool" && ptype !== "enum" && ptype !== "tristate"
                  text: modelData.value
                  // Typing severs the declarative `text` binding, so the field
                  // would keep showing a stale value after the source changes
                  // elsewhere (a backend switch, applying detected defaults).
                  // Restored whenever the field is not being edited.
                  Binding on text {
                    value: modelData.value
                    when: !activeFocus
                    restoreMode: Binding.RestoreNone
                  }
                  onEditingFinished: root.setCustomParam(modelData.key, text)
                }

                Button {
                  text: "×"
                  tooltipText: "Remove " + modelData.key
                  onClicked: root.removeCustomParam(modelData.key)
                }
              }
            }


            // What the splitter could not attribute to a flag. Still passed
            // verbatim at launch, so it has to be visible: a stray token that
            // reaches the server unannounced is the invisible state splitting
            // was meant to end.
            Text {
              Layout.fillWidth: true
              visible: root.effectiveTuningPage === 0 &&
                       String(root.extraArgs).trim() !== "" && root.paramCatalogue.length > 0
              text: "Not recognised as flags, passed through as typed: " + root.extraArgs
              color: root.bar.foreground
              opacity: 0.7
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            // Unlike stray args, these are dropped: a token that is not
            // NAME=value has no safe meaning in front of the server command.
            Text {
              Layout.fillWidth: true
              visible: root.builtinOnPage("envVars") && root.parsedEnv.invalid.length > 0
              text: "Ignored in Environment (not NAME=value): " + root.parsedEnv.invalid.join(" ")
              color: root.bar.urgent
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            // Footer: the parameter list takes the rest of the page. The
            // suggestion line and the button that applies it live on Model,
            // next to the pick they are computed from -- a full first page of
            // controls left no room for them here, and they overlapped the
            // panel's log button.
            Item { Layout.fillHeight: true }


          }

          // Stats -------------------------------------------------------
          ColumnLayout {
            anchors.fill: parent
            spacing: Style.space(6)
            visible: root.currentPage === 3

            GridLayout {
              Layout.fillWidth: true
              columns: 2
              columnSpacing: Style.space(8)
              rowSpacing: Style.space(4)

              Text {
                text: "Prompt (pp)"
                color: root.bar.foreground
                opacity: 0.65
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                Layout.fillWidth: true
                text: root.ppTokensPerSec > 0
                  ? root.ppTokensPerSec.toFixed(1) + " t/s" + (root.ppActive ? "  (" + root.ppPercent.toFixed(0) + "%)" : "")
                  : "—"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                text: "Generation (tg)"
                color: root.bar.foreground
                opacity: 0.65
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                Layout.fillWidth: true
                text: root.tokensPerSec > 0 ? root.tokensPerSec.toFixed(1) + " t/s" : "—"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                text: "Endpoint"
                color: root.bar.foreground
                opacity: 0.65
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                Layout.fillWidth: true
                text: root.host + ":" + root.port
                color: root.bar.foreground
                elide: Text.ElideRight
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                text: "Loaded"
                visible: root.loadedModelInfo !== ""
                color: root.bar.foreground
                opacity: 0.65
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                Layout.fillWidth: true
                visible: root.loadedModelInfo !== ""
                text: root.loadedModelInfo
                color: root.bar.foreground
                elide: Text.ElideRight
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            PanelSeparator { Layout.fillWidth: true }

            Text {
              Layout.fillWidth: true
              text: root.hardwareSummary !== "" ? root.hardwareSummary : "Detecting hardware…"
              color: root.bar.foreground
              opacity: 0.6
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              Layout.fillWidth: true
              visible: root.backendSpec.metricsMode === "log"
              text: "ollama reports throughput per completed request; llama.cpp adds a live prompt sweep."
              color: root.bar.foreground
              opacity: 0.5
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Item { Layout.fillHeight: true }
          }
        }

        // ---- Log overlay ----
        // Not one of the category pages: a log is inherently longer than any
        // fixed height, so this is the one place scrolling is appropriate.
        //
        // A live log is read at its bottom edge, so the view follows the tail
        // by default. Scrolling up detaches it -- reading back through a crash
        // must not be yanked away by the next line -- and the jump button
        // reattaches, counting what arrived meanwhile so the cost of staying
        // detached is visible.
        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: root.showingLogs

          ListView {
            id: logView
            anchors.fill: parent
            clip: true
            model: root.logLines
            spacing: 0
            // Cheap for a 400-line cap, and it keeps positionViewAtEnd exact
            // with variable-height wrapped delegates instead of estimated.
            cacheBuffer: 4000

            // Whether the view is following the tail. Set by where the user
            // left the view, not by where the content is.
            property bool stickToBottom: true
            // Lines that arrived while detached; shown on the jump button.
            property int missedLines: 0

            delegate: Text {
              required property var modelData
              width: logView.width
              text: modelData
              color: root.bar.foreground
              opacity: 0.8
              wrapMode: Text.WrapAnywhere
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            // Any user-driven movement decides the mode: released at the
            // bottom means follow, anywhere else means stay put. Covers wheel,
            // drag and scrollbar alike.
            onMovementEnded: {
              logView.stickToBottom = logView.atYEnd
              if (logView.stickToBottom) logView.missedLines = 0
            }

            // Opening the log always starts at the tail -- that is what the
            // user came to read.
            onVisibleChanged: if (visible) {
              stickToBottom = true
              missedLines = 0
              Qt.callLater(positionViewAtEnd)
            }
            Component.onCompleted: Qt.callLater(positionViewAtEnd)
          }

          // logLines is replaced wholesale on every line, and once the 400-line
          // cap is reached the count stops changing, so onCountChanged alone
          // would stop following exactly when the log gets busy.
          Connections {
            target: root
            function onLogLinesChanged() {
              if (logView.stickToBottom) Qt.callLater(logView.positionViewAtEnd)
              else logView.missedLines = Math.min(logView.missedLines + 1, root.logLinesMax)
            }
          }

          // An empty log used to be indistinguishable from a broken one.
          // Say which it is: no journal for this server, or one attached
          // and simply quiet so far.
          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            visible: root.logLines.length === 0
            text: root.logsSource === "none"
                  ? "This server was started outside systemd, so its output is not in any journal. Restart it from here to see its log."
                  : (root.running ? "Waiting for the server to log something…"
                                  : "No log yet -- the server is not running.")
            color: root.bar.foreground
            opacity: 0.5
            wrapMode: Text.WordWrap
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Button {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: Style.space(12)
            anchors.bottomMargin: Style.space(8)
            visible: !logView.stickToBottom && root.logLines.length > 0
            bordered: true
            // Opaque, because it floats over log text it must stay readable
            // against.
            background: Color.background
            fontSize: Style.font.caption
            text: logView.missedLines > 0
                  ? "\u2193 " + logView.missedLines + " new"
                  : "\u2193 Latest"
            tooltipText: "Follow the end of the log again"
            onClicked: {
              logView.stickToBottom = true
              logView.missedLines = 0
              logView.positionViewAtEnd()
            }
          }
        }

        // Shared chrome: reachable from every category, not just Stats.
        // Setup sits here rather than on the Server page, which is already
        // at its row budget and would squeeze a new row to nothing.
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(4)

          Button {
            Layout.fillWidth: true
            text: root.showingLogs ? "Hide log" : "Show log"
            onClicked: root.showingLogs = !root.showingLogs
          }
          Button {
            visible: !root.showingSetup
            text: "Setup…"
            tooltipText: "Walk through backend, models folder and starting tuning again"
            onClicked: root.startSetup()
          }
        }
      }

      ConfirmDialog {
        id: resetConfirm
        message: "Replace tuning values with ones detected for this machine?"
        confirmText: "Apply"
        onConfirmed: root.resetToDetectedDefaults()
      }

      ConfirmDialog {
        id: clearProfileConfirm
        message: "Drop this model's tuning and go back to the shared defaults?"
        confirmText: "Drop"
        onConfirmed: root.clearProfile()
      }
    }
  }
}
