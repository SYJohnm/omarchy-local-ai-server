"use strict"

// The llama-server argv.
//
// This was ~190 lines inside Panel.qml, which meant the single most important
// function in the plugin -- the one that decides what actually gets launched
// -- could not be run by a test. That is not a hypothetical cost: a read of an
// identifier nothing defined (`model`, where the model alias is derived) threw
// a ReferenceError out of it for every direct llama.cpp launch whose alias row
// was on "auto", which is the default. No argv was ever built and Start did
// nothing. It shipped, and survived several releases, because router mode
// assembles its argv elsewhere. One test over this function would have caught
// it on the first run.
//
// Pure: plain data in, an argv array out. Everything it would otherwise reach
// for is passed in, including the three helpers it needs -- a QML JS library
// cannot import another one, so they are injected rather than required.
//
// What the caller resolves, so this file touches no filesystem and expands no
// paths: the model, the build, the binary, the slot directory, the projector
// beside the model (autoMmproj) and the draft beside it (autoMtp).

/**
 * @param {object} cfg
 * @param {string}   cfg.model       the .gguf to serve (goes to --model)
 * @param {object}   cfg.build       resolved build descriptor, or null
 * @param {string}   cfg.binary      argv[0]
 * @param {string}   cfg.host
 * @param {string|number} cfg.port
 * @param {string}   cfg.slotDir     already-expanded --slot-save-path
 * @param {string}   cfg.backend     backend id; flags are llamacpp-only
 * @param {object}   cfg.tuning      resolved profile (Profiles.resolveFor)
 * @param {object}   cfg.ownedFlags  flag -> tuning property it belongs to
 * @param {string}   [cfg.autoMmproj] projector found beside the model
 * @param {string}   [cfg.autoMtp]    MTP draft found beside the model
 * @param {function} cfg.supportsFlag (build, flag) -> boolean
 * @param {function} cfg.customArgv   (entry) -> argv tokens for one added param
 * @param {function} cfg.splitExtraArgs
 * @param {function} cfg.parseArgs
 * @param {function} cfg.deriveDefaultAlias
 * @returns {{args: string[], ignoredFlags: string[], emittedFlags: object}}
 */
