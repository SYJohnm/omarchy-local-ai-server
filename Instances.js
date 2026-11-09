"use strict"

// Multi-instance planning and state reduction.
//
// `instanceCount` was a manifest setting with nothing behind it: the Server
// page showed one hardcoded "Instance 0" whatever the number said, and the
// extra servers it promised were never launched. This module is the pure half
// of making it real -- identity, port allocation, liveness and the labels --
// so the parts that decide what the panel shows are testable under Node and
// the QML side only has to execute the plan.
//
// An instance is an index. Everything else about it is derived:
//
//   index 0            the server the panel has always managed. Its unit and
//                      process marker keep their un-suffixed names, so a
//                      server launched by an older version is still adopted.
//   index n > 0        unit "<base>-<n>", marker "<base>-<n>-proc", port
//                      portBase + n.
//
// Only llama.cpp can run as several instances. ollama is a single daemon
// configured by environment (a second one on another port would serve the same
// store with the same settings), System One serves decision models on its own
// port, and a router already answers for every model from one process -- so
// each of those is clamped to one, rather than offering a number that would
// launch servers nothing can use.

var MAX_INSTANCES = 8

// Ports are allocated portBase + index, so the window has to fit under the
// 16-bit limit with room for the whole count.
var MAX_PORT = 65535

/**
 * The instance count actually supported for a given mode, clamped to
 * [1, MAX_INSTANCES]. Anything unparseable reads as 1 rather than 0: a count
 * of zero would mean "the Start button has nowhere to launch".
 *
 * @param {*} value         raw setting value
 * @param {string} backendId
 * @param {boolean} [routerMode]
 * @returns {number}
 */
function clampCount(value, backendId, routerMode) {
  if (!supportsMultiple(backendId, routerMode)) return 1
  var n = parseInt(value, 10)
  if (!isFinite(n) || n < 1) return 1
  return Math.min(MAX_INSTANCES, n)
}

function supportsMultiple(backendId, routerMode) {
  return String(backendId) === "llamacpp" && !routerMode
}

/**
 * Port for an index, or 0 when portBase + index does not fit in a port.
 * Returning 0 rather than a wrapped number is deliberate: the caller skips an
 * instance it cannot address instead of launching one on a nonsense port.
 */
function portFor(portBase, index) {
  var base = parseInt(portBase, 10)
  var n = parseInt(index, 10)
  if (!isFinite(base) || base < 1 || !isFinite(n) || n < 0) return 0
  var port = base + n
  if (port < 1 || port > MAX_PORT) return 0
  return port
}

/**
 * Identity of every instance the current settings call for.
 *
 * @param {object} input
 * @param {string} input.pluginId
 * @param {string} input.backendId
 * @param {string|number} input.portBase
 * @param {number} input.count
 * @param {boolean} [input.routerMode]
 * @param {function} input.unitName    Backends.unitName
 * @param {function} input.procMarker  Backends.procMarker
 * @returns {Array<{index:number, port:number, unitName:string, procMarker:string, primary:boolean}>}
 */
function plan(input) {
  var cfg = input || {}
  var count = clampCount(cfg.count, cfg.backendId, cfg.routerMode)
  var unitName = typeof cfg.unitName === "function" ? cfg.unitName : function() { return "" }
  var procMarker = typeof cfg.procMarker === "function" ? cfg.procMarker : function() { return "" }
  var out = []
  for (var i = 0; i < count; i++) {
    var port = portFor(cfg.portBase, i)
    // Index 0 is the panel's own server; it is listed even if the port is
    // unusable so the page can show why, but a surplus index with no port is
    // simply not offered.
    if (port === 0 && i > 0) break
    out.push({
      index: i,
      port: port,
      unitName: unitName(cfg.pluginId, cfg.backendId, i),
      procMarker: procMarker(cfg.pluginId, cfg.backendId, i),
      primary: i === 0
    })
  }
  return out
}

/**
 * Unit names for the indices a shrunken count no longer covers, up to the
 * cap. Lowering the count while the shell is running destroys those runners,
 * which stop their own servers -- but lowering it between sessions leaves
 * nothing to notice them: no runner is created for an index that is gone, so
 * a server from the previous, larger configuration keeps a port and its share
 * of VRAM with nothing in the panel that mentions it. These are the units to
 * sweep once at startup.
 *
 * Index 0 is never included: it is the primary, which is adopted rather than
 * swept.
 *
 * @param {object} input
 * @param {string} input.pluginId
 * @param {string} input.backendId
 * @param {number} input.count      the current instance count
 * @param {function} input.unitName Backends.unitName
 * @param {number} [input.max]
 * @returns {string[]}
 */
function staleUnits(input) {
  var cfg = input || {}
  var unitName = typeof cfg.unitName === "function" ? cfg.unitName : null
  if (unitName === null) return []
  var from = parseInt(cfg.count, 10)
  if (!isFinite(from) || from < 1) from = 1
  var max = isFinite(cfg.max) && cfg.max > 0 ? cfg.max : MAX_INSTANCES
  var out = []
  for (var i = Math.max(1, from); i < max; i++)
    out.push(unitName(cfg.pluginId, cfg.backendId, i))
  return out
}

// ---- Liveness ----
//
// Every poller used to swallow a failure ("keep the last known state"), and
// the only watch on the unit was started by the launch path alone. A server
// that was adopted and then died -- crashed, OOM-killed, stopped by hand --
// therefore stayed "running, idle" in the panel for as long as the shell ran.
// That is the bug this answers: a failure is evidence, it just is not proof,
// so it takes a few of them in a row.

