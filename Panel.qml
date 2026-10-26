import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model
import "Backends.js" as Backends
import "Hardware.js" as Hardware
import "Params.js" as Params
import "Profiles.js" as Profiles
import "LlamaSwap.js" as LlamaSwap
import "Migration.js" as Migration

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
  readonly property bool _depsReady: {
    LlamaSwap.setDeps({ Model: Model, Params: Params, Backends: Backends })
    Migration.setDeps({ LS: LlamaSwap, Profiles: Profiles, Backends: Backends })
    return true
  }
  moduleName: "io.github.syjohnm.local-ai-server"
  ipcTarget: "io.github.syjohnm.local-ai-server"

  // Two points above the shell's caption size. The panel is read at a glance
  // from a desk away, and the dotted rows have room to spare.
  readonly property int fontSize: Style.font.caption + 2
  readonly property int fontSizeSmall: Style.font.bodySmall + 2
  readonly property int fontSizeSubtitle: Style.font.subtitle + 2

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
  readonly property string configuredSystemoneBinary: setting("systemoneBinary", "")
  readonly property string configuredSystemoneModelsDir: setting("systemoneModelsDir", "")
  // llama-swap owns the model child processes. Blank means auto-detect; the
  // capability probe fills detectedLlamaSwapBinary in.
  readonly property string configuredLlamaSwapBinary: setting("llamaSwapBinary", "")
  property string detectedLlamaSwapBinary: ""
  readonly property string llamaSwapBinary:
    root.configuredLlamaSwapBinary !== "" ? expandPath(root.configuredLlamaSwapBinary) : root.detectedLlamaSwapBinary
  // Blank means "use the preferred llama-server", the same binary the chat
  // backend runs. A separate build only matters for a fork.
  readonly property string activeSystemoneBinary:
    root.configuredSystemoneBinary !== "" ? expandPath(root.configuredSystemoneBinary) : root.launchLlamaBinary
  // Real path of that binary when the build probe knows it; empty otherwise.
  // Used to notice a build change, since argv[0] is the process marker.
  readonly property string activeSystemoneExe: {
    var b = Backends.findBuild(root.llamaBuilds, root.activeSystemoneBinary)
    return b && b.real ? b.real : ""
  }
  property string systemoneModel: ""
  property var systemoneScannedOptions: []
  property bool systemoneScanning: false
  // Blank means "auto-detect": reuse the main model scan, which already
  // searches the configured/detected model directories. A separate directory
  // is scanned on its own so decision models can live apart from chat models.
  readonly property var systemoneModelOptions:
    root.configuredSystemoneModelsDir !== "" ? root.systemoneScannedOptions : root.modelOptions
  function setSystemoneBinary(v) { root.setWidgetSetting("systemoneBinary", v) }
  function setSystemoneModelsDir(v) { root.setWidgetSetting("systemoneModelsDir", v) }
  function validateSystemoneModel() {
    if (root.systemoneModel === "") return
    // Empty means a scan is in flight or the backend switch just cleared the
    // shared list; do not throw the saved choice away for that.
    if (root.systemoneModelOptions.length === 0) return
    for (var i = 0; i < root.systemoneModelOptions.length; i++)
      if (root.systemoneModelOptions[i].value === root.systemoneModel) return
    root.systemoneModel = ""
  }
  function refreshSystemoneModels() {
    if (root.configuredSystemoneModelsDir === "") {
      root.refreshModels()
      return
    }
    root.systemoneScanning = true
    root.systemoneScanGen++
    systemoneScan.command = ["find", "-L", expandPath(root.configuredSystemoneModelsDir),
      "-maxdepth", String(root.modelScanDepth),
      "(", "-type", "f", "-iname", "*.gguf", "!", "-iname", "*mmproj*", "-printf", "F\t%p\n", ")"]
    systemoneScan.gen = root.systemoneScanGen
    systemoneScan.running = false
    systemoneScan.running = true
  }
  onConfiguredSystemoneModelsDirChanged: {
    root.systemoneScannedOptions = []
    if (root.settingsLoaded) root.refreshSystemoneModels()
  }
  onSystemoneModelOptionsChanged: root.validateSystemoneModel()

  property string detectedLlamaBinary: ""
  property string detectedOllamaBinary: ""
  // Model directories found by the capability probe. Read by the Model page
  // and by model discovery; persisted rather than re-derived every load.
  property var detectedModelDirs: []



  readonly property string llamaBinary: configuredLlamaBinary !== "" ? expandPath(configuredLlamaBinary) : detectedLlamaBinary
  readonly property string ollamaBinary: configuredOllamaBinary !== "" ? expandPath(configuredOllamaBinary) : detectedOllamaBinary
  readonly property string activeBinary: root.backend === "ollama" ? root.ollamaBinary : (root.backend === "systemone" ? root.activeSystemoneBinary : root.launchLlamaBinary)
  // The model the current backend would launch. System One keeps its own
  // selection because the chat model list can point at a different file.
  // The model the active backend would launch.
  //
  // Handlers that run on a selection change must not read `launchModel`: a
  // binding still holds the previous value for the rest of the handler, and is
  // refreshed only after the event loop -- so the profile applied on a switch
  // would be the one belonging to the model just left. This reads the
  // selection properties themselves, which are already updated.
  function currentModel() {
    return root.backend === "systemone" ? root.systemoneModel : root.selectedModel
  }
  readonly property string launchModel: root.currentModel()
  // The Model page follows the backend: same picker, but reading and writing
  // the selection and the directory list of whichever model is launched.
  readonly property var activeModelOptions:
    root.backend === "systemone" ? root.systemoneModelOptions : root.modelOptions
  readonly property var activeSearchDirs:
    root.backend === "systemone" && root.configuredSystemoneModelsDir !== ""
      ? [expandPath(root.configuredSystemoneModelsDir)] : root.searchDirs
  readonly property bool activeScanning:
    root.backend === "systemone" ? root.systemoneScanning : root.scanning
  function selectActiveModel(value) {
    if (root.backend === "systemone") {
      root.systemoneModel = value
      return
    }
    root.selectModel(value)
  }


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
    if (dir === "") dir = expandPath("~/.config/omarchy/plugins/io.github.syjohnm.local-ai-server")
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

  // A launched server outlives this widget: `omarchy restart shell` runs
  // `quickshell kill`, which tears this panel down; with this on, the
  // server is left running and re-adopted by the next instance.
  // Survive restart is always on — no toggle, no setting key.

  // ---- Hardware ----

  property var hardware: null
  readonly property string hardwareSummary: root.hardware ? Hardware.summary(root.hardware) : ""

  // Attention geometry of the selected model, from gguf_probe.py. What one
  // token of KV cache costs depends on it, so the context suggestion is only
  // a real calculation once a model is picked.
  property var modelGeometry: ({})
  // path -> {tools, thinking, mtp} from gguf_probe; reported to hooks so an
  // agent config can describe each served model.
  property var modelCaps: ({})
  readonly property var selectedGeometry: root.modelGeometry[root.launchModel] || null

  // Recomputed as the inputs change, so the suggestion tracks the settings
  // that actually determine what fits -- cache type and MoE offload move it
  // by an order of magnitude on a small card.
  // Suggestion object, recomputed from hardware + geometry + tuning.
  // Used by the Model page and by the Tuning page footer; no longer the
  // seed for "detected defaults" (that mechanism was removed).
  readonly property var suggestion: {
    if (!root.hardware) return null
    return Hardware.suggestAll(root.hardware, {
      geometry: root.selectedGeometry,
      cacheTypeK: root.cacheTypeK,
      cacheTypeV: root.cacheTypeV,
      cpuMoeActive: root.cpuMoe || String(root.nCpuMoe).trim() !== ""
    })
  }

  // ---- Discovered models ----

  property var modelOptions: []
  property var pendingModelFiles: []
  property var visionDirs: ({})
  property var mtpDirs: ({})
  property string selectedModel: ""
  property bool scanning: false
  // Bumped on every scan so a late result cannot overwrite a newer list.
  property int scanGen: 0
  property int systemoneScanGen: 0
  // When the last full model scan ran, so opening the panel does not repeat it.
  property double lastModelScanAt: 0

  // ---- Model picker accordion ----
  //
  // Models are laid out in the folders they live in. `expandedModelDirs`
  // holds the one chain that is open (accordion semantics), so the list stays
  // short however deep the collection is; `modelFilter` switches to a flat
  // result list when the user is searching instead of browsing.
  property var expandedModelDirs: ({})
  property string modelFilter: ""

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
  property string systemoneCtx: "0"

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
    if (root.launchModel === "") return ""
    var found = root.visionDirs[Model.dirName(root.launchModel)]
    return found ? String(found) : ""
  }
  readonly property string resolvedMmproj: {
    if (root.mmprojMode === "off") return ""
    if (root.mmprojMode === "custom") return String(root.mmprojPath).trim()
    return root.detectedMmproj
  }
  readonly property bool mmprojActive: root.resolvedMmproj !== ""

  // The external MTP draft found beside the launched model, if any. Like the
  // projector, it is not a model: the scan maps it by directory and the launch
  // path hands it to llama.cpp as the draft for speculative decoding.
  function mtpDraftFor(model) {
    if (model === "") return ""
    var found = root.mtpDirs[Model.dirName(model)]
    return found ? String(found) : ""
  }
  readonly property string detectedMtp: root.mtpDraftFor(root.launchModel)
  // Loaded only when the spec type will use it -- --model-draft alone loads the
  // draft weights and decodes nothing with them.
  readonly property bool mtpDraftActive: root.detectedMtp !== "" && root.specType === "draft-mtp"

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
  // ollama reads OLLAMA_* variables; a row left over from a llama.cpp profile
  // is not passed. Name it instead of dropping it in envPrefix.
  readonly property var ollamaInvalidParams: {
    var out = []
    if (root.backend !== "ollama") return out
    for (var i = 0; i < root.customParams.length; i++)
      if (!/^OLLAMA_[A-Za-z0-9_]+$/.test(root.customParams[i].key))
        out.push(root.customParams[i].key)
    return out
  }
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
    { id: "envVars",   label: "Environment",     feature: "envVars",   props: ["extraEnv"],  optional: true },
    // System One specific rows — visible only when the backend is systemone
    { id: "systemoneCtx",   label: "System One context", feature: "systemoneCtx", props: ["systemoneCtx"], optional: true }
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
    extraEnv: "",
    systemoneCtx: "0"
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
        // Register flag aliases for supportsFlag (étape 7)
        Backends.registerFlagAliases("--gpu-layers", ["--gpu-layers", "-ngl"])
        Backends.registerFlagAliases("--cache-type-k", ["--cache-type-k", "--ctx-k"])
        Backends.registerFlagAliases("--cache-type-v", ["--cache-type-v", "--ctx-v"])
        Backends.registerFlagAliases("--load-mode", ["--load-mode", "-m"])
        Backends.registerFlagAliases("--mmproj-offload", ["--mmproj-offload"])
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
  // ---- Services ----
  //
  // Three services run side by side: the main llama-swap router, the System
  // One router, and ollama. The panel shows one category at a time, so the
  // runtime properties below stay the active service's live view; the other
  // two keep a snapshot here and are polled from it. Switching category saves
  // the outgoing view and restores the incoming one.
  property var serviceStates: ({})
  property string lastBackend: ""
  // ollama has no config file; its live tuning is set aside here on the way out
  // so switching to a router and back does not replace it.
  property var ollamaTuning: null

  function blankServiceState() {
    return {
      running: false, starting: false, stopping: false, adopted: false, ownsUnit: false,
      loadedModel: "", loadedModelId: "", tokensPerSec: 0,
      ppPercent: 0, ppTokensPerSec: 0, ppActive: false, ppFromLog: false,
      loadedModelInfo: "", lastError: "", healthUrl: "", startingElapsed: 0,
      logsSource: "", rateHistory: []
    }
  }

  function getServiceState(id) {
    var s = root.serviceStates[id]
    return (s && typeof s === "object") ? s : root.blankServiceState()
  }

  function setServiceState(id, patch) {
    var next = {}
    var current = root.getServiceState(id)
    for (var k in current) next[k] = current[k]
    for (var p in patch) next[p] = patch[p]
    var all = {}
    for (var s in root.serviceStates) all[s] = root.serviceStates[s]
    all[id] = next
    root.serviceStates = all
  }

  function activeSnapshot() {
    return {
      running: root.running, starting: root.starting, stopping: root.stopping,
      adopted: root.adopted, ownsUnit: root.ownsUnit,
      loadedModel: root.runningModel, loadedModelId: root.loadedModelId,
      tokensPerSec: root.tokensPerSec, ppPercent: root.ppPercent,
      ppTokensPerSec: root.ppTokensPerSec, ppActive: root.ppActive,
      ppFromLog: root.ppFromLog, loadedModelInfo: root.loadedModelInfo,
      lastError: root.lastError, healthUrl: root.healthUrl,
      startingElapsed: root.startingElapsed, logsSource: root.logsSource,
      rateHistory: root.rateHistory.slice()
    }
  }

  function saveActiveState() {
    if (!root.settingsLoaded) return
    root.setServiceState(root.backend, root.activeSnapshot())
  }

  function restoreActiveState() {
    var s = root.getServiceState(root.backend)
    root.running = s.running
    root.starting = s.starting
    root.stopping = s.stopping
    root.adopted = s.adopted
    root.ownsUnit = s.ownsUnit
    root.runningModel = s.loadedModel
    root.loadedModelId = s.loadedModelId
    root.tokensPerSec = s.tokensPerSec
    root.ppPercent = s.ppPercent
    root.ppTokensPerSec = s.ppTokensPerSec
    root.ppActive = s.ppActive
    root.ppFromLog = s.ppFromLog
    root.loadedModelInfo = s.loadedModelInfo
    root.lastError = s.lastError
    root.healthUrl = s.healthUrl
    root.startingElapsed = s.startingElapsed
    root.logsSource = s.logsSource
    root.rateHistory = s.rateHistory || []
    root.slotsProcessing = 0
    root.slotsBusy = false
  }

  // Every UI path that changes category goes through here, so the outgoing
  // service's numbers are not lost and the incoming one's are not overwritten.
  function setBackend(value) {
    if (value === root.backend) return
    root.saveActiveState()
    if (root.backend === "ollama") root.ollamaTuning = Profiles.snapshot(root)
    root.backend = value
    root.lastBackend = value
    root.restoreActiveState()
  }

  // An adopted server or a distribution unit is not ours to signal. Routers
  // are always ours now; ollama keeps the takeover path.
  readonly property bool canTakeOver: root.running && root.adopted && !root.ownsUnit &&
                                      root.backendSpec.systemUnit !== undefined

  property bool hasSystemdRun: false
  readonly property string unitName: Backends.unitName(root.moduleName, root.backend)

  // Set once the capability probe has reported, so the backend list never acts
  // on binaries that simply are not known yet.
  property bool capabilitiesProbed: false

  // Backends with a binary on this machine; the only ones the Backend
  // dropdown offers.
  readonly property var installedBackends: Backends.installedBackends({
    llamacpp: root.llamaBinary !== "" || root.altBinary !== "" || root.llamaBuilds.length > 0,
    ollama: root.ollamaBinary !== "",
    systemone: root.activeSystemoneBinary !== ""
  }, root.capabilitiesProbed)

  // A saved backend that is not installed here (settings copied from another
  // machine, or ollama since removed) moves to one that is. Never while a
  // server is up -- that server is still the one being watched.
  function ensureInstalledBackend() {
    if (!root.capabilitiesProbed || !root.settingsLoaded) return
    if (root.running || root.starting) return
    var ids = root.installedBackends.map(function(b) { return b.id })
    if (ids.indexOf(root.backend) === -1) root.setBackend(ids[0])
  }

  // Nothing is pending any more: tuning edits write the model's command and
  // reload only that model, so there is no whole-server restart to offer.
  readonly property bool configChanged: false
  readonly property bool switching: false
  readonly property string switchPhase: ""
  property bool slotsBusy: false
  property int slotsProcessing: 0
  property real slotsSeenAtMs: 0
  property string restartPhase: ""
  property int restartIdleTicks: 0
  property bool restartAfterStop: false
  property bool stopAfterAutosave: false
  property var runningArgs: []
  property string runningExe: ""
  property string runningConfigHash: ""

  // ---- Metrics ----

  property real tokensPerSec: 0
  property real ppPercent: 0
  property real ppTokensPerSec: 0
  property bool ppFromLog: false
  property bool ppActive: false
  property var lastDecodeSample: null
  property var lastPromptSample: null
  property bool showMetric: true
  property string loadedModelInfo: ""
  // Recent tg samples for the bar's hover sparkline. Replaced, not mutated,
  // so the Canvas repaints.
  property var rateHistory: []
  function pushRate(value) {
    var next = root.rateHistory.slice()
    next.push(Number(value) || 0)
    if (next.length > 60) next = next.slice(next.length - 60)
    root.rateHistory = next
  }

  // What the router currently has loaded, in the config's ids.
  property string loadedModelId: ""

  property string lastLogLine: ""
  // The log is a ListModel so a new line appends one delegate instead of
  // resetting the whole view. logRevision changes on every append (the count
  // stops changing at the cap) and is what the view follows.
  ListModel { id: logModel }
  property int logRevision: 0
  readonly property int logLinesMax: 400
  // "" not attached yet | "user" transient unit | "system" distribution unit |
  // "none" foreign server whose output no journal holds.
  property string logsSource: ""
  property bool showingLogs: false

  property int currentPage: 0
  readonly property var pageNames: ["Server", "Model", "Tuning"]

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
  // .gguf count per candidate directory, filled when the settings page opens.
  property var modelDirCounts: ({})
  // Waits for detection so the first step never flashes "not installed" for
  // a binary the probe simply has not reported yet.
  readonly property bool showingSetup: root.settingsLoaded && root.capabilitiesProbed &&
                                       !root.setupDone && !root.showingMigration
  // Reuses the setup overlay after first run, so folders and forks can be
  // added later without hand-editing shell.json. Kept separate from
  // `setupDone` so closing settings does not bring first-run setup back.
  property bool showingSettings: false
  // One section open at a time, like the model accordion.
  property string settingsSection: "backend"

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
  // read, and the cap was dropped to five to compensate. The panel is 460 now
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
  // Check if any of a row's flags were ignored this build
  function rowHasIgnoredFlag(id) {
    var row = null
    for (var i = 0; i < root.builtinRows.length; i++) {
      if (root.builtinRows[i].id === id) { row = root.builtinRows[i]; break }
    }
    if (!row) return false
    var rowFlags = []
    for (var j = 0; j < row.props.length; j++) {
      var spec = Params.find(root.paramCatalogue, row.props[j])
      if (spec) rowFlags.push(spec.flag)
    }
    for (var f = 0; f < rowFlags.length; f++)
      if (root.ignoredFlags.indexOf(rowFlags[f]) !== -1) return true
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
  component NumField: TextField {
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
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

  // A plain text action. Tabs, the log controls and the footer use these
  // instead of boxed buttons: the panel is a list of values, and a link reads
  // as an action without adding another rectangle.
  component TextAction: Text {
    id: action

    property bool active: false
    signal clicked()

    color: action.active ? Commons.Color.accent : root.bar.foreground
    opacity: actionMouse.containsMouse ? 1.0 : (action.active ? 1.0 : 0.65)
    font.family: root.bar.fontFamily
    font.pixelSize: root.fontSize

    MouseArea {
      id: actionMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: action.clicked()
    }
  }


  // One row for the llama.cpp fork: Auto or a detected build. Shared by the
  // Server and Model pages so the choice reads and behaves the same in both.
  component BuildPickerRow: Rectangle {
    id: row

    property bool readOnly: false

    Layout.fillWidth: true
    implicitHeight: 26
    visible: root.backend === "llamacpp"
    radius: 3
    color: rowHover.containsMouse && !row.readOnly
      ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
      : "transparent"

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(4)
      anchors.rightMargin: Style.space(4)
      spacing: Style.space(4)

      Text {
        text: "Build"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontSize
        opacity: 0.85
      }

      Text {
        Layout.fillWidth: true
        text: "...................................................................................................."
        color: root.bar.foreground
        opacity: 0.15
        elide: Text.ElideRight
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontSize
      }

      Text {
        Layout.maximumWidth: row.width * 0.6
        text: {
          if (root.llamaBuild !== "") {
            var chosen = Backends.findBuild(root.llamaBuilds, root.llamaBuild)
            return chosen ? Backends.buildLabel(chosen) : Model.baseName(root.llamaBuild)
          }
          return root.autoBuild ? "Auto · " + Backends.buildLabel(root.autoBuild) : "Auto"
        }
        color: root.bar.foreground
        opacity: row.readOnly ? 0.45 : 0.85
        elide: Text.ElideRight
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontSize
      }

      Text {
        text: "v"
        color: root.bar.foreground
        opacity: 0.5
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontSize
      }
    }

    HoverHandler { id: rowHover; cursorShape: row.readOnly ? Qt.ArrowCursor : Qt.PointingHandCursor }
    MouseArea {
      anchors.fill: parent
      cursorShape: row.readOnly ? Qt.ArrowCursor : Qt.PointingHandCursor
      enabled: !row.readOnly
      onClicked: popup.open()
    }
    PanelToolTip {
      visible: rowHover.hovered
      text: row.readOnly
        ? "Stop the server to change the build."
        : "llama.cpp fork and build used for this server. Auto picks one that accepts the model's cache types."
    }

    Popup {
      id: popup
      x: 0
      y: parent.height + 4
      width: row.width
      height: popupCol.implicitHeight + 16
      padding: 8
      background: Rectangle {
        color: Commons.Color.menu.background
        radius: 6
        border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)
        border.width: 1
      }

      ColumnLayout {
        id: popupCol
        width: parent.width
        spacing: 2

        Repeater {
          model: [{ value: "", label: root.autoBuild
                      ? "Auto · " + Backends.buildLabel(root.autoBuild)
                      : "Auto" }]
            .concat(root.llamaBuilds.map(function(b) {
              return { value: b.path, label: Backends.buildLabel(b) }
            }))

          delegate: Rectangle {
            required property var modelData

            readonly property bool chosen: root.llamaBuild === modelData.value ||
              (modelData.value === "" && Backends.findBuild(root.llamaBuilds, root.llamaBuild) === null)

            Layout.fillWidth: true
            implicitHeight: 26
            radius: 3
            color: choiceHover.hovered
              ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
              : "transparent"

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(4)
              anchors.rightMargin: Style.space(4)
              spacing: Style.space(4)

              Text {
                text: "•"
                color: Commons.Color.accent
                visible: parent.parent.chosen
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
              Text {
                Layout.fillWidth: true
                text: modelData.label
                color: parent.parent.chosen ? Commons.Color.accent : root.bar.foreground
                elide: Text.ElideRight
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
            }

            HoverHandler { id: choiceHover; cursorShape: Qt.PointingHandCursor }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.llamaBuild = modelData.value
                popup.close()
              }
            }
          }
        }

        Rectangle {
          Layout.fillWidth: true
          implicitHeight: 1
          color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
        }

        TextAction {
          Layout.fillWidth: true
          text: buildsProbe.running ? "Detecting…" : "Rescan builds"
          onClicked: root.probeBuilds()
        }
      }
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

  // ---- Per-model tuning ----
  //
  // A model's tuning is its `cmd` in the router config. Selecting a model
  // parses that command onto the live properties; editing any of them writes
  // the command back and reloads that model in place. The config is the one
  // store: the old per-model profile object is only read by the migration.
  property bool applyingTuning: false
  property bool configDirty: false
  // Flags this model's build rejected while its command was composed. The
  // Tuning page marks the rows; set here because the config is the launch line.
  property var ignoredFlags: []
  readonly property bool hasProfile: root.managedEntryFor(root.backend, root.launchModel) !== null

  function configViewFor(id) {
    return id === "systemone" ? systemoneConfigFile : mainConfigFile
  }
  function configTextFor(id) {
    if (id !== "llamacpp" && id !== "systemone") return ""
    var view = root.configViewFor(id)
    return view ? String(view.text() || "") : ""
  }
  function setConfigText(id, text) {
    var view = root.configViewFor(id)
    if (!view) return
    view.setText(text)
    root.configRevision++
  }
  function managedInText(text, path) {
    if (path === "") return null
    var parsed = LlamaSwap.parseConfig(String(text || ""))
    for (var i = 0; i < parsed.models.length; i++) {
      var m = parsed.models[i]
      if (m.managedPath === path) return m
    }
    return null
  }
  function foreignInText(text, path) {
    var parsed = LlamaSwap.parseConfig(String(text || ""))
    for (var i = 0; i < parsed.models.length; i++) {
      var m = parsed.models[i]
      if (m.managedPath === "" && m.modelPath === path) return m
    }
    return null
  }
  function managedEntryFor(id, path) {
    return root.managedInText(root.configTextFor(id), path)
  }
  function foreignEntryFor(id, path) {
    return root.foreignInText(root.configTextFor(id), path)
  }
  function envText(list) {
    var out = []
    for (var i = 0; i < (list || []).length; i++) {
      var text = String(list[i])
      var eq = text.indexOf("=")
      var name = eq >= 0 ? text.slice(0, eq) : text
      var value = eq >= 0 ? text.slice(eq + 1) : ""
      out.push(name + "=" + root.shellQuote(value))
    }
    return out.join(" ")
  }
  function buildForTuning(id, tuning) {
    var chosen = String(tuning && tuning.llamaBuild ? tuning.llamaBuild : "")
    if (id === "systemone") {
      if (chosen !== "") {
        var pinned = Backends.findBuild(root.llamaBuilds, chosen)
        return { binary: pinned ? pinned.path : chosen, build: pinned }
      }
      return { binary: root.activeSystemoneBinary,
               build: Backends.findBuild(root.llamaBuilds, root.activeSystemoneBinary) }
    }
    if (chosen !== "") {
      var found = Backends.findBuild(root.llamaBuilds, chosen)
      return { binary: found ? found.path : chosen, build: found }
    }
    var auto = Backends.resolveBuild(root.llamaBuilds, "", tuning.cacheTypeK, tuning.cacheTypeV)
    return { binary: auto ? auto.path : root.llamaBinary, build: auto }
  }
  function cmdForTuning(id, path, tuning) {
    var resolved = root.buildForTuning(id, tuning)
    var command = LlamaSwap.modelCommand(resolved.binary, {
      modelPath: path,
      tuning: tuning,
      build: resolved.build,
      visionDirs: id === "systemone" ? {} : root.visionDirs,
      mtpDirs: id === "systemone" ? {} : root.mtpDirs,
      catalogue: root.paramCatalogue,
      systemone: id === "systemone",
      customParams: tuning.customParams || []
    })
    if (id === root.backend && path === root.currentModel())
      root.ignoredFlags = command.ignored
    return command
  }
  function liveTuning(id) {
    var t = Profiles.snapshot(root)
    if (id === "systemone") t.systemoneCtx = String(root.systemoneCtx)
    return t
  }
  function tuningFromEntry(id, entry) {
    var parsed = LlamaSwap.parseCmd(entry.cmd)
    var t = parsed.tuning
    if (id === "systemone") {
      t.systemoneCtx = String(t.contextSize || "0")
      t.contextSize = "0"
    }
    t.extraEnv = root.envText(entry.env)
    // A cmd has no separate parameter list: unknown flags come back through
    // extraArgs, which is what the Tuning page edits.
    t.customParams = []
    if (parsed.binary !== "") {
      var build = Backends.findBuild(root.llamaBuilds, parsed.binary)
      t.llamaBuild = build ? build.path : ""
    }
    return t
  }

  // A user edit to any tuning value: writes this model's command. The write is
  // debounced, then the model is unloaded and loaded again if it is the one
  // the router has resident.
  function touchTuning() {
    var model = root.currentModel()
    if (!root.settingsLoaded || root.applyingTuning || model === "") return
    if (root.backend === "ollama") {
      root.scheduleSettingsSave()
      return
    }
    if (root.migrationNeeded && !root.migrationDone) return
    root.configDirty = true
    configSaveTimer.restart()
  }

  function applyTuning(values) {
    var resolved = Profiles.resolve(values)
    root.applyingTuning = true
    try {
      for (var i = 0; i < Profiles.FIELDS.length; i++) {
        var f = Profiles.FIELDS[i]
        // Page layout is not per model: the config holds commands, not which
        // rows the user removed, so those stay in settings.
        if (Profiles.STRUCTURED.indexOf(f) !== -1) continue
        root[f] = resolved[f]
      }
      if (root.backend === "systemone")
        root.systemoneCtx = String(resolved.systemoneCtx === undefined ? "0" : resolved.systemoneCtx)
      root.customParams = resolved.customParams || []
      root.tuningPage = 0
      root.addParamOpen = false
      root.sanitizeSettings()
    } finally {
      root.applyingTuning = false
    }
  }

  // Called when the selection changes, including when the model scan replaces
  // a selection that no longer exists.
  function applyTuningForSelection() {
    if (!root.settingsLoaded || root.applyingTuning) return
    var model = root.currentModel()
    if (root.backend === "ollama") {
      // ollama tuning is still flat in settings; keep it across a category
      // switch rather than replacing it with the router's tuning.
      if (root.ollamaTuning !== null) root.applyTuning(root.ollamaTuning)
      return
    }
    if (model === "") {
      root.applyTuning(Profiles.resolve(null))
      return
    }
    // Before the config exists there is nothing to read: an upgrade keeps the
    // flat tuning it loaded until the migration writes the real commands.
    if (root.configTextFor(root.backend).trim() === "" && root.oldSettings !== null) return
    var entry = root.managedEntryFor(root.backend, model)
    root.applyTuning(entry ? root.tuningFromEntry(root.backend, entry) : LlamaSwap.defaults())
    root.splitPastedArgs()
    root.autoSpecType(model)
  }

  // An external MTP draft is a decision the plugin can make for the user: the
  // draft weights are useless until the spec type asks for them. A spec type
  // the user chose themselves always wins.
  function autoSpecType(model) {
    var m = model === undefined ? root.currentModel() : model
    if (root.specTypeUserSet || root.specType === "draft-mtp") return
    // A removed row is a decision too: the draft is not loaded behind it.
    if (root.hiddenBuiltins.indexOf("specType") !== -1) return
    if (root.mtpDraftFor(m) === "") return
    root.specType = "draft-mtp"
  }

  // Drops this model's tuning and goes back to the neutral defaults.
  function clearProfile() {
    if (!root.hasProfile) return
    var id = root.backend
    var model = root.launchModel
    var text = root.configTextFor(id)
    var entry = root.managedEntryFor(id, model)
    var tuning = LlamaSwap.defaults()
    if (id === "systemone") tuning.systemoneCtx = "0"
    var command = root.cmdForTuning(id, model, tuning)
    var written = LlamaSwap.setManagedModel(text, {
      path: model, id: entry ? entry.id : LlamaSwap.modelId(model, {}),
      cmd: command.cmd, env: command.env
    })
    text = LlamaSwap.setPreload(written.text, [written.id])
    root.setConfigText(id, text)
    root.applyTuning(tuning)
    root.reloadLoadedModel()
  }

  // Models this router should carry. The main router takes the whole scan so
  // the picker can load any of them; System One takes only its own directory
  // (or its one picked decision model), never the chat store.
  function scanPathsFor(id) {
    var out = []
    function add(path) {
      var p = String(path || "")
      if (p === "" || out.indexOf(p) !== -1) return
      if (!/\.gguf$/i.test(p)) return
      out.push(p)
    }
    if (id === "llamacpp") {
      for (var i = 0; i < root.modelOptions.length; i++) add(root.modelOptions[i].value)
      add(root.selectedModel)
    } else {
      if (root.configuredSystemoneModelsDir !== "") {
        for (var j = 0; j < root.systemoneModelOptions.length; j++) add(root.systemoneModelOptions[j].value)
      }
      add(root.systemoneModel)
    }
    return out
  }
  function preloadPathFor(id) {
    return String(id === "systemone" ? root.systemoneModel : root.selectedModel)
  }

  // The config with every model this router should serve and the selection in
  // the startup preload list. Existing managed commands are left exactly as
  // they are; only missing models are added.
  function ensureConfig(id) {
    if (id !== "llamacpp" && id !== "systemone") return ""
    var existing = root.configTextFor(id)
    var paths = root.scanPathsFor(id)
    var preload = root.preloadPathFor(id)
    var text = existing
    var used = {}
    var additions = []

    if (text.trim() === "") {
      text = LlamaSwap.createConfig({ startPort: root.serviceStartPort(id) })
    } else {
      var parsed = LlamaSwap.parseConfig(text)
      for (var p = 0; p < parsed.models.length; p++) used[parsed.models[p].id] = true
    }

    for (var i = 0; i < paths.length; i++) {
      var path = paths[i]
      if (root.managedInText(text, path) !== null) continue
      if (root.foreignInText(text, path) !== null) continue
      var tuning = LlamaSwap.defaults()
      if (id === "systemone") tuning.systemoneCtx = "0"
      var command = root.cmdForTuning(id, path, tuning)
      additions.push({
        path: path,
        id: LlamaSwap.modelId(path, used),
        cmd: command.cmd,
        env: command.env
      })
      used[additions[additions.length - 1].id] = true
    }

    if (additions.length > 0) {
      // On a fresh file build the whole list at once so the blank lines land
      // the same way createConfig writes them.
      if (existing.trim() === "") {
        text = LlamaSwap.createConfig({
          startPort: root.serviceStartPort(id),
          models: additions,
          preload: []
        })
      } else {
        for (var a = 0; a < additions.length; a++)
          text = LlamaSwap.setManagedModel(text, additions[a]).text
      }
    }

    var selected = root.managedInText(text, preload)
    if (selected !== null) text = LlamaSwap.setPreload(text, [selected.id])
    if (text !== existing) root.setConfigText(id, text)
    return text
  }

  // Writes the live tuning as this model's command, then queues a reload if
  // the router currently has that model resident.
  function flushConfigTuning() {
    if (!root.configDirty) return
    root.configDirty = false
    var id = root.backend
    if (id === "ollama" || !root.settingsLoaded) return
    var model = root.currentModel()
    if (model === "") return
    var text = root.ensureConfig(id)
    if (root.foreignEntryFor(id, model) !== null) {
      root.lastError = "This model's command is hand-written in " + root.serviceConfigPath(id) +
        "; edit it there instead."
      return
    }
    var entry = root.managedEntryFor(id, model)
    var tuning = root.liveTuning(id)
    var command = root.cmdForTuning(id, model, tuning)
    var written = LlamaSwap.setManagedModel(text, {
      path: model,
      id: entry ? entry.id : LlamaSwap.modelId(model, {}),
      cmd: command.cmd,
      env: command.env
    })
    text = LlamaSwap.setPreload(written.text, [written.id])
    root.setConfigText(id, text)
    if (root.running && root.runningModel === model) configReloadTimer.restart()
  }



  // ---- Settings persistence ----
  // Plain properties survive a hot-reload (Quickshell patches this object in
  // place) but not a real restart, so config is mirrored to disk.
  readonly property string settingsDir: expandPath("~/.local/state/omarchy/io.github.syjohnm.local-ai-server/")
  readonly property string settingsPath: settingsDir + "settings.json"
  property bool settingsLoaded: false

  // llama-swap owns the model command lines. The two routers get one file
  // each so their child-port ranges never collide; ollama keeps no file.
  readonly property string mainConfigPath: settingsDir + "config.yaml"
  readonly property string systemoneConfigPath: settingsDir + "systemone.yaml"
  readonly property string migrationReportPath: settingsDir + "migration-report.txt"
  readonly property string unitDir: expandPath("~/.config/systemd/user/")
  function serviceUnit(id) {
    return id === "ollama" ? Backends.unitName(root.moduleName, "ollama")
         : id === "systemone" ? Backends.unitName(root.moduleName, "systemone")
         : Backends.unitName(root.moduleName, "llamacpp")
  }
  function serviceUnitPath(id) { return root.unitDir + root.serviceUnit(id) + ".service" }
  function serviceConfigPath(id) {
    return id === "systemone" ? root.systemoneConfigPath
         : id === "llamacpp" ? root.mainConfigPath : ""
  }
  function serviceStartPort(id) { return id === "systemone" ? 5900 : 5800 }
  // id -> true. A service with this on is enabled in systemd, so it comes back
  // at login even while the shell is not running.
  property var startOnLogin: ({})
  function loginOn(id) { return root.startOnLogin[id] === true }

  // Bumped whenever a config file is read or written, so bindings that inspect
  // its text (hasProfile, the tuning page) re-evaluate.
  property int configRevision: 0
  property var oldSettings: null
  property bool migrationNeeded: false
  property bool migrationDone: false
  property bool showingMigration: false

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
      if (typeof parsed.systemoneModel === "string") root.systemoneModel = parsed.systemoneModel
      if (typeof parsed.showMetric === "boolean") root.showMetric = parsed.showMetric
      if (typeof parsed.extraArgs === "string") root.extraArgs = parsed.extraArgs
      if (typeof parsed.extraEnv === "string") root.extraEnv = parsed.extraEnv
      if (typeof parsed.llamaBuild === "string") root.llamaBuild = parsed.llamaBuild
      if (typeof parsed.keepAlive === "string") root.keepAlive = parsed.keepAlive
      if (typeof parsed.systemoneCtx === "string") root.systemoneCtx = parsed.systemoneCtx
      if (parsed.startOnLogin && typeof parsed.startOnLogin === "object") {
        var login = {}
        for (var li in parsed.startOnLogin)
          if (Backends.ids().indexOf(li) !== -1 && parsed.startOnLogin[li] === true) login[li] = true
        root.startOnLogin = login
      }

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
    // The old object is kept for the one-shot migration: it carries the flat
    // tuning and the per-model profiles the router configs are built from.
    root.oldSettings = parsed
    root.migrationNeeded = Migration.needsMigration(parsed)
    root.sanitizeSettings()
    root.settingsLoaded = true
    // Configs and units need the detected binaries and builds; afterReady
    // waits for those probes rather than writing paths that are not there.
    root.afterReady()
  }

  readonly property bool readyForConfig:
    root.settingsLoaded && root.capabilitiesProbed && root.buildsProbed
  property bool servicesReady: false
  onReadyForConfigChanged: if (root.readyForConfig) root.afterReady()

  function afterReady() {
    if (!root.readyForConfig) return
    if (root.servicesReady) {
      root.applyTuningForSelection()
      return
    }
    root.servicesReady = true
    mainConfigFile.reload()
    systemoneConfigFile.reload()
    if (root.migrationNeeded && !root.migrationDone) {
      root.prepareMigration()
      return
    }
    root.ensureConfig("llamacpp")
    root.ensureConfig("systemone")
    root.writeUnit("llamacpp")
    root.writeUnit("systemone")
    root.writeUnit("ollama")
    root.applyTuningForSelection()
    root.ensureInstalledBackend()
    if (root.configuredSystemoneModelsDir !== "") root.refreshSystemoneModels()
    servicePollTimer.restart()
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
    if (root.migrationNeeded && !root.migrationDone) return
    settingsFile.setText(JSON.stringify({
      version: 4,
      configVersion: Migration.CONFIG_VERSION,
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
      systemoneModel: root.systemoneModel,
      extraArgs: root.extraArgs, keepAlive: root.keepAlive, extraEnv: root.extraEnv,
      llamaBuild: root.llamaBuild,
      systemoneCtx: root.systemoneCtx,
      startOnLogin: root.startOnLogin,
      hiddenBuiltins: root.hiddenBuiltins, shownOptionals: root.shownOptionals,
      customParams: root.customParams
    }, null, 2) + "\n")
  }

  // Applies the values derived from this machine's actual hardware, replacing
  // whatever was tuned for another one. Leaves host/port/model alone -- those
  // are environment choices, not tuning.
  function resetToDetectedDefaults() {
    var s = root.suggestion || Hardware.suggestAll(root.hardware || {})
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
    root.lastBackend = root.backend
    // A model path means nothing to ollama and a tag means nothing to
    // llama.cpp, so each category keeps its own selection.
    if (root.backend === "ollama") root.selectedModel = ""
    root.ignoredFlags = []
    root.paramCatalogue = []
    root.addParamOpen = false
    root.scheduleSettingsSave()
    root.refreshModels()
    root.refreshCatalogue()
    root.applyTuningForSelection()
    root.refreshServiceStatus()
    if (root.servicesReady) servicePollTimer.restart()
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
    // System One retunes from its own selection, not from the chat model's.
    if (root.backend !== "systemone") {
      root.applyTuningForSelection()
      root.selectPreload()
    }
    root.scheduleSettingsSave()
    if (root.selectedModel !== "") root.revealModel(root.selectedModel)
  }
  onSystemoneModelChanged: {
    if (root.backend === "systemone") {
      root.applyTuningForSelection()
      root.selectPreload()
      if (root.systemoneModel !== "") root.revealModel(root.systemoneModel)
    }
    root.scheduleSettingsSave()
  }
  onSystemoneCtxChanged: root.scheduleSettingsSave()
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
  onStartOnLoginChanged: root.scheduleSettingsSave()

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

  // The two router configs. watchChanges is on so a hand edit shows up in the
  // Tuning page; the plugin itself only ever rewrites marked blocks.
  FileView {
    id: mainConfigFile
    path: root.mainConfigPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: root.configRevision++
  }

  FileView {
    id: systemoneConfigFile
    path: root.systemoneConfigPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: root.configRevision++
  }

  // Units are generated, not edited: writing the same text again is harmless.
  FileView { id: unitMainFile; path: root.serviceUnitPath("llamacpp"); atomicWrites: true; printErrors: false }
  FileView { id: unitSys1File; path: root.serviceUnitPath("systemone"); atomicWrites: true; printErrors: false }
  FileView { id: unitOllamaFile; path: root.serviceUnitPath("ollama"); atomicWrites: true; printErrors: false }
  FileView { id: migrationReportFile; path: root.migrationReportPath; atomicWrites: true; printErrors: false }

  // Tuning edits are debounced into the config; the router needs a moment to
  // notice the watched file before the model is reloaded.
  Timer {
    id: configSaveTimer
    interval: 600
    repeat: false
    onTriggered: root.flushConfigTuning()
  }

  Timer {
    id: configReloadTimer
    interval: 1200
    repeat: false
    onTriggered: root.reloadLoadedModel()
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
    root.setupDone = false
    root.showingSettings = false
    root.settingsSection = "backend"
    root.showingLogs = false
  }

  function openSettings() {
    root.showingSettings = true
    root.settingsSection = "backend"
    root.showingLogs = false
  }

  function closeSettings() {
    root.showingSettings = false
  }

  function finishSetup() {
    root.setupDone = true
    root.showingSettings = false
    root.currentPage = 0
    root.scheduleSettingsSave()
  }

  function skipSetup() {
    root.setupDone = true
    root.showingSettings = false
    root.currentPage = 0
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
      "for d in \"$@\"; do n=$(find -L \"$d\" -maxdepth " + root.modelScanDepth +
      " -type f -iname '*.gguf' ! -iname '*mmproj*' ! -iname '*mtp*' 2>/dev/null | wc -l); " +
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
  onShowingSettingsChanged: if (root.showingSettings) root.countModelDirs()
  onSetupModelDirsChanged: if (root.showingSetup || root.showingSettings) root.countModelDirs()

  // A models folder chosen in setup (or edited in shell.json) lands through
  // settings, not through a call here, so the list follows it.
  onConfiguredModelsDirChanged: if (root.capabilitiesProbed) root.refreshModels()

  // ---- Scripting ----
  //
  // The panel's own open/close/toggle live on the base Panel's handler (target
  // "io.github.syjohnm.local-ai-server"); server control gets its own target so keybindings
  // and scripts can drive it without the panel open:
  //   qs -p /usr/share/omarchy/shell ipc call local-ai-server status
  IpcHandler {
    target: "local-ai-server"

    function start(): void { if (!root.running && !root.starting && !root.stopping) root.startService(root.backend) }
    function stop(): void { if ((root.running || root.starting) && !root.stopping) root.stopService(root.backend) }
    // Reloads the resident model so its config is re-read; starts the service
    // when it is not up.
    function restart(): void {
      if (!root.running) root.startService(root.backend)
      else if (root.loadedModelId !== "") root.reloadLoadedModel()
      else root.loadSelectedModel()
    }
    function model(path: string): void { root.selectActiveModel(path) }
    function page(name: string): void {
      var i = root.pageNames.map(function(n) { return n.toLowerCase() }).indexOf(String(name).toLowerCase())
      if (i === -1) return
      root.currentPage = i
      root.showingLogs = false
      root.showingSettings = false
      root.open()
    }
    function settings(): void { root.openSettings(); root.open() }
    function setup(): void { root.startSetup(); root.open() }
    function migrate(dryRun: bool): string {
      root.prepareMigration()
      if (dryRun) return root.migrationReport
      root.runMigration(false)
      return "Migration started: " + (root.migrationReport !== "" ? root.migrationReport : "running")
    }
    function status(): string {
      return JSON.stringify({
        running: root.running, starting: root.starting, stopping: root.stopping,
        online: root.loginOn(root.backend),
        backend: root.backend, model: root.runningModel, loaded: root.loadedModelId,
        selected: root.launchModel,
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
      "for b in ~/.local/bin/llama-swap /usr/local/bin/llama-swap /usr/bin/llama-swap /opt/llama-swap/llama-swap; do " +
      "  [ -x \"$b\" ] && { echo \"swappath=$b\"; break; }; done; " +
      "command -v llama-swap >/dev/null 2>&1 && echo \"swapcmd=$(command -v llama-swap)\"; " +
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
          else if (key === "swappath" && root.detectedLlamaSwapBinary === "") root.detectedLlamaSwapBinary = value
          else if (key === "swapcmd" && root.detectedLlamaSwapBinary === "") root.detectedLlamaSwapBinary = value
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
    if (root.configuredSystemoneBinary !== "") extra.push(expandPath(root.configuredSystemoneBinary))
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
  onConfiguredSystemoneBinaryChanged: if (root.capabilitiesProbed) root.probeBuilds()

  Process {
    id: hwProbe
    command: ["bash", root.hwProbeScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.hardware = Hardware.parseProbe(text)
    }
  }

  // ---- Model discovery ----

  // Deep enough for LM Studio/Jan layouts, shallow enough that pointing the
  // setting at $HOME does not walk every cache and node_modules on the disk.
  readonly property int modelScanDepth: 8

  readonly property var searchDirs: {
    if (root.configuredModelsDir !== "") return [expandPath(root.configuredModelsDir)]
    return root.detectedModelDirs
  }

  function isUnder(path, dir) {
    var d = String(dir || "").replace(/\/+$/, "")
    if (d === "") return false
    var prefix = d === "/" ? "/" : d + "/"
    return path === d || String(path).indexOf(prefix) === 0
  }

  // Nerd Font glyphs, monochrome and already in the bar font. Anything not
  // listed here (quantisation, size) stays as text.
  function capabilityGlyph(label) {
    switch (label) {
      case "vision": return "\uf06e"
      case "tools": return "\uf0ad"
      case "thinking":
      case "reasoning": return "\uf0eb"
      case "mtp": return "\uf0e7"
      case "shared with ollama": return "\uf1c0"
    }
    return ""
  }

  function modelRootFor(path) {
    var best = ""
    var dirs = root.activeSearchDirs || []
    for (var i = 0; i < dirs.length; i++) {
      var dir = String(dirs[i] || "").replace(/\/+$/, "")
      if (dir === "") dir = "/"
      if (root.isUnder(path, dir) && dir.length > best.length) best = dir
    }
    return best
  }

  // Labels in one pass and returns how many files the subtree holds, so the
  // folder counts cost one walk of the tree rather than one walk per folder.
  function labelModelTree(nodes, byPath, used) {
    var n = 0
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i]
      if (node.type === "file") {
        var opt = byPath[node.path]
        node.label = opt ? opt.label : node.name.replace(/\.gguf$/i, "")
        node.description = opt ? opt.description : ""
        node.mtp = opt ? opt.mtp : false
        used[node.path] = true
        n++
      } else {
        node.count = root.labelModelTree(node.children, byPath, used)
        n += node.count
      }
    }
    return n
  }

  // Rebuilt whenever the scan result changes. Each configured/detected
  // folder becomes a top-level section, so the same relative path under two
  // collections stays distinguishable. Files that are not under any of them
  // (ollama's shared blob store, or ollama's model names) get their own
  // section instead of vanishing.
  function buildPickerTree() {
    var opts = root.activeModelOptions || []
    if (opts.length === 0) return []

    var byPath = {}
    for (var i = 0; i < opts.length; i++) byPath[opts[i].value] = opts[i]

    var used = {}
    var roots = []
    var dirs = root.activeSearchDirs || []
    for (var d = 0; d < dirs.length; d++) {
      var dir = String(dirs[d] || "").replace(/\/+$/, "")
      if (dir === "") dir = "/"
      var files = []
      for (var path in byPath)
        if (root.isUnder(path, dir)) files.push(path)
      if (files.length === 0) continue

      var children = Model.buildModelTree(dir, files, root.modelCaps, root.visionDirs)
      root.labelModelTree(children, byPath, used)
      roots.push({
        type: "dir",
        path: dir,
        name: Model.baseName(dir) !== "" ? Model.baseName(dir) : dir,
        subtitle: dir.replace(Quickshell.env("HOME"), "~"),
        count: files.length,
        children: children
      })
    }

    var loose = []
    for (var p in byPath)
      if (!used[p]) loose.push(p)
    if (loose.length > 0) {
      loose.sort()
      var looseChildren = []
      for (var j = 0; j < loose.length; j++) {
        var opt = byPath[loose[j]]
        looseChildren.push({
          type: "file",
          path: loose[j],
          name: opt.label,
          label: opt.label,
          description: opt.description,
          mtp: opt.mtp,
          children: []
        })
      }
      roots.push({
        type: "dir",
        path: "ollama",
        name: "ollama",
        subtitle: "shared store",
        count: loose.length,
        children: looseChildren
      })
    }
    return roots
  }

  readonly property var modelTree: root.buildPickerTree()
  // Flat list built once per tree, so typing in the search field does not walk
  // the same folders on every keystroke.
  readonly property var modelFilesFlat: Model.collectFiles(root.modelTree)

  // A flat search can match thousands of files; a Repeater would build a
  // delegate for every one. The list is capped and the count says "200+".
  readonly property int modelSearchLimit: 200
  readonly property var modelRows: {
    var q = String(root.modelFilter || "").trim().toLowerCase()
    if (q !== "") {
      var files = root.modelFilesFlat
      var out = []
      for (var i = 0; i < files.length; i++) {
        var node = files[i]
        var hay = (String(node.label || "") + " " + node.path).toLowerCase()
        if (hay.indexOf(q) !== -1) out.push({ node: node, depth: 0, flat: true })
        if (out.length >= root.modelSearchLimit) break
      }
      return out
    }
    return Model.flattenTree(root.modelTree, root.expandedModelDirs)
  }

  readonly property var selectedModelOption: {
    for (var i = 0; i < root.activeModelOptions.length; i++)
      if (root.activeModelOptions[i].value === root.launchModel) return root.activeModelOptions[i]
    return null
  }
  readonly property string selectedModelLabel: root.selectedModelOption
    ? root.selectedModelOption.label
    : ""

  // Keeps one chain open at a time: expanding a folder opens its ancestors
  // and closes every other branch, which is what makes the list readable at
  // any depth without a scrollbar per directory.
  function revealModel(path) {
    var dir = root.modelRootFor(path)
    var map = {}
    if (dir === "") {
      map["ollama"] = true
    } else {
      map[dir] = true
      var chain = Model.ancestorDirs(path, dir)
      for (var i = 0; i < chain.length; i++) map[chain[i]] = true
    }
    root.expandedModelDirs = map
  }

  function toggleModelDir(node) {
    var map = {}
    if (root.expandedModelDirs[node.path] === true) {
      // Collapse just this branch, keeping its ancestors open.
      var dir = root.modelRootFor(node.path)
      if (dir !== "" && node.path !== dir) {
        map[dir] = true
        var chain = Model.ancestorDirs(node.path, dir)
        for (var i = 0; i < chain.length; i++) map[chain[i]] = true
      }
    } else {
      var rootDir = root.modelRootFor(node.path)
      if (rootDir === "") {
        map[node.path] = true
      } else {
        map[rootDir] = true
        var up = Model.ancestorDirs(node.path, rootDir)
        for (var j = 0; j < up.length; j++) map[up[j]] = true
        map[node.path] = true
      }
    }
    root.expandedModelDirs = map
  }

  function refreshModels() {
    root.scanGen++
    root.lastModelScanAt = Date.now()
    // A separate System One directory is the only list its picker shows, so
    // scan that instead of the chat library.
    if (root.backend === "systemone" && root.configuredSystemoneModelsDir !== "") {
      root.refreshSystemoneModels()
      return
    }
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
      ollamaStoreScan.gen = root.scanGen
      ollamaStoreScan.running = false
      ollamaStoreScan.running = true
      return
    }
    if (root.searchDirs.length === 0) {
      root.modelOptions = []
      root.scanning = false
      return
    }
    root.scanning = true
    // -L so symlinked model collections are followed; findings are de-duped
    // by path in buildModelOptions. The depth cap matches the Settings count.
    var cmd = ["find", "-L"].concat(root.searchDirs).concat([
      "-maxdepth", String(root.modelScanDepth),
      "(", "-type", "f", "-iname", "*.gguf", "-printf", "F\t%p\n", ")"
    ])
    treeScan.command = cmd
    treeScan.gen = root.scanGen
    treeScan.running = false
    treeScan.running = true
  }

  Process {
    id: treeScan
    property int gen: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (treeScan.gen !== root.scanGen) return
        var parsed = Model.parseFindOutput(text)
        var split = Model.classifyModelFiles(parsed.files)
        root.pendingModelFiles = split.models
        root.visionDirs = split.visionDirs
        root.mtpDirs = split.mtpDirs
        root.autoSpecType()
        // Resolve ollama's blobs before probing, so both sources go through
        // one gguf_probe pass and land in one list.
        blobScan.command = ["python3", root.blobScript].concat(root.ollamaStoreDirs())
        blobScan.gen = root.scanGen
        blobScan.running = false
        blobScan.running = true
      }
    }
  }

  // System One models are GGUF files like any other; only the directory can
  // differ. Blank uses the main scan (systemoneModelOptions is bound to it).
  Process {
    id: systemoneScan
    property int gen: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (systemoneScan.gen !== root.systemoneScanGen) return
        var parsed = Model.parseFindOutput(text)
        var split = Model.classifyModelFiles(parsed.files)
        var opts = []
        for (var i = 0; i < split.models.length; i++) {
          var p = split.models[i]
          opts.push({ value: p, label: Model.baseName(p).replace(/\.gguf$/i, ""), description: Model.dirName(p) })
        }
        root.systemoneScannedOptions = opts
        root.systemoneScanning = false
        root.validateSystemoneModel()
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
    property int gen: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (blobScan.gen !== root.scanGen) return
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
        probeScan.gen = root.scanGen
        probeScan.running = false
        probeScan.running = true
      }
    }
  }

  Process {
    id: probeScan
    property int gen: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (probeScan.gen !== root.scanGen) return
        var caps = Model.parseProbeCapabilities(text)
        root.modelCaps = caps
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
      // The draft is a file of its own, so "mtp" means either the weights are
      // embedded in this model or a draft sits beside it.
      var hasMtp = !!cap.mtp || !!root.mtpDirs[Model.dirName(path)]
      if (hasMtp) badges.push("mtp")
      // A shared blob is labelled by its ollama name and marked, so it is
      // clear the same file is serving both backends rather than being a
      // second copy.
      var sharedName = blobNames[path]
      if (sharedName) badges.unshift("shared with ollama")

      out.push({
        value: path,
        label: sharedName ? sharedName : name.replace(/\.gguf$/i, ""),
        description: badges.join(" · ") || Model.dirName(path),
        mtp: hasMtp
      })
    }
    return out
  }

  Process {
    id: ollamaStoreScan
    property int gen: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (ollamaStoreScan.gen !== root.scanGen) return
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
        ollamaTags.gen = root.scanGen
        ollamaTags.running = false
        ollamaTags.running = true
      }
    }
  }

  Process {
    id: ollamaTags
    property int gen: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (ollamaTags.gen !== root.scanGen) return
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

  // Keeps the backend's selection pointing at something that still exists,
  // falling back to the first entry rather than launching against a deleted
  // path. System One never falls back: a decision model is picked on purpose.
  function validateSelection() {
    if (root.backend === "systemone") {
      root.validateSystemoneModel()
      return
    }
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

  // ---- Service lifecycle ----
  //
  // llama-swap owns the llama-server children; this panel owns the router's
  // systemd user unit. Start/stop is `systemctl --user`, "start on login" is
  // `enable`, and what is loaded comes from the router's /running. ollama keeps
  // its own unit and API; it never goes through llama-swap.

  property var unitStates: ({})
  property var migrationPlan: null
  property string migrationReport: ""
  property bool migrationRunning: false
  property bool migrationStartFresh: false
  property string migrationError: ""
  property string migrationBackupDir: ""

  function serviceIsRouter(id) { return id === "llamacpp" || id === "systemone" }
  function servicePort(id) {
    var stored = root.backendPorts[id]
    return String(stored !== undefined && String(stored).trim() !== "" ? stored : Backends.get(id).defaultPort)
  }
  function serviceHealthUrl(id) { return Backends.healthUrl(id, root.host, root.servicePort(id)) }
  function serviceUnitState(id) { return String(root.unitStates[id] || "") }

  // ---- Units ----
  //
  // A persistent unit, not systemd-run: only a real unit can be enabled, and
  // "start on login" is what keeps the router independent of the shell.
  function ollamaLaunchSpec() {
    return Backends.ollamaLaunch({
      binary: root.ollamaBinary,
      host: root.host,
      port: root.servicePort("ollama")
    })
  }
  function ollamaLaunchEnv(launch) {
    launch = launch || root.ollamaLaunchSpec()
    return launch.env
  }
  function ollamaUnitText() {
    var launch = root.ollamaLaunchSpec()
    var env = root.ollamaLaunchEnv(launch)
    var lines = [
      "[Unit]",
      "Description=Local AI Server (ollama)",
      "After=network.target",
      "",
      "[Service]",
      "Type=simple",
      "ExecStart=" + launch.argv.map(LlamaSwap.systemdQuote).join(" "),
      "Restart=on-failure",
      "RestartSec=5"
    ]
    var keys = Object.keys(env).sort()
    for (var i = 0; i < keys.length; i++)
      if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(keys[i]))
        lines.push("Environment=" + LlamaSwap.systemdQuote(keys[i] + "=" + env[keys[i]]))
    lines.push("", "[Install]", "WantedBy=default.target")
    return lines.join("\n") + "\n"
  }

  function unitViewFor(id) {
    return id === "systemone" ? unitSys1File : id === "ollama" ? unitOllamaFile : unitMainFile
  }

  function writeUnit(id) {
    var view = root.unitViewFor(id)
    if (!view) return
    if (id === "ollama") {
      view.setText(root.ollamaUnitText())
      return
    }
    view.setText(LlamaSwap.unitFile({
      binary: root.llamaSwapBinary !== "" ? root.llamaSwapBinary : "llama-swap",
      configPath: root.serviceConfigPath(id),
      host: root.host,
      port: root.servicePort(id),
      unitName: root.serviceUnit(id),
      label: Backends.get(id).label,
      workDir: root.settingsDir
    }))
  }

  function unitCommand(id, action) {
    var unit = root.serviceUnit(id)
    if (action === "start")
      return ["bash", "-lc", "systemctl --user daemon-reload; " +
        "systemctl --user reset-failed " + root.shellQuote(unit) + " 2>/dev/null; " +
        "systemctl --user start " + root.shellQuote(unit)]
    if (action === "stop")
      return ["systemctl", "--user", "stop", unit]
    if (action === "enable")
      return ["systemctl", "--user", "enable", unit]
    return ["systemctl", "--user", "disable", unit]
  }

  function setStartOnLogin(id, on) {
    var map = {}
    for (var key in root.startOnLogin) map[key] = root.startOnLogin[key]
    map[id] = !!on
    root.startOnLogin = map
    root.writeUnit(id)
    serviceCommandProc.action = on ? "enable" : "disable"
    serviceCommandProc.serviceId = id
    serviceCommandProc.command = root.unitCommand(id, serviceCommandProc.action)
    serviceCommandProc.running = false
    serviceCommandProc.running = true
  }

  // ---- Start / stop ----

  function toggleServer() {
    if (root.stopping) return
    if (root.running || root.starting) root.stopService(root.backend)
    else root.startService(root.backend)
  }
  function stopServer() { root.stopService(root.backend) }

  function startService(id) {
    if (root.stopping || root.starting) return
    if (!root.readyForConfig) {
      root.lastError = "Still detecting llama.cpp builds — try again in a moment."
      return
    }
    if (root.serviceIsRouter(id)) {
      if (root.llamaSwapBinary === "") {
        root.lastError = "llama-swap not found — install llama-swap v262 or newer and set its path in Settings."
        return
      }
      root.ensureConfig(id)
      var wanted = root.preloadPathFor(id)
      if (wanted !== "" && root.managedEntryFor(id, wanted) === null) {
        root.lastError = "The selected model is not in " + root.serviceConfigPath(id) +
          " — pick it again or add it to the config."
        return
      }
    } else if (root.ollamaBinary === "") {
      root.lastError = "ollama binary not found — set it in plugin settings"
      return
    }
    root.lastError = ""
    root.expectedStop = false
    root.adopted = false
    root.ownsUnit = true
    if (id === root.backend) {
      root.starting = true
      root.startingElapsed = 0
      startingTimer.restart()
    }
    root.writeUnit(id)
    serviceCommandProc.action = "start"
    serviceCommandProc.serviceId = id
    serviceCommandProc.command = root.unitCommand(id, "start")
    serviceCommandProc.running = false
    serviceCommandProc.running = true
    servicePollTimer.restart()
  }

  function stopService(id) {
    if (root.stopping) return
    if (!root.running && !root.starting) return
    if (!root.canStop && id === root.backend) {
      root.lastError = "This server was not started by this widget, so it cannot be stopped from here."
      return
    }
    root.expectedStop = true
    root.stopping = true
    serviceCommandProc.action = "stop"
    serviceCommandProc.serviceId = id
    serviceCommandProc.command = root.unitCommand(id, "stop")
    serviceCommandProc.running = false
    serviceCommandProc.running = true
  }

  Process {
    id: serviceCommandProc
    property string action: ""
    property string serviceId: ""
    onExited: function(exitCode) {
      var id = serviceCommandProc.serviceId
      if (serviceCommandProc.action === "start") {
        if (exitCode !== 0) {
          if (id === root.backend) {
            root.starting = false
            startingTimer.stop()
            root.lastError = "Could not start " + Backends.get(id).label + " (systemctl code " + exitCode + ")"
          }
        }
        if (id === root.backend) servicePollTimer.restart()
        return
      }
      if (serviceCommandProc.action === "stop") {
        root.expectedStop = false
        root.stopping = false
        if (id !== root.backend) {
          root.setServiceState(id, { running: false, starting: false, stopping: false })
          return
        }
        root.running = false
        root.starting = false
        root.resetMetrics()
        root.stopMetrics()
        root.runHook("stopped")
        return
      }
      // enable / disable: a failure leaves the old login setting visibly wrong,
      // so say so rather than silently disagreeing with systemd.
      if (exitCode !== 0)
        root.lastError = "Could not " + serviceCommandProc.action + " " + root.serviceUnit(id) + "."
    }
  }

  // One poll for the three units plus the active service's health. is-active
  // answers for a unit that is starting as well, which is what keeps the panel
  // from calling a slow model load a stop.
  Timer {
    id: servicePollTimer
    interval: 1500
    repeat: true
    onTriggered: if (!serviceStatusProc.running) serviceStatusProc.running = true
  }

  Process {
    id: serviceStatusProc
    command: ["bash", "-lc",
      "systemctl --user is-active " + root.shellQuote(root.serviceUnit("llamacpp")) + " 2>/dev/null; " +
      "systemctl --user is-active " + root.shellQuote(root.serviceUnit("systemone")) + " 2>/dev/null; " +
      "systemctl --user is-active " + root.shellQuote(root.serviceUnit("ollama")) + " 2>/dev/null; " +
      "curl -s -o /dev/null -w '%{http_code}' -m 1 " + root.shellQuote(root.serviceHealthUrl(root.backend))]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var states = {}
        var i = 0
        var ids = ["llamacpp", "systemone", "ollama"]
        for (var n = 0; n < ids.length; n++) {
          while (i < lines.length && String(lines[i]).trim() === "") i++
          states[ids[n]] = i < lines.length ? String(lines[i]).trim() : ""
          i++
        }
        while (i < lines.length && String(lines[i]).trim() === "") i++
        var health = i < lines.length ? String(lines[i]).trim() : ""
        root.unitStates = states
        root.applyActiveServiceState(health === "200", states[root.backend] || "")
      }
    }
  }

  // ollama is the one service a distribution may already run as a root system
  // unit. Taking it over means stopping that unit (polkit asks) and starting
  // ours; nothing here touches a system unit for the two routers.
  function takeOver() {
    if (root.takingOver || !root.backendSpec.systemUnit) return
    root.takingOver = true
    root.lastError = ""
    root.stopMetrics()
    takeoverProc.command = Backends.takeoverStopCommand(root.backendSpec.systemUnit)
    takeoverProc.running = false
    takeoverProc.running = true
  }

  Process {
    id: takeoverProc
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.takingOver = false
        root.lastError = "Could not stop the system service (authentication declined)."
        return
      }
      root.running = false
      root.adopted = false
      root.systemUnitActive = false
      portWaitProc.command = ["bash", "-lc",
        "for i in $(seq 1 40); do " +
        "  curl -s -o /dev/null -m 1 " + root.shellQuote(Backends.healthUrl("ollama", root.host, root.port)) +
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
      root.startService("ollama")
    }
  }

  function probeSystemUnit() {
    var unit = root.backendSpec.systemUnit
    if (!unit || systemUnitProc.running) return
    systemUnitProc.command = ["bash", "-lc",
      "systemctl is-active " + root.shellQuote(unit) + " 2>/dev/null; " +
      "systemctl show " + root.shellQuote(unit) + " -p Environment --no-pager 2>/dev/null"]
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

  function applyActiveServiceState(healthy, unitState) {
    if (healthy) {
      var first = !root.running
      root.adopted = unitState !== "active"
      root.ownsUnit = unitState === "active"
      if (root.adopted && root.backend === "ollama" && root.systemModelsDir === "")
        root.probeSystemUnit()
      root.running = true
      root.startingElapsed = 0
      root.lastError = ""
      if (root.starting) {
        root.starting = false
        startingTimer.stop()
      }
      if (first) {
        root.runHook("started")
        root.startMetrics()
      }
      if (root.serviceIsRouter(root.backend) && !root.loadedModelId && !runningPollProc.running)
        runningPollTimer.restart()
      return
    }

    if (unitState === "active" || unitState === "activating" || unitState === "reloading") {
      if (!root.running) {
        root.starting = true
        if (!startingTimer.running) {
          root.startingElapsed = 0
          startingTimer.restart()
        }
      }
      return
    }

    if (!root.running && !root.starting) return
    if (root.stopping || root.expectedStop) return
    var detail = root.lifecycleErrorLine()
    root.lastError = (root.starting ? "Service failed to start" : "Service stopped") +
      (unitState === "failed" ? " (crashed)" : "") + (detail ? ": " + detail : "")
    root.running = false
    root.starting = false
    startingTimer.stop()
    root.resetMetrics()
    root.stopMetrics()
    root.runHook("stopped")
  }

  function refreshServiceStatus() {
    if (!root.servicesReady) return
    if (!serviceStatusProc.running) serviceStatusProc.running = true
  }

  // ---- Loaded model ----

  function modelPathForId(id, modelId) {
    var parsed = LlamaSwap.parseConfig(root.configTextFor(id))
    for (var i = 0; i < parsed.models.length; i++)
      if (parsed.models[i].id === modelId)
        return parsed.models[i].managedPath || parsed.models[i].modelPath
    return ""
  }

  Timer {
    id: runningPollTimer
    interval: 1200
    repeat: true
    onTriggered: {
      if (!root.running || !root.serviceIsRouter(root.backend) || runningPollProc.running) return
      runningPollProc.command = ["curl", "-s", "-m", "2", LlamaSwap.runningUrl(root.host, root.port)]
      runningPollProc.running = true
    }
  }

  Process {
    id: runningPollProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleRunningResponse(text)
    }
  }

  function handleRunningResponse(text) {
    if (!root.serviceIsRouter(root.backend)) return
    var list = LlamaSwap.parseRunning(text)
    if (list.length === 0) {
      if (root.loadedModelId !== "") {
        root.loadedModelId = ""
        root.runningModel = ""
        root.loadedModelInfo = ""
        root.starting = false
        journalProc.running = false
      }
      return
    }
    var entry = list[0]
    for (var i = 0; i < list.length; i++) if (list[i].state === "ready") { entry = list[i]; break }
    var changed = root.loadedModelId !== entry.model
    root.loadedModelId = entry.model
    var path = root.modelPathForId(root.backend, entry.model)
    if (path !== "") root.runningModel = path
    root.loadedModelInfo = entry.model
    if (entry.state === "ready" && root.starting) {
      root.starting = false
      root.startingElapsed = 0
      startingTimer.stop()
    }
    if (changed || !journalProc.running) root.followModelLogs()
  }

  // Unloads then loads one model through the router, so its cmd is re-read.
  // The unit is deliberately not restarted: other models and the router stay.
  function reloadModel(id, previous) {
    if (!root.serviceIsRouter(root.backend) || !root.running || id === "") return
    root.starting = true
    root.startingElapsed = 0
    startingTimer.restart()
    var script = ""
    if (previous !== undefined && previous !== "" && previous !== id)
      script += "curl -s -m 10 -X POST " +
        root.shellQuote(LlamaSwap.unloadUrl(root.host, root.port, previous)) + " >/dev/null 2>&1; "
    script += "curl -s -m 10 -X POST " +
      root.shellQuote(LlamaSwap.unloadUrl(root.host, root.port, id)) + " >/dev/null 2>&1; "
    script += "curl -s -m 1800 " +
      root.shellQuote(LlamaSwap.loadUrl(root.host, root.port, id)) + " >/dev/null 2>&1"
    reloadProc.command = ["bash", "-lc", script]
    reloadProc.running = false
    reloadProc.running = true
  }

  function reloadLoadedModel() {
    if (root.loadedModelId === "") return
    root.reloadModel(root.loadedModelId)
  }

  function loadSelectedModel() {
    if (!root.running || !root.serviceIsRouter(root.backend) || root.migrationNeeded) return
    var path = root.preloadPathFor(root.backend)
    if (path === "") return
    var entry = root.managedEntryFor(root.backend, path)
    if (entry === null) return
    if (entry.id === root.loadedModelId && !root.starting) return
    root.reloadModel(entry.id, root.loadedModelId)
  }

  // Picking a model while the router runs loads it. Debounced: browsing the
  // picker must not load every model it passes over.
  Timer {
    id: modelSelectTimer
    interval: 1200
    repeat: false
    onTriggered: root.loadSelectedModel()
  }

  Process {
    id: reloadProc
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim() !== "") root.handleServerLine(text) }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.starting = false
        startingTimer.stop()
        root.lastError = "Could not load " + (root.loadedModelId || "the selected model") +
          " (router returned an error; see the log)."
      }
    }
  }

  function selectPreload() {
    var id = root.backend
    if (!root.serviceIsRouter(id) || !root.readyForConfig || root.migrationNeeded) return
    var text = root.ensureConfig(id)
    var path = root.preloadPathFor(id)
    var entry = root.managedInText(text, path)
    if (entry !== null) {
      var next = LlamaSwap.setPreload(text, [entry.id])
      if (next !== text) root.setConfigText(id, next)
    }
    if (root.running) modelSelectTimer.restart()
  }

  // ---- Config files ----

  function ensureUnitDir() {
    Quickshell.execDetached(["mkdir", "-p", root.unitDir])
  }

  // Migration ------------------------------------------------------------

  function prepareMigration() {
    if (!root.migrationNeeded || root.migrationDone) return
    var scan = root.scanning ? null : {
      models: root.modelOptions.map(function(o) { return o.value }),
      visionDirs: root.visionDirs,
      mtpDirs: root.mtpDirs
    }
    var systemoneScan = null
    if (root.configuredSystemoneModelsDir !== "")
      systemoneScan = { models: root.systemoneModelOptions.map(function(o) { return o.value }) }
    var ports = {
      main: root.servicePort("llamacpp"),
      systemone: root.servicePort("systemone"),
      ollama: root.servicePort("ollama")
    }
    Migration.setDeps({ LS: LlamaSwap, Profiles: Profiles, Backends: Backends })
    root.migrationPlan = Migration.plan({
      settings: root.oldSettings,
      builds: root.llamaBuilds,
      catalogue: root.paramCatalogue,
      scan: scan,
      systemoneScan: systemoneScan,
      existingMain: root.configTextFor("llamacpp"),
      existingSystemone: root.configTextFor("systemone"),
      mainBinary: root.configuredLlamaBinary !== "" ? root.llamaBinary : "",
      systemoneBinary: root.configuredSystemoneBinary !== "" ? root.activeSystemoneBinary : "",
      systemoneModelsDir: root.configuredSystemoneModelsDir,
      host: root.host,
      ports: ports,
      paths: { main: root.mainConfigPath, systemone: root.systemoneConfigPath },
      slotsDir: root.slotSaveDir
    })
    root.migrationReport = root.migrationPlan.report
    root.showingMigration = true
  }

  function runMigration(startFresh) {
    if (root.migrationRunning) return
    if (!startFresh && root.migrationPlan === null) root.prepareMigration()
    if (!startFresh && root.migrationPlan === null) return
    root.migrationRunning = true
    root.migrationStartFresh = !!startFresh
    root.migrationError = ""
    root.migrationBackupDir = root.settingsDir + "migration-backup-" + Date.now()
    var files = [
      root.settingsPath,
      root.mainConfigPath,
      root.systemoneConfigPath,
      root.serviceUnitPath("llamacpp"),
      root.serviceUnitPath("systemone"),
      root.serviceUnitPath("ollama")
    ]
    var script = "mkdir -p " + root.shellQuote(root.migrationBackupDir) + "; "
    for (var i = 0; i < files.length; i++)
      script += "if [ -e " + root.shellQuote(files[i]) + " ]; then cp -a " +
        root.shellQuote(files[i]) + " " + root.shellQuote(root.migrationBackupDir) + "/; fi; "
    migrationBackupProc.command = ["bash", "-lc", script]
    migrationBackupProc.running = false
    migrationBackupProc.running = true
  }

  Process {
    id: migrationBackupProc
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.migrationRunning = false
        root.migrationError = "Could not write the backup in " + root.migrationBackupDir
        root.showingMigration = true
        return
      }
      root.writeMigrationFiles()
    }
  }

  function writeMigrationFiles() {
    var mainText = ""
    var systemoneText = ""
    if (!root.migrationStartFresh) {
      mainText = root.migrationPlan.main.text
      systemoneText = root.migrationPlan.systemone.text
      migrationReportFile.setText(root.migrationPlan.report)
    }
    root.setConfigText("llamacpp", mainText)
    root.setConfigText("systemone", systemoneText)

    if (root.llamaSwapBinary === "" || (mainText.trim() === "" && systemoneText.trim() === "")) {
      root.finishMigration()
      return
    }
    var script = "set -e; "
    if (mainText.trim() !== "")
      script += root.shellQuote(root.llamaSwapBinary) + " -config " +
        root.shellQuote(root.mainConfigPath) + " -validate; "
    if (systemoneText.trim() !== "")
      script += root.shellQuote(root.llamaSwapBinary) + " -config " +
        root.shellQuote(root.systemoneConfigPath) + " -validate"
    migrationValidateProc.command = ["bash", "-lc", script]
    migrationValidateProc.running = false
    migrationValidateProc.running = true
  }

  Process {
    id: migrationValidateProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: if (text.trim() !== "") root.migrationValidateError = text.trim() }
    property string migrationValidateError: ""
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.finishMigration()
        return
      }
      var detail = migrationValidateProc.migrationValidateError
      migrationRestoreProc.command = ["bash", "-lc", root.restoreMigrationScript()]
      migrationRestoreProc.running = false
      migrationRestoreProc.running = true
      root.migrationError = "llama-swap rejected the generated config" + (detail ? ": " + detail : ".")
    }
  }

  Process {
    id: migrationRestoreProc
    onExited: {
      root.migrationRunning = false
      root.showingMigration = true
      root.applyTuningForSelection()
    }
  }

  function restoreMigrationScript() {
    function restore(from, to) {
      return "if [ -e " + root.shellQuote(root.migrationBackupDir + "/" + from) + " ]; then cp -a " +
        root.shellQuote(root.migrationBackupDir + "/" + from) + " " + root.shellQuote(to) + "; else rm -f " +
        root.shellQuote(to) + "; fi; "
    }
    var script = restore(root.settingsPath.split("/").pop(), root.settingsPath)
    script += restore(root.mainConfigPath.split("/").pop(), root.mainConfigPath)
    script += restore(root.systemoneConfigPath.split("/").pop(), root.systemoneConfigPath)
    return script
  }

  function finishMigration() {
    // A migration is the user's confirmation: the old transient units are
    // stopped here, before the persistent unit takes the same name.
    Quickshell.execDetached(["systemctl", "--user", "stop",
      Backends.unitName(root.moduleName, "llamacpp"),
      Backends.unitName(root.moduleName, "systemone")])
    root.migrationNeeded = false
    root.migrationDone = true
    root.oldSettings = null
    root.migrationRunning = false
    root.showingMigration = false
    root.ensureUnitDir()
    root.writeUnit("llamacpp")
    root.writeUnit("systemone")
    root.writeUnit("ollama")
    root.ensureConfig("llamacpp")
    root.ensureConfig("systemone")
    root.applyTuningForSelection()
    root.flushSettings()
    if (root.configuredSystemoneModelsDir !== "") root.refreshSystemoneModels()
    servicePollTimer.restart()
  }

  // ---- Hooks ----
  //
  // Runs `omarchy hook local-ai-server <started|stopped> <json>` -- every
  // script in ~/.config/omarchy/hooks/local-ai-server.d/ -- whenever a service
  // comes up and when it goes away. The plugin itself writes no one else's
  // configuration; pointing a coding agent at the live endpoint is what a hook
  // is for. The JSON describes what is being served; see README "Hooks".
  function servedModelEntry(path, label) {
    var probed = root.modelCaps[path] || {}
    var geometry = root.modelGeometry[path] || null
    return { id: path,
             name: (label || Model.baseName(path)).replace(/\.gguf$/i, ""),
             thinking: !!probed.thinking, tools: !!probed.tools,
             vision: !!root.visionDirs[Model.dirName(path)],
             contextLength: geometry ? (geometry.context_length || 0) : 0 }
  }

  function servedModels() {
    var out = []
    if (root.backend === "ollama") {
      for (var i = 0; i < root.modelOptions.length; i++) {
        var opt = root.modelOptions[i]
        var blob = root.ollamaBlobs[opt.value]
        var blobPath = blob ? blob.path : ""
        var caps = (blobPath && root.modelCaps[blobPath]) || {}
        var geom = blobPath ? root.modelGeometry[blobPath] : null
        out.push({ id: opt.value, name: opt.label,
                   thinking: !!caps.thinking, tools: !!caps.tools, vision: false,
                   contextLength: geom ? (geom.context_length || 0) : 0 })
      }
      return out
    }
    // Every model in the config, not only the loaded one (README "Hooks").
    var parsed = LlamaSwap.parseConfig(root.configTextFor(root.backend))
    for (var m = 0; m < parsed.models.length; m++) {
      var path = parsed.models[m].managedPath || parsed.models[m].modelPath
      if (path !== "") out.push(root.servedModelEntry(path, ""))
    }
    var loaded = root.runningModel !== "" ? root.runningModel : root.launchModel
    if (loaded === "") return out
    var listed = false
    for (var k = 0; k < out.length; k++) if (out[k].id === loaded) listed = true
    if (!listed) out.push(root.servedModelEntry(loaded, ""))
    return out
  }

  function runHook(event) {
    var serving = event === "started"
    var payload = {
      event: event,
      backend: root.backend,
      endpoint: Backends.baseUrl(root.host, root.port),
      openaiBaseUrl: Backends.baseUrl(root.host, root.port) + "/v1",
      // The context the server was launched with; 0 means the model's own.
      contextSize: root.backend === "systemone"
        ? (parseInt(root.systemoneCtx, 10) || 0)
        : (parseInt(root.contextSize, 10) || 0),
      model: serving ? (root.runningModel !== "" ? root.runningModel : root.launchModel) : "",
      build: serving && root.backend === "llamacpp" ? Backends.buildLabel(root.resolvedBuild) : "",
      // shortcut: the whole store travels as one argv string; past ~600 models
      // it can exceed MAX_ARG_STRLEN, then write the payload to a temp file.
      models: serving ? root.servedModels() : []
    }
    Quickshell.execDetached(["omarchy-hook", "local-ai-server", event, JSON.stringify(payload)])
  }

  // ---- Metrics ----

  function startMetrics() {
    if (root.backend === "ollama") {
      psPollTimer.restart()
      root.followJournal(200)
      return
    }
    runningPollTimer.restart()
    if (root.loadedModelId !== "") root.followModelLogs()
  }

  function stopMetrics() {
    runningPollTimer.stop()
    psPollTimer.stop()
    journalProc.running = false
    root.logsSource = ""
  }

  function resetMetrics() {
    root.runningModel = ""
    root.loadedModelId = ""
    root.tokensPerSec = 0
    root.ppActive = false
    root.ppPercent = 0
    root.ppTokensPerSec = 0
    root.ppFromLog = false
    root.lastDecodeSample = null
    root.lastPromptSample = null
    root.loadedModelInfo = ""
    root.rateHistory = []
  }

  // Router output comes from its per-model log stream; ollama keeps journald.
  function followModelLogs() {
    if (root.backend === "ollama") {
      root.followJournal(200)
      return
    }
    if (root.loadedModelId === "") return
    if (journalProc.running && journalProc.streamId === root.loadedModelId) return
    journalProc.running = false
    journalProc.streamId = root.loadedModelId
    journalProc.command = ["curl", "-N", "-s", "--max-time", "86400",
      LlamaSwap.logsUrl(root.host, root.port, root.loadedModelId, true)]
    root.logsSource = "router"
    journalProc.running = true
  }

  function followJournal(tailLines) {
    var command = Backends.journalCommand(root.backend, root.serviceUnit(root.backend), root.ownsUnit, tailLines)
    if (!command) {
      root.logsSource = "none"
      journalProc.running = false
      return
    }
    root.logsSource = root.ownsUnit ? "user" : "system"
    journalProc.streamId = ""
    journalProc.command = command
    journalProc.running = false
    journalProc.running = true
  }

  Process {
    id: journalProc
    property string streamId: ""
    stdout: SplitParser { onRead: function(line) { root.handleServerLine(line) } }
    stderr: SplitParser { onRead: function(line) { root.handleServerLine(line) } }
    onExited: {
      if (root.logsSource === "router" && root.running) root.logsSource = ""
    }
  }

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
        root.loadedModelId = String(m.name || "")
        root.runningModel = String(m.name || "")
      }
    }
  }

  function handleServerLine(line) {
    var text = String(line).trim()
    if (text !== "") {
      root.lastLogLine = text
      logModel.append({ line: text })
      if (logModel.count > root.logLinesMax)
        logModel.remove(0, logModel.count - root.logLinesMax)
      root.logRevision++
    }

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
      root.ppTokensPerSec = timing.tps
      root.ppActive = false
    } else {
      root.tokensPerSec = timing.tps
      root.pushRate(timing.tps)
    }
  }

  // Log triage lives in Model.js so it can be tested against real captured
  // crash output; this is the one caller.
  function logLinesArray() {
    var out = []
    for (var i = 0; i < logModel.count; i++) out.push(logModel.get(i).line)
    return out
  }
  function lifecycleErrorLine() {
    return Model.pickErrorLine(root.logLinesArray(), root.lastLogLine)
  }
  function lastErrorLine() { return root.lifecycleErrorLine() }

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
        var detail = root.lifecycleErrorLine()
        root.lastError = "Gave up waiting after " + root.startupTimeoutSec + "s" +
          (detail ? ": " + detail : " — no response on " + root.healthUrl)
        root.starting = false
      }
    }
  }

  // The shell tears this panel down on restart or plugin removal. Services are
  // deliberately left running to be adopted; the last debounced edit is not,
  // so flush it before the FileView goes away.
  Component.onDestruction: {
    settingsSaveTimer.stop()
    configSaveTimer.stop()
    if (root.settingsLoaded) root.flushSettings()
    journalProc.running = false
  }

  onOpenedChanged: if (opened) {
    briefPopup.open = false
    root.showingLogs = false
    // shortcut: a full scan at most once a minute, refreshed by any explicit
    // rescan; upgrade to a watch if new models must appear immediately.
    if (!root.activeScanning &&
        (root.activeModelOptions.length === 0 || Date.now() - root.lastModelScanAt > 60000))
      refreshModels()
    root.refreshServiceStatus()
    if (root.running && root.serviceIsRouter(root.backend)) runningPollTimer.restart()
  }

  // ---- Bar widget ----

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Hover popup: graphical brief showing running status, active model,
  // prompt/decode speed and real-time sparkline.
  property bool barHovered: buttonHover.hovered
  readonly property bool showBriefPopup: (root.barHovered || briefPopup.containsMouse) && !root.opened

  Timer {
    id: briefPopupTimer
    interval: 350
    running: root.showBriefPopup && !briefPopup.open
    onTriggered: if (root.showBriefPopup && !root.opened) briefPopup.open = true
  }

  Timer {
    id: briefPopupCloseTimer
    interval: 200
    running: !root.showBriefPopup && briefPopup.open
    onTriggered: if (!root.showBriefPopup) briefPopup.open = false
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    readonly property string switchState: ""
    text: Model.barSwitchText(
      Model.barText(Model.BAR_ICON,
                    root.running, root.showMetric, root.ppActive,
                    root.ppPercent, root.tokensPerSec, root.ppTokensPerSec),
      switchState, false)
    active: root.running || root.starting
    // The live number already says the server is up; an accent colour on top
    // would be the only coloured mark in the bar.
    useActiveColor: false
    fontFamily: root.bar.fontFamily
    fontSize: Style.font.bodySmall
    dimmed: root.starting
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.showMetric = !root.showMetric
      else root.toggle()
    }

    HoverHandler {
      id: buttonHover
    }
  }

  PopupCard {
    id: briefPopup
    anchorItem: button
    bar: root.bar
    owner: root
    triggerMode: "hover"
    contentWidth: fittedContentWidth(Style.space(260))
    contentHeight: fittedContentHeight(briefLayout.implicitHeight)

    ColumnLayout {
      id: briefLayout
      anchors.fill: parent
      spacing: Style.space(6)

      // Title & primary status header
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Rectangle {
          width: 8
          height: 8
          radius: 4
          color: root.running ? Commons.Color.accent : (root.starting ? Commons.Color.warning : Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.3))
        }

        Text {
          text: root.backendSpec.label
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Item { Layout.fillWidth: true }

        Text {
          text: root.starting ? "Starting…" : (root.running ? "Active" : "Stopped")
          color: root.running ? Commons.Color.accent : root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          opacity: 0.8
        }
      }

      // Loaded model
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(4)

        Text {
          text: "Model:"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          opacity: 0.6
        }

        Text {
          Layout.fillWidth: true
          text: {
            if (root.loadedModelId !== "") return root.loadedModelId
            if (root.runningModel !== "") return Model.baseName(root.runningModel).replace(/\.gguf$/i, "")
            return "None resident"
          }
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: root.loadedModelId !== "" || root.runningModel !== ""
          elide: Text.ElideMiddle
        }
      }

      // Live metrics: Prompt processing & Token Generation
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(12)
        visible: root.running

        ColumnLayout {
          spacing: 1
          Text {
            text: "Generation"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            opacity: 0.6
          }
          Text {
            text: root.tokensPerSec > 0 ? root.tokensPerSec.toFixed(1) + " tk/s" : "idle"
            color: root.tokensPerSec > 0 ? Commons.Color.accent : root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: root.tokensPerSec > 0
          }
        }

        ColumnLayout {
          spacing: 1
          Text {
            text: "Prompt eval"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            opacity: 0.6
          }
          Text {
            text: root.ppActive
              ? (root.ppPercent > 0 ? root.ppPercent + "%" : "evaluating…")
              : (root.ppTokensPerSec > 0 ? root.ppTokensPerSec.toFixed(1) + " tk/s" : "idle")
            color: (root.ppActive || root.ppTokensPerSec > 0) ? Commons.Color.accent : root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: root.ppActive || root.ppTokensPerSec > 0
          }
        }
      }

      // Graphical speed sparkline (recent token generation rate)
      Canvas {
        id: sparkCanvas
        Layout.fillWidth: true
        implicitHeight: Style.space(32)
        visible: root.running

        property var history: root.rateHistory

        onHistoryChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
          var ctx = getContext("2d")
          ctx.clearRect(0, 0, width, height)
          var list = root.rateHistory || []
          if (list.length === 0) return

          // Find peak for scaling (at least 10 tk/s floor)
          var maxVal = 10
          for (var i = 0; i < list.length; i++) {
            if (list[i] > maxVal) maxVal = list[i]
          }

          var step = width / Math.max(1, list.length - 1)
          var accent = Commons.Color.accent

          // Area fill
          ctx.beginPath()
          ctx.moveTo(0, height)
          for (var j = 0; j < list.length; j++) {
            var val = list[j]
            var x = j * step
            var y = height - (val / maxVal) * (height - 4) - 2
            if (j === 0) ctx.lineTo(x, y)
            else ctx.lineTo(x, y)
          }
          ctx.lineTo(width, height)
          ctx.closePath()
          ctx.fillStyle = Qt.rgba(accent.r, accent.g, accent.b, 0.15)
          ctx.fill()

          // Line stroke
          ctx.beginPath()
          for (var k = 0; k < list.length; k++) {
            var valK = list[k]
            var xK = k * step
            var yK = height - (valK / maxVal) * (height - 4) - 2
            if (k === 0) ctx.moveTo(xK, yK)
            else ctx.lineTo(xK, yK)
          }
          ctx.strokeStyle = accent
          ctx.lineWidth = 1.5
          ctx.stroke()
        }
      }

      // Status indicator for all services
      PanelSeparator { Layout.fillWidth: true; visible: root.running }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Repeater {
          model: [
            { id: "llamacpp", label: "Router" },
            { id: "systemone", label: "Sys 1" },
            { id: "ollama", label: "Ollama" }
          ]

          RowLayout {
            spacing: Style.space(4)
            readonly property bool isUp: modelData.id === root.backend ? root.running : (root.unitStates[modelData.id] === "active")

            Rectangle {
              width: 6
              height: 6
              radius: 3
              color: isUp ? Commons.Color.accent : Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.25)
            }
            Text {
              text: modelData.label
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              opacity: isUp ? 0.85 : 0.4
            }
          }
        }
      }
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
    // One fixed card for every page: switching tabs must not resize the
    // panel. Pages that need more room scroll inside it.
    contentWidth: fittedContentWidth(Style.space(380))
    contentHeight: fittedContentHeight(Style.space(460), Style.space(600))

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
            color: root.running ? Commons.Color.accent : (root.starting ? root.bar.foreground : "transparent")
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
                                      "",
                                      root.slotsProcessing) +
                    " · " + root.backendSpec.label +
                    (root.adopted && !root.ownsUnit ? " · external" : "")
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSizeSubtitle
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
              font.pixelSize: root.fontSize
              elide: Text.ElideRight
              Layout.fillWidth: true
            }
          }

          Button {
            text: {
              if (root.takingOver) return "…"
              if (root.canTakeOver) return "Take over"
              return root.starting || root.running ? "Stop" : "Start"
            }
            enabled: !root.stopping && !root.takingOver &&
                     (root.canTakeOver || root.starting || !root.running || root.canStop)
            tooltipText: root.canTakeOver
              ? "Stop the system service and run an instance this widget controls"
              : (root.running ? "Stop the " + root.backendSpec.label + " service" : "")
            onClicked: {
              if (root.canTakeOver) root.takeOver()
              else root.toggleServer()
            }
          }
        }

        PanelSeparator { Layout.fillWidth: true }

        // ---- Category tabs ----
        // Plain labels with an accent underline, matching the dotted rows
        // below rather than sitting in a box of chips.
        RowLayout {
          Layout.fillWidth: true
          visible: !root.showingSetup && !root.showingSettings
          spacing: 0

          Repeater {
            model: root.pageNames

            delegate: Item {
              required property string modelData
              required property int index

              readonly property bool current: root.currentPage === index

              Layout.fillWidth: true
              implicitHeight: 26

              Text {
                id: tabText
                anchors.centerIn: parent
                text: modelData
                color: parent.current ? Commons.Color.accent : root.bar.foreground
                opacity: parent.current ? 1.0 : (tabMouse.containsMouse ? 0.85 : 0.55)
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
                font.bold: parent.current
              }

              Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                width: tabText.width + Style.space(10)
                height: 1
                color: Commons.Color.accent
                visible: parent.current
              }

              MouseArea {
                id: tabMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.currentPage = index
                  // Choosing a category means "show me that", so the log
                  // steps aside rather than staying up over the selection.
                  root.showingLogs = false
                }
              }
            }
          }
        }

        // ---- Settings / first-run ----
        //
        // shortcut: sections are not scrollable; about six rows per section
        // fit the fixed 460px card. Wrap this in a Flickable if a collection
        // ever grows past that.
        //
        // One page of dotted rows and collapsible sections, not a wizard:
        // after first run the same screen is the settings panel, so a folder
        // or a fork can be added without hand-editing shell.json. The first
        // run simply opens it with setupDone still false.
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: (root.showingSetup || root.showingSettings) && !root.showingLogs
          spacing: Style.space(6)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              text: root.showingSetup ? "Setup" : "Settings"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSizeSubtitle
            }

            Text {
              Layout.fillWidth: true
              text: "...................................................................................................."
              color: root.bar.foreground
              opacity: 0.15
              elide: Text.ElideRight
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
            }

            Text {
              text: root.backendSpec.label
              color: root.bar.foreground
              opacity: 0.45
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSizeSmall
            }
          }

          // Backend section ---------------------------------------------
          Rectangle {
            Layout.fillWidth: true
            implicitHeight: 26
            radius: 3
            color: settingsBackendHover.hovered
              ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
              : "transparent"

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(4)
              anchors.rightMargin: Style.space(4)
              spacing: Style.space(4)

              Text {
                text: "Backend"
                color: root.bar.foreground
                opacity: 0.85
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
              Text {
                Layout.fillWidth: true
                text: "...................................................................................................."
                color: root.bar.foreground
                opacity: 0.15
                elide: Text.ElideRight
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
              Text {
                text: root.backendSpec.label
                color: root.bar.foreground
                opacity: 0.85
                elide: Text.ElideRight
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
              Text {
                text: root.settingsSection === "backend" ? "-" : "+"
                color: root.bar.foreground
                opacity: 0.5
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
            }

            HoverHandler { id: settingsBackendHover; cursorShape: Qt.PointingHandCursor }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.settingsSection = root.settingsSection === "backend" ? "" : "backend"
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Style.space(8)
            spacing: 2
            visible: root.settingsSection === "backend"

            // Which server. The list is the same installed-backends list the
            // Server page offers.
            Rectangle {
              id: settingsBackendRow
              Layout.fillWidth: true
              implicitHeight: 26
              radius: 3
              color: settingsBackendPickHover.hovered
                ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                : "transparent"

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)
                spacing: Style.space(4)

                Text {
                  text: "Server"
                  color: root.bar.foreground
                  opacity: 0.8
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  Layout.fillWidth: true
                  text: "...................................................................................................."
                  color: root.bar.foreground
                  opacity: 0.15
                  elide: Text.ElideRight
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  text: root.backendSpec.label
                  color: root.bar.foreground
                  opacity: (root.running || root.starting) ? 0.45 : 0.85
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
              }

              HoverHandler { id: settingsBackendPickHover; cursorShape: Qt.PointingHandCursor }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                enabled: !root.running && !root.starting
                onClicked: settingsBackendPopup.open()
              }
              PanelToolTip {
                visible: settingsBackendPickHover.hovered
                text: root.running || root.starting
                  ? "Stop the server to change the backend."
                  : "The inference server this widget launches."
              }

              Popup {
                id: settingsBackendPopup
                x: 0
                y: parent.height + 4
                width: 260
                height: settingsBackendPopupCol.implicitHeight + 16
                padding: 8
                background: Rectangle {
                  color: Commons.Color.menu.background
                  radius: 6
                  border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)
                  border.width: 1
                }

                ColumnLayout {
                  id: settingsBackendPopupCol
                  width: parent.width
                  spacing: 2

                  Repeater {
                    model: root.installedBackends

                    delegate: Rectangle {
                      required property var modelData

                      readonly property bool chosen: root.backend === modelData.id

                      Layout.fillWidth: true
                      implicitHeight: 26
                      radius: 3
                      color: settingsBackendChoiceHover.hovered
                        ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                        : "transparent"

                      RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(4)
                        anchors.rightMargin: Style.space(4)
                        spacing: Style.space(4)

                        Text {
                          text: "•"
                          visible: parent.parent.chosen
                          color: Commons.Color.accent
                          font.family: root.bar.fontFamily
                          font.pixelSize: root.fontSize
                        }
                        Text {
                          Layout.fillWidth: true
                          text: modelData.label
                          color: parent.parent.chosen ? Commons.Color.accent : root.bar.foreground
                          elide: Text.ElideRight
                          font.family: root.bar.fontFamily
                          font.pixelSize: root.fontSize
                        }
                      }

                      HoverHandler { id: settingsBackendChoiceHover; cursorShape: Qt.PointingHandCursor }
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.backend = modelData.id
                          settingsBackendPopup.close()
                        }
                      }
                    }
                  }
                }
              }
            }

            // Binary. Clicking the row edits it in place, the same gesture as
            // host:port on the Server page.
            Rectangle {
              id: settingsBinaryRow
              Layout.fillWidth: true
              implicitHeight: 26
              radius: 3
              property bool editing: false
              color: settingsBinaryHover.hovered
                ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                : "transparent"

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)
                spacing: Style.space(4)
                visible: !settingsBinaryRow.editing

                Text {
                  text: "Binary"
                  color: root.bar.foreground
                  opacity: 0.8
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  Layout.fillWidth: true
                  text: "...................................................................................................."
                  color: root.bar.foreground
                  opacity: 0.15
                  elide: Text.ElideRight
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  Layout.maximumWidth: settingsBinaryRow.width * 0.55
                  text: root.activeBinary !== ""
                        ? root.activeBinary.replace(Quickshell.env("HOME"), "~")
                        : "auto"
                  color: root.bar.foreground
                  opacity: root.activeBinary !== "" ? 0.85 : 0.45
                  elide: Text.ElideMiddle
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
              }

              TextField {
                id: settingsBinaryField
                anchors.fill: parent
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)
                visible: settingsBinaryRow.editing
                text: root.setupBinaryKey() === "binary" ? root.configuredLlamaBinary : root.configuredOllamaBinary
                placeholderText: "auto-detect (leave empty)"
                onEditingFinished: {
                  root.setWidgetSetting(root.setupBinaryKey(), text.trim())
                  settingsBinaryRow.editing = false
                }
                Keys.onEscapePressed: {
                  settingsBinaryField.text = root.setupBinaryKey() === "binary"
                    ? root.configuredLlamaBinary
                    : root.configuredOllamaBinary
                  settingsBinaryRow.editing = false
                }
              }

              HoverHandler { id: settingsBinaryHover; cursorShape: Qt.PointingHandCursor }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                visible: !settingsBinaryRow.editing
                onClicked: {
                  settingsBinaryRow.editing = true
                  settingsBinaryField.text = root.setupBinaryKey() === "binary"
                    ? root.configuredLlamaBinary
                    : root.configuredOllamaBinary
                  settingsBinaryField.forceActiveFocus()
                }
              }
              PanelToolTip {
                visible: settingsBinaryHover.hovered
                text: "Path to " + root.backendSpec.label + ". Leave empty to use the detected binary."
              }
            }

            TextAction {
              Layout.fillWidth: true
              text: capabilityProbe.running ? "Detecting…" : "Detect again"
              onClicked: {
                root.detectedLlamaBinary = ""
                root.detectedOllamaBinary = ""
                capabilityProbe.running = true
              }
            }
          }

          // Models section ----------------------------------------------
          Rectangle {
            Layout.fillWidth: true
            implicitHeight: 26
            radius: 3
            color: settingsModelsHover.hovered
              ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
              : "transparent"

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(4)
              anchors.rightMargin: Style.space(4)
              spacing: Style.space(4)

              Text {
                text: "Model folders"
                color: root.bar.foreground
                opacity: 0.85
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
              Text {
                Layout.fillWidth: true
                text: "...................................................................................................."
                color: root.bar.foreground
                opacity: 0.15
                elide: Text.ElideRight
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
              Text {
                text: root.configuredModelsDir !== ""
                      ? root.configuredModelsDir.replace(Quickshell.env("HOME"), "~")
                      : "auto"
                color: root.bar.foreground
                opacity: 0.65
                elide: Text.ElideMiddle
                Layout.maximumWidth: parent.width * 0.45
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSizeSmall
              }
              Text {
                text: root.settingsSection === "models" ? "-" : "+"
                color: root.bar.foreground
                opacity: 0.5
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
            }

            HoverHandler { id: settingsModelsHover; cursorShape: Qt.PointingHandCursor }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.settingsSection = root.settingsSection === "models" ? "" : "models"
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Style.space(8)
            spacing: 2
            visible: root.settingsSection === "models"

            // Auto: every detected folder.
            Rectangle {
              Layout.fillWidth: true
              implicitHeight: 26
              radius: 3
              color: settingsAutoHover.hovered
                ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                : "transparent"

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)
                spacing: Style.space(4)

                Text {
                  text: root.configuredModelsDir === "" ? "•" : "·"
                  color: Commons.Color.accent
                  opacity: root.configuredModelsDir === "" ? 1.0 : 0.3
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  Layout.fillWidth: true
                  text: "All detected folders"
                  color: root.configuredModelsDir === "" ? Commons.Color.accent : root.bar.foreground
                  opacity: 0.85
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  text: root.detectedModelDirs.length + " folder" + (root.detectedModelDirs.length === 1 ? "" : "s")
                  color: root.bar.foreground
                  opacity: 0.42
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSizeSmall
                }
              }

              HoverHandler { id: settingsAutoHover; cursorShape: Qt.PointingHandCursor }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.useModelsDir("")
              }
            }

            Repeater {
              model: root.setupModelDirs

              delegate: Rectangle {
                required property string modelData

                readonly property var count: root.modelDirCounts[modelData]
                readonly property bool chosen: root.configuredModelsDir !== "" &&
                  expandPath(root.configuredModelsDir) === modelData

                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                color: settingsDirHover.hovered
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)

                  Text {
                    text: chosen ? "•" : "·"
                    color: Commons.Color.accent
                    opacity: chosen ? 1.0 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    Layout.fillWidth: true
                    text: modelData.replace(Quickshell.env("HOME"), "~")
                    color: chosen ? Commons.Color.accent : root.bar.foreground
                    opacity: 0.85
                    elide: Text.ElideMiddle
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    text: count === undefined
                          ? "…"
                          : count + " model" + (count === 1 ? "" : "s")
                    color: root.bar.foreground
                    opacity: 0.42
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSizeSmall
                  }
                }

                HoverHandler { id: settingsDirHover; cursorShape: Qt.PointingHandCursor }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.useModelsDir(modelData)
                }
              }
            }

            Rectangle {
              id: settingsAddFolderRow
              Layout.fillWidth: true
              implicitHeight: 26
              radius: 3
              property bool editing: false
              color: settingsAddFolderHover.hovered
                ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                : "transparent"

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)
                spacing: Style.space(4)
                visible: !settingsAddFolderRow.editing

                Text {
                  text: "Add folder"
                  color: root.bar.foreground
                  opacity: 0.8
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  Layout.fillWidth: true
                  text: "...................................................................................................."
                  color: root.bar.foreground
                  opacity: 0.15
                  elide: Text.ElideRight
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  text: "click to add"
                  color: root.bar.foreground
                  opacity: 0.42
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSizeSmall
                }
              }

              TextField {
                id: settingsFolderField
                anchors.fill: parent
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)
                visible: settingsAddFolderRow.editing
                placeholderText: "~/models"
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
                onEditingFinished: {
                  if (text.trim() !== "") root.useModelsDir(text)
                  settingsAddFolderRow.editing = false
                }
                Keys.onEscapePressed: {
                  settingsFolderField.text = ""
                  settingsAddFolderRow.editing = false
                }
              }

              HoverHandler { id: settingsAddFolderHover; cursorShape: Qt.PointingHandCursor }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                visible: !settingsAddFolderRow.editing
                onClicked: {
                  settingsFolderField.text = ""
                  settingsAddFolderRow.editing = true
                  settingsFolderField.forceActiveFocus()
                }
              }
              PanelToolTip {
                visible: settingsAddFolderHover.hovered
                text: "Add a folder that holds .gguf files."
              }
            }
          }

          // Builds section ----------------------------------------------
          Rectangle {
            Layout.fillWidth: true
            implicitHeight: 26
            radius: 3
            color: settingsBuildsHover.hovered
              ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
              : "transparent"

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(4)
              anchors.rightMargin: Style.space(4)
              spacing: Style.space(4)

              Text {
                text: "Builds"
                color: root.bar.foreground
                opacity: 0.85
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
              Text {
                Layout.fillWidth: true
                text: "...................................................................................................."
                color: root.bar.foreground
                opacity: 0.15
                elide: Text.ElideRight
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
              Text {
                text: root.llamaBuilds.length + " found"
                color: root.bar.foreground
                opacity: 0.45
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSizeSmall
              }
              Text {
                text: root.settingsSection === "builds" ? "-" : "+"
                color: root.bar.foreground
                opacity: 0.5
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
            }

            HoverHandler { id: settingsBuildsHover; cursorShape: Qt.PointingHandCursor }
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.settingsSection = root.settingsSection === "builds" ? "" : "builds"
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Style.space(8)
            spacing: 2
            visible: root.settingsSection === "builds"

            Repeater {
              model: root.llamaBuilds

              delegate: Rectangle {
                required property var modelData

                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                color: "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)

                  Text {
                    text: modelData.fork || "llama-server"
                    color: root.bar.foreground
                    opacity: 0.8
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    text: Backends.buildLabel(modelData)
                    color: root.bar.foreground
                    opacity: 0.42
                    elide: Text.ElideRight
                    Layout.maximumWidth: Style.space(160)
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSizeSmall
                  }
                }
              }
            }

            Text {
              Layout.fillWidth: true
              visible: root.llamaBuilds.length === 0
              text: "No llama.cpp build detected yet."
              color: root.bar.foreground
              opacity: 0.45
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSizeSmall
            }

            Rectangle {
              id: settingsAddForkRow
              Layout.fillWidth: true
              implicitHeight: 26
              radius: 3
              property bool editing: false
              color: settingsAddForkHover.hovered
                ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                : "transparent"

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)
                spacing: Style.space(4)
                visible: !settingsAddForkRow.editing

                Text {
                  text: "Add fork"
                  color: root.bar.foreground
                  opacity: 0.8
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  Layout.fillWidth: true
                  text: "...................................................................................................."
                  color: root.bar.foreground
                  opacity: 0.15
                  elide: Text.ElideRight
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  text: "click to add"
                  color: root.bar.foreground
                  opacity: 0.42
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSizeSmall
                }
              }

              TextField {
                id: settingsForkField
                anchors.fill: parent
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)
                visible: settingsAddForkRow.editing
                text: root.altBinary
                placeholderText: "path to llama-server"
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
                onEditingFinished: {
                  root.setWidgetSetting("altBinary", text.trim())
                  settingsAddForkRow.editing = false
                }
                Keys.onEscapePressed: {
                  settingsForkField.text = root.altBinary
                  settingsAddForkRow.editing = false
                }
              }

              HoverHandler { id: settingsAddForkHover; cursorShape: Qt.PointingHandCursor }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                visible: !settingsAddForkRow.editing
                onClicked: {
                  settingsForkField.text = root.altBinary
                  settingsAddForkRow.editing = true
                  settingsForkField.forceActiveFocus()
                }
              }
              PanelToolTip {
                visible: settingsAddForkHover.hovered
                text: "Path to another llama-server build."
              }
            }

            TextAction {
              Layout.fillWidth: true
              text: buildsProbe.running ? "Detecting…" : "Rescan builds"
              onClicked: root.probeBuilds()
            }
          }

          Item { Layout.fillHeight: true }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(12)

            TextAction {
              text: root.showingSetup ? "Skip" : "Close"
              onClicked: {
                if (root.showingSetup) root.skipSetup()
                else root.closeSettings()
              }
            }

            Item { Layout.fillWidth: true }

            TextAction {
              visible: !root.showingSetup
              text: "Re-run migration"
              onClicked: {
                root.closeSettings()
                root.prepareMigration()
                root.showingMigration = true
              }
            }

            TextAction {
              active: true
              text: root.showingSetup ? "Finish" : "Done"
              onClicked: {
                if (root.showingSetup) root.finishSetup()
                else root.closeSettings()
              }
            }
          }
        }

        // ---- Migration dialog overlay ----
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: root.showingMigration && !root.showingLogs
          spacing: Style.space(8)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              text: "Migrate to Router"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSizeSubtitle
              font.bold: true
            }

            Text {
              Layout.fillWidth: true
              text: "...................................................................................................."
              color: root.bar.foreground
              opacity: 0.15
              elide: Text.ElideRight
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
            }

            Text {
              text: "v4"
              color: Commons.Color.accent
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSizeSmall
              font.bold: true
            }
          }

          Text {
            Layout.fillWidth: true
            text: "This version migrates settings to llama-swap config files (config.yaml and systemone.yaml) with independent persistent background services."
            color: root.bar.foreground
            opacity: 0.8
            wrapMode: Text.WordWrap
            font.family: root.bar.fontFamily
            font.pixelSize: root.fontSizeSmall
          }

          // Migration report / summary box
          Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
            border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.15)
            border.width: 1
            radius: 4

            Flickable {
              anchors.fill: parent
              anchors.margins: Style.space(6)
              contentWidth: width
              contentHeight: reportText.implicitHeight
              clip: true

              Text {
                id: reportText
                width: parent.width
                text: root.migrationReport !== "" ? root.migrationReport : "Ready to migrate existing settings and models."
                color: root.bar.foreground
                opacity: 0.9
                wrapMode: Text.WrapAnywhere
                font.family: "monospace"
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            Layout.fillWidth: true
            visible: root.migrationError !== ""
            text: root.migrationError
            color: Commons.Color.urgent
            wrapMode: Text.WordWrap
            font.family: root.bar.fontFamily
            font.pixelSize: root.fontSizeSmall
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(12)

            TextAction {
              text: "Start fresh"
              enabled: !root.migrationRunning
              onClicked: root.runMigration(true)
            }

            Item { Layout.fillWidth: true }

            TextAction {
              text: "Cancel"
              visible: root.migrationDone || !root.migrationNeeded
              enabled: !root.migrationRunning
              onClicked: root.showingMigration = false
            }

            TextAction {
              active: true
              text: root.migrationRunning ? "Migrating…" : "Migrate"
              enabled: !root.migrationRunning
              onClicked: root.runMigration(false)
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
          visible: !root.showingLogs && !root.showingSetup && !root.showingSettings && !root.showingMigration
          clip: true

          // Server ------------------------------------------------------
          ColumnLayout {
            anchors.fill: parent
            spacing: Style.space(8)
            visible: root.currentPage === 0

            // Backend section -----------------------------------------------
            // Backend and endpoint. Same shape as the tuning rows: a label,
            // a dotted leader, and the value the next start will use. Clicking
            // the row is what changes it, which keeps two controls out of a
            // page that already has enough of them.
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 2

              Rectangle {
                id: backendRow
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                color: backendHover.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)

                  Text {
                    text: "Backend"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }

                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }

                  Text {
                    text: root.backendSpec.label
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                }

                MouseArea {
                  id: backendHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  enabled: !root.running && !root.starting
                  onClicked: backendPopup.open()
                }
                PanelToolTip {
                  visible: backendHover.containsMouse
                  text: root.running || root.starting
                    ? "Stop the server to change the backend."
                    : "The inference server this widget launches."
                }

                Popup {
                  id: backendPopup
                  x: 0
                  y: parent.height + 4
                  width: 260
                  height: backendPopupCol.implicitHeight + 16
                  padding: 8
                  background: Rectangle {
                    color: Commons.Color.menu.background
                    radius: 6
                    border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)
                    border.width: 1
                  }
                  ColumnLayout {
                    id: backendPopupCol
                    width: parent.width
                    spacing: 6
                    Dropdown {
                      Layout.fillWidth: true
                      showLabel: false
                      options: root.installedBackends.map(function(b) { return { value: b.id, label: b.label } })
                      value: root.backend
                      onChanged: function(v) {
                        root.backend = v
                        backendPopup.close()
                      }
                    }
                  }
                }
              }

              BuildPickerRow { readOnly: root.running || root.starting }

              Rectangle {
                id: endpointRow
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                property bool editing: false
                color: endpointHover.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)
                  visible: !endpointRow.editing

                  Text {
                    text: "host:port"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }

                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }

                  Text {
                    text: root.host + ":" + root.port
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: (root.running || root.starting) ? 0.45 : 0.85
                  }
                }

                TextField {
                  id: endpointEdit
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  visible: endpointRow.editing
                  text: root.host + ":" + root.port
                  placeholderText: "127.0.0.1:8080"
                  onEditingFinished: {
                    var value = String(text).trim()
                    // Split on the last colon: an IPv6 literal is bracketed,
                    // so the port is always what follows the final one.
                    var cut = value.lastIndexOf(":")
                    if (cut > 0) {
                      var address = value.slice(0, cut).trim()
                      var portText = value.slice(cut + 1).trim()
                      var port = parseInt(portText, 10)
                      if (address !== "" && isFinite(port) && port >= 1 && port <= 65535) {
                        root.host = address
                        root.setPort(String(port))
                      }
                    }
                    endpointRow.editing = false
                  }
                  Keys.onEscapePressed: endpointRow.editing = false
                }

                MouseArea {
                  id: endpointHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  visible: !endpointRow.editing
                  enabled: !root.running && !root.starting
                  onClicked: {
                    endpointRow.editing = true
                    endpointEdit.text = root.host + ":" + root.port
                    endpointEdit.forceActiveFocus()
                  }
                }
                PanelToolTip {
                  visible: endpointHover.containsMouse
                  text: root.running || root.starting
                    ? "Stop the server to change the endpoint."
                    : "Address the server listens on — host:port, e.g. 127.0.0.1:8080."
                }
              }

              // Start on login toggle
              Rectangle {
                id: loginRow
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                color: loginHover.hovered
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)

                  Text {
                    text: "Start on login"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }

                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }

                  Text {
                    text: root.loginOn(root.backend) ? "on" : "off"
                    color: root.loginOn(root.backend) ? Commons.Color.accent : root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: root.loginOn(root.backend) ? 1.0 : 0.6
                  }
                }

                HoverHandler { id: loginHover; cursorShape: Qt.PointingHandCursor }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setStartOnLogin(root.backend, !root.loginOn(root.backend))
                }
                PanelToolTip {
                  visible: loginHover.hovered
                  fontSize: root.fontSize
                  text: "Enable the " + root.backendSpec.label + " user systemd service to start when you log in."
                }
              }
            }


            // llama-server runs without an API key here, so an endpoint off
            // loopback serves the model -- and its slot save/restore API -- to
            // anyone who can reach the port.
            Text {
              Layout.fillWidth: true
              visible: !/^(127\.|localhost$|\[::1\]$|::1$)/.test(String(root.host).trim())
              text: "⚠ " + root.host + " is reachable from other machines, and the server has no API key. " +
                    "Use 127.0.0.1 unless you mean to share it."
              color: root.bar.urgent
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
            }

            Text {
              Layout.fillWidth: true
              visible: root.running || root.starting
              text: "Stop the server to change backend, build or endpoint."
              color: root.bar.foreground
              opacity: 0.5
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
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
              font.pixelSize: root.fontSize
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
              font.pixelSize: root.fontSize
            }
            // System One section ------------------------------------------
            Item { Layout.fillWidth: true; Layout.preferredHeight: Style.space(4) }

            Text {
              Layout.fillWidth: true
              visible: root.backend === "systemone"
              text: "System One"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
              font.bold: true
            }

            RowLayout {
              Layout.fillWidth: true
              visible: root.backend === "systemone"
              spacing: Style.space(4)

              TextField {
                Layout.fillWidth: true
                text: root.configuredSystemoneBinary
                placeholderText: "systemone binary path (blank = preferred llama-server)"
                enabled: !root.running && !root.starting
                opacity: enabled ? 1.0 : 0.45
                onEditingFinished: root.setSystemoneBinary(text)
              }
            }

            RowLayout {
              Layout.fillWidth: true
              visible: root.backend === "systemone"
              spacing: Style.space(4)

              SearchableDropdown {
                Layout.fillWidth: true
                label: "System One Model"
                showLabel: false
                options: root.systemoneModelOptions
                value: root.systemoneModel
                placeholderText: "Select a System One model…"
                emptyText: root.systemoneScanning ? "Scanning…" : "No models found"
                triggerLabel: root.systemoneModel === "" ? "Select a System One model" : ""
                onChanged: function(v) { root.systemoneModel = v }
              }

              Button {
                text: "⟳"
                tooltipText: root.systemoneScanning ? "Scanning…" : "Rescan for System One models"
                enabled: !root.systemoneScanning
                onClicked: root.refreshSystemoneModels()
              }
            }

            TextField {
              Layout.fillWidth: true
              visible: root.backend === "systemone"
              text: root.configuredSystemoneModelsDir
              placeholderText: "System One models directory (blank = main model scan)"
              enabled: !root.running && !root.starting
              opacity: enabled ? 1.0 : 0.45
              onEditingFinished: root.setSystemoneModelsDir(text)
            }

            Item { Layout.fillHeight: true }

            Text {
              Layout.fillWidth: true
              text: root.hardwareSummary !== "" ? root.hardwareSummary : "Detecting hardware…"
              color: root.bar.foreground
              opacity: 0.6
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
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
              font.pixelSize: root.fontSize
            }
          }

          // Model -------------------------------------------------------
          ColumnLayout {
            anchors.fill: parent
            spacing: Style.space(6)
            visible: root.currentPage === 1

            // Model row -------------------------------------------------
            // The picker lives here, not on Server: choosing a model is
            // browsing a collection, and the collection is a folder tree.
            Rectangle {
              id: modelRow
              Layout.fillWidth: true
              implicitHeight: 26
              radius: 3
              color: "transparent"

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)
                spacing: Style.space(4)

                Text {
                  text: "Model"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                  opacity: 0.85
                }

                Text {
                  Layout.fillWidth: true
                  text: "...................................................................................................."
                  color: root.bar.foreground
                  opacity: 0.15
                  elide: Text.ElideRight
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }

                Text {
                  Layout.maximumWidth: modelRow.width * 0.72
                  text: root.selectedModelLabel !== ""
                        ? root.selectedModelLabel
                        : (root.activeScanning ? "Scanning…" : "Select a model")
                  color: root.bar.foreground
                  opacity: root.selectedModelLabel !== "" ? 0.85 : 0.45
                  elide: Text.ElideRight
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }

              }

              HoverHandler { id: modelRowHover }
              PanelToolTip {
                visible: modelRowHover.hovered
                text: root.launchModel !== ""
                      ? root.launchModel.replace(Quickshell.env("HOME"), "~")
                      : "Pick the model this server loads."
              }
            }

            // Accordion -------------------------------------------------
            // One chain open at a time. Filtering swaps the tree for a flat
            // result list, which is the only way to find one model by name
            // in a collection hundreds deep.
            ColumnLayout {
              Layout.fillWidth: true
              Layout.fillHeight: true
              spacing: 2

              Rectangle {
                Layout.fillWidth: true
                implicitHeight: 24
                color: "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)

                  Text {
                    text: "Filter"
                    color: root.bar.foreground
                    opacity: 0.7
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }

                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }

                  TextField {
                    id: modelFilterField
                    Layout.preferredWidth: Math.max(Style.space(130), modelRow.width * 0.45)
                    implicitHeight: 22
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    placeholderText: "name or folder"
                    text: root.modelFilter
                    onTextEdited: root.modelFilter = text
                  }

                  Text {
                    visible: root.modelFilter !== ""
                    text: "×"
                    Layout.leftMargin: Style.space(8)
                    color: root.bar.foreground
                    opacity: filterClearHover.hovered ? 0.9 : 0.45
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    HoverHandler { id: filterClearHover; cursorShape: Qt.PointingHandCursor }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.modelFilter = ""
                        modelFilterField.text = ""
                      }
                    }
                  }
                }
              }

              Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 4
                color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.035)

                Flickable {
                  id: modelFlick
                  anchors.fill: parent
                  anchors.margins: 2
                  clip: true
                  contentWidth: width
                  contentHeight: modelColumn.implicitHeight
                  boundsBehavior: Flickable.StopAtBounds
                  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                  Column {
                    id: modelColumn
                    width: modelFlick.width
                    spacing: 0

                    Repeater {
                      model: root.modelRows

                      delegate: Rectangle {
                        required property var modelData

                        readonly property var node: modelData.node
                        readonly property int depth: modelData.depth
                        readonly property bool isDir: node.type === "dir"
                        readonly property bool current: !isDir && node.path === root.launchModel
                        readonly property bool open: isDir && root.expandedModelDirs[node.path] === true

                        width: modelColumn.width
                        height: 26
                        radius: 3
                        color: current
                          ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.10)
                          : (rowHover.hovered
                              ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                              : "transparent")

                        RowLayout {
                          anchors.fill: parent
                          anchors.leftMargin: Style.space(4) + depth * Style.space(12)
                          anchors.rightMargin: Style.space(4)
                          spacing: Style.space(4)

                          Text {
                            text: isDir ? (open ? "-" : "+") : "·"
                            color: current ? Commons.Color.accent : root.bar.foreground
                            opacity: current ? 1.0 : 0.45
                            font.family: root.bar.fontFamily
                            font.pixelSize: root.fontSize
                          }

                          Text {
                            Layout.fillWidth: true
                            text: isDir ? node.name : node.label
                            color: current ? Commons.Color.accent : root.bar.foreground
                            opacity: isDir ? 0.9 : (current ? 1.0 : 0.85)
                            elide: Text.ElideRight
                            font.family: root.bar.fontFamily
                            font.pixelSize: root.fontSize
                          }

                          RowLayout {
                            Layout.maximumWidth: modelColumn.width * 0.45
                            spacing: Style.space(4)

                            Text {
                              visible: isDir
                              text: isDir ? String(node.count) : ""
                              color: current ? Commons.Color.accent : root.bar.foreground
                              opacity: current ? 0.75 : 0.42
                              font.family: root.bar.fontFamily
                              font.pixelSize: root.fontSize
                            }

                            Repeater {
                              model: isDir
                                ? []
                                : String(node.description || "").split(" · ").filter(function(b) {
                                    return b !== ""
                                  })

                              delegate: Text {
                                required property string modelData
                                readonly property string glyph: root.capabilityGlyph(modelData)

                                Layout.maximumWidth: glyph !== "" ? implicitWidth : modelColumn.width * 0.3
                                text: glyph !== "" ? glyph : modelData
                                color: current ? Commons.Color.accent : root.bar.foreground
                                opacity: current ? 0.75 : (glyph !== "" ? 0.55 : 0.42)
                                elide: Text.ElideRight
                                font.family: root.bar.fontFamily
                                font.pixelSize: root.fontSize
                              }
                            }
                          }
                        }

                        HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            if (isDir) root.toggleModelDir(node)
                            else root.selectActiveModel(node.path)
                          }
                        }
                        PanelToolTip {
                          visible: rowHover.hovered && !isDir && node.description !== ""
                          text: node.description || ""
                        }
                      }
                    }
                  }
                }

                Text {
                  anchors.centerIn: parent
                  visible: root.modelRows.length === 0
                  text: root.activeScanning
                        ? "Scanning…"
                        : (root.modelFilter !== ""
                            ? "No matching model"
                            : (root.backend === "ollama"
                                ? "No models pulled. Run: ollama pull <model>"
                                : "No .gguf files found. Set a models directory in plugin settings."))
                  color: root.bar.foreground
                  opacity: 0.5
                  width: parent.width - Style.space(24)
                  horizontalAlignment: Text.AlignHCenter
                  wrapMode: Text.WordWrap
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
              }
            }

            // Build row -------------------------------------------------
            // The fork/engine this model runs on. A single build is still
            // named here, so it is never a mystery which binary will launch.
            BuildPickerRow { }

            Text {
              Layout.fillWidth: true
              visible: root.running && root.runningModel !== "" &&
                       root.launchModel !== root.runningModel &&
                       Backends.supports(root.backend, "slotKv")
              text: "Running " + Model.baseName(root.runningModel) + " — press Restart to load this one."
              color: root.bar.foreground
              opacity: 0.6
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
            }

            Text {
              Layout.fillWidth: true
              text: {
                if (root.activeScanning) return "Scanning…"
                var n = root.activeModelOptions.length
                if (n === 0) return "No models available"
                var shown = root.modelRows.length
                var capped = root.modelFilter !== "" && shown >= root.modelSearchLimit
                return root.modelFilter !== ""
                  ? shown + (capped ? "+" : "") + " match" + (shown === 1 ? "" : "es") + " of " + n
                  : n + " model" + (n === 1 ? "" : "s") + " available"
              }
              color: root.bar.foreground
              opacity: 0.5
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSizeSmall
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
                  if (root.launchModel === "")
                    return "Select a model first"
                  var name = Model.baseName(root.launchModel).replace(/\.gguf$/i, "")
                  return root.hasProfile ? "Profile · " + name : "Tuning · " + name
                }
                color: root.bar.foreground
                opacity: root.launchModel === "" ? 0.45 : 0.7
                elide: Text.ElideMiddle
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }

              Button {
                visible: root.hasProfile
                text: "Reset"
                tooltipText: "Drop this model's profile and go back to defaults"
                onClicked: clearProfileConfirm.opened = true
              }
            }

            // Sub-tabs: the built-in controls sit on the first page, and
            // added parameters flow onto further ones rather than making the
            // page scroll. A page holds few enough rows that an enum's popup
            // still has room to open downward.
            // Sub-tabs, as plain numbers: an active page is the one shown in
            // the accent colour, not the one drawn as a pressed button.
            RowLayout {
              Layout.fillWidth: true
              visible: root.tuningPageCount > 1
              spacing: Style.space(2)

              Repeater {
                model: root.tuningPageLabels

                Rectangle {
                  required property int index
                  required property var modelData

                  implicitWidth: pageNumber.implicitWidth + Style.space(12)
                  implicitHeight: 22
                  radius: 3
                  color: pageHover.hovered
                    ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.08)
                    : "transparent"

                  Text {
                    id: pageNumber
                    anchors.centerIn: parent
                    text: modelData
                    color: index === root.effectiveTuningPage ? Commons.Color.accent : root.bar.foreground
                    opacity: index === root.effectiveTuningPage ? 1.0 : 0.55
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    font.bold: index === root.effectiveTuningPage
                  }

                  HoverHandler { id: pageHover; cursorShape: Qt.PointingHandCursor }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.tuningPage = index
                  }
                }
              }

              Item { Layout.fillWidth: true }
            }

            // Above the rows, not under them. SearchableDropdown opens its
            // popup downward from the trigger with no flip-up fallback and
            // asks for 220px of it, so the picker sitting at the end of a full
            // parameter list opened straight past the panel's bottom edge --
            // the same clipping the row order at the top of this page is
            // arranged to avoid, in the one control that most needs the room.
            // A row rather than a button: the picker is one more thing on the
            // page, and a bordered box here was the heaviest thing on it.
            Rectangle {
              Layout.fillWidth: true
              implicitHeight: 26
              radius: 3
              visible: !addParamOpen
              color: addHover.hovered && root.addableCount > 0
                ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                : "transparent"

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)

                Text {
                  // "Reading parameters…" only while there is nothing to
                  // offer: a removed row can be restored without any
                  // catalogue at all, and a refresh in the background should
                  // not disable the row.
                  text: root.catalogueLoading && root.addableCount === 0
                    ? "Reading parameters…"
                    : "+  Add parameter" + (root.addableCount > 0 ? "  (" + root.addableCount + ")" : "")
                  color: root.addableCount > 0 ? Commons.Color.accent : root.bar.foreground
                  opacity: root.addableCount > 0 ? 1.0 : 0.45
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }

                Item { Layout.fillWidth: true }
              }

              HoverHandler {
                id: addHover
                cursorShape: root.addableCount > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
              }
              MouseArea {
                anchors.fill: parent
                enabled: root.addableCount > 0
                cursorShape: Qt.PointingHandCursor
                onClicked: addParamOpen = true
              }
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

            // One row per built-in flag, in the same shape as the endpoint:
            // label, dotted leader, value, and a × that takes the row off the
            // page. The value is the thing to click -- a number opens an inline
            // field, an enum opens a list -- so the page reads as a list of
            // settings rather than a form of boxes.
            ColumnLayout {
              Layout.fillWidth: true
              visible: root.tuningPageHasBuiltins
              spacing: 2

              // ---- KV cache k/v ----
              Rectangle {
                id: cacheRow
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                visible: root.builtinOnPage("cacheType")
                color: cacheHoverArea.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)

                  Text {
                    text: "KV cache k/v"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    text: root.cacheTypeK + " / " + root.cacheTypeV
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    text: "×"
                    Layout.leftMargin: Style.space(8)
                    color: cacheHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: cacheHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeBuiltin("cacheType")
                    }
                  }
                }

                MouseArea {
                  id: cacheHoverArea
                  z: -1
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: cachePopup.open()
                }
                PanelToolTip {
                  visible: cacheHoverArea.containsMouse
                  text: "--cache-type-k / --cache-type-v — quantization of the K and V caches. Lower than f16 trades some accuracy for less VRAM per token of context."
                }

                Popup {
                  id: cachePopup
                  x: 0
                  y: parent.height + 4
                  width: 260
                  height: cachePopupCol.implicitHeight + 16
                  padding: 8
                  background: Rectangle {
                    color: Commons.Color.menu.background
                    radius: 6
                    border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)
                    border.width: 1
                  }
                  ColumnLayout {
                    id: cachePopupCol
                    width: parent.width
                    spacing: 6
                    Text {
                      text: "Cache type K"
                      color: root.bar.foreground
                      opacity: 0.7
                      font.family: root.bar.fontFamily
                      font.pixelSize: root.fontSize
                    }
                    Dropdown {
                      Layout.fillWidth: true
                      showLabel: false
                      options: root.availableCacheTypes
                      value: root.cacheTypeK
                      onChanged: function(v) { root.cacheTypeK = v }
                    }
                    Text {
                      text: "Cache type V"
                      color: root.bar.foreground
                      opacity: 0.7
                      font.family: root.bar.fontFamily
                      font.pixelSize: root.fontSize
                    }
                    Dropdown {
                      Layout.fillWidth: true
                      showLabel: false
                      options: root.availableCacheTypes
                      value: root.cacheTypeV
                      onChanged: function(v) { root.cacheTypeV = v }
                    }
                  }
                }
              }
              Text {
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("cacheType") && root.rowHasIgnoredFlag("cacheType")
                text: "⚠ not in this build"
                font.pixelSize: root.fontSizeSmall
                font.italic: true
                color: Commons.Color.urgent
              }

              // ---- Flash attention ----
              Rectangle {
                id: flashRow
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                visible: root.builtinOnPage("flashAttn")
                color: flashHoverArea.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)

                  Text {
                    text: "Flash attn"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    text: root.flashAttn
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    text: "×"
                    Layout.leftMargin: Style.space(8)
                    color: flashHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: flashHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeBuiltin("flashAttn")
                    }
                  }
                }

                MouseArea {
                  id: flashHoverArea
                  z: -1
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    var values = root.flashAttnValues
                    var index = -1
                    for (var i = 0; i < values.length; i++) {
                      var value = typeof values[i] === "object" ? values[i].value : values[i]
                      if (value === root.flashAttn) { index = i; break }
                    }
                    var next = (index + 1) % values.length
                    root.flashAttn = typeof values[next] === "object" ? values[next].value : values[next]
                  }
                }
                PanelToolTip {
                  visible: flashHoverArea.containsMouse
                  text: "--flash-attn — fused attention kernel. Faster and lighter on VRAM; auto leaves the backend to decide, off falls back to the unfused path. Click to cycle."
                }
              }
              Text {
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("flashAttn") && root.rowHasIgnoredFlag("flashAttn")
                text: "⚠ not in this build"
                font.pixelSize: root.fontSizeSmall
                font.italic: true
                color: Commons.Color.urgent
              }

              // ---- GPU layers ----
              Rectangle {
                id: nglRow
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                visible: root.builtinOnPage("ngl")
                property bool editing: false
                color: nglHoverArea.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)
                  visible: !nglRow.editing

                  Text {
                    text: "GPU layers"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    text: root.gpuLayers
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    text: "×"
                    Layout.leftMargin: Style.space(8)
                    color: nglHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: nglHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeBuiltin("ngl")
                    }
                  }
                }

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)
                  visible: nglRow.editing

                  Text {
                    text: "GPU layers"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  NumField {
                    id: nglEdit
                    Layout.fillWidth: true
                    text: root.gpuLayers
                    validator: IntValidator { bottom: -1; top: 999 }
                    onEditingFinished: {
                      root.gpuLayers = text
                      nglRow.editing = false
                    }
                    Keys.onEscapePressed: nglRow.editing = false
                  }
                }

                MouseArea {
                  id: nglHoverArea
                  z: -1
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  visible: !nglRow.editing
                  onClicked: {
                    nglRow.editing = true
                    nglEdit.text = root.gpuLayers
                    nglEdit.forceActiveFocus()
                  }
                }
                PanelToolTip {
                  visible: nglHoverArea.containsMouse
                  text: "--n-gpu-layers — how many layers to offload to the GPU. -1 offloads every layer the backend can fit; 0 keeps the whole model on CPU. Click to edit."
                }
              }

              // ---- MoE on CPU ----
              Rectangle {
                id: moeRow
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                visible: root.builtinOnPage("cpuMoe")
                color: moeHoverArea.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)

                  Text {
                    text: "MoE on CPU"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    text: root.cpuMoe ? "all" : (root.nCpuMoe !== "" ? root.nCpuMoe : "off")
                    color: root.cpuMoe ? Commons.Color.accent : root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    text: "×"
                    Layout.leftMargin: Style.space(8)
                    color: moeHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: moeHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeBuiltin("cpuMoe")
                    }
                  }
                }

                MouseArea {
                  id: moeHoverArea
                  z: -1
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: moePopup.open()
                }
                PanelToolTip {
                  visible: moeHoverArea.containsMouse
                  text: "--n-cpu-moe N — keep the first N layers' experts in system RAM\n" +
                        "All — --cpu-moe, every layer's experts on CPU\n" +
                        "Empty and All off — neither flag is passed"
                }

                Popup {
                  id: moePopup
                  x: 0
                  y: parent.height + 4
                  width: 260
                  height: moePopupCol.implicitHeight + 16
                  padding: 8
                  background: Rectangle {
                    color: Commons.Color.menu.background
                    radius: 6
                    border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)
                    border.width: 1
                  }
                  ColumnLayout {
                    id: moePopupCol
                    width: parent.width
                    spacing: 6
                    Text {
                      text: "Layers whose experts stay on CPU"
                      color: root.bar.foreground
                      opacity: 0.7
                      font.family: root.bar.fontFamily
                      font.pixelSize: root.fontSize
                    }
                    NumField {
                      Layout.fillWidth: true
                      placeholderText: root.cpuMoe ? "all layers" : "off"
                      text: root.nCpuMoe
                      enabled: !root.cpuMoe
                      opacity: enabled ? 1.0 : 0.45
                      validator: IntValidator { bottom: 0; top: 999 }
                      onEditingFinished: root.nCpuMoe = text
                    }
                    Text {
                      Layout.fillWidth: true
                      text: (root.cpuMoe ? "✓ " : "") + "All layers (--cpu-moe)"
                      color: root.cpuMoe ? Commons.Color.accent : root.bar.foreground
                      opacity: root.cpuMoe ? 1.0 : 0.7
                      font.family: root.bar.fontFamily
                      font.pixelSize: root.fontSize
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.cpuMoe = !root.cpuMoe
                          if (root.cpuMoe) root.nCpuMoe = ""
                        }
                      }
                    }
                  }
                }
              }
              Text {
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("cpuMoe") && root.rowHasIgnoredFlag("cpuMoe")
                text: "⚠ not in this build"
                font.pixelSize: root.fontSizeSmall
                font.italic: true
                color: Commons.Color.urgent
              }

              // ---- Context ----
              Rectangle {
                id: ctxRow
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                visible: root.builtinOnPage("ctxSize")
                property bool editing: false
                color: ctxHoverArea.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)
                  visible: !ctxRow.editing

                  Text {
                    text: "Context"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    text: root.contextSize !== "" ? root.contextSize : "0"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    text: "×"
                    Layout.leftMargin: Style.space(8)
                    color: ctxHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: ctxHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeBuiltin("ctxSize")
                    }
                  }
                }

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)
                  visible: ctxRow.editing

                  Text {
                    text: "Context"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  NumField {
                    id: ctxEdit
                    Layout.fillWidth: true
                    text: root.contextSize
                    validator: IntValidator { bottom: 0; top: 10000000 }
                    onEditingFinished: {
                      root.contextSize = text
                      ctxRow.editing = false
                    }
                    Keys.onEscapePressed: ctxRow.editing = false
                  }
                }

                MouseArea {
                  id: ctxHoverArea
                  z: -1
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  visible: !ctxRow.editing
                  onClicked: {
                    ctxRow.editing = true
                    ctxEdit.text = root.contextSize
                    ctxEdit.forceActiveFocus()
                  }
                }
                PanelToolTip {
                  visible: ctxHoverArea.containsMouse
                  text: "--ctx-size — the context window in tokens, shared across every slot. 0 uses the model's own trained context. Click to edit."
                }
              }
              Text {
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("ctxSize") && root.rowHasIgnoredFlag("ctxSize")
                text: "⚠ not in this build"
                font.pixelSize: root.fontSizeSmall
                font.italic: true
                color: Commons.Color.urgent
              }

              // ---- Threads ----
              Rectangle {
                id: threadsRow
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                visible: root.builtinOnPage("threads")
                property bool editing: false
                color: threadsHoverArea.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)
                  visible: !threadsRow.editing

                  Text {
                    text: "Threads"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    text: root.threads !== "" ? root.threads : "auto"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    text: "×"
                    Layout.leftMargin: Style.space(8)
                    color: threadsHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: threadsHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeBuiltin("threads")
                    }
                  }
                }

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)
                  visible: threadsRow.editing

                  Text {
                    text: "Threads"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  NumField {
                    id: threadsEdit
                    Layout.fillWidth: true
                    text: root.threads
                    validator: IntValidator { bottom: 0; top: 512 }
                    onEditingFinished: {
                      root.threads = text
                      threadsRow.editing = false
                    }
                    Keys.onEscapePressed: threadsRow.editing = false
                  }
                }

                MouseArea {
                  id: threadsHoverArea
                  z: -1
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  visible: !threadsRow.editing
                  onClicked: {
                    threadsRow.editing = true
                    threadsEdit.text = root.threads
                    threadsEdit.forceActiveFocus()
                  }
                }
                PanelToolTip {
                  visible: threadsHoverArea.containsMouse
                  text: "--threads — CPU threads for generation. Only matters for work not offloaded to the GPU, so it does little on a fully-offloaded model. Click to edit."
                }
              }
              Text {
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("threads") && root.rowHasIgnoredFlag("threads")
                text: "⚠ not in this build"
                font.pixelSize: root.fontSizeSmall
                font.italic: true
                color: Commons.Color.urgent
              }

              // ---- Batch / ubatch ----
              Rectangle {
                id: batchRow
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                visible: root.builtinOnPage("batchSize")
                color: batchHoverArea.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)

                  Text {
                    text: "Batch / ubatch"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    text: (root.batchSize !== "" ? root.batchSize : "auto") + " / " +
                          (root.ubatchSize !== "" ? root.ubatchSize : "auto")
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    text: "×"
                    Layout.leftMargin: Style.space(8)
                    color: batchHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: batchHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeBuiltin("batchSize")
                    }
                  }
                }

                MouseArea {
                  id: batchHoverArea
                  z: -1
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: batchPopup.open()
                }
                PanelToolTip {
                  visible: batchHoverArea.containsMouse
                  text: "--batch-size / --ubatch-size — tokens processed per prompt-eval pass and per physical GPU batch. Higher trades VRAM for faster prompt processing."
                }

                Popup {
                  id: batchPopup
                  x: 0
                  y: parent.height + 4
                  width: 280
                  height: batchPopupCol.implicitHeight + 16
                  padding: 8
                  background: Rectangle {
                    color: Commons.Color.menu.background
                    radius: 6
                    border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)
                    border.width: 1
                  }
                  ColumnLayout {
                    id: batchPopupCol
                    width: parent.width
                    spacing: 6
                    Text {
                      text: "Batch"
                      color: root.bar.foreground
                      opacity: 0.7
                      font.family: root.bar.fontFamily
                      font.pixelSize: root.fontSize
                    }
                    NumField {
                      Layout.fillWidth: true
                      text: root.batchSize
                      placeholderText: "auto"
                      validator: IntValidator { bottom: 0; top: 1000000 }
                      onEditingFinished: root.batchSize = text
                    }
                    Text {
                      text: "Ubatch"
                      color: root.bar.foreground
                      opacity: 0.7
                      font.family: root.bar.fontFamily
                      font.pixelSize: root.fontSize
                    }
                    NumField {
                      Layout.fillWidth: true
                      text: root.ubatchSize
                      placeholderText: "auto"
                      validator: IntValidator { bottom: 0; top: 1000000 }
                      onEditingFinished: root.ubatchSize = text
                    }
                  }
                }
              }
              Text {
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("batchSize") && root.rowHasIgnoredFlag("batchSize")
                text: "⚠ not in this build"
                font.pixelSize: root.fontSizeSmall
                font.italic: true
                color: Commons.Color.urgent
              }

              // ---- Slots ----
              Rectangle {
                id: parallelRow
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                visible: root.builtinOnPage("parallel")
                property bool editing: false
                color: parallelHoverArea.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)
                  visible: !parallelRow.editing

                  Text {
                    text: "Slots (-np)"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    text: root.parallel !== "" ? root.parallel : "auto"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    text: "×"
                    Layout.leftMargin: Style.space(8)
                    color: parallelHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: parallelHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeBuiltin("parallel")
                    }
                  }
                }

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)
                  visible: parallelRow.editing

                  Text {
                    text: "Slots (-np)"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  NumField {
                    id: parallelEdit
                    Layout.fillWidth: true
                    text: root.parallel
                    placeholderText: "auto"
                    validator: IntValidator { bottom: 0; top: 256 }
                    onEditingFinished: {
                      root.parallel = text
                      parallelRow.editing = false
                    }
                    Keys.onEscapePressed: parallelRow.editing = false
                  }
                }

                MouseArea {
                  id: parallelHoverArea
                  z: -1
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  visible: !parallelRow.editing
                  onClicked: {
                    parallelRow.editing = true
                    parallelEdit.text = root.parallel
                    parallelEdit.forceActiveFocus()
                  }
                }
                PanelToolTip {
                  visible: parallelHoverArea.containsMouse
                  text: "Number of server slots. Blank leaves the backend on auto.\nEach slot holds its own KV cache, so the context above is divided between them."
                }
              }
              Text {
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("parallel") && root.rowHasIgnoredFlag("parallel")
                text: "⚠ not in this build"
                font.pixelSize: root.fontSizeSmall
                font.italic: true
                color: Commons.Color.urgent
              }

              // ---- Reasoning trace ----
              Rectangle {
                id: reasoningRow
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                visible: root.builtinOnPage("reasoning")
                color: reasoningHoverArea.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)

                  Text {
                    text: "Reasoning trace"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    text: root.reasoningPreserve
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    text: "×"
                    Layout.leftMargin: Style.space(8)
                    color: reasoningHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: reasoningHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeBuiltin("reasoning")
                    }
                  }
                }

                MouseArea {
                  id: reasoningHoverArea
                  z: -1
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    var values = root.tristateValues
                    var index = -1
                    for (var i = 0; i < values.length; i++) {
                      var value = typeof values[i] === "object" ? values[i].value : values[i]
                      if (value === root.reasoningPreserve) { index = i; break }
                    }
                    var next = (index + 1) % values.length
                    root.reasoningPreserve = typeof values[next] === "object" ? values[next].value : values[next]
                  }
                }
                PanelToolTip {
                  visible: reasoningHoverArea.containsMouse
                  text: "--reasoning-preserve: keep the thinking trace across the whole history rather than only the last reply.\n\"default\" passes neither the flag nor its negation, leaving the chat template's own choice — which is the only safe setting for a template that does not support it. Click to cycle."
                }
              }
              Text {
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("reasoning") && root.rowHasIgnoredFlag("reasoning")
                text: "⚠ not in this build"
                font.pixelSize: root.fontSizeSmall
                font.italic: true
                color: Commons.Color.urgent
              }

              // ---- Speculative ----
              Rectangle {
                id: specRow
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                visible: root.builtinOnPage("specType")
                color: specHoverArea.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)

                  Text {
                    text: "Speculative"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    text: root.specType
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    text: "×"
                    Layout.leftMargin: Style.space(8)
                    color: specHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: specHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeBuiltin("specType")
                    }
                  }
                }

                MouseArea {
                  id: specHoverArea
                  z: -1
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: specPopup.open()
                }
                PanelToolTip {
                  visible: specHoverArea.containsMouse
                  text: root.specType !== "none" && !root.specTypeUserSet
                    ? "--spec-type, picked from this model's own metadata. Change it and the pick stops being automatic."
                    : "--spec-type: draft or n-gram strategy. Only some models carry the weights a draft mode needs."
                }

                Popup {
                  id: specPopup
                  x: 0
                  y: parent.height + 4
                  width: 260
                  height: specPopupCol.implicitHeight + 16
                  padding: 8
                  background: Rectangle {
                    color: Commons.Color.menu.background
                    radius: 6
                    border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)
                    border.width: 1
                  }
                  ColumnLayout {
                    id: specPopupCol
                    width: parent.width
                    spacing: 6
                    SearchableDropdown {
                      Layout.fillWidth: true
                      showLabel: false
                      options: root.specTypeValues
                      value: root.specType
                      triggerLabel: root.specType
                      onChanged: function(v) {
                        root.specType = v
                        // Choosing here ends the automatic pick: the next MTP
                        // model selected must not quietly overwrite it.
                        root.specTypeUserSet = true
                        specPopup.close()
                      }
                    }
                  }
                }
              }
              Text {
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("specType") && root.rowHasIgnoredFlag("specType")
                text: "⚠ not in this build"
                font.pixelSize: root.fontSizeSmall
                font.italic: true
                color: Commons.Color.urgent
              }

              // ---- Vision projector ----
              Rectangle {
                id: visionRow
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                visible: root.builtinOnPage("vision")
                color: visionHoverArea.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)

                  Text {
                    text: "Vision projector"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    text: root.mmprojMode + (root.mmprojActive ? " · offload " + root.mmprojOffload : "")
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    text: "×"
                    Layout.leftMargin: Style.space(8)
                    color: visionHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: visionHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeBuiltin("vision")
                    }
                  }
                }

                MouseArea {
                  id: visionHoverArea
                  z: -1
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: visionPopup.open()
                }
                PanelToolTip {
                  visible: visionHoverArea.containsMouse
                  text: root.detectedMmproj !== ""
                    ? "Found next to this model:\n" + root.detectedMmproj +
                      "\n\nauto: use it · off: --no-mmproj · custom: name another file"
                    : "auto: use a projector found next to the model — none was\noff: --no-mmproj · custom: name a file"
                }

                Popup {
                  id: visionPopup
                  x: 0
                  // This row sits low on the page: open upward rather than
                  // past the panel's clipped bottom edge.
                  y: -height - 4
                  width: 300
                  height: visionPopupCol.implicitHeight + 16
                  padding: 8
                  background: Rectangle {
                    color: Commons.Color.menu.background
                    radius: 6
                    border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)
                    border.width: 1
                  }
                  ColumnLayout {
                    id: visionPopupCol
                    width: parent.width
                    spacing: 6
                    Text {
                      text: "Projector mode"
                      color: root.bar.foreground
                      opacity: 0.7
                      font.family: root.bar.fontFamily
                      font.pixelSize: root.fontSize
                    }
                    Dropdown {
                      Layout.fillWidth: true
                      showLabel: false
                      options: root.mmprojModes
                      value: root.mmprojMode
                      onChanged: function(v) { root.mmprojMode = v }
                    }
                    Text {
                      text: "Offload"
                      color: root.bar.foreground
                      opacity: root.mmprojActive ? 0.7 : 0.3
                      font.family: root.bar.fontFamily
                      font.pixelSize: root.fontSize
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
                    TextField {
                      Layout.fillWidth: true
                      visible: root.mmprojMode === "custom"
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
                }
              }
              Text {
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("vision") && root.rowHasIgnoredFlag("vision")
                text: "⚠ not in this build"
                font.pixelSize: root.fontSizeSmall
                font.italic: true
                color: Commons.Color.urgent
              }

              // ---- Paste args ----
              Rectangle {
                id: extraRow
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                visible: root.builtinOnPage("extraArgs")
                property bool editing: false
                color: extraHoverArea.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)
                  visible: !extraRow.editing

                  Text {
                    text: "Paste args"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    text: root.extraArgs !== "" ? "..." : "—"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.5
                  }
                  Text {
                    text: "×"
                    Layout.leftMargin: Style.space(8)
                    color: extraHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: extraHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeBuiltin("extraArgs")
                    }
                  }
                }

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)
                  visible: extraRow.editing

                  Text {
                    text: "Paste args"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  TextField {
                    id: extraEdit
                    Layout.fillWidth: true
                    text: root.extraArgs
                    placeholderText: "-np 1 --reasoning-preserve …"
                    onEditingFinished: {
                      root.extraArgs = text
                      extraRow.editing = false
                    }
                    Keys.onEscapePressed: extraRow.editing = false
                  }
                }

                MouseArea {
                  id: extraHoverArea
                  z: -1
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  visible: !extraRow.editing
                  onClicked: {
                    extraRow.editing = true
                    extraEdit.text = root.extraArgs
                    extraEdit.forceActiveFocus()
                  }
                }
                PanelToolTip {
                  visible: extraHoverArea.containsMouse
                  text: "Paste a command line here and it splits into rows — one per flag, filling the controls above where a flag has one.\nThe field empties as it is consumed; it stores nothing of its own."
                }
              }
              Text {
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("extraArgs") && root.rowHasIgnoredFlag("extraArgs")
                text: "⚠ not in this build"
                font.pixelSize: root.fontSizeSmall
                font.italic: true
                color: Commons.Color.urgent
              }

              // ---- Environment ----
              // A small editor instead of one whitespace-separated line:
              // values may contain spaces, and each variable gets its own
              // row so it can be changed or removed without retyping the rest.
              Rectangle {
                id: envRow
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                visible: root.builtinOnPage("envVars")
                color: envHoverArea.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                // Declared before the row so the × child sits above it and
                // gets the click that removes the row, not the editor.
                MouseArea {
                  id: envHoverArea
                  z: -1
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: envPopup.open()
                }

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)

                  Text {
                    text: "Environment"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    Layout.maximumWidth: envRow.width * 0.5
                    text: {
                      var n = root.parsedEnv.env.length
                      if (n === 0) return "—"
                      if (n === 1) return root.parsedEnv.env[0].name + "=" + root.parsedEnv.env[0].value
                      return n + " variables"
                    }
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.5
                    elide: Text.ElideRight
                  }
                  Text {
                    text: "v"
                    color: root.bar.foreground
                    opacity: 0.5
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    text: "×"
                    Layout.leftMargin: Style.space(8)
                    color: envHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: envHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeBuiltin("envVars")
                    }
                  }
                }

                PanelToolTip {
                  visible: envHoverArea.containsMouse
                  text: "Environment variables for the server, per model. Click to edit."
                }

                Popup {
                  id: envPopup
                  x: 0
                  y: parent.height + 4
                  width: envRow.width
                  height: Math.min(Style.space(420), envPopupCol.implicitHeight + 16)
                  padding: 8
                  focus: true
                  property string error: ""
                  // Edited here, written once when the popup closes: a field
                  // that loses focus because the popup vanished must not lose
                  // the value that was typed into it.
                  property var draft: []
                  property bool dirty: false
                  onOpened: {
                    draft = root.parsedEnv.env.map(function(e) { return { name: e.name, value: e.value } })
                    dirty = false
                  }
                  onClosed: {
                    if (!dirty) return
                    root.extraEnv = Model.formatEnvAssignments(draft)
                    dirty = false
                  }

                  background: Rectangle {
                    color: Commons.Color.menu.background
                    radius: 6
                    border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)
                    border.width: 1
                  }

                  function addVar() {
                    var name = newEnvName.text.trim()
                    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) {
                      error = "Name must use A-Z, 0-9 or _, and not start with a digit."
                      return
                    }
                    var env = draft.slice()
                    var found = false
                    for (var i = 0; i < env.length; i++)
                      if (env[i].name === name) { env[i] = { name: name, value: newEnvValue.text }; found = true; break }
                    if (!found) env.push({ name: name, value: newEnvValue.text })
                    draft = env
                    dirty = true
                    newEnvName.text = ""
                    newEnvValue.text = ""
                    error = ""
                    newEnvName.forceActiveFocus()
                  }

                  function removeVar(index) {
                    if (index < 0 || index >= draft.length) return
                    var env = draft.slice()
                    env.splice(index, 1)
                    draft = env
                    dirty = true
                  }

                  ColumnLayout {
                    id: envPopupCol
                    width: parent.width
                    spacing: Style.space(6)

                    Flickable {
                      id: envFlick
                      Layout.fillWidth: true
                      Layout.preferredHeight: Math.min(Style.space(220), envList.implicitHeight)
                      contentWidth: width
                      contentHeight: envList.implicitHeight
                      clip: true
                      boundsBehavior: Flickable.StopAtBounds

                      Column {
                        id: envList
                        width: envFlick.width
                        spacing: 2

                        Repeater {
                          model: envPopup.draft

                          delegate: Rectangle {
                            required property var modelData
                            required property int index

                            width: envList.width
                            height: 26
                            radius: 3
                            color: envVarHover.hovered
                              ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                              : "transparent"

                            RowLayout {
                              anchors.fill: parent
                              anchors.leftMargin: Style.space(4)
                              anchors.rightMargin: Style.space(4)
                              spacing: Style.space(4)

                              Text {
                                Layout.preferredWidth: Style.space(110)
                                text: modelData.name
                                color: root.bar.foreground
                                opacity: 0.85
                                elide: Text.ElideRight
                                font.family: root.bar.fontFamily
                                font.pixelSize: root.fontSize
                              }
                              TextField {
                                Layout.fillWidth: true
                                text: modelData.value
                                placeholderText: "value"
                                font.family: root.bar.fontFamily
                                font.pixelSize: root.fontSize
                                onTextEdited: { envPopup.draft[index].value = text; envPopup.dirty = true }
                              }
                              Text {
                                text: "×"
                                Layout.leftMargin: Style.space(8)
                                color: envVarHover.hovered ? Commons.Color.urgent : root.bar.foreground
                                opacity: envVarHover.hovered ? 0.8 : 0.3
                                font.family: root.bar.fontFamily
                                font.pixelSize: root.fontSize
                                MouseArea {
                                  anchors.fill: parent
                                  cursorShape: Qt.PointingHandCursor
                                  onClicked: envPopup.removeVar(index)
                                }
                              }
                            }

                            HoverHandler { id: envVarHover }
                          }
                        }
                      }
                    }

                    Text {
                      Layout.fillWidth: true
                      visible: root.parsedEnv.invalid.length > 0
                      text: "Ignored: " + root.parsedEnv.invalid.join(" ")
                      color: Commons.Color.urgent
                      wrapMode: Text.WordWrap
                      font.family: root.bar.fontFamily
                      font.pixelSize: root.fontSizeSmall
                    }

                    RowLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(4)

                      TextField {
                        id: newEnvName
                        Layout.preferredWidth: Style.space(110)
                        placeholderText: "NAME"
                        font.family: root.bar.fontFamily
                        font.pixelSize: root.fontSize
                        onAccepted: envPopup.addVar()
                      }
                      TextField {
                        id: newEnvValue
                        Layout.fillWidth: true
                        placeholderText: "value"
                        font.family: root.bar.fontFamily
                        font.pixelSize: root.fontSize
                        onAccepted: envPopup.addVar()
                      }
                      TextAction {
                        text: "Add"
                        onClicked: envPopup.addVar()
                      }
                    }

                    Text {
                      Layout.fillWidth: true
                      visible: envPopup.error !== ""
                      text: envPopup.error
                      color: Commons.Color.urgent
                      wrapMode: Text.WordWrap
                      font.family: root.bar.fontFamily
                      font.pixelSize: root.fontSizeSmall
                    }

                    RowLayout {
                      Layout.fillWidth: true
                      TextAction {
                        text: "Done"
                        active: true
                        onClicked: envPopup.close()
                      }
                    }
                  }
                }
              }

              // ---- System One context ----
              Rectangle {
                id: systemoneCtxRow
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                visible: root.builtinOnPage("systemoneCtx")
                property bool editing: false
                color: systemoneCtxHoverArea.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)
                  visible: !systemoneCtxRow.editing

                  Text {
                    text: "System One context"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    text: root.systemoneCtx !== "" ? root.systemoneCtx : "0"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    text: "×"
                    Layout.leftMargin: Style.space(8)
                    color: systemoneCtxHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: systemoneCtxHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeBuiltin("systemoneCtx")
                    }
                  }
                }

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)
                  visible: systemoneCtxRow.editing

                  Text {
                    text: "System One context"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  NumField {
                    id: systemoneCtxEdit
                    Layout.fillWidth: true
                    text: root.systemoneCtx
                    validator: IntValidator { bottom: 0; top: 10000000 }
                    onEditingFinished: {
                      root.systemoneCtx = text
                      systemoneCtxRow.editing = false
                    }
                    Keys.onEscapePressed: systemoneCtxRow.editing = false
                  }
                }

                MouseArea {
                  id: systemoneCtxHoverArea
                  z: -1
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  visible: !systemoneCtxRow.editing
                  onClicked: {
                    systemoneCtxRow.editing = true
                    systemoneCtxEdit.text = root.systemoneCtx
                    systemoneCtxEdit.forceActiveFocus()
                  }
                }
                PanelToolTip {
                  visible: systemoneCtxHoverArea.containsMouse
                  text: "Context window for the System One backend, in tokens."
                }
              }
              Text {
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("systemoneCtx") && root.rowHasIgnoredFlag("systemoneCtx")
                text: "⚠ not in this build"
                font.pixelSize: root.fontSizeSmall
                font.italic: true
                color: Commons.Color.urgent
              }
            }

            // Added parameters for this sub-page, one dotted row each. The
            // value is the control: clicking the row opens the editor that
            // fits the type, so a page of parameters reads like the built-in
            // rows above it.
            Repeater {
              model: root.customParamsForPage(root.effectiveTuningPage)

              Rectangle {
                required property var modelData
                id: customRow
                Layout.fillWidth: true
                implicitHeight: 26
                radius: 3
                color: customHover.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                readonly property var spec: Params.find(root.paramCatalogue, modelData.key)
                readonly property string ptype: spec
                  ? spec.type
                  : (modelData.type ? modelData.type : "string")
                readonly property bool longOptionList: spec && spec.options.length > 12

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)

                  Text {
                    text: spec ? spec.label : modelData.key
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                    elide: Text.ElideRight
                  }
                  Text {
                    Layout.fillWidth: true
                    text: "...................................................................................................."
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    text: customRow.ptype === "bool"
                      ? (modelData.value === "true" ? "on" : "off")
                      : (String(modelData.value) !== "" ? modelData.value : "—")
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                    elide: Text.ElideRight
                    Layout.maximumWidth: Style.space(140)
                  }
                  Text {
                    text: "×"
                    Layout.leftMargin: Style.space(8)
                    color: customHover.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: customHover.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeCustomParam(modelData.key)
                    }
                  }
                }

                MouseArea {
                  id: customHover
                  // Below the row content, like every built-in row, so the ✕
                  // is reachable instead of only opening the editor.
                  z: -1
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: customPopup.open()
                }
                PanelToolTip {
                  visible: customHover.containsMouse
                  text: modelData.key + (spec && spec.description ? "\n" + spec.description : "")
                }

                Popup {
                  id: customPopup
                  x: 0
                  y: parent.height + 4
                  width: 280
                  height: customPopupCol.implicitHeight + 16
                  padding: 8
                  background: Rectangle {
                    color: Commons.Color.menu.background
                    radius: 6
                    border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)
                    border.width: 1
                  }

                  ColumnLayout {
                    id: customPopupCol
                    width: parent.width
                    spacing: 6

                    // Booleans are presence-only flags, so the control is on/off.
                    Toggle {
                      visible: customRow.ptype === "bool"
                      checked: modelData.value === "true"
                      onClicked: root.setCustomParam(modelData.key, modelData.value === "true" ? "false" : "true")
                    }

                    // Enums are chosen, never typed: the value has to be one
                    // the backend accepts, and a typo here only surfaces as a
                    // server that refuses to start.
                    Dropdown {
                      Layout.fillWidth: true
                      visible: (customRow.ptype === "enum" || customRow.ptype === "tristate") && !customRow.longOptionList
                      showLabel: false
                      options: customRow.spec ? customRow.spec.options : []
                      value: modelData.value
                      onChanged: function(v) { root.setCustomParam(modelData.key, v) }
                    }

                    // Past a dozen entries a plain dropdown is a wall to
                    // scroll -- --cache-type-k offers 17 quant types -- so the
                    // same choice is offered with a filter box. Still a closed
                    // set: the field searches the options, it does not accept
                    // a new value.
                    SearchableDropdown {
                      Layout.fillWidth: true
                      visible: customRow.ptype === "enum" && customRow.longOptionList
                      options: customRow.spec ? customRow.spec.options : []
                      value: modelData.value
                      triggerLabel: modelData.value
                      onChanged: function(v) { root.setCustomParam(modelData.key, v) }
                    }

                    TextField {
                      Layout.fillWidth: true
                      visible: customRow.ptype !== "bool" && customRow.ptype !== "enum" && customRow.ptype !== "tristate"
                      text: modelData.value
                      // Typing severs the declarative `text` binding, so the
                      // field would keep showing a stale value after the
                      // source changes elsewhere. Restored whenever the field
                      // is not being edited.
                      Binding on text {
                        value: modelData.value
                        when: !activeFocus
                        restoreMode: Binding.RestoreNone
                      }
                      onEditingFinished: root.setCustomParam(modelData.key, text)
                    }
                  }
                }
              }
            }


            // ollama only understands OLLAMA_* variables. A row left over from
            // a llama.cpp profile is not passed; name it instead of letting
            // envPrefix drop it silently.
            Text {
              Layout.fillWidth: true
              visible: root.backend === "ollama" && root.ollamaInvalidParams.length > 0
              text: "Ignored by ollama (not OLLAMA_* variables): " +
                    root.ollamaInvalidParams.join(", ")
              color: Commons.Color.urgent
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
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
              font.pixelSize: root.fontSize
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
              font.pixelSize: root.fontSize
            }

            // Footer: the parameter list takes the rest of the page.
            Item { Layout.fillHeight: true }


          }
        }


        // ---- Log overlay ----
        // Not one of the category pages: a log is inherently longer than any
        // fixed height, so this is the one place scrolling is appropriate.
        //
        // A live log is read at its bottom edge, so the view follows the tail
        // by default. Scrolling up detaches it -- reading back through a crash
        // must not be yanked away by the next line -- and the follow pill
        // reattaches, counting what arrived meanwhile so the cost of staying
        // detached is visible.
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: root.showingLogs
          spacing: Style.space(6)

          // Header: what is being read, and whether it is still following.
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              text: "Log"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
              opacity: 0.85
            }

            Text {
              Layout.fillWidth: true
              text: "...................................................................................................."
              color: root.bar.foreground
              opacity: 0.15
              elide: Text.ElideRight
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
            }

            Text {
              text: logView.stickToBottom ? "live" : "paused"
              color: logView.stickToBottom ? Commons.Color.accent : root.bar.foreground
              opacity: logView.stickToBottom ? 1.0 : 0.5
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSizeSmall
            }

            Text {
              text: logModel.count + " line" + (logModel.count === 1 ? "" : "s")
              color: root.bar.foreground
              opacity: 0.45
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSizeSmall
            }
          }

          Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: 4
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.035)

            ListView {
              id: logView
              anchors.fill: parent
              anchors.margins: Style.space(6)
              clip: true
              model: logModel
              spacing: 1
              // Cheap for a 400-line cap, and it keeps positionViewAtEnd exact
              // with variable-height wrapped delegates instead of estimated.
              cacheBuffer: 4000

              // Whether the view is following the tail. Set by where the user
              // left the view, not by where the content is.
              property bool stickToBottom: true
              // Lines that arrived while detached; shown on the follow pill.
              property int missedLines: 0

              delegate: Text {
                required property string line
                width: logView.width
                text: line
                color: root.bar.foreground
                opacity: 0.8
                wrapMode: Text.WrapAnywhere
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
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

            // A ListModel append is cheap, but the view still has to be told
            // to follow the tail; logRevision changes on every line, including
            // once the 400-line cap stops count from changing.
            Connections {
              target: root
              function onLogRevisionChanged() {
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
              anchors.margins: Style.space(8)
              visible: logModel.count === 0
              text: root.logsSource === "none"
                    ? "This server was started outside systemd, so its output is not in any journal. Restart it from here to see its log."
                    : (root.running ? "Waiting for the server to log something…"
                                    : "No log yet -- the server is not running.")
              color: root.bar.foreground
              opacity: 0.5
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
            }

            // A small floating pill, not a button: it is a state hint that
            // happens to be clickable, and it must stay readable over text.
            Rectangle {
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.margins: Style.space(6)
              visible: !logView.stickToBottom && logModel.count > 0
              implicitWidth: followLabel.implicitWidth + Style.space(16)
              implicitHeight: 24
              radius: 12
              color: Commons.Color.menu.background
              border.width: 1
              border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)

              Text {
                id: followLabel
                anchors.centerIn: parent
                text: logView.missedLines > 0
                      ? "\u2193 " + logView.missedLines + " new"
                      : "\u2193 Latest"
                color: Commons.Color.accent
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSizeSmall
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  logView.stickToBottom = true
                  logView.missedLines = 0
                  logView.positionViewAtEnd()
                }
              }
            }
          }
        }

        // Shared chrome: reachable from every category, not just Stats.
        // Setup sits here rather than on the Server page, which is already
        // at its row budget and would squeeze a new row to nothing.
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(12)
          visible: !root.showingSetup && !root.showingSettings && !root.showingMigration

          TextAction {
            text: root.showingLogs ? "Hide log" : "Show log"
            active: root.showingLogs
            onClicked: root.showingLogs = !root.showingLogs
          }

          Item { Layout.fillWidth: true }

          TextAction {
            visible: !root.showingSetup
            active: root.showingSettings
            text: root.showingSettings ? "Done" : "Settings…"
            onClicked: {
              if (root.showingSettings) root.closeSettings()
              else root.openSettings()
            }
          }
        }
      }

      ConfirmDialog {
        id: clearProfileConfirm
        message: "Drop this model's tuning and go back to defaults?"
        confirmText: "Drop"
        onConfirmed: root.clearProfile()
      }
    }
  }
}
