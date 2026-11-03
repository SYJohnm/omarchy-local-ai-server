"use strict"

// Pure reconciliation plan for the plugin's systemd user unit.
//
// The widget knows what it wants (server up/down, enabled at login) and what
// it can observe (unit load/active state, unit file, config hash, endpoint
// health). This module turns the two into an ordered list of actions; it never
// runs anything, so the same plan is testable and the QML side stays small.
//
// Verbs are systemd-shaped on purpose: they map one-to-one to commands the
// caller already knows how to run.
//
//   write-unit     rewrite the unit file from the current launch spec
//   daemon-reload  systemctl --user daemon-reload (after write-unit)
//   reset-failed   systemctl --user reset-failed <unit>
//   start/stop/restart
//   enable/disable  persistent units only
//
// `activating` is treated as "already starting": the planner does not stack a
// start or a restart on top of it, because that is how a slow model load turns
// into a restart loop.

const ACTIVE_STATES = new Set(["active", "activating", "reloading"])
const STOPPED_STATES = new Set(["inactive", "failed", "deactivating"])

/**
 * @param {object} input
 * @param {{running:boolean, enabled?:boolean}} input.desired
 * @param {object} input.unit
 * @param {boolean} [input.unit.persistent]  unit can be enabled/disabled
 * @param {boolean} [input.unit.exists]
 * @param {string}  [input.unit.loadState]   systemd LoadState (`loaded`, `not-found`)
 * @param {string}  [input.unit.activeState] active|activating|reloading|deactivating|inactive|failed
 * @param {string}  [input.unit.enabled]     enabled|disabled|static|masked
 * @param {boolean} [input.unit.configMatches]  unit file matches the launch spec
 * @param {{responsive?:boolean, healthy?:boolean}} [input.endpoint]
 * @returns {{actions: Array<{verb:string, reason:string}>, healthy:boolean, summary:string}}
 */
function plan(input) {
  const desired = (input && input.desired) || {}
  const unit = (input && input.unit) || {}
  const endpoint = (input && input.endpoint) || {}
  const actions = []
  const push = (verb, reason) => actions.push({ verb, reason })

  const exists = unit.exists !== undefined ? !!unit.exists : unit.loadState !== "not-found"
  const configMatches = unit.configMatches !== false
  const state = String(unit.activeState || "unknown")
  const active = ACTIVE_STATES.has(state)
  const activating = state === "activating" || state === "reloading"
  const failed = state === "failed"
  const healthy = !!(endpoint.responsive && endpoint.healthy)

  const rewrite = !exists || !configMatches
  if (rewrite) {
    push("write-unit", exists ? "unit file does not match the launch spec" : "unit file is missing")
    push("daemon-reload", "unit file changed")
  }
  if (failed) push("reset-failed", "previous start failed")

  if (desired.running) {
    if (activating) {
      // Already on its way up; wait for health instead of restarting.
    } else if (active && (!healthy || !configMatches)) {
      push("restart", !configMatches ? "unit config changed" : "unit is active but the endpoint is unhealthy")
    } else if (!active) {
      push("start", failed ? "unit failed and must be restarted" : "unit is not running")
    }
  } else {
    if (active || (unit.persistent && state === "deactivating")) {
      push("stop", "unit should be stopped")
    }
  }

  if (unit.persistent && desired.enabled !== undefined && unit.enabled !== undefined) {
    const isEnabled = unit.enabled === "enabled"
    if (desired.enabled && !isEnabled) push("enable", "unit should start at login")
    if (!desired.enabled && isEnabled) push("disable", "unit should not start at login")
  }

  const willRun = desired.running && (active || actions.some(a => a.verb === "start" || a.verb === "restart"))
  const disruptive = actions.some(a =>
    a.verb === "start" || a.verb === "stop" || a.verb === "restart" ||
    a.verb === "write-unit" || a.verb === "daemon-reload")
  // Enabling/disabling does not change whether the current process is healthy.
  const settled = desired.running
    ? (healthy && !activating && !disruptive)
    : !active

  let summary
  if (actions.length === 0) summary = desired.running ? "running and healthy" : "stopped"
  else summary = actions.map(a => a.verb).join(", ")

  return { actions, healthy: settled, summary, willRun, active, failed, exists }
}

module.exports = { plan }