// One poll in three may legitimately miss: curl's one-second timeout is short,
// and a server that is busy decoding on a loaded machine can be slow to
// answer /health. Three consecutive misses at the poll interval is a server
// that is actually gone.
var FAILURES_BEFORE_GONE = 3

/**
 * What consecutive poll failures mean for an instance believed to be up.
 *
 * "alive"  -- a poll answered.
 * "grace"  -- it did not, but not often enough to call it gone.
 * "gone"   -- it has missed FAILURES_BEFORE_GONE in a row; the caller tears
 *             the instance's state down and reports it stopped.
 *
 * A starting instance is never "gone" on this evidence: it has not answered
 * yet by definition, and the startup timeout is what bounds that wait.
 *
 * @param {object} state
 * @param {boolean} state.running
 * @param {boolean} [state.starting]
 * @param {number}  state.failures   consecutive failed polls
 * @param {number}  [state.threshold]
 * @returns {"alive"|"grace"|"gone"}
 */
function healthVerdict(state) {
  var s = state || {}
  var threshold = isFinite(s.threshold) && s.threshold > 0 ? s.threshold : FAILURES_BEFORE_GONE
  var failures = parseInt(s.failures, 10)
  if (!isFinite(failures) || failures <= 0) return "alive"
  if (!s.running || s.starting) return "grace"
  return failures >= threshold ? "gone" : "grace"
}

// ---- Rate decay ----
//
// tokensPerSec was only ever cleared by a stop or a restart, so after one
// generation the bar and the Server page kept showing that rate for as long as
// the server ran -- a number that described a request finished an hour ago. It
// is held briefly after a generation ends (the final rate is the interesting
// one) and then released, so "idle" means idle.

var RATE_LINGER_MS = 4000

/**
 * The rate to display given how long it has been since the last token.
 *
 * @param {number} rate
 * @param {number} idleForMs  ms since the last decode sample / timing line
 * @param {number} [lingerMs]
 * @returns {number}
 */
function rateAfterIdle(rate, idleForMs, lingerMs) {
  var r = Number(rate)
  if (!isFinite(r) || r <= 0) return 0
  var idle = Number(idleForMs)
  var linger = isFinite(lingerMs) && lingerMs >= 0 ? lingerMs : RATE_LINGER_MS
  if (!isFinite(idle) || idle < 0) return r
  return idle > linger ? 0 : r
}

// ---- Presentation ----

/**
 * The one-word state of an instance, in the order the user needs it: what is
 * happening to it beats what it is doing.
 *
 * @param {object} inst
 * @returns {string}
 */
function stateLabel(inst) {
  var s = inst || {}
  if (s.stopping) return "stopping…"
  if (s.switching) return "restarting…"
  if (s.starting) return "starting…"
  if (!s.running) return s.failed ? "crashed" : "stopped"
  if (s.ppActive) {
    var pct = Math.round(Number(s.ppPercent) || 0) + "%"
    var pp = Number(s.ppTokensPerSec) || 0
    return pp > 0 ? pct + " · " + pp.toFixed(0) + " t/s" : pct
  }
  var tg = Number(s.tokensPerSec) || 0
  if (tg > 0) return tg.toFixed(1) + " t/s"
  return "idle"
}

/**
 * Who is in charge of an instance, which is what decides whether Unload can
 * do anything. "external" is a server on that port this widget did not start
 * and cannot stop.
 */
function ownerLabel(inst) {
  var s = inst || {}
  if (!s.running && !s.starting) return ""
  if (s.adopted && !s.ownsUnit) return "external"
  if (s.adopted) return "adopted"
  return "this widget"
}

/**
 * Total generation rate across the instances that are actually producing
 * tokens. The bar shows one number for the whole widget, and with several
 * servers decoding at once the sum is what the machine is doing.
 */
function aggregateRate(list) {
  var items = list || []
  var total = 0
  for (var i = 0; i < items.length; i++) {
    var inst = items[i] || {}
    if (!inst.running) continue
    var r = Number(inst.tokensPerSec)
    if (isFinite(r) && r > 0) total += r
  }
  return total
}

/**
 * The instance whose prompt ingestion the bar should show while no generation
 * is running, or null. Ingestion is a single-prompt event, so the furthest
 * along is the one worth reporting rather than a sum.
 */
function leadingPrompt(list) {
  var items = list || []
  var best = null
  for (var i = 0; i < items.length; i++) {
    var inst = items[i] || {}
    if (!inst.running || !inst.ppActive) continue
    if (best === null || (Number(inst.ppPercent) || 0) > (Number(best.ppPercent) || 0)) best = inst
  }
  return best
}

/** How many instances are up, for the "2/3 running" summary. */
function runningCount(list) {
  var items = list || []
  var n = 0
  for (var i = 0; i < items.length; i++) if (items[i] && items[i].running) n++
  return n
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_INSTANCES: MAX_INSTANCES,
    FAILURES_BEFORE_GONE: FAILURES_BEFORE_GONE,
    RATE_LINGER_MS: RATE_LINGER_MS,
    supportsMultiple: supportsMultiple,
    clampCount: clampCount,
    portFor: portFor,
    plan: plan,
    staleUnits: staleUnits,
    healthVerdict: healthVerdict,
    rateAfterIdle: rateAfterIdle,
    stateLabel: stateLabel,
    ownerLabel: ownerLabel,
    aggregateRate: aggregateRate,
    leadingPrompt: leadingPrompt,
    runningCount: runningCount
  }
}
