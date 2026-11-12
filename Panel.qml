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
import "ModelsIni.js" as ModelsIni
import "Instances.js" as Instances
import "LlamaArgs.js" as LlamaArgs


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
  moduleName: "io.github.syjohnm.local-ai-server"
  ipcTarget: "io.github.syjohnm.local-ai-server"

  // Two points above the shell's caption size. The panel is read at a glance
  // from a desk away, and the dotted rows have room to spare.
  // ---- Scale ----
  //
  // Steps from the shell's type scale rather than hand offsets. The previous
  // values were caption/bodySmall/subtitle each "+2", which had two problems:
  // the offset does not follow a theme's own font scale, so a user who sized
  // the shell up got a panel that did not move with it; and bodySmall + 2 (13)
  // came out larger than caption + 2 (12), so every "small" label rendered
  // bigger than the text it was secondary to. The intent -- a panel read at a
  // glance from a desk away, a step above the shell default -- is kept by
  // taking the step above, not by adding to it.
  readonly property int fontSize: Style.font.subtitle            // 13
  readonly property int fontSizeSmall: Style.font.body           // 12
  readonly property int fontSizeSubtitle: Style.font.title       // 14

  // One height for every dotted row, on the 4px grid. It was 26 in 36 places,
  // with 22 and 24 for rows of the same kind elsewhere.
  readonly property int rowHeight: 24

  // ---- Icons ----
  //
  // One set, written as escapes rather than literal private-use characters so
  // the source stays readable and survives a copy or a diff. These are Nerd
  // Font (nf-fa-*), the same set the bar mark already uses for its server
  // glyph, so the panel and the bar agree. Before this they were four
  // different sets at once: U+00D7 multiplication and U+2715 for remove,
  // U+2212 minus for the stepper, and a latin letter "v" as a chevron.
  //
  // No fallback is needed. Omarchy installs JetBrainsMono Nerd Font and the
  // shell draws in it, and every codepoint below was checked against the
  // shipped TTF -- worth doing, because Nerd Fonts v3 relocated part of the
  // Font Awesome block, so "the font is installed" is not the same as "this
  // glyph exists".
  readonly property var icons: ({
    check: "\uf00c",     // nf-fa-check
    remove: "\uf00d",    // nf-fa-times
    refresh: "\uf021",   // nf-fa-refresh
    chevron: "\uf078",   // nf-fa-chevron_down
    plus: "\uf067",      // nf-fa-plus
    minus: "\uf068",     // nf-fa-minus
    warning: "\uf071"    // nf-fa-warning
  })
  // Icons take the size of the text they sit beside, one step down, and the
  // colour of their text role -- never a colour of their own.
  readonly property int iconSize: Style.font.body

  // Corners follow the theme. Style.cornerRadius mirrors Hyprland's
  // decoration:rounding, which is what the rest of the shell rounds by, so a
  // hardcoded radius made this panel the only rounded surface on a screen set
  // to square -- and it would be the only square one on a screen set round.
  // A row inside a card steps down from it, never below zero.
  readonly property int radiusSurface: Style.cornerRadius
  readonly property int radiusControl: Math.max(0, Style.cornerRadius - Style.space(2))

  // Tabular figures, so a ticking rate does not change width between frames.
  // This is what the bar's minimum-width floor was working around.
  readonly property var tabularFigures: ({ "tnum": 1 })

  // The dotted leader that carries every label to its value. The plugin's own
  // device, and the one thing in the bar that looks like this -- so it lives
  // in one place rather than as a 100-character literal repeated 33 times.
  readonly property string leaderDots:
    "...................................................................................................."

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
  // Blank means "use the preferred llama-server", the same binary the chat
  // backend runs. A separate build only matters for a fork.
  // ---- Decision model (System One), running alongside the chat server ----
  //
  // System One used to be a third backend, so choosing it stopped the chat
  // server. That is backwards for what it is: a decision model answers typed
  // queries on its own endpoint, costs almost no VRAM, and is most useful
  // while a chat model is loaded. It also needs a *current* llama.cpp, which
  // is exactly the build a user running an older optimised fork for chat does
  // not have -- so it needs its own binary as well as its own port, and both
  // servers have to be up at once.
  //
  // Everything it needs was already separate: its own default port (8081), its
  // own unit suffix (sys1), its own model and models directory, its own launch
  // args and its own profile namespace. Only the exclusive `backend` choice
  // stood in the way.
  property bool decisionEnabled: false
  onDecisionEnabledChanged: {
    if (root.settingsLoaded) root.scheduleSettingsSave()
    // Turning it off takes its tab away; without this the panel would be left
    // on a page that no longer renders, which reads as the panel going blank.
    if (!root.decisionEnabled && root.currentPage >= 3) root.currentPage = 0
  }
  // Which llama.cpp build serves it, "" meaning the configured binary or the
  // preferred llama-server. Separate from the chat build on purpose: this is
  // the whole point of running it alongside an older fork.
  property string systemoneBuild: ""
  readonly property var systemoneResolvedBuild:
    root.systemoneBuild !== "" ? (Backends.findBuild(root.llamaBuilds, root.systemoneBuild) || null) : null
  readonly property string systemonePort: {
    var stored = root.backendPorts["systemone"]
    if (stored !== undefined && String(stored).trim() !== "") return String(stored)
    return String(Backends.get("systemone").defaultPort)
  }
  readonly property string systemoneUnitName: Backends.unitName(root.moduleName, "systemone")
  readonly property string systemoneProcMarker: Backends.procMarker(root.moduleName, "systemone")

  // Takes what the Server page's endpoint row takes, and keeps the port. The
  // host belongs to the panel, not to one server -- both run on this machine
  // and share the one address -- so a different host typed here would move the
  // chat server too, which is not what editing the companion's row means.
  function setDecisionEndpoint(text) {
    var value = String(text).trim()
    var cut = value.lastIndexOf(":")
    var portText = cut > 0 ? value.slice(cut + 1).trim() : value
    var port = parseInt(portText, 10)
    if (!isFinite(port) || port < 1 || port > 65535) return
    // The chat server's own port: taking it would put two servers on one
    // socket, and the second one to start simply fails to bind.
    if (String(port) === String(root.port)) return
    root.setSystemonePort(String(port))
  }

  function setSystemonePort(value) {
    var trimmed = String(value).trim()
    if (trimmed === root.systemonePort) return
    var next = {}
    for (var key in root.backendPorts) next[key] = root.backendPorts[key]
    next["systemone"] = trimmed
    root.backendPorts = next
    root.scheduleSettingsSave()
  }

  function setSystemoneBuild(value) {
    root.systemoneBuild = String(value)
    root.scheduleSettingsSave()
  }

  function toggleDecision() {
    var runner = root.decisionRunner()
    if (!runner) return
    if (runner.running || runner.starting) runner.stop()
    else runner.start()
  }

  function decisionRunner() {
    for (var i = 0; i < decisionInstance.count; i++) {
      var runner = decisionInstance.objectAt(i)
      if (runner) return runner
    }
    return null
  }

  readonly property var decisionState: root.extraSnapshots["decision"] || null

  readonly property string activeSystemoneBinary:
    root.systemoneResolvedBuild && String(root.systemoneResolvedBuild.path || "") !== ""
      ? String(root.systemoneResolvedBuild.path)
      : (root.configuredSystemoneBinary !== "" ? expandPath(root.configuredSystemoneBinary) : root.launchLlamaBinary)
  // Real path of that binary when the build probe knows it; empty otherwise.
  // Used to notice a build change, since argv[0] is the process marker.
  readonly property string activeSystemoneExe: {
    var b = Backends.findBuild(root.llamaBuilds, root.activeSystemoneBinary)
    return b && b.real ? b.real : ""
  }
  property string systemoneModel: ""
  // When set, Start launches llama-server in its own router mode
  // (--models-preset over the converted models.ini) instead of one model.
  property bool routerMode: false
  onRouterModeChanged: if (root.settingsLoaded) root.scheduleSettingsSave()
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
  // Folders added by hand. modelsDir is the single selected folder from the
  // widget settings; this list is additive and survives restarts.
  property var extraModelDirs: []



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
  // Paths added by hand through "Add fork"; keeps every added build instead of
  // replacing the single altBinary setting.
  property var extraBuildPaths: []

  // The build row under the pointer, so the line below the list can show its
  // path. A row is too narrow for one, and the path is what tells two builds
  // of the same fork apart.
  property string hoveredBuildPath: ""

  // Builds the user has agreed may be launched. A build is identified inside
  // a sandbox whether or not it is in here (llama_builds.py sandbox()), so
  // this grants running it as a real server -- unconfined, with access to the
  // models, the network and the account. Separate from extraBuildPaths on
  // purpose: naming a path says where to look, not that it is vouched for.
  property var approvedBuilds: []
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
  property string modelAlias: ""

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
    return root.envScriptPrefixFor(root.extraEnv)
  }

  // The same rendering for an arbitrary profile's environment, which is what
  // an extra instance launches with.
  function envScriptPrefixFor(extraEnv) {
    var parsed = Model.parseEnvAssignments(extraEnv)
    return parsed.env.map(function(e) { return e.name + "=" + root.shellQuote(e.value) }).join(" ")
  }


  // ollama-only
  property string keepAlive: ""

  // ---- Custom parameters ----
  //
  // Rather than exposing every flag a backend has (llama-server alone has
  // ~250), the page carries a small set of common controls and lets the user
  // add any other parameter on demand. The catalogue is generated from the
  // binary's own --help, so it matches the build actually installed.

  // Recent tg samples for the bar's hover sparkline.
  property var rateHistory: []
  function pushRate(value) {
    var next = root.rateHistory.slice()
    next.push(Number(value) || 0)
    if (next.length > 50) next = next.slice(next.length - 50)
    root.rateHistory = next
  }

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
    { id: "modelAlias", label: "Model alias",   feature: "",          props: ["modelAlias"] },

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
    modelAlias: "",
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
  // Set when the last stop was not asked for -- a crash, an OOM kill, or a
  // server stopped from outside. The Server page says "crashed" rather than
  // "stopped" for it, and a plain Start clears it.
  property bool lastExitWasCrash: false

  // ---- Diagnostics ----
  //
  // lastError holds one string and the next event overwrites it, so by the
  // time anyone looks, the thing that went wrong is usually gone. This keeps
  // the last few lifecycle events with a timestamp and which server they came
  // from, and `ipc call local-ai-server diagnose` returns them with the rest
  // of the state as one JSON document -- which is what makes a failure
  // something a person or an agent can read rather than guess at.
  property var events: []
  readonly property int eventsMax: 40

  function note(who, kind, detail) {
    var entry = {
      at: new Date().toISOString(),
      who: String(who),
      kind: String(kind),
      detail: Model.plainText(detail, 300)
    }
    var next = root.events.slice()
    next.push(entry)
    if (next.length > root.eventsMax) next = next.slice(next.length - root.eventsMax)
    root.events = next
    // Also to the shell's own log, so it lands in `qs log` beside whatever
    // else was happening at that moment.
    if (kind === "crash" || kind === "gone")
      console.warn("local-ai-server: " + entry.who + " " + entry.kind + ": " + entry.detail)
  }
  // Consecutive failed liveness polls. A single miss is not a dead server:
  // curl's timeout is one second and a server decoding on a loaded machine can
  // be slower than that, so it takes a few in a row (Instances.healthVerdict).
  property int healthFailures: 0
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
  readonly property string unitDir: expandPath("~/.config/systemd/user/")
  readonly property string unitName: Backends.unitName(root.moduleName, root.backend)
  readonly property string activeUnitName: root.unitName
  readonly property string procMarker: Backends.procMarker(root.moduleName, root.backend)

  // ---- Instances ----
  //
  // `instanceCount` was a manifest setting with nothing behind it: whatever
  // number it held, one server was launched and the Server page showed one
  // hardcoded "Instance 0". It is real now -- every index above 0 is its own
  // persistent llama-server, with its own transient unit, process marker,
  // port (portBase + n), model, build and prompt cache.
  //
  // Index 0 stays the server the rest of this file manages through its own
  // properties: it owns the restart lifecycle, the log view, the hooks and the
  // KV-cache bookkeeping, and its unit and marker keep their un-suffixed names
  // so a server left running by an older version is still adopted. The extra
  // indices are InstanceRunner objects, each a small copy of the same
  // launch/adopt/watch cycle over its own endpoint.
  readonly property int requestedInstanceCount: Instances.clampCount(
    setting("instanceCount", 1), root.backend, root.routerMode)
  readonly property var instancePlan: Instances.plan({
    pluginId: root.moduleName,
    backendId: root.backend,
    portBase: root.port,
    count: root.requestedInstanceCount,
    routerMode: root.routerMode,
    // The companion's port is held back whether or not it is running: a chat
    // instance must not be handed the port the decision model will bind when
    // it is turned on.
    reserved: [root.systemonePort],
    unitName: Backends.unitName,
    procMarker: Backends.procMarker
  })
  readonly property int instanceCount: root.instancePlan.length

  // Which model and which build each index above 0 serves, keyed by index as
  // a string so the map survives JSON. The primary keeps using the Model and
  // Tuning pages; these are the assignments the Server page makes per row.
  property var instanceModels: ({})
  property var instanceBuilds: ({})

  function setInstanceModel(index, path) {
    var next = {}
    for (var k in root.instanceModels) next[k] = root.instanceModels[k]
    if (String(path) === "") delete next[String(index)]
    else next[String(index)] = String(path)
    root.instanceModels = next
    root.scheduleSettingsSave()
  }

  function setInstanceBuild(index, build) {
    var next = {}
    for (var k in root.instanceBuilds) next[k] = root.instanceBuilds[k]
    if (String(build) === "") delete next[String(index)]
    else next[String(index)] = String(build)
    root.instanceBuilds = next
    root.scheduleSettingsSave()
  }

  // Models already claimed by another index (or by the primary). Two servers
  // on one model would write the same prompt-cache files and hold the weights
  // twice, so a row does not offer what another row already has, and
  // InstanceRunner.start() refuses it even when the assignment arrived from a
  // hand-edited settings file.
  //
  // It is one-directional: the first server's picker is the Model page's own
  // and is not filtered, so it can still be pointed at a model an extra
  // instance holds. The cost is a rejected cache restore and a cold start, not
  // a corrupt file -- slot_kv.py writes to a .tmp and renames.
  // The runner object for an index above 0, or null.
  function runnerFor(index) {
    for (var i = 0; i < extraInstances.count; i++) {
      var runner = extraInstances.objectAt(i)
      if (runner && runner.idx === Number(index)) return runner
    }
    return null
  }

  // Every extra instance stopped, for a change that invalidates their
  // endpoints: a backend switch retargets the port map, and nothing else would
  // ever come back for a server whose index the new backend does not have.
  function stopAllExtras() {
    for (var i = 0; i < extraInstances.count; i++) {
      var runner = extraInstances.objectAt(i)
      if (runner && (runner.running || runner.starting)) runner.stop()
    }
  }

  // Re-probe every extra index for a server that appeared since: one started
  // by hand, or left by a shell that went away between panel opens.
  function adoptExtras() {
    for (var i = 0; i < extraInstances.count; i++) {
      var runner = extraInstances.objectAt(i)
      if (runner) runner.adopt()
    }
  }

  function toggleInstance(index) {
    var runner = root.runnerFor(index)
    if (!runner) return
    if (runner.running || runner.starting) runner.stop()
    else runner.start()
  }

  function restartInstance(index) {
    var runner = root.runnerFor(index)
    if (runner) runner.restart()
  }

  // The models an index may be assigned: everything the scan found, minus what
  // another instance already has. The current assignment is always kept, or
  // the row would show an empty picker for the model it is serving.
  function instanceModelOptions(index) {
    var current = String(root.instanceModels[String(index)] || "")
    var out = []
    for (var i = 0; i < root.activeModelOptions.length; i++) {
      var option = root.activeModelOptions[i]
      var value = String(option.value)
      if (value !== current && root.modelClaimedBy(index, value) !== -1) continue
      out.push(option)
    }
    return out
  }

  // Build choices for an extra instance, in the same shape and order as the
  // primary's picker.
  // The companion's own tuning, in the "systemone" profile namespace that
  // InstanceRunner already resolves for it. Kept apart from the chat side on
  // purpose: the point of the companion is that it runs alongside, so its
  // layers and context cannot be the chat model's.
  readonly property var decisionTuning:
    Profiles.resolveFor(root.profiles, "systemone", root.systemoneModel, root.systemoneBuild)

  function setDecisionField(field, value) {
    if (root.systemoneModel === "") return
    root.profiles = Profiles.setField(root.profiles, "systemone", root.systemoneModel, field, value)
    root.scheduleSettingsSave()
  }

  // Builds that carry the /v1/systemone route, for the companion's picker.
  // The route is a string in the binary, so this is known without running it;
  // a build without it answers 404 to every decision, which looked like the
  // model being wrong rather than the build being too old.
  //
  // If nothing qualifies the whole list is offered instead: being unable to
  // pick any build at all is worse than offering one that may not work, and
  // the detection can only prove the route is present, never that it is not.
  function decisionBuildOptions() {
    var out = []
    for (var i = 0; i < root.llamaBuilds.length; i++) {
      var b = root.llamaBuilds[i]
      if (b && b.decision === true && b.missing !== true)
        out.push({ value: b.path, label: Backends.buildLabel(b) })
    }
    if (out.length === 0) return root.instanceBuildOptions()
    var auto = root.decisionAutoBuild
    out.unshift({ value: "", label: auto ? "Auto · " + Backends.buildLabel(auto) : "Auto" })
    return out
  }

  // What Auto resolves to for the companion: the first build that both serves
  // decisions and is allowed to run.
  readonly property var decisionAutoBuild: {
    for (var i = 0; i < root.llamaBuilds.length; i++) {
      var b = root.llamaBuilds[i]
      if (b && b.decision === true && b.missing !== true) return b
    }
    return null
  }

  function instanceBuildOptions() {
    var out = [{ value: "", label: root.autoBuild
                   ? "Auto · " + Backends.buildLabel(root.autoBuild)
                   : (root.heldBuilds.length > 0 ? "Auto · trust a build first" : "Auto") }]
    for (var i = 0; i < root.llamaBuilds.length; i++) {
      var b = root.llamaBuilds[i]
      // A build that cannot be launched is not offered as a choice. Listing
      // it made Start a button that quietly did nothing, and the reason was
      // two pages away on Settings.
      if (!b || b.missing === true) continue
      out.push({ value: b.path, label: Backends.buildLabel(b) })
    }
    return out
  }

  function modelClaimedBy(index, path) {
    if (String(path) === "") return -1
    if (index !== 0 && String(path) === String(root.launchModel)) return 0
    for (var k in root.instanceModels) {
      if (Number(k) === Number(index)) continue
      if (Number(k) >= root.instanceCount) continue
      if (String(root.instanceModels[k]) === String(path)) return Number(k)
    }
    return -1
  }
  readonly property bool multiInstance: root.instanceCount > 1
  readonly property bool canAddInstances:
    Instances.supportsMultiple(root.backend, root.routerMode)

  // The primary described the way Instances.js describes any instance, so one
  // set of labels and one aggregation serve the whole list.
  readonly property var primaryInstance: ({
    index: 0,
    port: parseInt(root.port, 10) || 0,
    unitName: root.unitName,
    procMarker: root.procMarker,
    primary: true,
    running: root.running,
    starting: root.starting,
    stopping: root.stopping,
    switching: root.switching,
    failed: root.lastExitWasCrash,
    adopted: root.adopted,
    ownsUnit: root.ownsUnit,
    tokensPerSec: root.tokensPerSec,
    ppActive: root.ppActive,
    ppPercent: root.ppPercent,
    ppTokensPerSec: root.ppTokensPerSec,
    model: root.runningModel !== "" ? root.runningModel : root.launchModel,
    build: root.backend === "llamacpp" ? Backends.buildLabel(root.resolvedBuild) : "",
    lastError: root.lastError,
    canStop: root.canStop,
    busy: root.stopping || root.takingOver
  })

  // Each runner publishes its own state here, keyed by index; the page and the
  // bar read the map. The runners are deliberately not polled through the
  // Instantiator: lowering the count fires objectRemoved while the object is
  // being torn down, and reading it there raises "attempted to evaluate a
  // function in an invalid context" and leaves the list showing instances
  // that no longer exist. A published snapshot outlives its runner, so
  // retiring an index is an ordinary removal from a map.
  property var extraSnapshots: ({})

  function publishInstance(index, data) {
    var next = {}
    for (var k in root.extraSnapshots) next[k] = root.extraSnapshots[k]
    next[String(index)] = data
    root.extraSnapshots = next
  }

  function retireInstance(key) {
    var next = {}
    // Compared as strings: the decision companion publishes under "decision",
    // and Number("decision") is NaN, which never equals itself -- so a numeric
    // comparison would have kept the very entry being retired.
    for (var k in root.extraSnapshots)
      if (String(k) !== String(key)) next[k] = root.extraSnapshots[k]
    root.extraSnapshots = next
  }

  // The chat instances only. Driven by the count, so the decision companion's
  // named key is not in it; the bar adds it in separately.
  readonly property var instanceStates: {
    var out = []
    for (var i = 0; i < root.instanceCount; i++) out.push(root.instanceState(i))
    return out
  }
  // Everything this widget is running, for the bar's one number.
  readonly property var allStates:
    root.decisionState ? root.instanceStates.concat([root.decisionState]) : root.instanceStates

  // The state of one index, by index rather than by position. A runner
  // publishes a frame or two after its index appears, so until then the row
  // describes an instance that exists but has not reported yet -- which is
  // what it is -- instead of shifting every row below it up by one.
  function instanceState(index) {
    if (Number(index) === 0) return root.primaryInstance
    var published = root.extraSnapshots[String(index)]
    if (published) return published
    var identity = root.instancePlan[Number(index)] || null
    return {
      index: Number(index),
      port: identity ? identity.port : 0,
      unitName: identity ? identity.unitName : "",
      procMarker: identity ? identity.procMarker : "",
      primary: false,
      running: false, starting: false, stopping: false, switching: false,
      failed: false, adopted: false, ownsUnit: false,
      tokensPerSec: 0, ppActive: false, ppPercent: 0, ppTokensPerSec: 0,
      model: String(root.instanceModels[String(index)] || ""),
      build: "", lastError: "", canStop: false, launchable: false, busy: false
    }
  }

  // What the bar reports for the widget as a whole. With several servers
  // decoding at once the sum is what the machine is actually doing; ingestion
  // is a single-prompt event, so the furthest-along prompt is reported instead.
  readonly property real aggregateRate: Instances.aggregateRate(root.allStates)
  readonly property var leadingPrompt: Instances.leadingPrompt(root.allStates)
  readonly property int instancesRunning: Instances.runningCount(root.allStates)
  readonly property bool anyInstanceRunning: root.instancesRunning > 0

  // Set once the capability probe has reported, so the backend list and the
  // restart comparison never act on binaries that simply are not known yet.
  property bool capabilitiesProbed: false

  // Backends with a binary on this machine; the only ones the Backend
  // dropdown offers.
  readonly property var installedBackends: Backends.installedBackends({
    llamacpp: root.llamaBinary !== "" || root.altBinary !== "" || root.llamaBuilds.length > 0,
    ollama: root.ollamaBinary !== "",
    // No longer a backend to switch to: the decision model is a companion
    // that runs alongside whichever chat backend is selected, so offering it
    // here would mean stopping the chat server to gain it.
    systemone: false
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

  // ---- Start on login ----
  //
  // The widget is what knows how to launch: it resolves the build, renders the
  // router preset from the current profiles and owns the tuned argv. So this is
  // the widget starting its own server once, as soon as everything it needs has
  // resolved -- not a separate systemd unit, which would go stale the moment
  // tuning, the model or the build changed.
  property bool startOnLogin: false
  // One shot per shell session. Without it a manual Stop would be undone the
  // next time any of the readiness inputs changed.
  //
  // It used to be set only where the auto-start actually ran, which left it
  // false in the ordinary case: the server outlives the shell on purpose, so
  // at most logins one is already up and the auto-start has nothing to do.
  // The session's one shot was then still unspent, and the first manual Stop
  // satisfied the last condition it was waiting on -- the panel restarted the
  // server the user had just deliberately stopped.
  property bool autoStartDone: false

  // When this login began, from systemd's user manager. A shell restart is
  // not a new login: the server outlives the shell on purpose, and so does
  // the decision to have stopped it.
  property string sessionStamp: ""
  // The login whose auto-start has already been spent, persisted. Without it
  // every `omarchy restart shell` was a fresh chance to start, so a server
  // the user had deliberately stopped came back each time the shell did.
  property string autoStartSession: ""

  onSessionStampChanged: {
    if (root.sessionStamp !== "" && root.sessionStamp !== "unknown"
        && root.autoStartSession === root.sessionStamp)
      root.autoStartDone = true
  }

  function markAutoStartSpent() {
    root.autoStartDone = true
    if (root.sessionStamp !== "" && root.sessionStamp !== "unknown"
        && root.autoStartSession !== root.sessionStamp) {
      root.autoStartSession = root.sessionStamp
      root.scheduleSettingsSave()
    }
  }

  // Everything the auto-start waits on, except the question of whether a
  // server is already there. Once these have landed the session's chance has
  // either been taken or was never needed.
  readonly property bool autoStartInputsReady:
    root.startOnLogin && root.adoptProbed && root.settingsLoaded &&
    root.capabilitiesProbed && (root.backend !== "llamacpp" || root.buildsProbed)

  // A server that is already up spends the shot, whoever started it.
  function spendAutoStart() {
    if (root.autoStartInputsReady && (root.running || root.starting))
      root.markAutoStartSpent()
  }
  onAutoStartInputsReadyChanged: root.spendAutoStart()
  onRunningChanged: root.spendAutoStart()
  onStartingChanged: root.spendAutoStart()
  // The adoption probe has answered, so "nothing is running" is a fact rather
  // than "not known yet". A launch sweeps the unit before starting, so firing
  // this before adoption resolves would tear down a server that was already up
  // -- which is exactly what happens on `omarchy restart shell`.
  property bool adoptProbed: false

  readonly property bool autoStartReady:
    root.startOnLogin && !root.autoStartDone && root.adoptProbed &&
    root.settingsLoaded && root.capabilitiesProbed &&
    // The build list decides which binary serves the model's cache types.
    (root.backend !== "llamacpp" || root.buildsProbed) &&
    root.activeBinary !== "" &&
    !root.running && !root.starting && !root.stopping &&
    // Router mode loads per request and ollama needs no model named up front;
    // everything else has to have one, which arrives with the model scan.
    (root.routerMode || root.backend === "ollama" || root.launchModel !== "")

  // Every input above is a property, so this fires on its own once the last
  // one lands -- no polling, and no call to sprinkle through the probes.
  onAutoStartReadyChanged: if (root.autoStartReady) autoStartTimer.restart()

  Timer {
    id: autoStartTimer
    // Settles the readiness inputs (the scan can re-select a model just after
    // the probes land) and keeps a multi-GB model load out of the first
    // seconds of the session, when the rest of the desktop is still coming up.
    interval: 3000
    repeat: false
    onTriggered: {
      // Re-checked rather than trusted: three seconds is long enough for the
      // user to have pressed Start, or for a server to have been adopted.
      if (!root.autoStartReady) return
      // A server still loading its weights does not answer /health yet, so the
      // adoption probe above reports nothing running. Launching on that would
      // sweep the unit and restart a model that was already most of the way
      // loaded -- minutes of work thrown away on every shell restart. The unit
      // itself gives the decisive answer.
      autoStartGuard.command = root.hasSystemdRun
        ? ["systemctl", "--user", "is-active", root.activeUnitName]
        : ["bash", "-c", "pgrep -f -- \"^$1 \" >/dev/null && echo active || echo inactive",
           "_", root.procMarker]
      autoStartGuard.running = false
      autoStartGuard.running = true
    }
  }

  Process {
    id: autoStartGuard
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.autoStartReady) return
        root.markAutoStartSpent()
        if (String(text).trim() === "active") {
          // Already up, just not answering yet: adopt it instead of replacing it.
          root.adoptRunningServer()
          return
        }
        root.startServer()
      }
    }
  }

  // The server outlives the shell on purpose: it is started detached, and the
  // next panel re-adopts it through /proc. Not a setting any more -- a shell
  // restart that took the model down with it was never what anyone wanted.
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
  // ollama takes no argv, so its launch environment is fingerprinted instead.
  property string runningConfigHash: ""
  // "draining" while a restart waits for running requests, "" otherwise.
  property string restartPhase: ""
  property int restartIdleTicks: 0
  // Set by a restart so the stop it goes through starts the server again.
  property bool restartAfterStop: false
  // Backend switch requested while a server was running: the current server is
  // stopped first (so its unit, not the target's, is torn down and its prompt
  // cache saved), then the backend is switched once the stop has fully
  // completed. See requestBackend / applyPendingBackendSwitch.
  property string pendingBackendSwitch: ""
  // After an auto-switch, the backend to start once its own model resolves
  // (model scan is async). Empty disarms it; a manual Stop/Start clears it.
  property string pendingBackendStart: ""
  // Stop was pressed while the debounced autosave was writing the cache.
  property bool stopAfterAutosave: false
  property bool slotsBusy: false
  property int slotsProcessing: 0
  property real slotsSeenAtMs: 0
  readonly property bool switching: root.running && root.restartPhase !== ""
  readonly property string switchPhase: root.switching ? root.restartPhase : ""
  // Waits for everything the argv depends on to be detected -- otherwise an
  // adopted server reads as changed until the hardware probe lands.
  readonly property bool configChanged: root.running && root.ownsUnit && !root.switching &&
    root.settingsLoaded && root.capabilitiesProbed &&
    (root.backend === "ollama"
      ? !root.catalogueLoading && root.runningConfigHash !== "" && root.ollamaConfigHash() !== root.runningConfigHash
      : (root.backend === "llamacpp" || root.backend === "systemone") &&
        root.runningArgs.length > 1 && root.buildsProbed && root.hardware !== null &&
        !root.catalogueLoading &&
        (JSON.stringify(root.currentLaunchArgs().slice(1)) !== JSON.stringify(root.runningArgs.slice(1)) ||
         (root.backend === "systemone"
           ? root.runningExe !== "" && root.activeSystemoneExe !== "" &&
             root.activeSystemoneExe !== root.runningExe
           : root.runningExe !== "" && root.resolvedBuild !== null &&
             root.resolvedBuild.real !== root.runningExe)))

  // Extra args are stored as semicolon-separated fragments ("--temp 0.5; --foo");
  // System One takes an argv token list, so parse each fragment first.
  function extraArgTokens() {
    return root.extraArgTokensFor(root.extraArgs)
  }

  // The same split for an arbitrary profile's extra args, which is what a
  // companion or an extra instance launches with.
  function extraArgTokensFor(extraArgs) {
    var pieces = Model.splitExtraArgs(extraArgs)
    var out = []
    for (var i = 0; i < pieces.length; i++) out = out.concat(Model.parseArgs(pieces[i]))
    return out
  }

  // What the page would launch now. The running argv is compared with this;
  // both llama.cpp and System One use the same /proc reader.
  function currentLaunchArgs() {
    if (root.backend === "systemone")
      return Backends.systemoneLaunchArgs(
        root.activeSystemoneBinary, root.systemoneModel, root.host, root.port,
        expandPath(root.slotSaveDir),
        {
          ngl: root.gpuLayers,
          cacheTypeK: root.cacheTypeK,
          cacheTypeV: root.cacheTypeV,
          loadMode: root.loadMode,
          threads: root.threads,
          cpuMoe: root.cpuMoe,
          nCpuMoe: root.nCpuMoe,
          parallel: root.parallel,
          systemoneCtx: root.systemoneCtx,
          extraPieces: root.extraArgTokens(),
          propOverridden: root.propOverridden
        })
    if (root.backend === "llamacpp" && root.routerMode)
      return ModelsIni.routerLaunchArgs(root.launchLlamaBinary, root.host, root.port, root.routerPresetPath, { extraPieces: root.extraArgTokens() })
    return root.buildLlamaArgs()
  }

  // ---- Metrics ----

  property real tokensPerSec: 0
  property real ppPercent: 0
  property real ppTokensPerSec: 0
  // When a rate was last measured. tokensPerSec used to be cleared only by a
  // stop or a restart, so one generation pinned that number to the bar and to
  // the Server page for the life of the process -- the widget reported a
  // request that had finished an hour earlier, and "idle" was a state it could
  // never show while a server was up. The rate is held briefly after the last
  // token (the final reading is the interesting one) and then released.
  property real lastRateAtMs: 0
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
  // Which unit the log view is reading. The view could only ever follow the
  // chat server, so a companion or a second instance that failed to start had
  // its journal nowhere in the panel -- the one place a failed start explains
  // itself. Empty means the chat server.
  property string logUnit: ""
  property string logTitle: "Log"

  property int currentPage: 0
  // The companion gets a tab only while it is on, so a user who never enables
  // it never pays a tab for it.
  readonly property var pageNames: root.decisionEnabled
    ? ["Server", "Model", "Tuning", "Decision"]
    : ["Server", "Model", "Tuning"]

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
  // A re-run of setup, as against a first run. Deliberately not setupDone:
  // that flag is the record that setup was completed once, and clearing it to
  // show the pages again meant dismissing the panel mid-way left the install
  // looking unconfigured for ever -- setup then came back on every open and
  // every shell restart until Finish or Skip was pressed. This is view state
  // and is not saved, so closing the panel ends the re-run.
  property bool showingSetupAgain: false
  readonly property bool showingSetup: root.settingsLoaded && root.capabilitiesProbed
    && (!root.setupDone || root.showingSetupAgain)
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
  // The row this panel is made of: a label, leader dots, and a value that
  // turns into a field when clicked. Every page had its own hand-copy of this
  // shape -- which is most of why the Tuning page runs to two thousand lines
  // -- and a page that copies it slightly differently stops looking like the
  // rest of the panel, which is exactly what the Decision page did.
  component ValueRow: Rectangle {
    id: vrow
    property string label: ""
    property string value: ""
    // Stands in for an empty value, so a row never reads as blank.
    property string hint: ""
    property var inputValidator: null
    // A row that must not be edited right now -- a port the running server is
    // already listening on -- still has to show its value: hiding it would
    // lose the one thing the user came to read.
    property bool editable: true
    property string tooltip: ""
    signal committed(string text)

    Layout.fillWidth: true
    implicitHeight: root.rowHeight
    radius: root.radiusControl
    property bool editing: false
    color: vrowHover.hovered && !vrow.editing
      ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
      : "transparent"

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(4)
      anchors.rightMargin: Style.space(4)
      spacing: Style.space(4)
      visible: !vrow.editing

      Text {
        textFormat: Text.PlainText
        text: vrow.label
        color: root.bar.foreground
        opacity: 0.85
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontSize
      }
      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: root.leaderDots
        color: root.bar.foreground
        opacity: 0.15
        elide: Text.ElideRight
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontSize
      }
      Text {
        textFormat: Text.PlainText
        text: vrow.value !== "" ? vrow.value : vrow.hint
        color: root.bar.foreground
        opacity: vrow.value !== "" ? 0.45 : 0.25
        elide: Text.ElideRight
        Layout.maximumWidth: Style.space(150)
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontSizeSmall
        font.features: root.tabularFigures
      }
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(4)
      anchors.rightMargin: Style.space(4)
      spacing: Style.space(4)
      visible: vrow.editing

      Text {
        textFormat: Text.PlainText
        text: vrow.label
        color: root.bar.foreground
        opacity: 0.85
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontSize
      }
      NumField {
        id: vrowField
        Layout.fillWidth: true
        placeholderText: vrow.hint
        validator: vrow.inputValidator
        onEditingFinished: {
          vrow.committed(text)
          vrow.editing = false
        }
        Keys.onEscapePressed: vrow.editing = false
      }
    }

    HoverHandler {
      id: vrowHover
      cursorShape: vrow.editable ? Qt.PointingHandCursor : Qt.ArrowCursor
    }
    PanelToolTip {
      visible: vrowHover.hovered && vrow.tooltip !== ""
      text: vrow.tooltip
    }
    MouseArea {
      anchors.fill: parent
      enabled: !vrow.editing && vrow.editable
      onClicked: {
        vrowField.text = vrow.value
        vrow.editing = true
        vrowField.forceActiveFocus()
      }
    }
  }

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
    textFormat: Text.PlainText
    id: action

    property bool active: false
    signal clicked()

    color: action.active ? Commons.Color.accent : root.bar.foreground
    opacity: actionMouse.containsMouse ? 1.0 : (action.active ? 1.0 : 0.65)
    font.family: root.bar.fontFamily
    font.pixelSize: root.fontSize

    // Everything else in the panel is a label with a value on the right, and
    // those are clickable too, so plain text said nothing about which words
    // do something. The outline is the only thing here that means "press me":
    // it stays drawn rather than appearing on hover, since a thing you have
    // to touch to discover is not an affordance.
    leftPadding: Style.spacing.controlPaddingX
    rightPadding: Style.spacing.controlPaddingX
    topPadding: Style.space(1)
    bottomPadding: Style.space(1)

    Rectangle {
      id: actionChip
      z: -1
      // Hugs the words, not the item: an action that fills its row would
      // otherwise draw a panel-wide box and read as a text field.
      width: action.contentWidth + action.leftPadding + action.rightPadding
      height: action.contentHeight + action.topPadding + action.bottomPadding
      x: action.horizontalAlignment === Text.AlignRight ? action.width - width
        : (action.horizontalAlignment === Text.AlignHCenter ? (action.width - width) / 2 : 0)
      y: (action.height - height) / 2
      radius: root.radiusControl
      // Fill, border and width come from the kit's control tokens, the same
      // ones Ui/Button paints with, so an inline action and a header button
      // are one look and a theme moves both. Only the padding stays tighter:
      // these sit inside dotted rows, not on their own line.
      color: Style.controlFill(false, actionMouse.containsMouse, action.color, Commons.Color.accent)
      border.width: Style.controlBorderWidth(false, actionMouse.containsMouse)
      border.color: Style.controlBorder(false, actionMouse.containsMouse, action.color, Commons.Color.accent)
    }

    MouseArea {
      id: actionMouse
      x: actionChip.x
      y: actionChip.y
      width: actionChip.width
      height: actionChip.height
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
    implicitHeight: root.rowHeight
    visible: root.backend === "llamacpp"
    radius: root.radiusControl
    color: rowHover.containsMouse && !row.readOnly
      ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
      : "transparent"

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(4)
      anchors.rightMargin: Style.space(4)
      spacing: Style.space(4)

      Text {
        textFormat: Text.PlainText
        text: "Build"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontSize
        opacity: 0.85
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: root.leaderDots
        color: root.bar.foreground
        opacity: 0.15
        elide: Text.ElideRight
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontSize
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
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
        textFormat: Text.PlainText
        text: root.icons.chevron
        color: root.bar.foreground
        opacity: 0.5
        font.family: root.bar.fontFamily
        font.pixelSize: root.iconSize
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
        radius: root.radiusSurface
        border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)
        border.width: 1
      }

      ColumnLayout {
        id: popupCol
        width: parent.width
        spacing: Style.space(2)

        Repeater {
          // Held and vanished builds are left out here too: picking one
          // writes it into the model's profile, so offering it is how a
          // choice that cannot run replaces one that can.
          model: [{ value: "", label: root.autoBuild
                      ? "Auto · " + Backends.buildLabel(root.autoBuild)
                      : (root.heldBuilds.length > 0 ? "Auto · trust a build first" : "Auto") }]
            .concat(root.llamaBuilds.filter(function(b) {
              return b && b.missing !== true
            }).map(function(b) {
              return { value: b.path, label: Backends.buildLabel(b) }
            }))

          delegate: Rectangle {
            required property var modelData

            readonly property bool chosen: root.llamaBuild === modelData.value ||
              (modelData.value === "" && Backends.findBuild(root.llamaBuilds, root.llamaBuild) === null)

            Layout.fillWidth: true
            implicitHeight: root.rowHeight
            radius: root.radiusControl
            color: choiceHover.hovered
              ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
              : "transparent"

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(4)
              anchors.rightMargin: Style.space(4)
              spacing: Style.space(4)

              Text {
                textFormat: Text.PlainText
                text: "•"
                color: Commons.Color.accent
                visible: parent.parent.chosen
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
              Text {
                textFormat: Text.PlainText
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

  // The build paths a setting names, expanded. A build that is gone is kept
  // in the list while one of these still names it, because the probe reports a
  // configured path itself, present or not.
  function configuredBuildPaths() {
    var out = root.approvedBuilds.slice()
    for (var i = 0; i < root.extraBuildPaths.length; i++)
      out.push(root.expandPath(root.extraBuildPaths[i]))
    return out
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
  // the first time that model's tuning is edited; without one the model runs
  // on the backend's neutral defaults (what llama.cpp starts with).
  //
  // The live properties above stay the single source of truth for a launch:
  // selecting a model writes its profile onto them, and editing them writes
  // back. Nothing reads a profile at launch time, so there is no second path
  // the launch line could come from.
  property var profiles: ({})

  // Set while a profile is being written onto the live properties. Every
  // change handler fires during that, and without the guard the apply would be
  // read as an edit -- creating a profile for a model merely selected, and
  // capturing the outgoing model's values into it.
  property bool applyingTuning: false

  // The model this backend would launch, with its own tuning if it has one.
  // Which build's profile the selected model is showing. The live build wins
  // for the selected model; other models use their pin, then auto.
  function profileBuildFor(model) {
    if (root.backend !== "llamacpp") return ""
    var m = model === undefined ? root.currentModel() : model
    var common = Profiles.get(root.profiles, root.backend, m)
    // If a build is explicitly pinned on this model, that build wins
    if (common && common.llamaBuild) return String(common.llamaBuild)
    if (root.llamaBuild !== "" && m === root.currentModel()) return root.llamaBuild
    // Otherwise look at the tuning in the model's profile to resolve the compatible build
    var tuning = Profiles.resolve(common || {})
    var build = Backends.resolveBuild(root.llamaBuilds, "", tuning.cacheTypeK, tuning.cacheTypeV)
    if (build) return build.path || ""
    if (m === root.currentModel() && root.resolvedBuild)
      return root.resolvedBuild.path || ""
    return ""
  }

  readonly property bool hasProfile: {
    var model = root.launchModel
    var build = root.profileBuildFor(model)
    return Profiles.hasFor(root.profiles, root.backend, model, build) ||
           Profiles.has(root.profiles, root.backend, model)
  }

  // A user edit to any tuning value: stores it against the model this backend
  // would launch, creating its profile if this is the first edit.
  //
  // With no model selected there is nothing to key on — edits are ignored
  // until a model is picked.
  function touchTuning() {
    var model = root.currentModel()
    if (!root.settingsLoaded || root.applyingTuning || model === "") return
    // The common profile is the shared baseline: seed it on the first edit so
    // another build inherits these values; later edits on a build store only
    // the fields that differ from it.
    var existing = Profiles.get(root.profiles, root.backend, model)
    var hasTuning = false
    if (existing) for (var key in existing) if (key !== "llamaBuild") hasTuning = true
    if (!hasTuning)
      root.profiles = Profiles.set(root.profiles, root.backend, model, Profiles.snapshot(root))
    var common = Profiles.resolve(Profiles.get(root.profiles, root.backend, model) || {})
    var build = root.profileBuildFor(model)
    root.profiles = Profiles.setFor(root.profiles, root.backend, model, build,
                                    Profiles.diff(common, Profiles.snapshot(root)))
    if (build !== "" && root.llamaBuild !== "")
      root.profiles = Profiles.setField(root.profiles, root.backend, model, "llamaBuild", root.llamaBuild)
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
    var model = root.currentModel()
    var build = root.profileBuildFor(model)
    root.applyTuning(Profiles.resolveFor(root.profiles, root.backend, model, build))
    // A profile written before arguments were split still carries a line.
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

  // Drops this model's profile and goes back to the neutral defaults.
  // The next edit starts a fresh profile from them.
  function clearProfile() {
    if (!root.hasProfile) return
    var model = root.launchModel
    var build = root.profileBuildFor(model)
    root.profiles = Profiles.removeFor(root.profiles, root.backend, model, build)
    root.profiles = Profiles.remove(root.profiles, root.backend, model)
    root.applyTuning(Profiles.resolveFor(root.profiles, root.backend, model, build))
    root.scheduleSettingsSave()
  }



  // ---- Settings persistence ----
  // Plain properties survive a hot-reload (Quickshell patches this object in
  // place) but not a real restart, so config is mirrored to disk.
  readonly property string settingsDir: expandPath("~/.local/state/omarchy/io.github.syjohnm.local-ai-server/")
  readonly property string settingsPath: settingsDir + "settings.json"
  readonly property string modelsIniPath: settingsDir + "models.ini"
  // Router preset written at launch, in llama.cpp's INI format.
  readonly property string routerPresetPath: settingsDir + "router.ini"
  property bool settingsLoaded: false

  readonly property string slotSaveDir: settingsDir + "slots/"

  // ---- Prompt-cache housekeeping ----
  //
  // A slot file is the size of a context, and the cache of a model that was
  // deleted or moved is never reclaimed by anything else, so a library churned
  // over a few months quietly leaves gigabytes in the state folder. Measured
  // when Settings opens and swept only on request: a model scan that has not
  // run (or ran for the other backend) must never be read as "those models are
  // gone".
  property var slotCacheFiles: []
  property var slotKeepPrefixes: []
  property bool slotCacheProbed: false
  property bool slotCacheBusy: false
  // False when the model sweep found nothing at all: with no catalogue to
  // compare against, every cache would look orphaned, so the offer is withheld.
  property bool slotKeepProbed: false
  readonly property real slotCacheBytes: Model.totalSlotBytes(root.slotCacheFiles)
  readonly property var slotCacheOrphans:
    Model.slotOrphans(root.slotCacheFiles, root.slotKeepPrefixes)

  // Every directory that can hold a model whose cache would land in the slot
  // folder. Both llama.cpp and System One save slots, and System One can have
  // a directory of its own, so the keep set is built from the union -- never
  // from the catalogue of whichever backend happens to be selected.
  readonly property var slotScanDirs: {
    var dirs = root.searchDirs.slice()
    if (root.configuredSystemoneModelsDir !== "") {
      var so = expandPath(root.configuredSystemoneModelsDir)
      if (so !== "" && dirs.indexOf(so) === -1) dirs.push(so)
    }
    return dirs
  }

  // One pass: the slot files with their sizes, then every model on disk. The
  // keep set comes from the filesystem rather than from the UI's current
  // catalogue, so a backend that has not been scanned this session cannot have
  // its caches mistaken for orphans.
  function refreshSlotCacheStats() {
    if (root.slotCacheBusy) return
    if (root.slotScanDirs.length === 0) return
    root.slotCacheBusy = true
    var dirs = root.slotScanDirs.map(root.shellQuote).join(" ")
    slotStatsProc.command = ["bash", "-lc",
      "find " + root.shellQuote(expandPath(root.slotSaveDir)) +
      " -maxdepth 1 -type f -name '*.slot*.bin' -printf 'S\\t%s\\t%f\\n' 2>/dev/null; " +
      "find -L " + dirs + " -maxdepth " + root.modelScanDepth +
      " -type f -iname '*.gguf' -printf 'M\\t%p\\n' 2>/dev/null; true"]
    slotStatsProc.running = false
    slotStatsProc.running = true
  }

  Process {
    id: slotStatsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var slotLines = []
        var keep = []
        var lines = String(text).split("\n")
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i]
          if (line.indexOf("S\t") === 0) {
            slotLines.push(line.slice(2))
          } else if (line.indexOf("M\t") === 0) {
            var p = line.slice(2)
            if (p === "") continue
            // Both spellings: a cache written before the path hash existed is
            // named after the model file alone.
            var hashed = Backends.slotPrefix(p)
            var legacy = Backends.legacySlotPrefix(p)
            if (hashed !== "" && keep.indexOf(hashed) === -1) keep.push(hashed)
            if (legacy !== "" && keep.indexOf(legacy) === -1) keep.push(legacy)
          }
        }
        root.slotCacheFiles = Model.parseSlotListing(slotLines.join("\n"))
        root.slotKeepPrefixes = keep
        root.slotKeepProbed = keep.length > 0
        root.slotCacheProbed = true
        root.slotCacheBusy = false
      }
    }
  }

  // Removes exactly the files the sweep named -- never a pattern, so nothing
  // else in the cache folder (the .staging tree, a lock) can be caught by it.
  function removeSlotOrphans() {
    var orphans = root.slotCacheOrphans
    if (orphans.length === 0) return
    var dir = expandPath(root.slotSaveDir)
    // "--" so a file name starting with a dash is still read as a path.
    var args = ["rm", "-f", "--"]
    for (var i = 0; i < orphans.length; i++) args.push(dir + orphans[i].name)
    Quickshell.execDetached(args)
    slotRefreshTimer.restart()
  }

  Timer {
    id: slotRefreshTimer
    interval: 400
    onTriggered: root.refreshSlotCacheStats()
  }

  // The model the running server actually loaded, captured at launch.
  //
  // Kept separate from selectedModel so the picker stays usable while a server
  // is up: a new selection is queued for the next start, and KV-cache saves
  // keep keying on what is really loaded. Without this, changing the selection
  // mid-run would autosave the live cache under the newly picked model's name,
  // which the next launch would then restore into a mismatched model.
  property string runningModel: ""
  // Last model a router poll saw as loaded, so the UI follows load events but
  // does not fight a selection the user just made by hand.
  property string routerLoadedSeen: ""

  // Set when the file on disk is present but could not be read. Every write is
  // refused while it is set, so a broken file is never saved over; the panel
  // runs on defaults and says so. Clearing it means fixing or removing the
  // file -- removing it makes the next start an ordinary first run.
  property bool settingsBroken: false

  function loadSettings(raw) {
    if (root.settingsLoaded) return
    var read = Model.readSettings(raw)
    if (read.broken) {
      root.settingsBroken = true
      root.lastError = "settings.json could not be read, so nothing will be saved. " +
        "Fix or remove " + root.settingsPath
      return
    }
    var parsed = read.parsed
    if (parsed && typeof parsed === "object") {
      if (typeof parsed.backend === "string" && Backends.ids().indexOf(parsed.backend) !== -1) root.backend = parsed.backend
      // System One stopped being a backend choice and became a companion that
      // runs alongside the chat server. A settings file that selected it as
      // the backend turns the companion on and leaves chat on llama.cpp --
      // which is what selecting it was standing in for.
      if (root.backend === "systemone") {
        root.backend = "llamacpp"
        root.decisionEnabled = true
      }
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
      if (typeof parsed.decisionEnabled === "boolean") root.decisionEnabled = parsed.decisionEnabled
      if (typeof parsed.systemoneBuild === "string") root.systemoneBuild = parsed.systemoneBuild
      if (parsed.instanceModels && typeof parsed.instanceModels === "object") {
        var im = {}
        for (var mk in parsed.instanceModels) im[String(mk)] = String(parsed.instanceModels[mk])
        root.instanceModels = im
      }
      if (parsed.instanceBuilds && typeof parsed.instanceBuilds === "object") {
        var ib = {}
        for (var bkk in parsed.instanceBuilds) ib[String(bkk)] = String(parsed.instanceBuilds[bkk])
        root.instanceBuilds = ib
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
      if (typeof parsed.routerMode === "boolean") root.routerMode = parsed.routerMode
      if (typeof parsed.showMetric === "boolean") root.showMetric = parsed.showMetric
      if (typeof parsed.extraArgs === "string") root.extraArgs = parsed.extraArgs
      if (typeof parsed.extraEnv === "string") root.extraEnv = parsed.extraEnv
      if (typeof parsed.llamaBuild === "string") root.llamaBuild = parsed.llamaBuild
      if (typeof parsed.keepAlive === "string") root.keepAlive = parsed.keepAlive
      if (typeof parsed.kvPersistence === "boolean") root.kvPersistence = parsed.kvPersistence
      if (typeof parsed.startOnLogin === "boolean") root.startOnLogin = parsed.startOnLogin
      if (typeof parsed.autoStartSession === "string") root.autoStartSession = parsed.autoStartSession
      if (typeof parsed.systemoneCtx === "string") root.systemoneCtx = parsed.systemoneCtx

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
      if (Array.isArray(parsed.extraModelDirs)) {
        var extraDirs = []
        for (var ed = 0; ed < parsed.extraModelDirs.length; ed++) {
          var edv = parsed.extraModelDirs[ed]
          if (typeof edv === "string" && edv.trim() !== "") {
            var edp = expandPath(edv)
            if (extraDirs.indexOf(edp) === -1) extraDirs.push(edp)
          }
        }
        root.extraModelDirs = extraDirs
      }
      if (Array.isArray(parsed.extraBuildPaths)) {
        var extraPaths = []
        for (var eb = 0; eb < parsed.extraBuildPaths.length; eb++) {
          var ebv = parsed.extraBuildPaths[eb]
          if (typeof ebv === "string" && ebv.trim() !== "") {
            var ebp = expandPath(ebv)
            if (extraPaths.indexOf(ebp) === -1) extraPaths.push(ebp)
          }
        }
        root.extraBuildPaths = extraPaths
      }
      if (Array.isArray(parsed.approvedBuilds)) {
        var okPaths = []
        for (var ab = 0; ab < parsed.approvedBuilds.length; ab++) {
          var abv = parsed.approvedBuilds[ab]
          if (typeof abv === "string" && abv.trim() !== "") {
            var abp = expandPath(abv)
            if (okPaths.indexOf(abp) === -1) okPaths.push(abp)
          }
        }
        root.approvedBuilds = okPaths
      }
      if (Array.isArray(parsed.detectedModelDirs))
        root.detectedModelDirs = Backends.mergeDirs(parsed.detectedModelDirs, root.detectedModelDirs)
      if (Array.isArray(parsed.llamaBuilds)) {
        var savedBuilds = []
        for (var sb = 0; sb < parsed.llamaBuilds.length; sb++) {
          var build = parsed.llamaBuilds[sb]
          if (!build || typeof build.path !== "string") continue
          // The cached list is restored before the probe can re-check it, and
          // a file written by a version that predates the gate carries no
          // verdict at all -- so every restored build is held until this
          // session's probe says otherwise. With startOnLogin that window is
          // long enough to launch one, and the path it names need not even
          // still be the build that was identified.
          if (root.approvedBuilds.indexOf(build.path) === -1) {
            build = Object.assign({}, build)
            build.missing = true
            build.needsApproval = true
            build.why = ["not re-checked yet"]
          }
          savedBuilds.push(build)
        }
        // The probe can answer before this file is read, and then this merge
        // is what lands in the panel: pruning only in the probe's own handler
        // let a deleted build come back here. Before the probe has spoken
        // nothing may be pruned, since absence is not yet evidence.
        root.llamaBuilds = Backends.mergeBuilds(savedBuilds, root.llamaBuilds,
          root.buildsProbed ? root.configuredBuildPaths() : null)
      }
    }
    // Profiles are read after the flat values, which double as the migration
    // source: a settings file written before profiles existed carries one
    // tuning set, and it belongs to the model that file names.
    var restoredProfiles = Profiles.fromSettings(parsed, Profiles.snapshot(root))
    root.profiles = restoredProfiles.profiles
    // Before the Model page could pick a System One model, that backend's
    // profile was keyed by the chat selection. Move it onto the decision model.
    root.profiles = Profiles.rekey(root.profiles, "systemone", root.selectedModel, root.systemoneModel)

    // Load models.ini if available, merging on top of profiles
    modelsIniFile.reload()

    root.sanitizeSettings()
    root.settingsLoaded = true
    root.scheduleSettingsSave()
    // The flat values on disk are the ones last live, which for a model with a
    // profile is that profile -- but not for a file hand-edited to name a
    // different model, so the selection has the last word.
    root.applyTuningForSelection()
    root.ensureInstalledBackend()
    if (root.configuredSystemoneModelsDir !== "") root.refreshSystemoneModels()
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
    // The same reasoning, for a build that is present but held for approval.
    // It has not gone away -- its file is there and the user has simply not
    // said yes yet -- so the types it alone accepts are not stale settings.
    // TurboQuant's KV types are the reason to keep that fork at all, and
    // resetting them to f16 on the way past is destroying the setting the
    // user came for, every time the shell restarts.
    var chosen = Backends.findBuild(root.llamaBuilds, root.llamaBuild)
    if (chosen && chosen.missing === true) return
    // Nothing usable to judge against: with every build held, the list falls
    // back to the generic types and would reset a fork-only choice for a
    // build that is still sitting right there.
    if (root.llamaBuilds.length > 0 && root.heldBuilds.length === root.llamaBuilds.length) return
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
    // One chokepoint rather than a guard at each caller: resetToDetectedDefaults
    // calls this directly, and clicking it with an unreadable file on disk
    // would have replaced that file instead of recovering from it.
    if (root.settingsBroken) return
    settingsFile.setText(JSON.stringify({
      version: 3,
      setupDone: root.setupDone,
      backend: root.backend,
      host: root.host, backendPorts: root.backendPorts,
      instanceModels: root.instanceModels, instanceBuilds: root.instanceBuilds,
      decisionEnabled: root.decisionEnabled, systemoneBuild: root.systemoneBuild,
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
      routerMode: root.routerMode,
      extraArgs: root.extraArgs, keepAlive: root.keepAlive, extraEnv: root.extraEnv,
      llamaBuild: root.llamaBuild,
      detectedModelDirs: root.detectedModelDirs,
      extraModelDirs: root.extraModelDirs,
      extraBuildPaths: root.extraBuildPaths,
      approvedBuilds: root.approvedBuilds,
      llamaBuilds: root.llamaBuilds,
      kvPersistence: root.kvPersistence,
      startOnLogin: root.startOnLogin,
      autoStartSession: root.autoStartSession,
      systemoneCtx: root.systemoneCtx,
      hiddenBuiltins: root.hiddenBuiltins, shownOptionals: root.shownOptionals,
      customParams: root.customParams,

      // The tuning above is also what the selected model's profile holds; it
      // is written flat as well so a build without profiles still reads the
      // values the user last had live.
      profiles: root.profiles
    }, null, 2) + "\n")

    // Mirror to models.ini for hand edits and multi-fork documentation
    try {
      var iniData = ModelsIni.fromProfiles(root.profiles, root.currentModel())
      modelsIniFile.setText(ModelsIni.serialize(iniData))
    } catch (e) {}
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
    root.selectedModel = ""
    root.modelOptions = []
    // Warnings are per launch line; do not carry the old backend's flags into
    // the new one's tuning page.
    root.ignoredFlags = []
    // Parameters are backend-specific: llama.cpp flags mean nothing to ollama
    // and vice versa, so both the catalogue and the user's additions reset --
    // as does the rest of the tuning, which comes back from the backend's
    // neutral defaults rather than carrying the other backend's numbers across.
    root.applyTuning(Profiles.resolve(null))
    root.paramCatalogue = []
    // An open picker would sit there listing the previous backend's flags
    // until the new catalogue arrived.
    root.addParamOpen = false
    root.scheduleSettingsSave()
    root.refreshModels()
    root.refreshCatalogue()
    // The new backend has its own model's profile to restore; for llama.cpp
    // the selection is empty here, so this is still the neutral default.
    root.applyTuningForSelection()
    root.adoptRunningServer()
    // ollama needs no model, so an auto-switch to it can start right away;
    // llama.cpp/System One wait for the async scan via onLaunchModelChanged.
    root.maybeAutoStartSwitched()
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
    if (root.applyingTuning) return
    var model = root.currentModel()
    if (model !== "") {
      root.profiles = Profiles.setField(root.profiles, root.backend, model, "llamaBuild", root.llamaBuild)
      root.applyTuningForSelection()
    }
    // A build picked by hand may not take the cache types the model had;
    // fall back rather than launch into a flag the binary rejects.
    root.sanitizeSettings()
  }
  onBuildsProbedChanged: {
    if (root.buildsProbed && root.settingsLoaded && !root.applyingTuning)
      root.applyTuningForSelection()
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
    if (root.backend !== "systemone") root.applyTuningForSelection()
    root.scheduleSettingsSave()
    if (root.selectedModel !== "") root.revealModel(root.selectedModel)
  }
  onSystemoneModelChanged: {
    if (root.backend === "systemone") {
      root.applyTuningForSelection()
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
  onModelAliasChanged: root.touchTuning()
  onKvPersistenceChanged: root.scheduleSettingsSave()
  onStartOnLoginChanged: root.scheduleSettingsSave()
  onExtraModelDirsChanged: root.scheduleSettingsSave()
  onExtraBuildPathsChanged: root.scheduleSettingsSave()
  onDetectedModelDirsChanged: root.scheduleSettingsSave()
  onLlamaBuildsChanged: root.scheduleSettingsSave()

  Process {
    id: ensureSettingsDirProc
    command: ["bash", "-lc",
      "mkdir -p -m 700 " + root.shellQuote(root.settingsDir) + "; " +
      "chmod 700 " + root.shellQuote(root.settingsDir) + "; " +
      "mkdir -p -m 700 " + root.shellQuote(root.slotSaveDir) + "; " +
      "chmod 700 " + root.shellQuote(root.slotSaveDir)]
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

  FileView {
    id: modelsIniFile
    path: root.modelsIniPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var parsed = ModelsIni.parse(text())
      if (parsed && parsed.models) {
        var converted = ModelsIni.toProfiles(parsed)
        // Built into a copy and assigned once. Writing into root.profiles in
        // place changed the data without assigning the property, and QML only
        // emits a change signal on assignment -- so every binding on profiles
        // (hasProfile, which decides whether a model offers to reset its
        // tuning) kept the previous answer after a hand edit, while the values
        // themselves did reach the server. It looked like it had worked while
        // part of the page disagreed.
        var next = {}
        for (var existing in root.profiles) next[existing] = root.profiles[existing]
        for (var k in converted) next[k] = converted[k]
        root.profiles = next
        if (root.settingsLoaded && !root.applyingTuning) {
          root.applyTuningForSelection()
        }
      }
    }
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
    root.showingSetupAgain = true
    root.showingSettings = false
    root.settingsSection = "backend"
    root.showingLogs = false
  }

  function openSettings() {
    root.showingSettings = true
    root.settingsSection = "backend"
    root.showingLogs = false
    // On demand only: the find walks the cache folder, and nothing outside
    // Settings shows the number.
    root.refreshSlotCacheStats()
  }

  function closeSettings() {
    root.showingSettings = false
    root.showingSetupAgain = false
  }


  function finishSetup() {
    root.setupDone = true
    root.showingSetupAgain = false
    root.showingSettings = false
    root.currentPage = 0
    root.scheduleSettingsSave()
  }

  function skipSetup() {
    root.setupDone = true
    root.showingSetupAgain = false
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
    if (dir !== "") Quickshell.execDetached(["mkdir", "-p", "-m", "700", expandPath(dir)])
    root.setWidgetSetting("modelsDir", dir)
  }

  function addModelDir(path) {
    var dir = expandPath(String(path || "").trim())
    if (dir === "") return
    Quickshell.execDetached(["mkdir", "-p", "-m", "700", dir])
    var dirs = root.extraModelDirs.slice()
    if (dirs.indexOf(dir) === -1) dirs.push(dir)
    root.extraModelDirs = dirs
    root.setWidgetSetting("modelsDir", dir)
    root.refreshModels()
  }

  function removeModelDir(dir) {
    var next = []
    for (var i = 0; i < root.extraModelDirs.length; i++)
      if (root.extraModelDirs[i] !== dir) next.push(root.extraModelDirs[i])
    root.extraModelDirs = next
    if (root.configuredModelsDir !== "" && expandPath(root.configuredModelsDir) === dir)
      root.setWidgetSetting("modelsDir", "")
    root.refreshModels()
  }

  function addBuildPath(path) {
    var file = expandPath(String(path || "").trim())
    if (file === "") return
    var paths = root.extraBuildPaths.slice()
    if (paths.indexOf(file) === -1) paths.push(file)
    root.extraBuildPaths = paths
    root.probeBuilds()
  }

  function removeBuildPath(path) {
    var next = []
    for (var i = 0; i < root.extraBuildPaths.length; i++)
      if (root.extraBuildPaths[i] !== path) next.push(root.extraBuildPaths[i])
    root.extraBuildPaths = next
    // altBinary is the single-path setting extraBuildPaths replaced. Nothing
    // writes it any more, but one left over from before still names a build,
    // so removing that build has to clear it -- the same way removeModelDir
    // clears the modelsDir setting it matches. Without this the row came back
    // on every probe with no way to get rid of it.
    if (root.altBinary !== "" && expandPath(root.altBinary) === path)
      root.setWidgetSetting("altBinary", "")
    // Forgetting a build withdraws the approval too, so re-adding the same
    // path later asks again rather than inheriting a decision made about
    // whatever used to be at it.
    root.revokeBuild(path)
    if (root.llamaBuild === path) root.llamaBuild = ""
    root.probeBuilds()
  }

  function trustBuild(path) {
    var file = expandPath(String(path || "").trim())
    if (file === "") return
    var next = root.approvedBuilds.slice()
    if (next.indexOf(file) === -1) next.push(file)
    root.approvedBuilds = next
    root.scheduleSettingsSave()
    root.probeBuilds()
    root.note("builds", "trusted", file)
  }

  function revokeBuild(path) {
    var file = expandPath(String(path || "").trim())
    var next = []
    for (var i = 0; i < root.approvedBuilds.length; i++)
      if (root.approvedBuilds[i] !== file) next.push(root.approvedBuilds[i])
    if (next.length === root.approvedBuilds.length) return
    root.approvedBuilds = next
    if (root.llamaBuild === file) root.llamaBuild = ""
    root.scheduleSettingsSave()
    root.probeBuilds()
    root.note("builds", "approval withdrawn", file)
  }

  // Builds that were identified but may not be launched, and why.
  readonly property var heldBuilds: {
    var out = []
    for (var i = 0; i < root.llamaBuilds.length; i++) {
      var b = root.llamaBuilds[i]
      if (b && (b.needsApproval === true || b.blocked === true)) out.push(b)
    }
    return out
  }

  readonly property string trustNote: {
    if (root.heldBuilds.length === 0) return ""
    // Each build's own reason is in its row; this says once what the rows are
    // evidence for, which is the part a per-row phrase cannot carry.
    var anyBlocked = false
    for (var i = 0; i < root.heldBuilds.length; i++)
      if (root.heldBuilds[i].blocked === true) anyBlocked = true
    var out = "Builds are identified in a sandbox. Trusting one lets it run for real, "
      + "so trust only the builds you know."
    if (anyBlocked) out += " Blocked: another account can rewrite it."
    return out
  }

  readonly property var setupModelDirs: {
    var dirs = []
    var configured = root.configuredModelsDir !== "" ? expandPath(root.configuredModelsDir) : ""
    if (configured !== "") dirs.push(configured)
    var all = root.detectedModelDirs.concat(root.extraModelDirs)
    for (var i = 0; i < all.length; i++) {
      var dir = expandPath(all[i])
      if (dir !== "" && dirs.indexOf(dir) === -1) dirs.push(dir)
    }
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
  // Shared by the IpcHandler below and by its per-instance entry points, so
  // index 0 goes through exactly the guards `start`/`stop` always had.
  function scriptStart() {
    if (!root.running && !root.starting && !root.stopping) root.startServer()
  }
  function scriptStop() {
    if ((root.running || root.starting) && !root.stopping) root.stopServer()
  }

  // Turning the companion on creates its runner, which cannot be started in
  // the same tick; this waits for it to exist.
  Timer {
    id: decisionStartTimer
    interval: 300
    repeat: false
    onTriggered: {
      var runner = root.decisionRunner()
      if (runner && !runner.running && !runner.starting) runner.start()
    }
  }

  //
  // The panel's own open/close/toggle live on the base Panel's handler (target
  // "io.github.syjohnm.local-ai-server"); server control gets its own target so keybindings
  // and scripts can drive it without the panel open:
  //   qs -p /usr/share/omarchy/shell ipc call local-ai-server status
  IpcHandler {
    target: "local-ai-server"

    function start(): void { root.scriptStart() }
    function stop(): void { root.scriptStop() }
    // Applies a changed model or tuning the same way the Restart button does;
    // called again while it waits for running requests, it forces (Force).
    function restart(): void {
      if (root.switching) root.forceSwitch()
      else if (root.configChanged) root.switchServer()
    }
    function model(path: string): void { root.selectActiveModel(path) }

    // Per-instance and companion control, so a keybinding or a script can
    // drive the servers the Server page shows rows for -- not just the first
    // one. Index 0 is the primary, the same server start/stop act on.
    function startInstance(index: int): void {
      if (index === 0) { root.scriptStart(); return }
      var runner = root.runnerFor(index)
      if (runner && !runner.running && !runner.starting) runner.start()
    }
    function stopInstance(index: int): void {
      if (index === 0) { root.scriptStop(); return }
      var runner = root.runnerFor(index)
      if (runner && (runner.running || runner.starting)) runner.stop()
    }
    // The decision model: "on" creates the companion and starts it, "off"
    // stops it and takes it away.
    function decision(state: string): void {
      var want = String(state) !== "off" && String(state) !== "0" && String(state) !== "false"
      root.decisionEnabled = want
      if (want) decisionStartTimer.restart()
    }
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
    // Everything needed to work out why something is not running, as one
    // JSON document:
    //   qs -p /usr/share/omarchy/shell ipc call local-ai-server diagnose
    //
    // The point is that nobody should have to guess, or know to go and read
    // `systemctl --user status` and `journalctl --user -u <unit>` by hand, to
    // find out that a build cannot load a model. Every unit name is in here,
    // so those commands are the obvious next step when they are needed.
    function diagnose(): string {
      return JSON.stringify({
        plugin: { id: root.moduleName, version: "3.10.0" },
        at: new Date().toISOString(),
        // Whether the probes that gate a launch have finished. A "nothing
        // happens when I press Start" question is usually one of these.
        ready: {
          settingsLoaded: root.settingsLoaded,
          settingsBroken: root.settingsBroken,
          capabilitiesProbed: root.capabilitiesProbed,
          buildsProbed: root.buildsProbed,
          adoptProbed: root.adoptProbed,
          hasSystemdRun: root.hasSystemdRun,
          scanning: root.activeScanning,
          modelsFound: root.activeModelOptions.length
        },
        config: {
          backend: root.backend,
          routerMode: root.routerMode,
          host: root.host,
          instanceCount: root.instanceCount,
          requestedInstanceCount: root.requestedInstanceCount,
          decisionEnabled: root.decisionEnabled,
          kvPersistence: root.kvPersistence,
          startOnLogin: root.startOnLogin,
          settingsPath: root.settingsPath,
          slotDir: expandPath(root.slotSaveDir)
        },
        binaries: {
          llamaServer: root.llamaBinary,
          ollama: root.ollamaBinary,
          decision: root.activeSystemoneBinary,
          resolvedChatBuild: root.resolvedBuild ? root.resolvedBuild.real : "",
          // The gate verdict is reported because "why will this build not
          // start" is otherwise invisible from outside the panel.
          detectedBuilds: root.llamaBuilds.map(function(b) {
            return {
              path: b.path, fork: b.fork, commit: b.commit, gpu: b.gpu,
              gate: b.blocked === true ? "blocked"
                : (b.needsApproval === true ? "needs approval"
                  : (b.missing === true ? "missing" : "launchable")),
              why: b.why || []
            }
          }),
          approvedBuilds: root.approvedBuilds
        },
        hardware: root.hardware,
        // One entry per server this widget manages, each naming the unit and
        // the journal that holds its output.
        servers: root.allStates.map(function(i) {
          return {
            role: i.role || (i.primary ? "primary" : "chat"),
            title: i.title || (i.primary ? "Server" : "Instance " + i.index),
            index: i.index,
            port: i.port,
            unit: i.unitName,
            procMarker: i.procMarker,
            state: Instances.stateLabel(i),
            running: !!i.running,
            starting: !!i.starting,
            failed: !!i.failed,
            owner: Instances.ownerLabel(i),
            model: i.model,
            build: i.build,
            launchable: i.launchable !== undefined ? !!i.launchable : true,
            lastError: String(i.lastError || ""),
            journal: i.unitName
              ? "journalctl --user -u " + i.unitName + " -n 200 -o cat"
              : ""
          }
        }),
        // What is actually running, read from /proc, beside what the page
        // would launch now. A mismatch means the server was adopted rather
        // than started from this configuration -- which is the difference
        // that sent one of these investigations in the wrong direction.
        runningNow: {
          adopted: root.adopted,
          ownsUnit: root.ownsUnit,
          exe: root.runningExe,
          model: root.runningModel,
          args: root.runningArgs,
          configChanged: root.configChanged
        },
        // Flags the resolved build does not describe, which is why a tuning
        // row can look set and change nothing.
        ignoredFlags: root.ignoredFlags,
        // What the next start would run, so a launch can be reproduced by hand.
        nextLaunchArgs: root.backend === "ollama" ? [] : root.currentLaunchArgs(),
        events: root.events,
        log: root.logLinesArray().slice(-40)
      }, null, 2)
    }

    function status(): string {
      return JSON.stringify({
        running: root.running, starting: root.starting, stopping: root.stopping,
        restarting: root.switching, changesPending: root.configChanged,
        backend: root.backend, model: root.runningModel, selected: root.launchModel,
        build: root.backend === "llamacpp" ? Backends.buildLabel(root.resolvedBuild) : "",
        endpoint: root.host + ":" + root.port,
        pp: root.ppTokensPerSec, tg: root.tokensPerSec,
        instances: root.allStates.map(function(i) {
          return { index: i.index, role: i.role || "primary",
                   port: i.port, state: Instances.stateLabel(i),
                   model: i.model, build: i.build, running: !!i.running }
        }),
        totalTg: root.aggregateRate
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
      // When this login began. New on every login, unchanged by a shell
      // restart, which is the difference the auto-start has to tell apart.
      "echo \"session=$(systemctl --user show -p ActiveEnterTimestamp --value init.scope 2>/dev/null)\"; " +
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
          else if (key === "session" && value !== "") root.sessionStamp = value
          else if (key === "llama" && root.detectedLlamaBinary === "") root.detectedLlamaBinary = value
          else if (key === "llamapath" && root.detectedLlamaBinary === "") root.detectedLlamaBinary = value
          else if (key === "ollama" && root.detectedOllamaBinary === "") root.detectedOllamaBinary = value
          else if (key === "ollamapath" && root.detectedOllamaBinary === "") root.detectedOllamaBinary = value
          else if (key === "dir") dirs.push(value)
        }
        // No systemd, or a manager too old to report it: fall back to the
        // one-shot-per-panel rule rather than never starting again.
        if (root.sessionStamp === "") root.sessionStamp = "unknown"
        root.detectedModelDirs = Backends.mergeDirs(root.detectedModelDirs, dirs)
        root.scheduleSettingsSave()
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
    for (var i = 0; i < root.extraBuildPaths.length; i++) extra.push(expandPath(root.extraBuildPaths[i]))
    var argv = ["python3", root.pluginDir + "/llama_builds.py"].concat(extra)
    if (root.approvedBuilds.length > 0)
      argv = argv.concat(["--trust"]).concat(root.approvedBuilds)
    buildsProbe.command = argv
    buildsProbe.running = true
  }

  Process {
    id: buildsProbe
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var builds = []
        try { builds = JSON.parse(String(text || "").trim() || "[]") } catch (e) { builds = [] }
        root.llamaBuilds = Backends.mergeBuilds(root.llamaBuilds,
          Array.isArray(builds) ? builds : [], root.configuredBuildPaths())
        root.buildsProbed = true
        root.scheduleSettingsSave()
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
    var dirs = root.configuredModelsDir !== ""
      ? [expandPath(root.configuredModelsDir)] : root.detectedModelDirs.slice()
    for (var i = 0; i < root.extraModelDirs.length; i++) {
      var dir = expandPath(root.extraModelDirs[i])
      if (dir !== "" && dirs.indexOf(dir) === -1) dirs.push(dir)
    }
    return dirs
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
          opts.push({ value: p,
                      label: Model.plainText(Model.baseName(p).replace(/\.gguf$/i, ""), 160),
                      description: Model.plainText(Model.dirName(p), 200) })
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

    // Count occurrences of each base model to only show quant badge if >= 2 variants exist
    var baseCounts = {}
    for (var bIdx = 0; bIdx < files.length; bIdx++) {
      var bName = Model.baseModelName(files[bIdx])
      baseCounts[bName] = (baseCounts[bName] || 0) + 1
    }

    var sorted = files.slice().sort()
    for (var i = 0; i < sorted.length; i++) {
      var path = sorted[i]
      if (seen[path]) continue
      seen[path] = true
      var name = Model.baseName(path)
      var baseModel = Model.baseModelName(path)
      var cap = (caps && caps[path]) || {}
      var badges = []
      var quant = Model.quantLabel(name)
      // Only show quantization badge if the same model has more than one file/variant (>= 2)
      if (quant && (baseCounts[baseModel] >= 2)) badges.push(quant)
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
        // The label and description are a file name and a directory, and the
        // picker renders them through a shared component whose Text format
        // the plugin cannot set -- so markup is neutralised here. The value
        // stays the real path: it is a launch argument, not display text.
        label: Model.plainText(sharedName ? sharedName : name.replace(/\.gguf$/i, ""), 160),
        description: Model.plainText(badges.join(" · ") || Model.dirName(path), 200),
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
            label: Model.plainText(names[i], 160),
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
          merged.push({ value: name, label: Model.plainText(name, 160),
                        description: Model.plainText(detailFor[name], 200), mtp: false })
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

  // ---- Server lifecycle ----

  function toggleServer() {
    if (root.stopping) return
    // A manual action overrides any armed auto-switch/start.
    root.pendingBackendStart = ""
    if (root.running || root.starting) stopServer()
    else startServer()
  }

  // Backend picker: switching while a server runs no longer needs a manual
  // Stop first. The running server is stopped (saving its prompt cache), the
  // backend is switched once that completes, and the new backend starts on its
  // own once its model has resolved.
  function requestBackend(v) {
    if (v === root.backend) return
    // Instance ports are allocated from the active backend's port base, so a
    // switch leaves every extra server listening where nothing will look for
    // it again. They go down with the primary.
    root.stopAllExtras()
    if (root.running || root.starting || root.stopping) {
      root.pendingBackendSwitch = v
      root.stopServer()
    } else {
      root.pendingBackendStart = ""
      root.backend = v
    }
  }

  // Runs from the single point where a stop has fully completed. Switches the
  // backend and arms the auto-start. Returns true when it consumed a pending
  // switch, so finishStop skips the ordinary restart path.
  function applyPendingBackendSwitch() {
    if (root.pendingBackendSwitch === "") return false
    var nb = root.pendingBackendSwitch
    root.pendingBackendSwitch = ""
    root.pendingBackendStart = nb
    // Triggers onBackendChanged: resets tuning and kicks off the async model
    // scan for the new backend. maybeAutoStartSwitched starts once it lands.
    root.backend = nb
    return true
  }

  // Arms once per switch: starts the freshly switched backend as soon as it has
  // a model to launch (ollama needs none). A no-op until then, and disarmed by
  // any manual Start/Stop, so it never fights a hand-made choice.
  function maybeAutoStartSwitched() {
    if (root.pendingBackendStart === "" || root.pendingBackendStart !== root.backend) return
    if (root.running || root.starting || root.stopping) return
    if (root.backend !== "ollama" && root.launchModel === "") return
    root.pendingBackendStart = ""
    root.startServer()
  }
  onLaunchModelChanged: root.maybeAutoStartSwitched()

  // Best-effort cleanup of a server this widget started but lost track of.
  // Matched on the per-instance marker, so it never touches an unrelated
  // server or another widget's.
  function killOrphans() {
    if (root.hasSystemdRun && root.ownsUnit) {
      Quickshell.execDetached(["systemctl", "--user", "stop", root.unitName])
      // The pre-relay era router unit: included so Stop cannot leave a relay
      // behind holding the port.
      Quickshell.execDetached(["systemctl", "--user", "stop", root.unitName + "-router"])
    } else
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
        // Set before any early return: what start-on-login needs to know is
        // that the question "is one already running?" has been answered, not
        // what the answer was.
        root.adoptProbed = true
        if (root.running || root.starting) return
        if (text.trim() !== "200") return
        root.running = true
        root.adopted = true
        root.healthUrl = Backends.healthUrl(root.backend, root.host, root.port)
        // Adopted, not launched: it is running whatever it was started with,
        // which is not necessarily the build or the tuning configured now.
        // Recorded as its own kind so that difference is never a mystery.
        root.note("server", "adopted", root.host + ":" + root.port)
        root.runHook("started")
        // Determine whether this is our own transient unit (stoppable) or an
        // externally managed server such as a root-owned ollama.service.
        //
        // Metrics deliberately wait for the answer: which journal to follow
        // depends on it, and starting first meant tailing the system unit --
        // inactive whenever the server is one we own -- so throughput silently
        // never appeared.
        // systemd is not always available: the fallback launch uses setsid,
        // and systemctl would call that server external, disabling Stop.
        // The per-instance marker is the same one killOrphans uses.
        unitOwnerProc.command = root.hasSystemdRun
          ? ["systemctl", "--user", "is-active", root.activeUnitName]
          : ["bash", "-c", "pgrep -f -- \"^$1 \" >/dev/null && echo active || echo inactive",
             "_", root.procMarker]
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
        // ollama has no argv to read; assume the unit was launched from the
        // settings on disk, which is what the panel just loaded.
        if (root.ownsUnit && root.backend === "ollama") root.runningConfigHash = root.ollamaConfigHash()
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
    if (root.backend !== "ollama" && !root.routerMode && !root.launchModel) {
      root.lastError = "Pick a model first"
      return
    }
    if (root.activeBinary === "") {
      root.lastError = root.backendSpec.label + " binary not found — set it in plugin settings"
      return
    }
    if (serverProc.running || root.stopping || startSweepProc.running) return
    root.lastError = ""
    root.lastExitWasCrash = false
    root.healthFailures = 0
    // Count the pre-launch sweep as starting too: Stop pressed in this window
    // must not be ignored while the sweep is still running.
    root.starting = true
    root.expectedStop = false
    // Sweep for a stale instance synchronously before launching. killOrphans
    // is fire-and-forget, and the new process carries the same marker the
    // sweep hunts for, so a late-arriving pkill could kill the process just
    // started. Chaining through onExited guarantees the sweep finished first.
    startSweepProc.command = root.hasSystemdRun
      ? ["bash", "-lc",
          "systemctl --user stop " + root.shellQuote(root.unitName) + " 2>/dev/null; " +
          // The pre-relay era router unit: a stale one would still hold the
          // port, and this widget runs only the direct llama-server now.
          "systemctl --user stop " + root.shellQuote(root.unitName + "-router") + " 2>/dev/null; true"]
      : ["pkill", "-f", root.procMarker]
    startSweepProc.running = false
    startSweepProc.running = true
  }

  Process {
    id: startSweepProc
    onExited: {
      // A stop that arrived during the sweep wins over the launch.
      if (root.stopping || root.expectedStop) return
      root.launchServerProcess()
    }
  }

  // A flag this build does not describe is left out of argv but remembered, so
  // the tuning page can say it was ignored.
  property var ignoredFlags: []
  // Which flags a built-in control emitted for this launch. The custom-parameter
  // backstop uses this map rather than searching argv, where a *value* could
  // equal a flag name and cause a false skip.
  property var emittedFlags: ({})

  // Builds the llama-server argv.
  //
  // The composition itself lives in LlamaArgs.js, which is pure and tested:
  // this is the adapter that gathers what it needs. Called with no argument it
  // describes the primary, reading the live tuning properties through
  // Profiles.snapshot -- the same values the old in-file accessor read, field
  // for field. `spec` points it at another instance instead: {model, build,
  // binary, port, tuning}, where tuning is that model's resolved profile. One
  // builder serves every instance, so an extra server cannot drift from the
  // flags the primary would use for the same model.
  function buildLlamaArgs(spec) {
    spec = spec || {}
    var forPrimary = spec.tuning === undefined || spec.tuning === null
    var tuning = forPrimary ? Profiles.snapshot(root) : spec.tuning
    var model = spec.model !== undefined ? spec.model : root.selectedModel

    // The module expands no paths, so a custom projector arrives expanded.
    var resolved = {}
    for (var f in tuning) resolved[f] = tuning[f]
    if (String(resolved.mmprojPath || "") !== "")
      resolved.mmprojPath = expandPath(resolved.mmprojPath)

    var result = LlamaArgs.build({
      model: model,
      build: spec.build !== undefined ? spec.build : root.resolvedBuild,
      binary: spec.binary !== undefined ? spec.binary : root.launchLlamaBinary,
      host: root.host,
      port: spec.port !== undefined ? spec.port : root.port,
      slotDir: expandPath(root.slotSaveDir),
      backend: root.backend,
      tuning: resolved,
      ownedFlags: root.ownedFlags,
      // The projector and the draft sitting beside the model being launched,
      // which only the model scan can resolve.
      autoMmproj: expandPath(root.mmprojFor(model)),
      autoMtp: expandPath(root.mtpDraftFor(model)),
      supportsFlag: Backends.supportsFlag,
      // A flag this build's --help does not describe still has to be passed:
      // it may come from an alternate binary, or from a line pasted before the
      // catalogue loaded. Without the stand-in the row rendered and the launch
      // line silently omitted it.
      customArgv: function(entry) {
        var paramSpec = Params.find(root.paramCatalogue, entry.key) ||
                        Params.fallbackSpec(entry.key, entry.type)
        return Params.toArgv(paramSpec, entry.value)
      },
      splitExtraArgs: Model.splitExtraArgs,
      parseArgs: Model.parseArgs,
      deriveDefaultAlias: ModelsIni.deriveDefaultAlias
    })

    // Which flags were dropped and which were emitted is page state: it tells
    // the Tuning rows that this build ignores a flag. Only the primary's
    // launch describes the page, so an extra instance's bookkeeping is not
    // published.
    if (forPrimary) {
      root.ignoredFlags = result.ignoredFlags
      root.emittedFlags = result.emittedFlags
    }
    return result.args
  }
  // The projector found beside a given model, if any. detectedMmproj is this
  // for the selected model; buildLlamaArgs needs it for an arbitrary one.
  function mmprojFor(model) {
    if (model === "") return ""
    var found = root.visionDirs[Model.dirName(model)]
    return found ? String(found) : ""
  }

  // The shell script that starts the backend, listening on the public
  // endpoint.
  function ollamaLaunchSpec() {
    return Backends.ollamaLaunch({
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
      // modelsDir is the GGUF search path, not necessarily an ollama store.
      // Passing it here made ollama serve an empty store on a normal
      // llama.cpp setup; a custom store belongs in the env-vars row.
      modelsDir: root.resolvedOllamaStore !== "" ? root.resolvedOllamaStore : root.systemModelsDir
    })
  }

  function ollamaLaunchEnv(launch) {
    launch = launch || root.ollamaLaunchSpec()
    // ollama is configured through the environment, so user-added parameters
    // become additional assignments rather than argv.
    for (var c = 0; c < root.customParams.length; c++) {
      var spec = Params.find(root.paramCatalogue, root.customParams[c].key) ||
                 Params.fallbackSpec(root.customParams[c].key, root.customParams[c].type)
      var entry = Params.toEnvEntry(spec, root.customParams[c].value)
      if (entry) launch.env[entry.name] = entry.value
    }
    for (var ev = 0; ev < root.parsedEnv.env.length; ev++)
      launch.env[root.parsedEnv.env[ev].name] = root.parsedEnv.env[ev].value
    return launch.env
  }

  // Stable fingerprint of what ollama would be launched with. The env map is
  // sorted so key order does not look like a change.
  function ollamaConfigHash() {
    var env = root.ollamaLaunchEnv()
    var keys = Object.keys(env).sort()
    var parts = [root.ollamaBinary]
    for (var i = 0; i < keys.length; i++) parts.push(keys[i] + "=" + env[keys[i]])
    return parts.join("\n")
  }

  function buildBackendScript() {
    var script = ""
    if (root.backend === "ollama") {
      var launch = root.ollamaLaunchSpec()
      var env = root.ollamaLaunchEnv(launch)
      script = Backends.envPrefix(env, root.shellQuote) + " " +
        "exec -a " + root.procMarker + " " + launch.argv.map(root.shellQuote).join(" ")
    } else if (root.backend === "llamacpp" && root.routerMode) {

      // Native router: llama-server serves every model listed in its preset
      // INI (converted from models.ini) and loads/unloads them per request.
      // The INI is written by the launch script itself so the preset matches
      // the profiles the page holds right now, not whatever was saved last.
      var iniData = ModelsIni.fromProfiles(root.profiles, root.currentModel())
      // Mode "auto" means "the projector sitting beside the model", which only
      // the model scan can resolve -- so it is handed to the serialiser per
      // entry. Without it, router mode emitted no projector for an auto model
      // while the direct launch passed --mmproj, and vision silently stopped
      // working for that model behind the router.
      for (var mp in iniData.models) iniData.models[mp].autoMmproj = root.mmprojFor(mp)
      var iniText = ModelsIni.toRouterIni(iniData)
      var rArgs = ModelsIni.routerLaunchArgs(root.launchLlamaBinary, root.host, root.port,
                                             root.routerPresetPath, {
        extraPieces: root.extraArgTokens()
      })

      // These two work around NVIDIA-specific faults and mean nothing on
      // other backends, so they are applied only when an NVIDIA GPU was
      // actually detected rather than injected unconditionally:
      //   GGML_CUDA_REGISTER_HOST pins CPU-resident weights for DMA transfer.
      //   GGML_CUDA_DISABLE_GRAPHS avoids CUDA graph capture, which assumes
      // stable tensor addresses that hybrid CPU/GPU offload can violate.
      var cudaEnv = Hardware.isCuda(root.hardware)
        ? "GGML_CUDA_REGISTER_HOST=1 GGML_CUDA_DISABLE_GRAPHS=1 " : ""
      var userEnv = root.envScriptPrefix()
      script = "mkdir -p -m 700 " + root.shellQuote(root.routerPresetPath.replace(/\/[^/]*$/, "")) + "; " +
        // printf '%s' rather than printf '<text>': the preset is data, and as
        // a format string its own content is interpreted -- a model path with
        // a % in it (URL-encoded names are common) loses characters to a
        // conversion specifier, and a backslash becomes an escape. The
        // quoting was already correct; the format was not.
        "printf '%s' " + root.shellQuote(iniText) + " > " + root.shellQuote(root.routerPresetPath) + "; " +
        cudaEnv + (userEnv !== "" ? userEnv + " " : "") +
        "exec -a " + root.procMarker + " " + rArgs.map(root.shellQuote).join(" ")
    } else if (root.backend === "systemone") {
      var soArgs = Backends.systemoneLaunchArgs(
        root.activeSystemoneBinary,
        root.launchModel,
        root.host,
        root.port,
        expandPath(root.slotSaveDir),
        {
          ngl: root.gpuLayers,
          cacheTypeK: root.cacheTypeK,
          cacheTypeV: root.cacheTypeV,
          loadMode: root.loadMode,
          threads: root.threads,
          cpuMoe: root.cpuMoe,
          nCpuMoe: root.nCpuMoe,
          parallel: root.parallel,
          systemoneCtx: root.systemoneCtx,
          extraPieces: root.extraArgTokens(),
          propOverridden: root.propOverridden
        }
      )
      var cudaEnv = Hardware.isCuda(root.hardware)
        ? "GGML_CUDA_REGISTER_HOST=1 GGML_CUDA_DISABLE_GRAPHS=1 " : ""
      var userEnv = root.envScriptPrefix()
      script = "mkdir -p -m 700 " + root.shellQuote(expandPath(root.slotSaveDir)) + "; chmod 700 " + root.shellQuote(expandPath(root.slotSaveDir)) + "; " +
        cudaEnv + (userEnv !== "" ? userEnv + " " : "") +
        "exec -a " + root.procMarker + " " + soArgs.map(root.shellQuote).join(" ")
    } else {

      // These two work around NVIDIA-specific faults and mean nothing on
      // other backends, so they are applied only when an NVIDIA GPU was
      // actually detected rather than injected unconditionally:
      //   GGML_CUDA_REGISTER_HOST pins CPU-resident weights for DMA transfer.
      //   GGML_CUDA_DISABLE_GRAPHS avoids CUDA graph capture, which assumes
      //   stable tensor addresses that hybrid CPU/GPU offload can violate.
      var cudaEnv = Hardware.isCuda(root.hardware)
        ? "GGML_CUDA_REGISTER_HOST=1 GGML_CUDA_DISABLE_GRAPHS=1 " : ""
      var userEnv = root.envScriptPrefix()
      var args = root.buildLlamaArgs()
      script = "mkdir -p -m 700 " + root.shellQuote(expandPath(root.slotSaveDir)) + "; chmod 700 " + root.shellQuote(expandPath(root.slotSaveDir)) + "; " +
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
    // Restart count before this launch, so a count left by a previous run is
    // not read as this one looping.
    restartBaselineProc.running = false
    restartBaselineProc.running = true
    serverProc.command = Backends.detachedCommand(root.hasSystemdRun, root.unitName, script)
    root.ownsUnit = root.hasSystemdRun
    // The router loads whatever a request asks for, so nothing is loaded yet.
    root.runningModel = root.routerMode ? "" : root.launchModel
    root.routerLoadedSeen = ""
    root.runningConfigHash = root.backend === "ollama" ? root.ollamaConfigHash() : ""
    root.adopted = false
    root.starting = true
    root.expectedStop = false
    root.lastLogLine = ""
    logModel.clear()
    root.logRevision++
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
    var command = Backends.journalCommand(root.backend, root.activeUnitName, root.ownsUnit, tailLines)
    if (!command) {
      // A server started by hand outside systemd: nothing to follow. Recorded
      // so the log view can say that instead of showing a blank page.
      root.logsSource = "none"
      journalProc.running = false
      return
    }
    root.logsSource = root.ownsUnit ? "user" : "system"
    // Following the chat server again takes the view back with it.
    root.logUnit = ""
    root.logTitle = "Log"
    journalProc.command = command
    journalProc.running = false
    journalProc.running = true
  }

  // Every journal the widget can show: the chat server, each extra instance,
  // and the decision companion. A function rather than a binding -- the
  // runners come from Instantiators, which a property binding does not track.
  function logSources() {
    var out = [{ title: "Log", unit: root.activeUnitName, owns: root.ownsUnit }]
    for (var i = 1; i < root.instanceCount; i++) {
      var r = root.runnerFor(i)
      if (r && r.unitName !== "") out.push({ title: r.title, unit: r.unitName, owns: true })
    }
    var d = root.decisionRunner()
    if (d && d.unitName !== "") out.push({ title: d.title, unit: d.unitName, owns: true })
    return out
  }

  function showLogFor(source) {
    root.logUnit = source.unit === root.activeUnitName ? "" : source.unit
    root.logTitle = source.title
    logModel.clear()
    root.logRevision++
    // The companion always runs llama.cpp, whatever the chat backend is; only
    // the chat server can be the one a distribution package manages.
    var backendId = root.logUnit === "" ? root.backend : "llamacpp"
    var command = Backends.journalCommand(backendId, source.unit, source.owns, 200)
    if (!command) {
      root.logsSource = "none"
      journalProc.running = false
      return
    }
    root.logsSource = source.owns ? "user" : "system"
    journalProc.command = command
    journalProc.running = false
    journalProc.running = true
  }

  function cycleLogSource() {
    var list = root.logSources()
    if (list.length < 2) return
    var at = 0
    for (var i = 0; i < list.length; i++)
      if (list[i].unit === (root.logUnit === "" ? root.activeUnitName : root.logUnit)) at = i
    root.showLogFor(list[(at + 1) % list.length])
  }

  // Lines from a companion or a second instance are logged but not measured:
  // the bar's rate readout belongs to the chat server, and feeding another
  // server's timings into it would make the bar report the wrong number.
  function handleJournalLine(line) {
    if (root.logUnit === "") root.handleServerLine(line)
    else root.appendLogLine(line)
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

  // NRestarts as well as ActiveState. The unit carries Restart=on-failure,
  // which is what keeps a server alive across a transient fault -- and what
  // hid the opposite case: a model the build cannot load goes active ->
  // failed -> active every few seconds, and `is-active` answers "active" or
  // "activating" every time it is asked. The panel said "starting..." for ten
  // minutes while systemd restarted it twenty times. The count is the signal.
  property int unitRestartBaseline: 0
  Process {
    id: unitStateProc
    command: ["systemctl", "--user", "show", "-p", "ActiveState", "-p", "NRestarts",
              "--value", root.activeUnitName]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var unit = Model.parseUnitState(text)
        if (Model.isCrashLooping(unit.restarts, root.unitRestartBaseline)) {
          root.reportCrashLoop(unit.restarts - root.unitRestartBaseline)
          return
        }
        var state = unit.activeState
        if (state === "active" || state === "activating" || state === "") return
        // "failed", "inactive": the unit is gone. Report why, using the last
        // meaningful line the journal produced.
        root.reportUnitStopped(state)
      }
    }
  }

  Process {
    id: restartBaselineProc
    command: ["systemctl", "--user", "show", "-p", "NRestarts", "--value", root.activeUnitName]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var n = parseInt(String(text || "").trim(), 10)
        root.unitRestartBaseline = isFinite(n) && n >= 0 ? n : 0
      }
    }
  }

  // A looping unit has to be taken down as well as reported: left alone it
  // keeps restarting for as long as the session lives, holding the port.
  function reportCrashLoop(count) {
    if (root.expectedStop || root.stopping) return
    if (!root.starting && !root.running) return
    root.expectedStop = true
    Quickshell.execDetached(["systemctl", "--user", "stop", root.activeUnitName])
    startingTimer.stop()
    healthPollTimer.stop()
    unitWatchTimer.stop()
    root.stopMetrics()
    var detail = root.lastErrorLine()
    root.lastError = "Server keeps crashing on start (" + count + " restarts)" +
      (detail ? ": " + detail : " — see the log") + ". Stopped."
    root.note("server", "crash", root.lastError)
    root.lastExitWasCrash = true
    root.healthFailures = 0
    root.runHook("stopped")
    root.starting = false
    root.running = false
    root.clearRestartState()
    root.resetMetrics()
    root.expectedStop = false
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
    root.note("server", "gone", root.lastError)
    root.lastExitWasCrash = true
    root.healthFailures = 0
    root.runHook("stopped")
    root.starting = false
    root.running = false
    root.clearRestartState()
    root.resetMetrics()
  }

  function clearRestartState() {
    root.runningArgs = []
    root.runningExe = ""
    root.runningConfigHash = ""
    root.restartPhase = ""
    restartDrainTimer.stop()
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

  // ---- Restart lifecycle ----

  // Waits for running requests to finish, then restarts with the page's
  // current flags. Returns at once; restartDrainTimer does the waiting.
  function switchServer() {
    if (!root.configChanged) return
    root.lastError = ""
    root.restartIdleTicks = 0
    // ollama has no /slots; waiting for a fresh poll would never finish.
    if (root.backendSpec.metricsMode !== "slots") {
      root.handleServerLine("[restart] requested: " + Model.baseName(root.launchModel) +
                            " — restarting (no slot drain for this backend)")
      root.finishRestart()
      return
    }
    root.restartPhase = "draining"
    root.handleServerLine("[restart] requested: " + Model.baseName(root.launchModel) +
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
    // ollama has no per-launch argv to compare; its restart hash is separate.
    if (root.backend === "ollama") {
      root.runningArgs = []
      root.runningExe = ""
      return
    }
    runningArgsProc.running = false
    runningArgsProc.running = true
  }

  Process {
    id: runningArgsProc
    // systemd first, then the marker for the setsid fallback; without the
    // fallback a non-systemd server had no argv and never offered Restart.
    // Unit and marker arrive as arguments, the way the per-instance reader
    // does it. Both are safe either way -- Backends.unitName strips them to
    // [A-Za-z0-9_-] -- but one rule spelled two ways is one a later edit can
    // get wrong in only one place.
    command: ["bash", "-c",
      "pid=$(systemctl --user show -p MainPID --value \"$1\" 2>/dev/null); " +
      "[ -n \"$pid\" ] && [ \"$pid\" != 0 ] || pid=$(pgrep -f -- \"^$2 \" | head -n1); " +
      "[ -n \"$pid\" ] && [ \"$pid\" != 0 ] && readlink /proc/$pid/exe && tr '\\0' '\\n' < /proc/$pid/cmdline",
      "_", root.unitName, root.procMarker]
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

  readonly property bool savesSlots: root.kvPersistence && !root.routerMode && Backends.supports(root.backend, "slotKv")

  function stopServer() {
    var model = root.runningModel !== "" ? root.runningModel : root.launchModel
    var plan = Model.stopPlan(root.running, root.starting, root.canStop,
                              root.savesSlots, model, serverProc.running)
    if (plan === "blocked") {
      // An adopted root-owned service or a hand-started server: nothing here
      // can stop it, so do not hide it and do not fire the stopped hook.
      root.restartAfterStop = false
      // An external server cannot be switched from here either.
      root.pendingBackendSwitch = ""
      root.pendingBackendStart = ""
      root.lastError = "This server was not started by this widget, so it cannot be stopped from here."
      return
    }

    root.starting = false
    startingTimer.stop()
    healthPollTimer.stop()
    slotsPollTimer.stop()
    slotAutosaveTimer.stop()
    stopMetrics()

    // Stop pressed while the pre-launch sweep is still running: let the
    // sweep finish the cleanup it already started, but onExited must not
    // launch afterwards.
    if (startSweepProc.running) {
      root.expectedStop = true
      root.restartAfterStop = false
      root.stopping = false
      // The sweep is tearing the just-launched unit down; honour a queued
      // backend switch here since finishStop will not run for this path.
      root.applyPendingBackendSwitch()
      return
    }

    // An autosave already writing the same files must finish before the stop
    // save starts; two writers to the same .tmp name can lose the cache.
    if (slotAutosaveProc.running) {
      root.expectedStop = true
      root.stopping = true
      root.stopAfterAutosave = true
      return
    }

    if (plan === "save") {
      // Dump the KV cache before stopping, so the next start does not
      // reprocess the whole prompt. The stop itself runs from the save's
      // completion.
      root.expectedStop = true
      root.stopping = true
      slotSaveProc.command = root.slotKvCommand("save", model)
      slotSaveProc.running = false
      slotSaveProc.running = true
    } else if (plan === "stop") {
      // The detached wrapper exits as soon as the unit is created, so during
      // model load serverProc.running is already false while the unit is very
      // much alive. starting has to count as "something to stop".
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
    root.stopAfterAutosave = false
    root.killOrphans()
    root.clearRestartState()
    root.runHook("stopped")
    root.running = false
    root.stopping = false
    root.lastExitWasCrash = false
    root.healthFailures = 0
    root.adopted = false
    root.resetMetrics()
    // A queued backend switch takes precedence over a plain restart: it reruns
    // through its own start once the new backend's model resolves.
    if (root.applyPendingBackendSwitch()) return
    if (root.restartAfterStop) {
      root.restartAfterStop = false
      // startServer sweeps the old unit synchronously before launching.
      root.startServer()
    }
  }

  function resetMetrics() {
    root.runningModel = ""
    root.routerLoadedSeen = ""
    root.tokensPerSec = 0
    root.ppActive = false
    root.ppPercent = 0
    root.ppTokensPerSec = 0
    root.ppFromLog = false
    root.lastDecodeSample = null
    root.lastPromptSample = null
    root.loadedModelInfo = ""
  }

  // The shell tears this panel down on restart or plugin removal. The server
  // is deliberately left running to be re-adopted; the last debounced edit
  // is not, so flush it before the FileView goes away.
  Component.onDestruction: {
    settingsSaveTimer.stop()
    if (root.settingsLoaded) root.flushSettings()
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
  //
  // This used to stop the moment a start answered, which left nothing watching
  // a server that was up. The unit watch below only covers a server launched
  // here under systemd -- not one adopted from a previous shell, not the
  // setsid fallback, and not a root-owned system service -- and every metrics
  // poller deliberately swallows a failure to keep the last known reading. So
  // a server that crashed, was OOM-killed, or was stopped from a terminal
  // stayed "running, idle" in the panel for as long as the shell lived, with
  // the rate of its last request still on the bar. It keeps beating now, at a
  // slower cadence once there is nothing to wait for.
  Timer {
    id: healthPollTimer
    interval: root.running && !root.starting ? 3000 : 800
    repeat: true
    onTriggered: if (!healthProc.running) healthProc.running = true
  }

  Process {
    id: healthProc
    command: ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "1", root.healthUrl]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var answered = text.trim() === "200"
        if (answered) {
          root.healthFailures = 0
          if (root.starting) {
            root.starting = false
            root.running = true
            root.lastExitWasCrash = false
            startingTimer.stop()
            root.restoreSlots()
            // What Restart compares the page against.
            root.readRunningArgs()
            root.note("server", "started", root.runningModel)
            root.runHook("started")
            root.lastDecodeSample = null
            root.startMetrics()
          }
          return
        }
        // A start that has not answered yet is the startup timeout's business,
        // and a stop in progress is expected to stop answering.
        if (!root.running || root.starting || root.stopping || root.expectedStop) return
        root.healthFailures += 1
        if (Instances.healthVerdict({ running: true, failures: root.healthFailures }) === "gone")
          root.reportServerGone()
      }
    }
  }

  // The endpoint stopped answering for long enough to call it gone. Separate
  // from reportUnitStopped because it is reached for servers that have no unit
  // to read a state from -- adopted, external, or started without systemd.
  function reportServerGone() {
    if (root.expectedStop || root.stopping) return
    if (!root.running && !root.starting) return
    root.healthFailures = 0
    startingTimer.stop()
    healthPollTimer.stop()
    unitWatchTimer.stop()
    root.stopMetrics()
    var detail = root.lastErrorLine()
    root.lastError = "Server stopped answering on " + root.healthUrl +
      (detail ? ": " + detail : "")
    root.note("server", "gone", root.lastError)
    root.lastExitWasCrash = true
    root.runHook("stopped")
    root.starting = false
    root.running = false
    root.adopted = false
    root.ownsUnit = false
    root.clearRestartState()
    root.resetMetrics()
  }

  // ---- Hooks ----
  //
  // Runs `omarchy hook local-ai-server <started|stopped> <json>` -- every
  // script in ~/.config/omarchy/hooks/local-ai-server.d/ -- whenever a server
  // comes up (launched or found running) and when it goes away. The plugin
  // itself writes no one else's configuration; pointing a coding agent at
  // the live endpoint is what a hook is for. The JSON describes what is being
  // served; see README "Hooks".
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
    // Every model in the store, not only the loaded one (README "Hooks").
    var options = root.backend === "systemone" ? root.systemoneModelOptions : root.modelOptions
    for (var j = 0; j < options.length; j++)
      out.push(root.servedModelEntry(options[j].value, options[j].label))
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
    if (root.routerMode) routerPollTimer.restart()
    // Liveness, not readiness. This is the one path every running server
    // reaches -- launched here, adopted from a previous shell, or taken over
    // -- so arming the watches here is what makes "running" mean running. The
    // unit watch is the fast, decisive signal when there is a unit to read;
    // the health poll covers the cases where there is not.
    root.healthFailures = 0
    if (root.healthUrl !== "") healthPollTimer.restart()
    if (root.hasSystemdRun && root.ownsUnit) unitWatchTimer.restart()
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
    routerPollTimer.stop()
    unitWatchTimer.stop()
    journalProc.running = false
    root.logsSource = ""
  }

  // Releases a rate the server is no longer producing. One second is fine
  // granularity for a four-second linger, and the timer only runs while there
  // is a number to release.
  Timer {
    id: idleDecayTimer
    interval: 1000
    repeat: true
    running: root.running && !root.ppActive &&
             (root.tokensPerSec > 0 || root.ppTokensPerSec > 0)
    onTriggered: {
      var idle = Date.now() - root.lastRateAtMs
      var tg = Instances.rateAfterIdle(root.tokensPerSec, idle)
      if (tg !== root.tokensPerSec) root.tokensPerSec = tg
      var pp = Instances.rateAfterIdle(root.ppTokensPerSec, idle)
      if (pp !== root.ppTokensPerSec) root.ppTokensPerSec = pp
    }
  }

  Timer {
    id: slotsPollTimer
    interval: 250
    repeat: true
    onTriggered: if (root.running && !slotsProc.running) slotsProc.running = true
  }

  Process {
    id: slotsProc
    command: ["curl", "-s", "-m", "1",
      Backends.loadedModelsUrl("llamacpp", root.host, root.port)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleSlotsResponse(text)
    }
  }

  // In router mode the loaded model changes per request, and /slots does not
  // answer (400: "model name is missing"). /v1/models carries each preset's
  // status, so that is the source of truth for the loaded alias.
  Timer {
    id: routerPollTimer
    interval: 2000
    repeat: true
    onTriggered: if (root.running && root.routerMode && !routerProc.running) routerProc.running = true
  }

  Process {
    id: routerProc
    command: ["curl", "-s", "-m", "2", "http://" + root.host + ":" + root.port + "/v1/models"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "") return // keep the last known state on a failed poll
        var data
        try { data = JSON.parse(raw) } catch (e) { return }
        var list = (data && data.data) || []
        for (var i = 0; i < list.length; i++) {
          if (list[i].status && list[i].status.value === "loaded") {
            // Prefer the on-disk path: the rest of the widget keys on paths.
            var args = list[i].status.args || []
            var idx = args.indexOf("--model")
            var loaded = idx !== -1 && idx + 1 < args.length
              ? String(args[idx + 1]) : String(list[i].id || "")
            // Follow load events (request-driven in router mode): the picker
            // and tuning page move to the model the server actually loaded.
            if (loaded !== "" && loaded !== root.routerLoadedSeen) {
              root.routerLoadedSeen = loaded
              if (root.selectedModel !== loaded) root.selectModel(loaded)
            }
            root.runningModel = loaded
            return
          }
        }
        root.routerLoadedSeen = ""
        root.runningModel = ""
      }
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
    stdout: SplitParser { onRead: function(line) { root.handleJournalLine(line) } }
    stderr: SplitParser { onRead: function(line) { root.handleJournalLine(line) } }
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
        if (ppDtSec > 0.05 && ppDn > 0) {
          root.ppTokensPerSec = ppDn / ppDtSec
          root.lastRateAtMs = ppNow
        }
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
        if (dtSec > 0.05 && dn > 0) {
          root.tokensPerSec = dn / dtSec
          root.lastRateAtMs = now
        }
      }
      root.lastDecodeSample = { n: nDecoded, t: now }
    } else {
      root.lastDecodeSample = null
    }
  }

  function appendLogLine(line) {
    var text = String(line).trim()
    if (text === "") return ""
    root.lastLogLine = text
    logModel.append({ line: text })
    if (logModel.count > root.logLinesMax)
      logModel.remove(0, logModel.count - root.logLinesMax)
    root.logRevision++
    return text
  }

  function handleServerLine(line) {
    var text = root.appendLogLine(line)

    // Live ingestion progress, when the build logs it. Both numbers come
    // measured, so they win over the /slots derivation, which reports a
    // percentage with no rate whenever n_prompt_tokens_processed sits still
    // between polls -- which is what a long prompt looks like on this build.
    var progress = Model.parsePromptProgressLine(text)
    if (progress) {
      root.ppActive = true
      root.ppPercent = progress.percent
      root.ppTokensPerSec = progress.tps
      root.lastRateAtMs = Date.now()
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
      root.lastRateAtMs = Date.now()
      root.ppActive = false
    } else {
      root.tokensPerSec = timing.tps
      root.lastRateAtMs = Date.now()
      root.pushRate(timing.tps)
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
    // One minute of quiet, not twenty seconds. An agent that makes a request
    // every 25 s used to trigger a full cache write every 25 s; at 60 s it
    // waits for a real gap, and Stop/Restart still save unconditionally.
    interval: 60000
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
    onExited: {
      if (!root.stopAfterAutosave) return
      root.stopAfterAutosave = false
      // The autosave just wrote the cache; go straight to the stop rather
      // than saving the same slots a second time.
      root.finishStop()
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

  onOpenedChanged: if (!opened) {
    // Clicking away ends a setup re-run, the same as Skip: a dismissed wizard
    // must not be waiting on the next open.
    root.showingSetupAgain = false
  } else {
    root.showingLogs = false
    // shortcut: a full scan at most once a minute, refreshed by any explicit
    // rescan; upgrade to a watch if new models must appear immediately.
    if (!root.activeScanning &&
        (root.activeModelOptions.length === 0 || Date.now() - root.lastModelScanAt > 60000))
      refreshModels()
    if (!root.running) root.adoptRunningServer()
    // A hot reload keeps `running` without adopting again, so the running
    // argv is looked up here as well.
    else if (root.ownsUnit && root.runningArgs.length === 0) root.readRunningArgs()
    // Every extra index is re-probed too: a server may have appeared on one
    // since the panel was last open.
    root.adoptExtras()
  }

  // ---- Extra instances ----
  //
  // One runner per index above 0: its own transient unit, process marker,
  // port, model, build and prompt cache, over a small copy of the primary's
  // launch / adopt / watch cycle. Argv comes from the same buildLlamaArgs, so
  // an extra server cannot drift from the flags the primary would use for the
  // same model.
  //
  // Deliberately not shared with the primary: the log view, the hooks, the
  // restart-on-change comparison and the Tuning page all describe one server,
  // and giving every instance a journal tail and a /proc read would multiply
  // the panel's process count by the instance count. An extra instance
  // reports its state and its throughput; the Model and Tuning pages stay the
  // primary's.
  component InstanceRunner: QtObject {
    id: inst

    property int idx: 1

    // "chat" is an indexed llama.cpp instance; "decision" is the System One
    // companion, which runs alongside whatever the chat side is doing and on
    // its own build. Only the derived properties below differ -- the whole
    // launch / adopt / watch lifecycle underneath is shared.
    property string role: "chat"
    readonly property bool decision: inst.role === "decision"
    readonly property string backendId: inst.decision ? "systemone" : root.backend
    // Where this runner publishes its state. A name rather than an index for
    // the companion: it is not one of the chat instances.
    readonly property string stateKey: inst.decision ? "decision" : String(inst.idx)
    readonly property string title: inst.decision ? "Decision model" : "Instance " + inst.idx

    readonly property var identity: inst.decision ? null : (root.instancePlan[inst.idx] || null)
    readonly property int port: inst.decision
      ? (parseInt(root.systemonePort, 10) || 0)
      : (inst.identity ? inst.identity.port : 0)
    readonly property string unitName: inst.decision
      ? root.systemoneUnitName : (inst.identity ? inst.identity.unitName : "")
    readonly property string procMarker: inst.decision
      ? root.systemoneProcMarker : (inst.identity ? inst.identity.procMarker : "")
    readonly property string baseUrl: "http://" + root.host + ":" + inst.port
    readonly property string healthUrl: inst.baseUrl + "/health"

    // The model and build this runner serves. Kept per index for a chat
    // instance, and in the System One settings for the companion, so a shell
    // restart finds the same assignment.
    readonly property string model: inst.decision
      ? root.systemoneModel : String(root.instanceModels[String(inst.idx)] || "")
    readonly property string build: inst.decision
      ? root.systemoneBuild : String(root.instanceBuilds[String(inst.idx)] || "")
    readonly property var resolvedBuild: inst.decision
      ? root.systemoneResolvedBuild
      : (inst.build !== "" ? (Backends.findBuild(root.llamaBuilds, inst.build) || root.autoBuild)
                           : root.autoBuild)
    readonly property string binary: inst.decision
      ? root.activeSystemoneBinary
      : (inst.resolvedBuild && inst.resolvedBuild.real ? inst.resolvedBuild.real : root.launchLlamaBinary)
    // The model's own resolved profile, which is what makes a runner tuned
    // rather than launched on defaults. Keyed by its own backend, so the
    // companion reads the System One namespace.
    readonly property var tuning:
      Profiles.resolveFor(root.profiles, inst.backendId, inst.model, inst.build)

    // The companion does not care which backend is selected or whether the
    // chat side is in router mode: that independence is the point of it.
    readonly property bool launchable: inst.decision
      ? (inst.model !== "" && inst.binary !== "" && inst.port > 0 && root.hasSystemdRun)
      : (root.backend === "llamacpp" && !root.routerMode &&
         inst.model !== "" && inst.binary !== "" && inst.port > 0 && root.hasSystemdRun)

    property bool running: false
    property bool starting: false
    property bool stopping: false
    property bool adopted: false
    property bool ownsUnit: false
    property bool failed: false
    property bool expectedStop: false
    property string runningModel: ""
    property string lastError: ""
    property int startingElapsed: 0
    property int healthFailures: 0
    property real tokensPerSec: 0
    property bool ppActive: false
    property real ppPercent: 0
    property real ppTokensPerSec: 0
    property real lastRateAtMs: 0
    property var lastDecodeSample: null
    property var lastPromptSample: null

    // Everything the Server page and the bar read, in the shape Instances.js
    // describes an instance. One binding over every displayed field, so a
    // single handler is enough to tell the panel that this row changed.
    readonly property var snapshotData: ({
      index: inst.decision ? -1 : inst.idx,
      role: inst.role,
      title: inst.title,
      port: inst.port,
      unitName: inst.unitName,
      procMarker: inst.procMarker,
      primary: false,
      running: inst.running,
      starting: inst.starting,
      stopping: inst.stopping,
      switching: false,
      failed: inst.failed,
      adopted: inst.adopted,
      ownsUnit: inst.ownsUnit,
      tokensPerSec: inst.tokensPerSec,
      ppActive: inst.ppActive,
      ppPercent: inst.ppPercent,
      ppTokensPerSec: inst.ppTokensPerSec,
      model: inst.runningModel !== "" ? inst.runningModel : inst.model,
      build: Backends.buildLabel(inst.resolvedBuild),
      lastError: inst.lastError,
      canStop: inst.running && inst.ownsUnit,
      launchable: inst.launchable,
      busy: inst.stopping
    })
    onSnapshotDataChanged: root.publishInstance(inst.stateKey, inst.snapshotData)
    Component.onDestruction: root.retireInstance(inst.stateKey)

    // ---- Lifecycle ----

    function start() {
      if (inst.running || inst.starting || inst.stopping) return
      if (inst.model === "") {
        inst.lastError = inst.decision
          ? "Pick a System One model first" : "Pick a model for this instance first"
        return
      }
      // Two servers on one model hold the weights twice and write the same
      // prompt-cache files. The row's picker already hides a claimed model,
      // but the assignment can also come from a hand-edited settings file.
      // The companion serves its own namespace and its own cache prefix, so it
      // never collides with a chat instance.
      var claimed = inst.decision ? -1 : root.modelClaimedBy(inst.idx, inst.model)
      if (claimed !== -1) {
        inst.lastError = "That model is already served by " +
          (claimed === 0 ? "the first server" : "instance " + claimed)
        return
      }
      if (!root.hasSystemdRun) {
        // The setsid fallback has no unit to adopt or watch, and several
        // detached servers with no unit between them is not something this
        // page could report on honestly.
        inst.lastError = (inst.decision ? "The decision model needs" : "Extra instances need") +
          " a systemd user session"
        return
      }
      if (inst.port <= 0) { inst.lastError = "No usable port for " + inst.title; return }
      inst.lastError = ""
      inst.failed = false
      inst.healthFailures = 0
      inst.startingElapsed = 0
      inst.starting = true
      inst.expectedStop = false
      // Sweep a stale unit of the same index first, exactly as the primary
      // does: the new process carries the marker the sweep hunts for, so the
      // two must not overlap.
      inst.ownSweep.command = ["bash", "-lc",
        "systemctl --user stop " + root.shellQuote(inst.unitName) + " 2>/dev/null; true"]
      inst.ownSweep.running = false
      inst.ownSweep.running = true
    }

    function launch() {
      var args = inst.decision
        ? Backends.systemoneLaunchArgs(inst.binary, inst.model, root.host, inst.port,
                                       expandPath(root.slotSaveDir), {
            ngl: inst.tuning.gpuLayers,
            cacheTypeK: inst.tuning.cacheTypeK,
            cacheTypeV: inst.tuning.cacheTypeV,
            loadMode: inst.tuning.loadMode,
            threads: parseInt(inst.tuning.threads, 10),
            cpuMoe: inst.tuning.cpuMoe,
            nCpuMoe: inst.tuning.nCpuMoe,
            parallel: inst.tuning.parallel,
            systemoneCtx: inst.tuning.systemoneCtx,
            extraPieces: root.extraArgTokensFor(inst.tuning.extraArgs),
            propOverridden: function() { return false }
          })
        : root.buildLlamaArgs({
            model: inst.model,
            build: inst.resolvedBuild,
            binary: inst.binary,
            port: inst.port,
            tuning: inst.tuning
          })
      var dir = expandPath(root.slotSaveDir)
      var cudaEnv = Hardware.isCuda(root.hardware)
        ? "GGML_CUDA_REGISTER_HOST=1 GGML_CUDA_DISABLE_GRAPHS=1 " : ""
      var userEnv = root.envScriptPrefixFor(inst.tuning.extraEnv)
      var script =
        "mkdir -p -m 700 " + root.shellQuote(dir) + "; chmod 700 " + root.shellQuote(dir) + "; " +
        cudaEnv + (userEnv !== "" ? userEnv + " " : "") +
        "exec -a " + inst.procMarker + " " + args.map(root.shellQuote).join(" ")
      inst.ownBaseline.running = false
      inst.ownBaseline.running = true
      inst.ownLaunch.command = Backends.detachedCommand(root.hasSystemdRun, inst.unitName, script)
      // Captured plainly: unitName is derived from instancePlan, and the
      // teardown path runs while that plan is shrinking. The value is correct
      // there today, but nothing in the code says it has to be.
      inst.liveUnitName = inst.unitName
      inst.ownsUnit = true
      inst.adopted = false
      inst.runningModel = inst.model
      inst.ownLaunch.running = false
      inst.ownLaunch.running = true
      inst.ownStartingTimer.restart()
      inst.ownHealthTimer.restart()
      inst.ownUnitTimer.restart()
    }

    function stop() {
      if (!inst.running && !inst.starting) return
      if (inst.running && !inst.ownsUnit) {
        inst.lastError = "This server was not started by this widget, so it cannot be stopped from here."
        inst.restartAfterStop = false
        return
      }
      inst.expectedStop = true
      inst.stopping = true
      inst.ownStartingTimer.stop()
      inst.ownHealthTimer.stop()
      inst.ownSlotsTimer.stop()
      inst.ownUnitTimer.stop()
      if (root.kvPersistence && inst.running && inst.runningModel !== "" &&
          Backends.supports(inst.backendId, "slotKv")) {
        // Dump the prompt cache before the unit goes, same as the primary.
        // The stop runs from the save's completion whether it succeeded or not.
        inst.ownSlotSave.command = inst.slotKvCommand("save", inst.runningModel)
        inst.ownSlotSave.running = false
        inst.ownSlotSave.running = true
        return
      }
      inst.finishStop()
    }

    function finishStop() {
      inst.ownLaunch.running = false
      Quickshell.execDetached(["systemctl", "--user", "stop", inst.unitName])
      inst.running = false
      inst.starting = false
      inst.stopping = false
      inst.adopted = false
      inst.ownsUnit = false
      inst.failed = false
      inst.healthFailures = 0
      inst.runningModel = ""
      inst.resetMetrics()
    }

    // Lowering the instance count destroys this runner; the server it started
    // holds VRAM and a port, and nothing would list it any more, so it goes
    // with it. execDetached outlives the object.
    function shutdownForRemoval() {
      if (!inst.running && !inst.starting) return
      var unit = inst.liveUnitName !== "" ? inst.liveUnitName : inst.unitName
      if (unit === "") return
      Quickshell.execDetached(["systemctl", "--user", "stop", unit])
    }

    function restart() {
      if (!inst.running && !inst.starting) { inst.start(); return }
      inst.restartAfterStop = true
      inst.stop()
    }
    property bool restartAfterStop: false
    // The unit this instance actually launched or adopted, held as a plain
    // value so a teardown never has to re-evaluate a binding to find it.
    property string liveUnitName: ""

    function resetMetrics() {
      inst.tokensPerSec = 0
      inst.ppActive = false
      inst.ppPercent = 0
      inst.ppTokensPerSec = 0
      inst.lastDecodeSample = null
      inst.lastPromptSample = null
    }

    function slotKvCommand(action, model) {
      return ["python3", root.slotKvScript, action,
              "--url", inst.baseUrl,
              "--dir", expandPath(root.slotSaveDir),
              "--prefix", Backends.slotPrefix(model)]
    }

    // A server on this index's port that this widget did not just launch --
    // left behind by a previous shell, or started by hand. Health answers
    // first, then the unit says whether it is ours to stop.
    function adopt() {
      if (inst.running || inst.starting || inst.port <= 0) return
      inst.ownAdopt.running = false
      inst.ownAdopt.running = true
    }

    // The crash-loop path has already set expectedStop, because it stops the
    // unit itself; it still has to report.
    function markGoneForced(reason) {
      inst.expectedStop = false
      inst.markGone(reason)
    }

    function markGone(reason) {
      if (inst.expectedStop || inst.stopping) return
      if (!inst.running && !inst.starting) return
      inst.ownStartingTimer.stop()
      inst.ownHealthTimer.stop()
      inst.ownSlotsTimer.stop()
      inst.ownUnitTimer.stop()
      inst.lastError = reason
      root.note(inst.title, reason.indexOf("crashing") !== -1 ? "crash" : "gone", reason)
      inst.failed = true
      inst.healthFailures = 0
      inst.running = false
      inst.starting = false
      inst.adopted = false
      inst.ownsUnit = false
      inst.runningModel = ""
      inst.resetMetrics()
    }

    function promoteToRunning() {
      root.note(inst.title, "started", inst.model)
      inst.starting = false
      inst.running = true
      inst.failed = false
      inst.healthFailures = 0
      inst.ownStartingTimer.stop()
      inst.ownSlotsTimer.restart()
      if (root.kvPersistence && inst.runningModel !== "" &&
          Backends.supports(inst.backendId, "slotKv")) {
        inst.ownSlotRestore.command = inst.slotKvCommand("restore", inst.runningModel)
        inst.ownSlotRestore.running = false
        inst.ownSlotRestore.running = true
      }
    }

    // ---- Processes ----

    property Process ownSweep: Process {
      onExited: {
        if (inst.expectedStop || inst.stopping) return
        inst.launch()
      }
    }

    property Process ownLaunch: Process { }

    property Process ownAdopt: Process {
      command: ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "1", inst.healthUrl]
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          if (inst.running || inst.starting) return
          if (String(text).trim() !== "200") return
          inst.running = true
          inst.adopted = true
          inst.failed = false
          inst.ownOwner.running = false
          inst.ownOwner.running = true
        }
      }
    }

    property Process ownOwner: Process {
      command: ["systemctl", "--user", "is-active", inst.unitName]
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          inst.ownsUnit = String(text).trim() === "active"
          if (inst.running) {
            // Rehydrate the model from the argv the server is actually running,
            // not from the setting -- an adopted instance may be serving
            // something the assignment has since changed.
            inst.ownArgs.running = false
            inst.ownArgs.running = true
            inst.ownHealthTimer.restart()
            inst.ownSlotsTimer.restart()
            if (inst.ownsUnit) inst.ownUnitTimer.restart()
          }
        }
      }
    }

    property Process ownArgs: Process {
      command: ["bash", "-c",
        "pid=$(systemctl --user show -p MainPID --value \"$1\" 2>/dev/null); " +
        "[ -n \"$pid\" ] && [ \"$pid\" != 0 ] || pid=$(pgrep -f -- \"^$2 \" | head -n1); " +
        "[ -n \"$pid\" ] && [ \"$pid\" != 0 ] && tr '\\0' '\\n' < /proc/$pid/cmdline",
        "_", inst.unitName, inst.procMarker]
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          if (!inst.running) return
          var argv = String(text || "").split("\n")
          var at = argv.indexOf("--model")
          if (at !== -1 && at + 1 < argv.length) inst.runningModel = argv[at + 1]
        }
      }
    }

    property Process ownHealth: Process {
      command: ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "1", inst.healthUrl]
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          if (String(text).trim() === "200") {
            inst.healthFailures = 0
            if (inst.starting) inst.promoteToRunning()
            return
          }
          if (!inst.running || inst.starting || inst.stopping || inst.expectedStop) return
          inst.healthFailures += 1
          if (Instances.healthVerdict({ running: true, failures: inst.healthFailures }) === "gone")
            inst.markGone(inst.title + " stopped answering on " + inst.healthUrl)
        }
      }
    }

    // The unit's own state is the decisive signal for a crash during model
    // load, when nothing has answered /health yet and nothing ever will.
    property Process ownUnitState: Process {
      command: ["systemctl", "--user", "show", "-p", "ActiveState", "-p", "NRestarts",
                "--value", inst.unitName]
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          var unit = Model.parseUnitState(text)
          // Restart=on-failure keeps a server alive across a transient fault
          // and hides a model the build cannot load: that unit cycles active
          // -> failed -> active every few seconds and reads as "active" every
          // time it is asked. The restart count is what tells the two apart.
          if (Model.isCrashLooping(unit.restarts, inst.restartBaseline)) {
            inst.reportCrashLoop(unit.restarts - inst.restartBaseline)
            return
          }
          var state = unit.activeState
          if (state === "active" || state === "activating" || state === "") return
          inst.markGone(inst.title +
            (state === "failed" ? " crashed" : " stopped") + " (unit " + state + ")")
        }
      }
    }

    // The restart count before this launch, so a previous run's count is not
    // read as this one looping.
    property int restartBaseline: 0
    property int loopRestarts: 0
    property Process ownBaseline: Process {
      command: ["systemctl", "--user", "show", "-p", "NRestarts", "--value", inst.unitName]
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          var n = parseInt(String(text || "").trim(), 10)
          inst.restartBaseline = isFinite(n) && n >= 0 ? n : 0
        }
      }
    }

    // A looping unit is stopped as well as reported -- left alone it restarts
    // for as long as the session lives, holding its port -- and the reason is
    // read out of its journal, which is the one thing that says why.
    function reportCrashLoop(count) {
      if (inst.expectedStop || inst.stopping) return
      if (!inst.starting && !inst.running) return
      inst.expectedStop = true
      inst.loopRestarts = count
      Quickshell.execDetached(["systemctl", "--user", "stop", inst.unitName])
      inst.ownStartingTimer.stop()
      inst.ownHealthTimer.stop()
      inst.ownSlotsTimer.stop()
      inst.ownUnitTimer.stop()
      inst.ownWhy.running = false
      inst.ownWhy.running = true
    }

    // One-shot journal read, only on a crash. An instance has no log tail of
    // its own by design; this is the exception, because "it crashed" without
    // the reason is not a report anyone can act on.
    property Process ownWhy: Process {
      command: ["journalctl", "--user", "-u", inst.unitName, "-n", "80", "-o", "cat", "--no-pager"]
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          var detail = Model.pickErrorLine(String(text || "").split("\n"), "")
          inst.markGoneForced(inst.title + " keeps crashing on start (" +
            inst.loopRestarts + " restarts)" +
            (detail ? ": " + detail : "") + ". Stopped.")
        }
      }
    }

    property Process ownSlots: Process {
      command: ["curl", "-s", "-m", "1", inst.baseUrl + "/slots"]
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: inst.handleSlots(text)
      }
    }

    // Both prompt-cache calls end the same way whatever they report: a cache
    // that cannot be written or read only costs this instance a cold start.
    property Process ownSlotSave: Process {
      onExited: inst.finishStop()
    }
    property Process ownSlotRestore: Process { }

    function handleSlots(text) {
      var body = String(text || "").trim()
      if (body === "") return
      var data
      try { data = JSON.parse(body) } catch (e) { return }
      if (!Array.isArray(data) || data.length === 0) return

      var slot = data[0]
      for (var i = 0; i < data.length; i++) if (data[i].is_processing) { slot = data[i]; break }
      var processing = !!slot.is_processing
      var promptTotal = slot.n_prompt_tokens || 0
      var promptDone = (slot.n_prompt_tokens_processed || 0) + (slot.n_prompt_tokens_cache || 0)
      var next = slot.next_token && slot.next_token[0]
      var decoded = (next && next.n_decoded) || 0
      var now = Date.now()

      if (processing && decoded === 0 && promptTotal > 0) {
        if (inst.lastPromptSample && inst.lastPromptSample.total === promptTotal &&
            promptDone >= inst.lastPromptSample.n) {
          var dt = (now - inst.lastPromptSample.t) / 1000
          var dn = promptDone - inst.lastPromptSample.n
          if (dt > 0.05 && dn > 0) { inst.ppTokensPerSec = dn / dt; inst.lastRateAtMs = now }
        } else {
          inst.ppTokensPerSec = 0
        }
        inst.lastPromptSample = { n: promptDone, t: now, total: promptTotal }
        inst.ppActive = true
        inst.ppPercent = Math.min(100, (promptDone / promptTotal) * 100)
        inst.lastDecodeSample = null
        return
      }

      inst.ppActive = false
      inst.lastPromptSample = null

      if (processing && decoded > 0) {
        if (inst.lastDecodeSample && decoded >= inst.lastDecodeSample.n) {
          var ddt = (now - inst.lastDecodeSample.t) / 1000
          var ddn = decoded - inst.lastDecodeSample.n
          if (ddt > 0.05 && ddn > 0) { inst.tokensPerSec = ddn / ddt; inst.lastRateAtMs = now }
        }
        inst.lastDecodeSample = { n: decoded, t: now }
      } else {
        inst.lastDecodeSample = null
      }
    }

    // ---- Timers ----

    property Timer ownHealthTimer: Timer {
      interval: inst.running && !inst.starting ? 3000 : 800
      repeat: true
      onTriggered: if (!inst.ownHealth.running) inst.ownHealth.running = true
    }

    property Timer ownUnitTimer: Timer {
      interval: 1500
      repeat: true
      onTriggered: if ((inst.starting || inst.running) && !inst.ownUnitState.running)
                     inst.ownUnitState.running = true
    }

    property Timer ownSlotsTimer: Timer {
      // Half the primary's cadence: this is one curl per tick per instance,
      // and at eight instances the primary's 250 ms would put eight more
      // processes a quarter-second on a machine that is busy inferring.
      interval: 500
      repeat: true
      onTriggered: if (inst.running && !inst.ownSlots.running) inst.ownSlots.running = true
    }

    property Timer ownStartingTimer: Timer {
      interval: 1000
      repeat: true
      onTriggered: {
        inst.startingElapsed += 1
        if (inst.starting && inst.startingElapsed >= root.startupTimeoutSec) {
          inst.markGone(inst.title + " gave up waiting after " +
                        root.startupTimeoutSec + "s")
        }
      }
    }

    property Timer ownIdleTimer: Timer {
      interval: 1000
      repeat: true
      running: inst.running && !inst.ppActive &&
               (inst.tokensPerSec > 0 || inst.ppTokensPerSec > 0)
      onTriggered: {
        var idle = Date.now() - inst.lastRateAtMs
        var tg = Instances.rateAfterIdle(inst.tokensPerSec, idle)
        if (tg !== inst.tokensPerSec) inst.tokensPerSec = tg
        var pp = Instances.rateAfterIdle(inst.ppTokensPerSec, idle)
        if (pp !== inst.ppTokensPerSec) inst.ppTokensPerSec = pp
      }
    }

    // A restart requested while the stop was still saving the cache.
    onStoppingChanged: {
      if (!inst.stopping && inst.restartAfterStop) {
        inst.restartAfterStop = false
        inst.start()
      }
    }

    // Reclaim whatever is already on this port -- the shell restarting is the
    // normal case and the servers outlive it on purpose.
    //
    // Gated on the settings rather than fired from Component.onCompleted: the
    // port is portBase + index, the base comes from the settings file, and
    // probing before it loads asks the wrong port whether anything is there.
    // The primary adopts from the same moment, for the same reason.
    property bool adoptTried: false
    readonly property bool adoptReady:
      !inst.adoptTried && root.settingsLoaded && root.capabilitiesProbed &&
      inst.port > 0 && !inst.running && !inst.starting
    onAdoptReadyChanged: if (inst.adoptReady) inst.ownAdoptTimer.restart()

    property Timer ownAdoptTimer: Timer {
      // Lets the plan settle before a probe is spent on it.
      interval: 600
      repeat: false
      onTriggered: {
        inst.adoptTried = true
        inst.adopt()
      }
    }
  }

  // Lowering the count between sessions leaves no runner to notice the servers
  // the previous, larger configuration started: they would hold a port and
  // their VRAM with nothing in the panel that mentions them. Swept once, after
  // the settings have loaded so the count is the user's and not the default.
  property bool staleInstancesSwept: false
  // Every input is a property, so this fires on its own once the last one
  // lands -- the same shape as autoStartReady above, and for the same reason:
  // sweeping on the default count would stop instances the user still wants.
  // Deliberately does not mention staleInstancesSwept: the sweep sets that
  // flag, which would re-evaluate this binding, which is the loop QML
  // reported. "Has it already run" is a guard inside the function, not an
  // input to the readiness it triggers.
  readonly property bool staleSweepReady:
    root.settingsLoaded && root.capabilitiesProbed && root.hasSystemdRun
  onStaleSweepReadyChanged: if (root.staleSweepReady) root.sweepStaleInstances()

  function sweepStaleInstances() {
    if (root.staleInstancesSwept || !root.staleSweepReady) return
    root.staleInstancesSwept = true
    var units = Instances.staleUnits({
      pluginId: root.moduleName,
      backendId: root.backend,
      count: root.instanceCount,
      unitName: Backends.unitName
    })
    if (units.length === 0) return
    var parts = units.map(function(u) {
      return "systemctl --user stop " + root.shellQuote(u) + " 2>/dev/null"
    })
    Quickshell.execDetached(["bash", "-lc", parts.join("; ") + "; true"])
  }

  // The decision companion. One runner, present only while it is enabled, so
  // turning it off tears its server down the same way an index going away
  // does. Independent of `backend` and of router mode by design.
  Instantiator {
    id: decisionInstance
    model: root.decisionEnabled ? 1 : 0
    delegate: InstanceRunner { role: "decision" }
    onObjectRemoved: function(index, object) {
      if (object) object.shutdownForRemoval()
    }
  }

  Instantiator {
    id: extraInstances
    model: Math.max(0, root.instanceCount - 1)
    delegate: InstanceRunner { idx: index + 1 }
    // The server an index was running holds VRAM and a port, and once the
    // index is gone nothing would list it again -- so it goes down with the
    // runner. shutdownForRemoval only hands the stop to execDetached, which
    // outlives the object being destroyed.
    onObjectRemoved: function(index, object) {
      if (object) object.shutdownForRemoval()
    }
  }

  // ---- Bar widget ----

  implicitWidth: button.showingMetric
    ? Math.max(button.implicitWidth, root.barMetricFloor)
    : button.implicitWidth
  implicitHeight: button.implicitHeight

  // A typical full-width live readout. The bar slot never shrinks below this
  // while a metric is showing, so the numbers ticking (9.8 → 127 t/s →
  // 52% - 63 t/s) stop reflowing the whole bar. It is a floor, not a cap: a
  // wider reading than this still grows the slot rather than being clipped.
  TextMetrics {
    id: barMetric
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
    text: "100% - 999 t/s"
  }
  readonly property int barMetricFloor: Math.ceil(barMetric.advanceWidth) + Style.space(8)

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    readonly property string switchState: root.switchPhase
    readonly property bool showingMetric: root.anyInstanceRunning && /\d/.test(text)
    // One bar slot for however many servers are up: generation is summed,
    // because that is what the machine is producing, while ingestion is a
    // single-prompt event and the furthest-along prompt is reported instead.
    text: Model.barSwitchText(
      Model.barText(Model.BAR_ICON,
                    root.anyInstanceRunning, root.showMetric,
                    root.leadingPrompt !== null,
                    root.leadingPrompt !== null ? root.leadingPrompt.ppPercent : 0,
                    root.aggregateRate,
                    root.leadingPrompt !== null ? root.leadingPrompt.ppTokensPerSec
                                                : root.ppTokensPerSec),
      switchState, root.configChanged)
    // Idle shows the glyph in the bar's icon slot, which WidgetButton sizes on
    // its own; the stable width for a live readout is a floor applied to the
    // widget's implicitWidth above, so a long reading is never clipped.
    active: root.anyInstanceRunning || root.starting
    // The live number already says the server is up; an accent colour on top
    // would be the only coloured mark in the bar.
    useActiveColor: false
    fontFamily: root.bar.fontFamily
    fontSize: Style.font.bodySmall
    opacity: root.starting ? 0.6 : 1.0
    // Plain tooltipText is disabled so the rich graphical briefPopup handles hover previews
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.showMetric = !root.showMetric
      else root.toggle()
    }

    HoverHandler {
      id: buttonHover
    }

    // Status dot: tells a stopped server from one that is up but idle, which
    // the monochrome glyph alone cannot. Hidden while a metric is showing,
    // since a live number already says the server is up.
    Rectangle {
      visible: !button.showingMetric && (root.anyInstanceRunning || root.starting)
      width: Style.space(5)
      height: Style.space(5)
      radius: width / 2
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.space(3)
      anchors.rightMargin: Style.space(3)
      // Three states, three readings. Idle used to be muted grey, which next
      // to no dot at all -- which is what a stopped server shows -- was not a
      // difference anyone could see at bar size.
      color: root.starting ? Commons.Color.warning : Commons.Color.accent
      opacity: root.starting ? 0.9
        : (root.tokensPerSec > 0 || root.ppActive ? 1.0 : 0.5)
    }
  }

  // Graphical brief popup card on hover over the bar widget
  PopupCard {
    id: briefPopup
    anchorItem: button
    bar: root.bar
    owner: root
    triggerMode: "hover"
    open: buttonHover.hovered && !panel.open
    contentWidth: briefPopup.fittedContentWidth(Style.space(260))
    contentHeight: briefPopup.fittedContentHeight(briefLayout.implicitHeight + Style.space(16))

    ColumnLayout {
      id: briefLayout
      anchors.fill: parent
      anchors.margins: Style.space(8)
      spacing: Style.space(6)

      // Header: Backend status
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Rectangle {
          width: 8
          height: 8
          radius: width / 2
          color: root.running ? Commons.Color.accent : (root.starting ? Commons.Color.warning : Commons.Color.muted)
        }

        Text {
          textFormat: Text.PlainText
          text: root.backendSpec.label
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: root.fontSize
          font.bold: true
        }

        Item { Layout.fillWidth: true }

        Text {
          textFormat: Text.PlainText
          text: root.starting ? "Starting…" : (root.running ? (root.tokensPerSec > 0 ? root.tokensPerSec.toFixed(1) + " t/s" : "Active") : "Stopped")
          color: root.running ? Commons.Color.accent : root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: root.fontSizeSmall
          font.features: root.tabularFigures
          opacity: 0.8
        }
      }

      // Active model and alias
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(4)

        Text {
          textFormat: Text.PlainText
          // The card reports what the server is doing, so while it is up the
          // label has to be about what is loaded. Stopped, naming the model
          // that Start would load is useful -- as long as it does not claim
          // to be loaded already.
          text: root.running ? "Model:" : "Will load:"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: root.fontSizeSmall
          opacity: 0.6
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          // It used to fall back to the model that would be launched whenever
          // none was loaded, which in router mode is always: the router loads
          // per request, so a running router with an empty slot was reported
          // as serving whichever model the Model page happened to have
          // selected.
          text: {
            var source = root.running ? root.runningModel : root.launchModel
            var m = source ? Model.baseName(source) : ""
            if (m === "")
              return root.running
                ? (root.routerMode ? "none loaded yet" : "none loaded")
                : "None"
            var al = String(root.modelAlias).trim() || ModelsIni.deriveDefaultAlias(m)
            return al || m
          }
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: root.fontSizeSmall
          font.bold: true
          elide: Text.ElideRight
        }
      }

      // Endpoint (host:port)
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(4)

        Text {
          textFormat: Text.PlainText
          text: "Endpoint:"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: root.fontSizeSmall
          opacity: 0.6
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: root.host + ":" + root.port
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: root.fontSizeSmall
          opacity: 0.85
        }
      }

      // Build info
      RowLayout {
        Layout.fillWidth: true
        visible: root.backend === "llamacpp" && root.resolvedBuild !== null
        spacing: Style.space(4)

        Text {
          textFormat: Text.PlainText
          text: "Fork:"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: root.fontSizeSmall
          opacity: 0.6
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: root.resolvedBuild ? Backends.buildLabel(root.resolvedBuild) : ""
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: root.fontSizeSmall
          elide: Text.ElideRight
          opacity: 0.85
        }
      }

      // Generation & Prompt speeds
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(4)
        visible: root.running

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(12)

          ColumnLayout {
            spacing: Style.space(1)
            Text {
              textFormat: Text.PlainText
              text: "Generation"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSizeSmall
              opacity: 0.6
            }
            Text {
              textFormat: Text.PlainText
              text: root.tokensPerSec > 0 ? root.tokensPerSec.toFixed(1) + " tk/s" : "idle"
              color: root.tokensPerSec > 0 ? Commons.Color.accent : root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
              font.features: root.tabularFigures
              font.bold: root.tokensPerSec > 0
            }
          }

          Item { Layout.fillWidth: true }

          ColumnLayout {
            spacing: Style.space(1)
            Text {
              textFormat: Text.PlainText
              Layout.alignment: Qt.AlignRight
              text: "Prompt eval"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSizeSmall
              opacity: 0.6
            }
            Text {
              textFormat: Text.PlainText
              Layout.alignment: Qt.AlignRight
              // The rate and how far along it is are two different facts; this
              // used to drop one to show the other, so during ingestion the
              // speed vanished and afterwards the progress did. The rate lives
              // here, the progress in the bar below.
              text: root.ppTokensPerSec > 0
                ? root.ppTokensPerSec.toFixed(1) + " tk/s"
                : (root.ppActive ? "evaluating…" : "idle")
              color: (root.ppActive || root.ppTokensPerSec > 0) ? Commons.Color.accent : root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
              font.features: root.tabularFigures
              font.bold: root.ppActive || root.ppTokensPerSec > 0
            }
          }
        }

        // Prompt ingestion is the one wait long enough to want a progress read
        // at a glance, and a number says far less than a bar filling.
        Item {
          Layout.fillWidth: true
          implicitHeight: Style.space(10)
          visible: root.ppActive

          Text {
            textFormat: Text.PlainText
            id: ppPctLabel
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.ppPercent.toFixed(0) + "%"
            color: Commons.Color.accent
            font.family: root.bar.fontFamily
            font.pixelSize: root.fontSizeSmall
            font.features: root.tabularFigures
            font.bold: true
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: ppPctLabel.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            height: Style.space(4)
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g,
                           root.bar.foreground.b, 0.15)

            Rectangle {
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: parent.width * Math.max(0, Math.min(1, root.ppPercent / 100))
              radius: parent.radius
              color: Commons.Color.accent
              Behavior on width {
                NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
              }
            }
          }
        }
      }

      // The sparkline plots generation only, which nothing on the card said.
      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        visible: root.running && root.rateHistory.length > 1
        text: "Recent generation"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontSizeSmall
        opacity: 0.6
      }

      // Graphical speed sparkline (recent token generation rate)
      Canvas {
        id: sparkCanvas
        Layout.fillWidth: true
        implicitHeight: Style.space(28)
        visible: root.running && root.rateHistory.length > 1

        property var history: root.rateHistory
        onHistoryChanged: requestPaint()

        onPaint: {
          var ctx = getContext("2d")
          ctx.clearRect(0, 0, width, height)
          var list = root.rateHistory || []
          if (list.length < 2) return

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
            ctx.lineTo(x, y)
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

      // Discoverability: the bar's click actions are otherwise only in the
      // README. A faint hint keeps the hover card the single source of truth.
      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        Layout.topMargin: Style.space(2)
        text: root.running
          ? "Click to open · right-click to " + (root.showMetric ? "hide the rate" : "show the rate")
          : "Click to open"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontSizeSmall
        opacity: 0.45
        // Elided, this read "right-click …", which is the half that says what
        // the other button does. The card is free to be one line taller.
        wrapMode: Text.WordWrap
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
              textFormat: Text.PlainText
              text: Model.statusLabel(root.running, root.starting, root.startingElapsed,
                                      root.switchPhase,
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
              textFormat: Text.PlainText
              text: {
                var m = Model.metricText(true, root.ppActive, root.ppPercent,
                                         root.tokensPerSec, root.ppTokensPerSec)
                return m !== "" ? m : (root.running ? root.host + ":" + root.port : "")
              }
              color: root.bar.foreground
              opacity: 0.65
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
              font.features: root.tabularFigures
              elide: Text.ElideRight
              Layout.fillWidth: true
            }
          }

          Button {
            bordered: true
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
            bordered: true
            visible: root.configChanged || root.switching
            text: "■"
            tooltipText: "Stop the server"
            enabled: !root.stopping && root.canStop
            onClicked: root.stopServer()
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
              implicitHeight: root.rowHeight

              Text {
                textFormat: Text.PlainText
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
              textFormat: Text.PlainText
              text: root.showingSetup ? "Setup" : "Settings"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSizeSubtitle
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: root.leaderDots
              color: root.bar.foreground
              opacity: 0.15
              elide: Text.ElideRight
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
            }

            Text {
              textFormat: Text.PlainText
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
            implicitHeight: root.rowHeight
            radius: root.radiusControl
            color: settingsBackendHover.hovered
              ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
              : "transparent"

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(4)
              anchors.rightMargin: Style.space(4)
              spacing: Style.space(4)

              Text {
                textFormat: Text.PlainText
                text: "Backend"
                color: root.bar.foreground
                opacity: 0.85
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: root.leaderDots
                color: root.bar.foreground
                opacity: 0.15
                elide: Text.ElideRight
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
              Text {
                textFormat: Text.PlainText
                text: root.backendSpec.label
                color: root.bar.foreground
                opacity: 0.85
                elide: Text.ElideRight
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
              Text {
                textFormat: Text.PlainText
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
            spacing: Style.space(2)
            visible: root.settingsSection === "backend"

            // Which server. The list is the same installed-backends list the
            // Server page offers.
            Rectangle {
              id: settingsBackendRow
              Layout.fillWidth: true
              implicitHeight: root.rowHeight
              radius: root.radiusControl
              color: settingsBackendPickHover.hovered
                ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                : "transparent"

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Server"
                  color: root.bar.foreground
                  opacity: 0.8
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: root.leaderDots
                  color: root.bar.foreground
                  opacity: 0.15
                  elide: Text.ElideRight
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  textFormat: Text.PlainText
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
                width: 500
                height: settingsBackendPopupCol.implicitHeight + 16
                padding: 8
                background: Rectangle {
                  color: Commons.Color.menu.background
                  radius: root.radiusSurface
                  border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)
                  border.width: 1
                }

                ColumnLayout {
                  id: settingsBackendPopupCol
                  width: parent.width
                  spacing: Style.space(2)

                  Repeater {
                    model: root.installedBackends

                    delegate: Rectangle {
                      required property var modelData

                      readonly property bool chosen: root.backend === modelData.id

                      Layout.fillWidth: true
                      implicitHeight: root.rowHeight
                      radius: root.radiusControl
                      color: settingsBackendChoiceHover.hovered
                        ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                        : "transparent"

                      RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(4)
                        anchors.rightMargin: Style.space(4)
                        spacing: Style.space(4)

                        Text {
                          textFormat: Text.PlainText
                          text: "•"
                          visible: parent.parent.chosen
                          color: Commons.Color.accent
                          font.family: root.bar.fontFamily
                          font.pixelSize: root.fontSize
                        }
                        Text {
                          textFormat: Text.PlainText
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
              implicitHeight: root.rowHeight
              radius: root.radiusControl
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
                  textFormat: Text.PlainText
                  text: "Binary"
                  color: root.bar.foreground
                  opacity: 0.8
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: root.leaderDots
                  color: root.bar.foreground
                  opacity: 0.15
                  elide: Text.ElideRight
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  textFormat: Text.PlainText
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
            implicitHeight: root.rowHeight
            radius: root.radiusControl
            color: settingsModelsHover.hovered
              ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
              : "transparent"

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(4)
              anchors.rightMargin: Style.space(4)
              spacing: Style.space(4)

              Text {
                textFormat: Text.PlainText
                text: "Model folders"
                color: root.bar.foreground
                opacity: 0.85
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: root.leaderDots
                color: root.bar.foreground
                opacity: 0.15
                elide: Text.ElideRight
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
              Text {
                textFormat: Text.PlainText
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
                textFormat: Text.PlainText
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
            spacing: Style.space(2)
            visible: root.settingsSection === "models"

            // Auto: every detected folder.
            Rectangle {
              Layout.fillWidth: true
              implicitHeight: root.rowHeight
              radius: root.radiusControl
              color: settingsAutoHover.hovered
                ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                : "transparent"

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: root.configuredModelsDir === "" ? "•" : "·"
                  color: Commons.Color.accent
                  opacity: root.configuredModelsDir === "" ? 1.0 : 0.3
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: "All detected folders"
                  color: root.configuredModelsDir === "" ? Commons.Color.accent : root.bar.foreground
                  opacity: 0.85
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  textFormat: Text.PlainText
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
                implicitHeight: root.rowHeight
                radius: root.radiusControl
                color: settingsDirHover.hovered
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)

                  Text {
                    textFormat: Text.PlainText
                    text: chosen ? "•" : "·"
                    color: Commons.Color.accent
                    opacity: chosen ? 1.0 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: modelData.replace(Quickshell.env("HOME"), "~")
                    color: chosen ? Commons.Color.accent : root.bar.foreground
                    opacity: 0.85
                    elide: Text.ElideMiddle
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: count === undefined
                          ? "…"
                          : count + " model" + (count === 1 ? "" : "s")
                    color: root.bar.foreground
                    opacity: 0.42
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSizeSmall
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.icons.remove
                    visible: root.extraModelDirs.indexOf(modelData) !== -1
                    color: root.bar.foreground
                    opacity: 0.45
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSizeSmall
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeModelDir(modelData)
                    }
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
              implicitHeight: root.rowHeight
              radius: root.radiusControl
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
                  textFormat: Text.PlainText
                  text: "Add folder"
                  color: root.bar.foreground
                  opacity: 0.8
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: root.leaderDots
                  color: root.bar.foreground
                  opacity: 0.15
                  elide: Text.ElideRight
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  textFormat: Text.PlainText
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
                  if (text.trim() !== "") root.addModelDir(text)
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
                text: "Add a folder that holds .gguf files"
              }
            }
          }

          // Builds section ----------------------------------------------
          Rectangle {
            Layout.fillWidth: true
            implicitHeight: root.rowHeight
            radius: root.radiusControl
            color: settingsBuildsHover.hovered
              ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
              : "transparent"

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(4)
              anchors.rightMargin: Style.space(4)
              spacing: Style.space(4)

              Text {
                textFormat: Text.PlainText
                text: "Builds"
                color: root.bar.foreground
                opacity: 0.85
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: root.leaderDots
                color: root.bar.foreground
                opacity: 0.15
                elide: Text.ElideRight
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
              Text {
                textFormat: Text.PlainText
                text: root.llamaBuilds.length + " found"
                color: root.bar.foreground
                opacity: 0.45
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSizeSmall
              }
              Text {
                textFormat: Text.PlainText
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
            spacing: Style.space(2)
            visible: root.settingsSection === "builds"

            Repeater {
              model: root.llamaBuilds

              delegate: Rectangle {
                required property var modelData

                Layout.fillWidth: true
                implicitHeight: root.rowHeight
                radius: root.radiusControl
                color: "transparent"

                HoverHandler {
                  id: buildRowHover
                  // Leaving a row fires after entering the next one, so a row
                  // only clears the path while it is still the one showing.
                  onHoveredChanged: {
                    if (hovered) root.hoveredBuildPath = modelData.path
                    else if (root.hoveredBuildPath === modelData.path)
                      root.hoveredBuildPath = ""
                  }
                }

                // The fork column elides -- "llama-cpp-turboquant-cu…" -- and
                // the elided half is the part that identifies the fork.
                PanelToolTip {
                  visible: buildRowHover.hovered
                  text: (modelData.fork || "llama-server")
                    + (modelData.version ? " · " + modelData.version : "")
                }

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.fork || "llama-server"
                    color: root.bar.foreground
                    opacity: 0.8
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
                    // What is worth knowing about this build: its commit and
                    // backend when it can be used, and otherwise why it
                    // cannot. A held build also carries `missing`, which is
                    // what keeps it out of Auto, so only a build that is
                    // genuinely absent says so.
                    text: {
                      var reason = (modelData.why || []).join(" · ")
                      if (modelData.blocked === true) return reason || "blocked"
                      if (modelData.needsApproval === true) return reason || "needs approval"
                      if (modelData.missing === true) return "missing"
                      return Backends.buildDetail(modelData)
                    }
                    color: modelData.blocked === true || modelData.missing === true
                      ? Commons.Color.urgent
                      : (modelData.needsApproval === true ? Commons.Color.warning
                        : root.bar.foreground)
                    opacity: modelData.needsApproval === true || modelData.blocked === true
                      || modelData.missing === true ? 0.8 : 0.42
                    elide: Text.ElideRight
                    Layout.maximumWidth: Style.space(150)
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSizeSmall
                  }
                  // A glyph was too quiet for the one action that decides
                  // whether anything can run at all. The panel already says
                  // "Rescan builds" and "click to add" in plain words; this is
                  // the same kind of thing and now looks like it.
                  TextAction {
                    visible: modelData.needsApproval === true
                    active: true
                    text: root.icons.check + "  trust"
                    font.pixelSize: root.fontSizeSmall
                    onClicked: root.trustBuild(modelData.path)
                  }

                  // Once trusted, say so where the reason used to be, so the
                  // row reads as settled rather than as one that lost its link.
                  Text {
                    textFormat: Text.PlainText
                    visible: root.approvedBuilds.indexOf(modelData.path) !== -1
                    text: root.icons.check + " trusted"
                    color: Commons.Color.accent
                    opacity: 0.75
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSizeSmall
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.icons.remove
                    visible: root.extraBuildPaths.indexOf(modelData.path) !== -1
                      || (root.altBinary !== "" && root.expandPath(root.altBinary) === modelData.path)
                      || root.approvedBuilds.indexOf(modelData.path) !== -1
                    color: root.bar.foreground
                    opacity: 0.45
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSizeSmall
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeBuildPath(modelData.path)
                    }
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              visible: root.llamaBuilds.length === 0
              text: "No llama.cpp build detected yet"
              color: root.bar.foreground
              opacity: 0.45
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSizeSmall
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              Layout.topMargin: Style.space(2)
              visible: root.trustNote !== "" || root.hoveredBuildPath !== ""
              // Cut in the middle: the ends say which tree and which file,
              // and every row here shares the "/home/sxy/" that eliding from
              // the right would keep.
              text: root.hoveredBuildPath !== ""
                ? Model.shortenPath(root.hoveredBuildPath, 64)
                : root.trustNote
              wrapMode: Text.WordWrap
              color: root.bar.foreground
              opacity: 0.45
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSizeSmall
            }

            Rectangle {
              id: settingsAddForkRow
              Layout.fillWidth: true
              implicitHeight: root.rowHeight
              radius: root.radiusControl
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
                  textFormat: Text.PlainText
                  text: "Add fork"
                  color: root.bar.foreground
                  opacity: 0.8
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: root.leaderDots
                  color: root.bar.foreground
                  opacity: 0.15
                  elide: Text.ElideRight
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  textFormat: Text.PlainText
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
                  if (text.trim() !== "") root.addBuildPath(text)
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
                text: "Path to another llama-server build"
              }
            }

            TextAction {
              Layout.fillWidth: true
              text: buildsProbe.running ? "Detecting…" : "Rescan builds"
              onClicked: root.probeBuilds()
            }
          }

          // Prompt cache ---------------------------------------------------
          // The only place the caches are visible at all. The sweep is offered
          // only once a model scan has actually produced a catalogue, so an
          // empty scan can never present every cache as orphaned.
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(2)

            RowLayout {
              Layout.fillWidth: true
              Layout.leftMargin: Style.space(4)
              Layout.rightMargin: Style.space(4)
              spacing: Style.space(4)

              Text {
                textFormat: Text.PlainText
                text: "Prompt cache"
                color: root.bar.foreground
                opacity: 0.85
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: root.leaderDots
                color: root.bar.foreground
                opacity: 0.15
                elide: Text.ElideRight
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSize
              }
              Text {
                textFormat: Text.PlainText
                text: root.slotCacheProbed ? Model.formatBytes(root.slotCacheBytes) : "…"
                color: root.bar.foreground
                opacity: 0.65
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSizeSmall
                font.features: root.tabularFigures
              }
            }

            TextAction {
              Layout.fillWidth: true
              visible: root.slotCacheOrphans.length > 0 && root.slotKeepProbed
              text: "Remove " + root.slotCacheOrphans.length + " orphaned cache" +
                    (root.slotCacheOrphans.length === 1 ? "" : "s") + " · " +
                    Model.formatBytes(Model.totalSlotBytes(root.slotCacheOrphans))
              onClicked: root.removeSlotOrphans()
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

            // Re-running setup was reachable only through the `setup` IPC call
            // documented in the README; this is the same thing without a
            // terminal. Hidden during setup itself, where it would be a no-op.
            TextAction {
              visible: !root.showingSetup
              text: "Re-run setup"
              onClicked: root.startSetup()
            }

            Item { Layout.fillWidth: true }

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
          visible: !root.showingLogs && !root.showingSetup && !root.showingSettings
          clip: true

          // Server ------------------------------------------------------
          ColumnLayout {
            anchors.fill: parent
            spacing: Style.space(8)
            visible: root.currentPage === 0

            // Instances section ---------------------------------------------
            //
            // One row per instance the settings call for, each reporting what
            // that server is actually doing. It used to be a single hardcoded
            // "Instance 0" whatever `instanceCount` said, with no liveness
            // watch behind it -- so a crashed server stayed "idle" and the
            // rate of its last request stayed on the page.
            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(4)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  text: "Instances"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSizeSmall
                  opacity: 0.6
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  visible: root.multiInstance
                  text: root.instancesRunning + "/" + root.instanceCount + " up" +
                        (root.aggregateRate > 0 ? " · " + root.aggregateRate.toFixed(1) + " t/s" : "")
                  color: root.anyInstanceRunning ? Commons.Color.accent : root.bar.foreground
                  opacity: root.anyInstanceRunning ? 0.9 : 0.45
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSizeSmall
                  font.features: root.tabularFigures
                }

                Item { Layout.fillWidth: true }

                // The count lives in the widget's manifest settings, so it is
                // written through omarchy-bar and applied to the live widget.
                Text {
                  textFormat: Text.PlainText
                  visible: root.canAddInstances
                  text: root.icons.minus
                  color: root.bar.foreground
                  opacity: root.instanceCount > 1 ? 0.8 : 0.2
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.iconSize
                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    cursorShape: Qt.PointingHandCursor
                    enabled: root.instanceCount > 1
                    onClicked: root.setWidgetSetting("instanceCount", root.instanceCount - 1)
                  }
                }
                Text {
                  textFormat: Text.PlainText
                  visible: root.canAddInstances
                  text: String(root.instanceCount)
                  color: root.bar.foreground
                  opacity: 0.7
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSizeSmall
                }
                Text {
                  textFormat: Text.PlainText
                  visible: root.canAddInstances
                  text: root.icons.plus
                  color: root.bar.foreground
                  opacity: root.instanceCount < Instances.MAX_INSTANCES ? 0.8 : 0.2
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.iconSize
                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    cursorShape: Qt.PointingHandCursor
                    enabled: root.instanceCount < Instances.MAX_INSTANCES
                    onClicked: root.setWidgetSetting("instanceCount", root.instanceCount + 1)
                  }
                }
                PanelToolTip {
                  visible: instanceCountHover.hovered
                  text: "Number of persistent llama-server instances. Each one gets " +
                        "its own port (" + root.port + " upwards), model and build."
                }
                HoverHandler { id: instanceCountHover }
              }

              // Driven by the count, which is stable, rather than by
              // instanceStates, which is replaced on every poll that moves a
              // rate -- a new array identity rebuilds every delegate, and a
              // model picker rebuilt four times a second cannot be used. The
              // row's bindings still follow the state; only the delegates
              // stay put.
              Repeater {
                model: root.instanceCount

                delegate: Rectangle {
                  id: instRow
                  required property int index
                  readonly property var snap: root.instanceState(instRow.index)
                  readonly property bool isPrimary: !!instRow.snap.primary
                  readonly property bool up: !!instRow.snap.running
                  readonly property bool pending:
                    !!instRow.snap.starting || !!instRow.snap.stopping
                  readonly property string modelPath: String(instRow.snap.model || "")

                  Layout.fillWidth: true
                  implicitHeight: instCol.implicitHeight + Style.space(8)
                  radius: root.radiusSurface
                  color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.03)
                  border.color: instRow.up
                    ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.25)
                    : Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.08)
                  border.width: 1

                  ColumnLayout {
                    id: instCol
                    anchors.fill: parent
                    anchors.margins: Style.space(6)
                    spacing: Style.space(4)

                    RowLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(6)

                      Rectangle {
                        width: 8
                        height: 8
                        radius: width / 2
                        color: instRow.up
                          ? Commons.Color.accent
                          : (instRow.pending
                              ? Commons.Color.urgent
                              : (instRow.snap.failed
                                  ? root.bar.urgent
                                  : Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.25)))
                      }

                      Text {
                        textFormat: Text.PlainText
                        text: root.multiInstance ? "Instance " + instRow.index : "Server"
                        color: root.bar.foreground
                        font.family: root.bar.fontFamily
                        font.pixelSize: root.fontSize
                        font.bold: true
                      }

                      Text {
                        textFormat: Text.PlainText
                        text: instRow.snap.port > 0 ? ":" + instRow.snap.port : "no port"
                        color: root.bar.foreground
                        opacity: 0.5
                        font.family: root.bar.fontFamily
                        font.pixelSize: root.fontSizeSmall
                      }

                      Text {
                        textFormat: Text.PlainText
                        visible: text !== "" && text !== "this widget"
                        text: Instances.ownerLabel(instRow.snap)
                        color: root.bar.foreground
                        opacity: 0.45
                        font.family: root.bar.fontFamily
                        font.pixelSize: root.fontSizeSmall
                      }

                      Item { Layout.fillWidth: true }

                      Text {
                        textFormat: Text.PlainText
                        text: Instances.stateLabel(instRow.snap)
                        color: instRow.snap.failed
                          ? root.bar.urgent
                          : (instRow.up ? Commons.Color.accent : root.bar.foreground)
                        opacity: instRow.up ? 0.9 : (instRow.snap.failed ? 0.9 : 0.45)
                        font.family: root.bar.fontFamily
                        font.pixelSize: root.fontSizeSmall
                        font.features: root.tabularFigures
                      }
                    }

                    // What this instance serves. The primary follows the Model
                    // page; an extra index is assigned here, because it is the
                    // only place that knows the index exists.
                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      visible: instRow.isPrimary
                      text: root.routerMode && root.backend === "llamacpp"
                        ? (root.running ? "Router · " + (root.runningModel !== ""
                              ? Model.baseName(root.runningModel) : "no model loaded yet")
                            : "Router mode (models.ini)")
                        : (instRow.modelPath !== ""
                            ? (instRow.up ? "Loaded: " : "Ready: ") + Model.baseName(instRow.modelPath)
                            : "No model selected")
                      color: root.bar.foreground
                      opacity: instRow.up ? 0.85 : 0.5
                      elide: Text.ElideRight
                      font.family: root.bar.fontFamily
                      font.pixelSize: root.fontSizeSmall
                    }

                    SearchableDropdown {
                      Layout.fillWidth: true
                      visible: !instRow.isPrimary
                      showLabel: false
                      enabled: !instRow.up && !instRow.pending
                      opacity: enabled ? 1.0 : 0.5
                      options: root.instanceModelOptions(instRow.index)
                      value: String(root.instanceModels[String(instRow.index)] || "")
                      placeholderText: "Search models…"
                      emptyText: root.activeScanning ? "Scanning…" : "No models found"
                      triggerLabel: instRow.modelPath === ""
                        ? "Pick a model for instance " + instRow.index : ""
                      onChanged: function(v) { root.setInstanceModel(instRow.index, v) }
                    }

                    // Build. The primary's picker writes the selected model's
                    // profile; an extra index keeps its own choice.
                    BuildPickerRow {
                      Layout.fillWidth: true
                      visible: instRow.isPrimary
                      readOnly: root.running || root.starting
                    }

                    Dropdown {
                      Layout.fillWidth: true
                      visible: !instRow.isPrimary && root.backend === "llamacpp"
                      showLabel: false
                      enabled: !instRow.up && !instRow.pending
                      opacity: enabled ? 1.0 : 0.5
                      options: root.instanceBuildOptions()
                      value: String(root.instanceBuilds[String(instRow.index)] || "")
                      onChanged: function(v) { root.setInstanceBuild(instRow.index, v) }
                    }

                    RowLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(6)
                      Item { Layout.fillWidth: true }

                      Button {
                        bordered: true
                        visible: instRow.isPrimary && root.backend === "llamacpp"
                        text: root.routerMode ? "Router: on" : "Router: off"
                        tooltipText: root.multiInstance
                          ? "Router mode serves every model from one process, so it runs as a single instance"
                          : "Serve every model in models.ini from one process"
                        enabled: !root.running && !root.starting && !root.stopping
                        onClicked: {
                          // routerMode lives in settings.json (loadSettings /
                          // flushSettings), not in the manifest -- it has no
                          // schema entry and is never read through setting().
                          // This used to call setWidgetSetting, which wrote a
                          // key nothing reads, so the toggle was lost on the
                          // next shell start unless an unrelated edit happened
                          // to schedule a save.
                          root.routerMode = !root.routerMode
                        }
                      }

                      Button {
                        bordered: true
                        visible: !instRow.isPrimary
                        text: "Restart"
                        tooltipText: "Stop and start this instance with its current model and build"
                        enabled: instRow.up && !instRow.pending && !!instRow.snap.canStop
                        onClicked: root.restartInstance(instRow.index)
                      }

                      Button {
                        bordered: true
                        text: instRow.up || instRow.snap.starting ? "Unload" : "Start"
                        tooltipText: instRow.isPrimary
                          ? ""
                          : (instRow.snap.launchable || instRow.up
                              ? ""
                              : "Needs a model, a llama.cpp build, a free port and a systemd user session")
                        enabled: instRow.isPrimary
                          ? (!root.stopping && (root.running ? root.canStop : true))
                          // ownsUnit, not canStop: canStop requires `running`,
                          // so Unload rendered and stayed disabled for the
                          // whole startup window -- up to startupTimeoutSec,
                          // ten minutes, with no way to cancel a model that
                          // was never going to load. InstanceRunner.stop()
                          // handles the starting case already.
                          : (instRow.up || instRow.snap.starting
                              ? !!instRow.snap.ownsUnit && !instRow.snap.stopping
                              : !!instRow.snap.launchable)
                        onClicked: instRow.isPrimary
                          ? root.toggleServer()
                          : root.toggleInstance(instRow.index)
                      }
                    }

                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      visible: !instRow.isPrimary && String(instRow.snap.lastError || "") !== ""
                      text: String(instRow.snap.lastError || "")
                      color: root.bar.urgent
                      wrapMode: Text.WordWrap
                      maximumLineCount: 2
                      elide: Text.ElideRight
                      font.family: root.bar.fontFamily
                      font.pixelSize: root.fontSizeSmall
                    }
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                visible: root.multiInstance && !root.hasSystemdRun
                text: root.icons.warning + " Extra instances need a systemd user session; only the first server can be managed here."
                color: root.bar.urgent
                wrapMode: Text.WordWrap
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSizeSmall
              }
            }

            // Backend section -----------------------------------------------
            // Backend and endpoint. Same shape as the tuning rows: a label,
            // a dotted leader, and the value the next start will use. Clicking
            // the row is what changes it, which keeps two controls out of a
            // page that already has enough of them.
            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)

              Rectangle {
                id: backendRow
                Layout.fillWidth: true
                implicitHeight: root.rowHeight
                radius: root.radiusControl
                color: backendHover.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)

                  Text {
                    textFormat: Text.PlainText
                    text: "Backend"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }

                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }

                  Text {
                    textFormat: Text.PlainText
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
                  // Switching while running is allowed now: requestBackend
                  // stops the current server first, then starts the new one.
                  enabled: !root.stopping
                  onClicked: backendPopup.open()
                }
                PanelToolTip {
                  visible: backendHover.containsMouse
                  text: root.running || root.starting
                    ? "Switch backend — the running server is stopped first, then the new one starts."
                    : "The inference server this widget launches."
                }

                Popup {
                  id: backendPopup
                  x: 0
                  y: parent.height + 4
                  width: 500
                  height: backendPopupCol.implicitHeight + 16
                  padding: 8
                  background: Rectangle {
                    color: Commons.Color.menu.background
                    radius: root.radiusSurface
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
                        root.requestBackend(v)
                        backendPopup.close()
                      }
                    }
                  }
                }
              }

              Rectangle {
                id: endpointRow
                Layout.fillWidth: true
                implicitHeight: root.rowHeight
                radius: root.radiusControl
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
                    textFormat: Text.PlainText
                    text: "host:port"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }

                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: root.host + ":" + root.port
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: (root.anyInstanceRunning || root.starting) ? 0.45 : 0.85
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
                  // This is the port base every index is allocated from, so a
                  // running extra instance locks it too -- moving it would
                  // leave that server listening on a port the page no longer
                  // watches.
                  enabled: !root.anyInstanceRunning && !root.starting
                  onClicked: {
                    endpointRow.editing = true
                    endpointEdit.text = root.host + ":" + root.port
                    endpointEdit.forceActiveFocus()
                  }
                }
                PanelToolTip {
                  visible: endpointHover.containsMouse
                  text: root.anyInstanceRunning || root.starting
                    ? "Stop every instance to change the endpoint — it is the port base they are allocated from."
                    : "Address the server listens on — host:port, e.g. 127.0.0.1:8080. Extra instances take the ports above it."
                }
              }
            }


            // llama-server runs without an API key here, so an endpoint off
            // loopback serves the model -- and its slot save/restore API -- to
            // anyone who can reach the port.
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              visible: !/^(127\.|localhost$|\[::1\]$|::1$)/.test(String(root.host).trim())
              text: root.icons.warning + " " + root.host + " is reachable from other machines, and the server has no API key. " +
                    "Use 127.0.0.1 unless you mean to share it."
              color: root.bar.urgent
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
            }

            // What is actually locked while a server runs. Switching backend
            // is not: requestBackend stops the running server, saving its
            // prompt cache, and starts the new one once its model resolves.
            // The page used to say "stop the server to change backend, build
            // or endpoint", which had been wrong since that path landed.
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              visible: root.running || root.starting
              text: "Build and endpoint change on the next start. Switching backend " +
                    "stops this server first, then starts the new one."
              color: root.bar.foreground
              opacity: 0.5
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
            }


            // Same dotted row as the tuning page, so the one switch on this
            // page does not read as a different kind of control.
            Rectangle {
              Layout.fillWidth: true
              implicitHeight: root.rowHeight
              radius: root.radiusControl
              visible: Backends.supports(root.backend, "slotKv")
              color: kvPersistenceHover.hovered
                ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                : "transparent"

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Keep prompt cache"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                  opacity: 0.85
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: root.leaderDots
                  color: root.bar.foreground
                  opacity: 0.15
                  elide: Text.ElideRight
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.kvPersistence ? "on" : "off"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                  opacity: root.kvPersistence ? 0.85 : 0.45
                }
              }

              HoverHandler { id: kvPersistenceHover; cursorShape: Qt.PointingHandCursor }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.kvPersistence = !root.kvPersistence
              }
              PanelToolTip {
                visible: kvPersistenceHover.hovered
                fontSize: root.fontSize
                text: "Save the prompt (KV) cache on stop, restart and when idle; restore it at start"
              }
            }

            Rectangle {
              Layout.fillWidth: true
              implicitHeight: root.rowHeight
              radius: root.radiusControl
              color: startOnLoginHover.hovered
                ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                : "transparent"

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Start on login"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                  opacity: 0.85
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: root.leaderDots
                  color: root.bar.foreground
                  opacity: 0.15
                  elide: Text.ElideRight
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.startOnLogin ? "on" : "off"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                  opacity: root.startOnLogin ? 0.85 : 0.45
                }
              }

              HoverHandler { id: startOnLoginHover; cursorShape: Qt.PointingHandCursor }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.startOnLogin = !root.startOnLogin
              }
              PanelToolTip {
                visible: startOnLoginHover.hovered
                fontSize: root.fontSize
                text: root.routerMode && root.backend === "llamacpp"
                  ? "Start the router automatically when the shell starts, a few seconds in"
                  : "Start this server automatically when the shell starts, a few seconds in"
              }
            }

            Text {
              textFormat: Text.PlainText
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
              textFormat: Text.PlainText
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
            // Decision model (System One) --------------------------------
            //
            // A companion, not a backend. It answers typed decisions on its
            // own port, costs almost no VRAM, and is most useful while a chat
            // model is loaded -- so choosing it used to stop the chat server,
            // which was backwards. It also wants a current llama.cpp, which is
            // exactly what a user running an older optimised fork for chat
            // does not have, so it picks its own build.
            Item { Layout.fillWidth: true; Layout.preferredHeight: Style.space(4) }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(4)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  text: "Decision model"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSizeSmall
                  opacity: 0.6
                  font.bold: true
                }

                Item { Layout.fillWidth: true }

                Text {
                  textFormat: Text.PlainText
                  text: root.decisionEnabled ? "on" : "off"
                  color: root.bar.foreground
                  opacity: root.decisionEnabled ? 0.85 : 0.45
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSizeSmall
                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.decisionEnabled = !root.decisionEnabled
                  }
                }
                HoverHandler { id: decisionToggleHover }
                PanelToolTip {
                  visible: decisionToggleHover.hovered
                  text: "Run a System One decision model alongside the chat server, " +
                        "on its own port and its own llama.cpp build. Turning it off stops it."
                }
              }

            }

            Item { Layout.fillHeight: true }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: root.hardwareSummary !== "" ? root.hardwareSummary : "Detecting hardware…"
              color: root.bar.foreground
              opacity: 0.6
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
              font.features: root.tabularFigures
            }

            Text {
              textFormat: Text.PlainText
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
              implicitHeight: root.rowHeight
              radius: root.radiusControl
              color: "transparent"

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "Model"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                  opacity: 0.85
                }

                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: root.leaderDots
                  color: root.bar.foreground
                  opacity: 0.15
                  elide: Text.ElideRight
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSize
                }

                Text {
                  textFormat: Text.PlainText
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
                // A file path from the model scan, rendered by a shared
                // tooltip whose Text format the plugin cannot set. Only the
                // dynamic fragment is neutralised, so the plugin's own
                // multi-line wording keeps its newlines.
                text: root.launchModel !== ""
                      ? Model.plainText(root.launchModel.replace(Quickshell.env("HOME"), "~"), 300)
                      : "Pick the model this server loads."
              }
            }

            // Scanning is triggered by the things that change what is on
            // disk -- a folder added, the backend switched -- so a model
            // copied in while the panel was open had no way to appear.
            TextAction {
              Layout.fillWidth: true
              text: root.activeScanning ? "Scanning…" : "Rescan models"
              onClicked: if (!root.activeScanning) root.refreshModels()
            }

            // Accordion -------------------------------------------------
            // One chain open at a time. Filtering swaps the tree for a flat
            // result list, which is the only way to find one model by name
            // in a collection hundreds deep.
            ColumnLayout {
              Layout.fillWidth: true
              Layout.fillHeight: true
              spacing: Style.space(2)

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
                    textFormat: Text.PlainText
                    text: "Filter"
                    color: root.bar.foreground
                    opacity: 0.7
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }

                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }

                  TextField {
                    id: modelFilterField
                    Layout.preferredWidth: Math.max(Style.space(130), modelRow.width * 0.45)
                    implicitHeight: root.rowHeight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    placeholderText: "name or folder"
                    text: root.modelFilter
                    onTextEdited: root.modelFilter = text
                  }

                  Text {
                    textFormat: Text.PlainText
                    visible: root.modelFilter !== ""
                    text: root.icons.remove
                    Layout.leftMargin: Style.space(8)
                    color: root.bar.foreground
                    opacity: filterClearHover.hovered ? 0.9 : 0.45
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.iconSize
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
                radius: root.radiusSurface
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
                        height: root.rowHeight
                        radius: root.radiusControl
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
                            textFormat: Text.PlainText
                            text: isDir ? (open ? "-" : "+") : "·"
                            color: current ? Commons.Color.accent : root.bar.foreground
                            opacity: current ? 1.0 : 0.45
                            font.family: root.bar.fontFamily
                            font.pixelSize: root.fontSize
                          }

                          Text {
                            textFormat: Text.PlainText
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
                              textFormat: Text.PlainText
                              visible: isDir
                              text: isDir ? String(node.count) : ""
                              color: current ? Commons.Color.accent : root.bar.foreground
                              opacity: current ? 0.75 : 0.42
                              font.family: root.bar.fontFamily
                              font.pixelSize: root.fontSize
                            }

                            TextAction {
                              visible: !isDir && current && !root.running
                              text: "Start"
                              onClicked: root.startServer()
                            }
                            TextAction {
                              visible: !isDir && current && root.running && root.runningModel !== node.path
                              text: "Switch"
                              onClicked: root.switchServer()
                            }
                            TextAction {
                              visible: !isDir && current && root.running && root.runningModel === node.path
                              text: "Unload"
                              onClicked: root.stopServer()
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
                  textFormat: Text.PlainText
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
              textFormat: Text.PlainText
              Layout.fillWidth: true
              visible: root.running && !root.routerMode && root.runningModel !== "" &&
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
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: {
                // The Rescan action already says "Scanning…" while it runs; this
                // line keeps counting, and speaks for the scan only when it has
                // nothing of its own to report -- "No models available" during a
                // first scan is a false negative, not a count.
                var n = root.activeModelOptions.length
                if (root.activeScanning && n === 0) return "Scanning…"
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
                textFormat: Text.PlainText
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
                bordered: true
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
                  implicitHeight: root.rowHeight
                  radius: root.radiusControl
                  color: pageHover.hovered
                    ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.08)
                    : "transparent"

                  Text {
                    textFormat: Text.PlainText
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
              implicitHeight: root.rowHeight
              radius: root.radiusControl
              visible: !addParamOpen
              color: addHover.hovered && root.addableCount > 0
                ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                : "transparent"

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(4)
                anchors.rightMargin: Style.space(4)

                Text {
                  textFormat: Text.PlainText
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
                bordered: true
                text: root.icons.remove
                tooltipText: "Cancel"
                onClicked: addParamOpen = false
              }
            }

            // One row per built-in flag, in the same shape as the endpoint:
            // label, dotted leader, value, and a remove icon that takes the row off the
            // page. The value is the thing to click -- a number opens an inline
            // field, an enum opens a list -- so the page reads as a list of
            // settings rather than a form of boxes.
            ColumnLayout {
              Layout.fillWidth: true
              visible: root.tuningPageHasBuiltins
              spacing: Style.space(2)

              // ---- KV cache k/v ----
              Rectangle {
                id: cacheRow
                Layout.fillWidth: true
                implicitHeight: root.rowHeight
                radius: root.radiusControl
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
                    textFormat: Text.PlainText
                    text: "KV cache k/v"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.cacheTypeK + " / " + root.cacheTypeV
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.icons.remove
                    Layout.leftMargin: Style.space(8)
                    color: cacheHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: cacheHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.iconSize
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
                  width: 500
                  height: cachePopupCol.implicitHeight + 16
                  padding: 8
                  background: Rectangle {
                    color: Commons.Color.menu.background
                    radius: root.radiusSurface
                    border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)
                    border.width: 1
                  }
                  ColumnLayout {
                    id: cachePopupCol
                    width: parent.width
                    spacing: 6
                    Text {
                      textFormat: Text.PlainText
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
                      textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("cacheType") && root.rowHasIgnoredFlag("cacheType")
                text: root.icons.warning + " not in this build"
                font.pixelSize: root.fontSizeSmall
                color: Commons.Color.urgent
              }

              // ---- Flash attention ----
              Rectangle {
                id: flashRow
                Layout.fillWidth: true
                implicitHeight: root.rowHeight
                radius: root.radiusControl
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
                    textFormat: Text.PlainText
                    text: "Flash attn"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.flashAttn
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.icons.remove
                    Layout.leftMargin: Style.space(8)
                    color: flashHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: flashHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.iconSize
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
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("flashAttn") && root.rowHasIgnoredFlag("flashAttn")
                text: root.icons.warning + " not in this build"
                font.pixelSize: root.fontSizeSmall
                color: Commons.Color.urgent
              }

              // ---- GPU layers ----
              Rectangle {
                id: nglRow
                Layout.fillWidth: true
                implicitHeight: root.rowHeight
                radius: root.radiusControl
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
                    textFormat: Text.PlainText
                    text: "GPU layers"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.gpuLayers
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.icons.remove
                    Layout.leftMargin: Style.space(8)
                    color: nglHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: nglHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.iconSize
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
                    textFormat: Text.PlainText
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
                implicitHeight: root.rowHeight
                radius: root.radiusControl
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
                    textFormat: Text.PlainText
                    text: "MoE on CPU"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.cpuMoe ? "all" : (root.nCpuMoe !== "" ? root.nCpuMoe : "off")
                    color: root.cpuMoe ? Commons.Color.accent : root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.icons.remove
                    Layout.leftMargin: Style.space(8)
                    color: moeHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: moeHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.iconSize
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
                  width: 500
                  height: moePopupCol.implicitHeight + 16
                  padding: 8
                  background: Rectangle {
                    color: Commons.Color.menu.background
                    radius: root.radiusSurface
                    border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)
                    border.width: 1
                  }
                  ColumnLayout {
                    id: moePopupCol
                    width: parent.width
                    spacing: 6
                    Text {
                      textFormat: Text.PlainText
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
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: (root.cpuMoe ? root.icons.check + " " : "") + "All layers (--cpu-moe)"
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
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("cpuMoe") && root.rowHasIgnoredFlag("cpuMoe")
                text: root.icons.warning + " not in this build"
                font.pixelSize: root.fontSizeSmall
                color: Commons.Color.urgent
              }

              // ---- Context ----
              Rectangle {
                id: ctxRow
                Layout.fillWidth: true
                implicitHeight: root.rowHeight
                radius: root.radiusControl
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
                    textFormat: Text.PlainText
                    text: "Context"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.contextSize !== "" ? root.contextSize : "0"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.icons.remove
                    Layout.leftMargin: Style.space(8)
                    color: ctxHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: ctxHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.iconSize
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
                    textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("ctxSize") && root.rowHasIgnoredFlag("ctxSize")
                text: root.icons.warning + " not in this build"
                font.pixelSize: root.fontSizeSmall
                color: Commons.Color.urgent
              }

              // ---- Threads ----
              Rectangle {
                id: threadsRow
                Layout.fillWidth: true
                implicitHeight: root.rowHeight
                radius: root.radiusControl
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
                    textFormat: Text.PlainText
                    text: "Threads"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.threads !== "" ? root.threads : "auto"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.icons.remove
                    Layout.leftMargin: Style.space(8)
                    color: threadsHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: threadsHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.iconSize
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
                    textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("threads") && root.rowHasIgnoredFlag("threads")
                text: root.icons.warning + " not in this build"
                font.pixelSize: root.fontSizeSmall
                color: Commons.Color.urgent
              }

              // ---- Batch / ubatch ----
              Rectangle {
                id: batchRow
                Layout.fillWidth: true
                implicitHeight: root.rowHeight
                radius: root.radiusControl
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
                    textFormat: Text.PlainText
                    text: "Batch / ubatch"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: (root.batchSize !== "" ? root.batchSize : "auto") + " / " +
                          (root.ubatchSize !== "" ? root.ubatchSize : "auto")
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.icons.remove
                    Layout.leftMargin: Style.space(8)
                    color: batchHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: batchHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.iconSize
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
                    radius: root.radiusSurface
                    border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)
                    border.width: 1
                  }
                  ColumnLayout {
                    id: batchPopupCol
                    width: parent.width
                    spacing: 6
                    Text {
                      textFormat: Text.PlainText
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
                      textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("batchSize") && root.rowHasIgnoredFlag("batchSize")
                text: root.icons.warning + " not in this build"
                font.pixelSize: root.fontSizeSmall
                color: Commons.Color.urgent
              }

              // ---- Slots ----
              Rectangle {
                id: parallelRow
                Layout.fillWidth: true
                implicitHeight: root.rowHeight
                radius: root.radiusControl
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
                    textFormat: Text.PlainText
                    text: "Slots (-np)"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.parallel !== "" ? root.parallel : "auto"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.icons.remove
                    Layout.leftMargin: Style.space(8)
                    color: parallelHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: parallelHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.iconSize
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
                    textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("parallel") && root.rowHasIgnoredFlag("parallel")
                text: root.icons.warning + " not in this build"
                font.pixelSize: root.fontSizeSmall
                color: Commons.Color.urgent
              }

              // ---- Reasoning trace ----
              Rectangle {
                id: reasoningRow
                Layout.fillWidth: true
                implicitHeight: root.rowHeight
                radius: root.radiusControl
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
                    textFormat: Text.PlainText
                    text: "Reasoning trace"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.reasoningPreserve
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.icons.remove
                    Layout.leftMargin: Style.space(8)
                    color: reasoningHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: reasoningHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.iconSize
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
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("reasoning") && root.rowHasIgnoredFlag("reasoning")
                text: root.icons.warning + " not in this build"
                font.pixelSize: root.fontSizeSmall
                color: Commons.Color.urgent
              }

              // ---- Speculative ----
              Rectangle {
                id: specRow
                Layout.fillWidth: true
                implicitHeight: root.rowHeight
                radius: root.radiusControl
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
                    textFormat: Text.PlainText
                    text: "Speculative"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.specType
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.icons.remove
                    Layout.leftMargin: Style.space(8)
                    color: specHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: specHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.iconSize
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
                  width: 500
                  height: specPopupCol.implicitHeight + 16
                  padding: 8
                  background: Rectangle {
                    color: Commons.Color.menu.background
                    radius: root.radiusSurface
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
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("specType") && root.rowHasIgnoredFlag("specType")
                text: root.icons.warning + " not in this build"
                font.pixelSize: root.fontSizeSmall
                color: Commons.Color.urgent
              }

              // ---- Vision projector ----
              Rectangle {
                id: visionRow
                Layout.fillWidth: true
                implicitHeight: root.rowHeight
                radius: root.radiusControl
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
                    textFormat: Text.PlainText
                    text: "Vision projector"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.mmprojMode + (root.mmprojActive ? " · offload " + root.mmprojOffload : "")
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.icons.remove
                    Layout.leftMargin: Style.space(8)
                    color: visionHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: visionHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.iconSize
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
                    ? "Found next to this model:\n" + Model.plainText(root.detectedMmproj, 300) +
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
                    radius: root.radiusSurface
                    border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)
                    border.width: 1
                  }
                  ColumnLayout {
                    id: visionPopupCol
                    width: parent.width
                    spacing: 6
                    Text {
                      textFormat: Text.PlainText
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
                      textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("vision") && root.rowHasIgnoredFlag("vision")
                text: root.icons.warning + " not in this build"
                font.pixelSize: root.fontSizeSmall
                color: Commons.Color.urgent
              }

              // ---- Paste args ----
              Rectangle {
                id: extraRow
                Layout.fillWidth: true
                implicitHeight: root.rowHeight
                radius: root.radiusControl
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
                    textFormat: Text.PlainText
                    text: "Paste args"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.extraArgs !== "" ? "..." : "—"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.5
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.icons.remove
                    Layout.leftMargin: Style.space(8)
                    color: extraHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: extraHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.iconSize
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
                    textFormat: Text.PlainText
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
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("extraArgs") && root.rowHasIgnoredFlag("extraArgs")
                text: root.icons.warning + " not in this build"
                font.pixelSize: root.fontSizeSmall
                color: Commons.Color.urgent
              }

              // ---- Environment ----
              // A small editor instead of one whitespace-separated line:
              // values may contain spaces, and each variable gets its own
              // row so it can be changed or removed without retyping the rest.
              Rectangle {
                id: envRow
                Layout.fillWidth: true
                implicitHeight: root.rowHeight
                radius: root.radiusControl
                visible: root.builtinOnPage("envVars")
                color: envHoverArea.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                // Declared before the row so the remove icon sits above it and
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
                    textFormat: Text.PlainText
                    text: "Environment"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
                    text: root.icons.chevron
                    color: root.bar.foreground
                    opacity: 0.5
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.iconSize
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.icons.remove
                    Layout.leftMargin: Style.space(8)
                    color: envHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: envHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.iconSize
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
                    radius: root.radiusSurface
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
                        spacing: Style.space(2)

                        Repeater {
                          model: envPopup.draft

                          delegate: Rectangle {
                            required property var modelData
                            required property int index

                            width: envList.width
                            height: root.rowHeight
                            radius: root.radiusControl
                            color: envVarHover.hovered
                              ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                              : "transparent"

                            RowLayout {
                              anchors.fill: parent
                              anchors.leftMargin: Style.space(4)
                              anchors.rightMargin: Style.space(4)
                              spacing: Style.space(4)

                              Text {
                                textFormat: Text.PlainText
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
                                textFormat: Text.PlainText
                                text: root.icons.remove
                                Layout.leftMargin: Style.space(8)
                                color: envVarHover.hovered ? Commons.Color.urgent : root.bar.foreground
                                opacity: envVarHover.hovered ? 0.8 : 0.3
                                font.family: root.bar.fontFamily
                                font.pixelSize: root.iconSize
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
                      textFormat: Text.PlainText
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
                      textFormat: Text.PlainText
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

              // ---- Model alias ----
              Rectangle {
                id: modelAliasRow
                Layout.fillWidth: true
                implicitHeight: root.rowHeight
                radius: root.radiusControl
                visible: root.builtinOnPage("modelAlias")
                property bool editing: false
                color: modelAliasHoverArea.containsMouse
                  ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.04)
                  : "transparent"

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)
                  visible: !modelAliasRow.editing

                  Text {
                    textFormat: Text.PlainText
                    text: "Model alias"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.modelAlias !== "" ? root.modelAlias : (ModelsIni.deriveDefaultAlias(root.currentModel()) || "auto")
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: root.modelAlias !== "" ? 0.85 : 0.45
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.icons.remove
                    Layout.leftMargin: Style.space(8)
                    color: modelAliasHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: modelAliasHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.iconSize
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeBuiltin("modelAlias")
                    }
                  }
                }

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4)
                  visible: modelAliasRow.editing

                  Text {
                    textFormat: Text.PlainText
                    text: "Model alias"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  TextField {
                    id: modelAliasEdit
                    Layout.fillWidth: true
                    text: root.modelAlias
                    placeholderText: ModelsIni.deriveDefaultAlias(root.currentModel())
                    onEditingFinished: {
                      root.modelAlias = text.trim()
                      modelAliasRow.editing = false
                    }
                    Keys.onEscapePressed: modelAliasRow.editing = false
                  }
                }

                MouseArea {
                  id: modelAliasHoverArea
                  z: -1
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  visible: !modelAliasRow.editing
                  onClicked: {
                    modelAliasRow.editing = true
                    modelAliasEdit.text = root.modelAlias
                    modelAliasEdit.forceActiveFocus()
                  }
                }
                PanelToolTip {
                  visible: modelAliasHoverArea.containsMouse
                  text: "Friendly name exposed via --alias for OpenAI-compatible clients and the UI"
                }
              }

              // ---- System One context ----
              Rectangle {
                id: systemoneCtxRow
                Layout.fillWidth: true
                implicitHeight: root.rowHeight
                radius: root.radiusControl
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
                    textFormat: Text.PlainText
                    text: "System One context"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.systemoneCtx !== "" ? root.systemoneCtx : "0"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.icons.remove
                    Layout.leftMargin: Style.space(8)
                    color: systemoneCtxHoverArea.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: systemoneCtxHoverArea.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.iconSize
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
                    textFormat: Text.PlainText
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
                  text: "Context window for the System One backend, in tokens"
                }
              }
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(4)
                visible: root.builtinOnPage("systemoneCtx") && root.rowHasIgnoredFlag("systemoneCtx")
                text: root.icons.warning + " not in this build"
                font.pixelSize: root.fontSizeSmall
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
                implicitHeight: root.rowHeight
                radius: root.radiusControl
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
                    textFormat: Text.PlainText
                    text: spec ? spec.label : modelData.key
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    opacity: 0.85
                    elide: Text.ElideRight
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.leaderDots
                    color: root.bar.foreground
                    opacity: 0.15
                    elide: Text.ElideRight
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                  }
                  Text {
                    textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
                    text: root.icons.remove
                    Layout.leftMargin: Style.space(8)
                    color: customHover.containsMouse ? Commons.Color.urgent : root.bar.foreground
                    opacity: customHover.containsMouse ? 0.8 : 0.3
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.iconSize
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeCustomParam(modelData.key)
                    }
                  }
                }

                MouseArea {
                  id: customHover
                  // Below the row content, like every built-in row, so the remove icon
                  // is reachable instead of only opening the editor.
                  z: -1
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: customPopup.open()
                }
                PanelToolTip {
                  visible: customHover.containsMouse
                  // Both come from the build's own --help output.
                  text: Model.plainText(modelData.key, 120) +
                        (spec && spec.description ? "\n" + Model.plainText(spec.description, 300) : "")
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
                    radius: root.radiusSurface
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
              textFormat: Text.PlainText
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
              textFormat: Text.PlainText
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
              textFormat: Text.PlainText
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

          // Decision ----------------------------------------------------
          // Its own page, and only while the companion is enabled. It has
          // a model, a build and a lifecycle of its own -- a page's worth
          // -- and on the Server page it sat under everything else, off
          // the bottom of the panel, where it could not be reached.
          ColumnLayout {
            anchors.fill: parent
            spacing: Style.space(6)
            visible: root.currentPage === 3

            // Every other page leads with one of these, and a page that opens
            // straight onto a card does not read as part of the set.
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: "Companion"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSizeSmall
                opacity: 0.6
                font.bold: true
              }

              Item { Layout.fillWidth: true }

              Text {
                textFormat: Text.PlainText
                text: root.decisionState ? Instances.stateLabel(root.decisionState) : "stopped"
                color: root.decisionState && root.decisionState.running
                  ? Commons.Color.accent : root.bar.foreground
                opacity: root.decisionState && root.decisionState.running ? 0.9 : 0.45
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontSizeSmall
                font.features: root.tabularFigures
              }
            }

            Rectangle {
              id: decisionCard
              Layout.fillWidth: true
              visible: root.decisionEnabled
              implicitHeight: decisionCol.implicitHeight + Style.space(8)
              radius: root.radiusSurface
              readonly property var snap: root.decisionState
              readonly property bool up: !!(decisionCard.snap && decisionCard.snap.running)
              readonly property bool pending:
                !!(decisionCard.snap && (decisionCard.snap.starting || decisionCard.snap.stopping))
              readonly property bool starting: !!(decisionCard.snap && decisionCard.snap.starting)
              color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.03)
              border.color: decisionCard.up
                ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.25)
                : Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.08)
              border.width: 1

              ColumnLayout {
                id: decisionCol
                anchors.fill: parent
                anchors.margins: Style.space(6)
                spacing: Style.space(4)

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(6)

                  Rectangle {
                    width: 8
                    height: 8
                    radius: width / 2
                    color: decisionCard.up
                      ? Commons.Color.accent
                      : (decisionCard.pending
                          ? Commons.Color.urgent
                          : Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.25))
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: "System One"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSize
                    font.bold: true
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: ":" + root.systemonePort
                    color: root.bar.foreground
                    opacity: 0.5
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSizeSmall
                  }

                  Item { Layout.fillWidth: true }

                  Text {
                    textFormat: Text.PlainText
                    text: root.decisionState ? Instances.stateLabel(root.decisionState) : "stopped"
                    color: decisionCard.up ? Commons.Color.accent : root.bar.foreground
                    opacity: decisionCard.up ? 0.9 : 0.45
                    font.family: root.bar.fontFamily
                    font.pixelSize: root.fontSizeSmall
                    font.features: root.tabularFigures
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(4)

                  SearchableDropdown {
                    Layout.fillWidth: true
                    showLabel: false
                    enabled: !decisionCard.up && !decisionCard.pending
                    opacity: enabled ? 1.0 : 0.5
                    options: root.systemoneModelOptions
                    value: root.systemoneModel
                    placeholderText: "Search decision models…"
                    emptyText: root.systemoneScanning ? "Scanning…" : "No models found"
                    triggerLabel: root.systemoneModel === "" ? "Pick a decision model" : ""
                    onChanged: function(v) { root.systemoneModel = v }
                  }

                  Button {
                    bordered: true
                    text: root.icons.refresh
                    tooltipText: root.systemoneScanning ? "Scanning…" : "Rescan for decision models"
                    enabled: !root.systemoneScanning
                    onClicked: root.refreshSystemoneModels()
                  }
                }

                // Its own build, and only the ones that carry the route. The
                // chat side can stay on an old fork that has no endpoint.
                Dropdown {
                  Layout.fillWidth: true
                  showLabel: false
                  enabled: !decisionCard.up && !decisionCard.pending
                  opacity: enabled ? 1.0 : 0.5
                  options: root.decisionBuildOptions()
                  value: root.systemoneBuild
                  onChanged: function(v) { root.setSystemoneBuild(v) }
                }

                // A decision model emits no tokens -- it reads logits at the
                // last prompt token -- so temperature, top-p and the rest of
                // the sampling page mean nothing here. What decides whether it
                // runs at all beside a chat model is how much of it sits on
                // the card and how long a prompt it must hold.
                // Where to reach it. The card's header carries the port, but a
                // port alone is not an address, and this is the one the
                // decision client has to be pointed at.
                ValueRow {
                  label: "host:port"
                  value: root.host + ":" + root.systemonePort
                  editable: !decisionCard.up && !decisionCard.starting
                  tooltip: decisionCard.up || decisionCard.starting
                    ? "Stop the companion to move it — it is listening on this port."
                    : "Address the companion listens on. The host is the panel's and is shared with the chat server; only the port is the companion's own."
                  onCommitted: function(committedText) {
                    root.setDecisionEndpoint(committedText)
                  }
                }

                ValueRow {
                  label: "GPU layers"
                  // The registry owns what "unset" means for a field;
                  // repeating the number here would be a second source.
                  hint: String(root.builtinDefaults.gpuLayers)
                  value: String(root.decisionTuning.gpuLayers === undefined
                    ? "" : root.decisionTuning.gpuLayers)
                  inputValidator: IntValidator { bottom: -1; top: 999 }
                  onCommitted: function(committedText) {
                    root.setDecisionField("gpuLayers", committedText)
                  }
                }

                ValueRow {
                  label: "Context"
                  hint: String(root.builtinDefaults.systemoneCtx)
                  value: root.systemoneCtx
                  inputValidator: IntValidator { bottom: 0; top: 1048576 }
                  onCommitted: function(committedText) { root.systemoneCtx = committedText }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(6)
                  Item { Layout.fillWidth: true }

                  Button {
                    bordered: true
                    text: decisionCard.up || decisionCard.starting ? "Unload" : "Start"
                    tooltipText: root.decisionState && root.decisionState.launchable
                      ? ""
                      : "Needs a decision model, a llama.cpp build, a free port and a systemd user session"
                    enabled: root.decisionState
                      ? (root.decisionState.running || root.decisionState.starting
                          ? !!root.decisionState.ownsUnit && !root.decisionState.stopping
                          : !!root.decisionState.launchable)
                      : false
                    onClicked: root.toggleDecision()
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  visible: !!(root.decisionState && String(root.decisionState.lastError || "") !== "")
                  text: root.decisionState ? String(root.decisionState.lastError || "") : ""
                  color: root.bar.urgent
                  wrapMode: Text.WordWrap
                  maximumLineCount: 2
                  elide: Text.ElideRight
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontSizeSmall
                }
              }
            }

            ValueRow {
              label: "Binary override"
              hint: "the build picked above"
              value: root.configuredSystemoneBinary
              onCommitted: function(committedText) { root.setSystemoneBinary(committedText) }
            }

            ValueRow {
              label: "Models folder"
              hint: "the main model scan"
              value: root.configuredSystemoneModelsDir
              onCommitted: function(committedText) { root.setSystemoneModelsDir(committedText) }
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

            // The title doubles as the source switch: with a companion or a
            // second instance running there is more than one journal, and the
            // header is where the view says which one it is reading.
            TextAction {
              text: root.logTitle
              active: root.logUnit !== ""
              font.pixelSize: root.fontSize
              onClicked: root.cycleLogSource()
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: root.leaderDots
              color: root.bar.foreground
              opacity: 0.15
              elide: Text.ElideRight
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSize
            }

            Text {
              textFormat: Text.PlainText
              text: logView.stickToBottom ? "live" : "paused"
              color: logView.stickToBottom ? Commons.Color.accent : root.bar.foreground
              opacity: logView.stickToBottom ? 1.0 : 0.5
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontSizeSmall
            }

            Text {
              textFormat: Text.PlainText
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
            radius: root.radiusSurface
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.035)

            ListView {
              id: logView
              anchors.fill: parent
              anchors.margins: Style.space(6)
              clip: true
              model: logModel
              spacing: Style.space(1)
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
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(8)
              visible: logModel.count === 0
              // "the server" is only right while the view follows the chat
              // server; following a companion it would name the wrong one.
              text: root.logsSource === "none"
                    ? "This server was started outside systemd, so its output is not in any journal. Restart it from here to see its log."
                    : (root.logUnit !== ""
                       ? "Nothing in the journal for " + root.logTitle + " yet."
                       : (root.running ? "Waiting for the server to log something…"
                                       : "No log yet -- the server is not running."))
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
              radius: root.radiusSurface
              color: Commons.Color.menu.background
              border.width: 1
              border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)

              Text {
                textFormat: Text.PlainText
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
          visible: !root.showingSetup && !root.showingSettings

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