function build(cfg) {
  var c = cfg || {}
  var model = String(c.model || "")
  var buildDesc = c.build || null
  var binary = String(c.binary || "")
  var host = String(c.host || "")
  var port = String(c.port === undefined || c.port === null ? "" : c.port)
  var slotDir = String(c.slotDir || "")
  var backend = String(c.backend || "")
  var tuning = c.tuning || {}
  var ownedFlags = c.ownedFlags || {}
  var autoMmproj = String(c.autoMmproj || "")
  var autoMtp = String(c.autoMtp || "")

  var supportsFlag = c.supportsFlag || function() { return true }
  var customArgv = c.customArgv || function() { return [] }
  var splitExtraArgs = c.splitExtraArgs || function(v) { return v ? [String(v)] : [] }
  var parseArgs = c.parseArgs || function(v) { return String(v).split(/\s+/).filter(Boolean) }
  var deriveDefaultAlias = c.deriveDefaultAlias || function() { return "" }

  // Tuning accessor, kept so the body reads as it did in Panel.qml.
  var T = function(field) { return tuning[field] }

  var params = T("customParams") || []
  var overridden = function(prop) {
    for (var oi = 0; oi < params.length; oi++)
      if (ownedFlags[params[oi].key] === prop) return true
    return false
  }

  // The projector and the draft belong to the model being launched.
  var mmprojMode = T("mmprojMode")
  var mmprojOffload = T("mmprojOffload")
  var resolvedMmproj =
    mmprojMode === "off" ? ""
    : mmprojMode === "custom" ? String(T("mmprojPath") || "").trim()
    : autoMmproj
  var mmprojActive = resolvedMmproj !== ""
  var mtp = autoMtp
  var mtpActive = mtp !== "" && T("specType") === "draft-mtp"

  // Declared before the closure that writes them, not after: `var` hoists, so
  // the old order worked at call time, but QML's compiler warns about the
  // use-before-declaration and a reader has to know the hoisting rule.
  var ignoredFlags = []
  var emittedFlags = {}

  var emitFlag = function(b, flag, value, args) {
    if (supportsFlag(b, flag)) {
      // Boolean flags carry no value; an empty argv entry is an error to
      // llama-server, not "use the default".
      args.push(flag)
      if (String(value) !== "") args.push(String(value))
      emittedFlags[flag] = true
      return true
    }
    if (ignoredFlags.indexOf(flag) === -1) ignoredFlags.push(flag)
    return false
  }

  var ngl = parseInt(T("gpuLayers"), 10)
  var currentBuild = buildDesc

  if (!isFinite(ngl)) ngl = 0
  // -1 is llama.cpp's "fit as many layers as VRAM allows" sentinel, not a
  // layer count, so it is passed through unclamped.
  if (ngl !== -1) ngl = Math.max(0, Math.min(999, ngl))

  var args = [
    binary,
    "--model", model,
    "--host", host,
    "--port", port,
    "--slot-save-path", slotDir,
    // Prometheus endpoint, so Stats can read totals the /slots view does
    // not carry.
    "--metrics"
  ]

  // Every flag a built-in control owns is emitted only while no added
  // parameter has taken it over. Emitting both is how a launch line ended up
  // carrying two "--load-mode mmap": llama.cpp keeps the last occurrence, so
  // the duplicate is silent -- the control still shows its own value while
  // the server runs on the other one.
  if (buildDesc && backend === "llamacpp") {
    if (!overridden("gpuLayers")) emitFlag(buildDesc, "--gpu-layers", ngl, args)
    if (!overridden("cacheTypeK")) emitFlag(buildDesc, "--cache-type-k", T("cacheTypeK"), args)
    if (!overridden("cacheTypeV")) emitFlag(buildDesc, "--cache-type-v", T("cacheTypeV"), args)
    if (!overridden("flashAttn")) emitFlag(buildDesc, "--flash-attn", T("flashAttn"), args)
    if (!overridden("loadMode")) emitFlag(buildDesc, "--load-mode", T("loadMode"), args)
  }

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
  var visionOwned = overridden("mmprojMode") ||
                    overridden("mmprojPath") ||
                    overridden("mmprojOffload")
  if (!visionOwned) {
    if (mmprojMode === "off") {
      args.push("--no-mmproj")
    } else if (mmprojActive) {
      args.push("--mmproj", resolvedMmproj)
      // GPU offload is llama.cpp's default but rarely fits alongside the
      // main model's layers, and the failure mode is an allocation abort
      // rather than a clean error -- so the plugin default stays "off".
      if (mmprojOffload === "on") {
        if (!buildDesc || backend !== "llamacpp" ||
          supportsFlag(buildDesc, "--mmproj-offload"))
          args.push("--mmproj-offload")
      } else if (!buildDesc || backend !== "llamacpp" ||
                 supportsFlag(buildDesc, "--no-mmproj-offload")) {
        args.push("--no-mmproj-offload")
      }
    }
  }

  // External MTP draft, the same idea as the projector above: a file named
  // like a draft beside the model, never a picker entry. It is passed only
  // while the spec type uses it -- --model-draft alone loads the weights and
  // decodes nothing with them. A hand-added --model-draft keeps the last
  // word on which file is loaded.
  var mtpOwned = false
  for (var d = 0; d < params.length; d++)
    if (params[d].key === "--model-draft") mtpOwned = true
  if (!mtpOwned && mtpActive) {
    if (!buildDesc || backend !== "llamacpp" ||
        supportsFlag(buildDesc, "--model-draft")) {
      args.push("--model-draft", mtp)
      emittedFlags["--model-draft"] = true
    } else if (ignoredFlags.indexOf("--model-draft") === -1) {
      ignoredFlags.push("--model-draft")
    }
  }

  if (buildDesc && backend === "llamacpp") {
    // Parallel, reasoning, threads, MoE, context, batch, cache, temp
    if (!overridden("parallel") && String(T("parallel")).trim() !== "")
      emitFlag(buildDesc, "--parallel", String(T("parallel")).trim(), args)

    if (!overridden("reasoningPreserve")) {
      if (T("reasoningPreserve") === "on") emitFlag(buildDesc, "--reasoning-preserve", "", args)
      else if (T("reasoningPreserve") === "off") emitFlag(buildDesc, "--no-reasoning-preserve", "", args)
    }

    var threadCount = parseInt(T("threads"), 10)
    if (!overridden("threads") && isFinite(threadCount) && threadCount > 0)
      emitFlag(buildDesc, "--threads", String(threadCount), args)

    // MoE flags are mutually exclusive in llama.cpp
    if (!overridden("nCpuMoe") && !overridden("cpuMoe")) {
      var nCpuMoeTrimmed = String(T("nCpuMoe")).trim()
      if (nCpuMoeTrimmed !== "") emitFlag(buildDesc, "--n-cpu-moe", nCpuMoeTrimmed, args)
      else if (T("cpuMoe")) emitFlag(buildDesc, "--cpu-moe", "", args)
    }

    if (!overridden("noRepack") && T("noRepack"))
      emitFlag(buildDesc, "--no-repack", "", args)
    if (!overridden("specType") && T("specType") !== "none")
      emitFlag(buildDesc, "--spec-type", T("specType"), args)

    var ctxSize = parseInt(T("contextSize"), 10)
    if (!overridden("contextSize") && isFinite(ctxSize) && ctxSize > 0)
      emitFlag(buildDesc, "--ctx-size", String(ctxSize), args)
    var batch = parseInt(T("batchSize"), 10)
    if (!overridden("batchSize") && isFinite(batch) && batch > 0)
      emitFlag(buildDesc, "--batch-size", String(batch), args)
    var ubatch = parseInt(T("ubatchSize"), 10)
    if (!overridden("ubatchSize") && isFinite(ubatch) && ubatch > 0)
      emitFlag(buildDesc, "--ubatch-size", String(ubatch), args)
    if (!overridden("cacheRam") && String(T("cacheRam")).trim() !== "")
      emitFlag(buildDesc, "--cache-ram", String(T("cacheRam")).trim(), args)
    if (!overridden("temperature") && String(T("temperature")).trim() !== "")
      emitFlag(buildDesc, "--temp", String(T("temperature")).trim(), args)
    // The model being launched, which is the one named by --model above.
    // This read used to be a bare `model` -- an identifier nothing in scope
    // defines, so it raised a ReferenceError out of buildLlamaArgs the
    // moment the alias row was left on "auto", which is its default. That
    // took the whole direct launch with it: no argv was ever built and
    // Start did nothing at all. Router mode assembles its argv elsewhere,
    // which is the only reason this was survivable.
    var activeAlias = String(T("modelAlias")).trim() ||
                      deriveDefaultAlias(model)
    if (!overridden("alias") && activeAlias !== "")
      emitFlag(buildDesc, "--alias", activeAlias, args)
  }
  // User-added parameters. Appended before the free-form extra args so a
  // hand-written flag still gets the last word on any duplicate.
  //
  // A flag a built-in still emitted is skipped rather than appended twice.
  // The override guards above are what normally prevent that; this stays as
  // the backstop for a flag no ownership entry covers -- an alias a future
  // llama.cpp buildDesc adds, or a settings file from a version that reserved
  // the flag instead of yielding it.
  for (var c = 0; c < params.length; c++) {
    var entry = params[c]
    if (emittedFlags[entry.key]) {
      console.warn("local-ai-server: skipping", entry.key,
                   "-- already set by a built-in control")
      continue
    }
    // A flag this buildDesc's --help does not describe still has to be passed:
    // it may come from an alternate binary, or from a line pasted before the
    // catalogue loaded. Without the stand-in the row rendered and the launch
    // line silently omitted it.
    args = args.concat(customArgv(entry))
  }

  var extraPieces = splitExtraArgs(T("extraArgs"))
  for (var p = 0; p < extraPieces.length; p++) args = args.concat(parseArgs(extraPieces[p]))

  return { args: args, ignoredFlags: ignoredFlags, emittedFlags: emittedFlags }
}

if (typeof module !== "undefined") {
  module.exports = { build: build }
}
