"use strict"

// Spike: render llama-server router preset INI files from a model catalog.
// Not wired into the widget yet. The production version will reuse the
// tuning/flag logic in Params.js and Backends.js; this module only proves the
// INI surface and the reserved-key rules.

// Keys the router owns and overwrites (or rejects) in a preset section. A
// preset must not try to set them; host/port/alias are rewritten per child,
// models-* and connect are router-level.
const RESERVED = new Set([
  "host", "port", "alias",
  "models-dir", "models-max", "models-memory-margin", "models-preset",
  "models-autoload", "no-models-autoload",
  "api-key", "api-key-file",
  "ssl-key-file", "ssl-cert-file",
  "connect", "connect-code",
  "log-colors"
])

// " --ctx-size" -> "ctx-size"; leaves short keys ("c", "ngl") alone.
function normalizeKey(key) {
  return String(key == null ? "" : key).replace(/^-+/, "").trim()
}

// INI values are rest-of-line. Keep them on one line and let llama.cpp parse
// the type; booleans are the flag spelling the preset parser expects.
function iniValue(value) {
  if (value === true) return "true"
  if (value === false) return "false"
  if (value === null || value === undefined) return ""
  return String(value).replace(/\r?\n/g, " ")
}

// A section name is the model id clients send. The router sets --alias to it,
// so the path can stay the id and existing path-based clients keep working.
function sectionId(id) {
  const value = String(id == null ? "" : id)
  if (value === "" || /[\r\n\]]/.test(value)) {
    throw new Error("preset section id must be non-empty and contain no newline or ']': " + JSON.stringify(value))
  }
  return value
}

/**
 * Render one build's preset file.
 *
 * @param {object} opts
 * @param {object} [opts.defaults] shared `[*]` parameters (CLI keys or names)
 * @param {Array<{id:string,path:string,mmproj?:string,draft?:string,params?:object}>} opts.models
 * @returns {string} INI text, newline-terminated
 */
function renderPreset(opts) {
  opts = opts || {}
  const lines = ["version = 1", ""]

  const defaultLines = []
  const defaults = opts.defaults || {}
  for (const rawKey of Object.keys(defaults)) {
    const key = normalizeKey(rawKey)
    const value = defaults[rawKey]
    if (RESERVED.has(key) || value === undefined) continue
    defaultLines.push(key + " = " + iniValue(value))
  }
  if (defaultLines.length > 0) {
    lines.push("[*]")
    lines.push.apply(lines, defaultLines)
    lines.push("")
  }

  const models = opts.models || []
  for (let i = 0; i < models.length; i++) {
    const model = models[i]
    const id = sectionId(model.id === undefined ? model.path : model.id)
    const seen = new Set()
    lines.push("[" + id + "]")

    const push = function (rawKey, value) {
      const key = normalizeKey(rawKey)
      if (RESERVED.has(key) || seen.has(key) || value === undefined) return
      seen.add(key)
      lines.push(key + " = " + iniValue(value))
    }

    push("model", model.path === undefined ? id : model.path)
    if (model.mmproj) push("mmproj", model.mmproj)
    if (model.draft) push("model-draft", model.draft)

    const params = model.params || {}
    for (const rawKey of Object.keys(params)) push(rawKey, params[rawKey])
    lines.push("")
  }

  return lines.join("\n")
}

/**
 * Group a flat catalog by the build that must serve each model.
 * @param {Array<{build?:string}>} models
 * @returns {Map<string, Array>} build -> models, insertion order preserved
 */
function splitByBuild(models) {
  const out = new Map()
  const list = models || []
  for (let i = 0; i < list.length; i++) {
    const build = list[i].build || "default"
    if (!out.has(build)) out.set(build, [])
    out.get(build).push(list[i])
  }
  return out
}

module.exports = { RESERVED, normalizeKey, iniValue, sectionId, renderPreset, splitByBuild }
