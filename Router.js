"use strict"

// Build the relay configuration for the native llama-server router.
//
// One relay process owns the public port and starts/stops one llama-server
// router per build. This module is pure: it turns the widget's catalogue and
// the selected model's tuned argv into the JSON relay.py consumes, and the
// systemd unit that runs it. The relay writes the per-build INI presets; the
// widget only writes this one JSON file.

// Flags the router owns. Presets must not set them, and the selected model's
// argv already carries some of them from the direct-launch path.
const ROUTER_FLAGS = new Set([
  "model", "m", "host", "port", "alias", "a", "metrics",
  "slot-save-path", "log-colors", "models-dir", "models-max",
  "models-memory-margin", "models-preset", "models-autoload",
  "no-models-autoload", "api-key", "api-key-file",
  "ssl-key-file", "ssl-cert-file"
])

function systemdQuote(value) {
  return '"' + String(value == null ? "" : value)
    .replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/%/g, "%%") + '"'
}

function iniValue(value) {
  if (value === true) return "true"
  if (value === false) return "false"
  if (value === null || value === undefined) return ""
  return String(value).replace(/\r?\n/g, " ")
}

// Turn one argv into INI-key/value pairs. The launch builder emits flags and
// their values as separate tokens, so a value is identified by the next token:
// anything that is not a flag, plus negative numbers (`-1` for GPU layers).
function argvToParams(argv) {
  const params = {}
  const list = argv || []
  let i = 0
  while (i < list.length) {
    let token = String(list[i])
    if (!token.startsWith("-")) { i++; continue }
    let key
    let value
    if (token.startsWith("--") && token.includes("=")) {
      const at = token.indexOf("=")
      key = token.slice(2, at)
      value = token.slice(at + 1)
      i++
    } else {
      key = token.replace(/^-+/, "")
      const next = list[i + 1]
      const takesValue = next !== undefined &&
        (!String(next).startsWith("-") || /^-?\d+(?:\.\d+)?$/.test(String(next)))
      value = takesValue ? next : true
      i += takesValue ? 2 : 1
    }
    if (key === "" || ROUTER_FLAGS.has(key)) continue
    params[key] = value
  }
  return params
}

/**
 * @param {object} opts
 * @param {string} opts.host
 * @param {string|number} opts.port
 * @param {string} opts.stateDir
 * @param {string} opts.defaultModel
 * @param {Array<{path:string, build:string, args?:string[]}>} opts.models
 * @param {Record<string,string>} [opts.env]
 * @param {number} [opts.internalPortBase]
 * @returns {{config:object, modelCount:number, buildCount:number}}
 */
function build(opts) {
  opts = opts || {}
  const models = (opts.models || []).filter(m => m && m.path && m.build)
  if (models.length === 0) throw new Error("router: no model has a usable build")

  const routers = {}
  const routes = []
  let nextPort = Number(opts.internalPortBase || 5800)
  for (const model of models) {
    if (!routers[model.build]) {
      routers[model.build] = {
        binary: model.build,
        port: nextPort++,
        args: ["--models-max", "2", "--models-memory-margin", "512"]
      }
      if (opts.env && Object.keys(opts.env).length > 0) routers[model.build].env = opts.env
    }
    routes.push({
      id: model.path,
      path: model.path,
      build: model.build,
      aliases: model.aliases || [],
      params: argvToParams(model.args || [])
    })
  }

  const config = {
    listen: { host: opts.host || "127.0.0.1", port: Number(opts.port || 8080) },
    state_dir: opts.stateDir,
    slot_dir: opts.slotDir || (String(opts.stateDir || "").replace(/\/+$/, "") + "/slots"),
    prompt_cache: opts.promptCache !== false,
    default_model: opts.defaultModel || models[0].path,
    start_timeout_s: 30,
    stop_timeout_s: 10,
    drain_timeout_s: 60,
    routers,
    models: routes
  }
  return { config, modelCount: routes.length, buildCount: Object.keys(routers).length }
}

function unitFile(opts) {
  opts = opts || {}
  const exec = [
    systemdQuote(opts.python || "python3"),
    systemdQuote(opts.relayPath),
    "--config", systemdQuote(opts.configPath),
    "--state-dir", systemdQuote(opts.stateDir)
  ]
  return [
    "[Unit]",
    "Description=Local AI Server router relay",
    "After=network.target",
    "",
    "[Service]",
    "Type=simple",
    "UMask=0077",
    // SIGTERM reaches the relay only; it still has live routers to save the
    // prompt cache into. After TimeoutStopSec systemd kills the whole group.
    "KillMode=mixed",
    "TimeoutStopSec=120",
    "Restart=on-failure",
    "RestartSec=5",
    "WorkingDirectory=" + (String(opts.workDir || "/").replace(/\/+$/, "") || "/"),
    "ExecStart=" + exec.join(" "),
    "",
    "[Install]",
    "WantedBy=default.target",
    ""
  ].join("\n")
}

module.exports = { ROUTER_FLAGS, systemdQuote, iniValue, argvToParams, build, unitFile }
