// switchState is "draining" while a restart waits for running requests to
// finish before the server is stopped; anything else reads as a plain run state.
function statusLabel(running, starting, startingElapsed, switchState, inflight) {
  if (starting) return "Starting… " + (startingElapsed || 0) + "s"
  if (running && switchState === "draining")
    return "Restarting · waiting for " + (inflight || 0) + " request" + (inflight === 1 ? "" : "s")
  return running ? "Running" : "Stopped"
}

// What pressing Stop should do. Split out of Panel.qml so the branches are
// testable. "blocked" means the server is running but is not ours to stop (an
// adopted root-owned service), which must not be reported as stopped.
function stopPlan(running, starting, canStop, savesSlots, model, serverRunning) {
  if (running && !canStop) return "blocked"
  if (running && savesSlots && model !== "") return "save"
  if (starting || serverRunning || running) return "stop"
  return "none"
}

// Parses a llama.cpp timing line into {kind: "pp"|"tg", tps}.
//
// Both backends emit this identical format, because ollama embeds llama.cpp
// and re-exports its server logs verbatim:
//   "slot print_timing: id  0 | task 0 | prompt eval time = 521.34 ms / 11 tokens (  47.39 ms per token,  21.10 tokens per second)"
//   "slot print_timing: id  0 | task 0 |        eval time = 941.26 ms /  8 tokens ( 134.47 ms per token,   7.44 tokens per second)"
// so one parser serves llama.cpp and ollama alike.
//
// The "prompt " prefix is what distinguishes prompt-processing throughput
// from generation throughput. It is matched inline rather than anchored to
// the line start: llama.cpp prefixes these lines with "slot print_timing:
// id N | task N |", so an anchored test would miss the prompt marker and
// silently report pp numbers as tg. Leftmost-match semantics guarantee the
// optional group binds when the word is present.
//
// "total time = ... ms / N tokens" carries no "tokens per second" clause and
// therefore never matches.
// Parse timing lines. Supports optional slot id extraction when present:
//   "slot print_timing: id  0 | task 0 | prompt eval time = ..."
//   "slot print_timing: id  1 | task 2 | eval time = ..."
// Bare lines without slot info return slot: null.
function parseTimingLine(line) {
  var text = String(line || "")
  var match = text.match(/(?:slot print_timing:\s*id\s*(\d+)\s*\|\s*task\s*\d+\s*\|\s*)?(prompt\s+)?eval time\s*=\s*[\d.]+ ms\s*\/\s*\d+ tokens\s*\(\s*[\d.]+ ms per token,\s*([\d.]+) tokens per second\)/i)
  if (!match) return null
  var slot = match[1] !== undefined ? parseInt(match[1], 10) : null
  var isPrompt = !!match[2]
  var value = parseFloat(match[3])
  if (!isFinite(value)) return null
  var res = { kind: isPrompt ? "pp" : "tg", tps: value }
  if (slot !== null && isFinite(slot)) res.slot = slot
  return res
}

// Live prompt-processing progress, logged per batch while the prompt is still
// being ingested:
//   "slot print_timing: id  0 | task 118 | prompt processing, n_tokens = 14336, progress = 0.46, t = 280.52 s / 51.11 tokens per second"
//
// Supports optional slot id extraction when present.
// Returns {kind: "pp_progress", tps, percent, [slot]} or null.
function parsePromptProgressLine(line) {
  var text = String(line || "")
  var match = text.match(/(?:slot print_timing:\s*id\s*(\d+)\s*\|\s*task\s*\d+\s*\|\s*)?prompt processing,\s*n_tokens\s*=\s*\d+,\s*progress\s*=\s*([\d.]+),\s*t\s*=\s*[\d.]+ s\s*\/\s*([\d.]+) tokens per second/i)
  if (!match) return null
  var slot = match[1] !== undefined ? parseInt(match[1], 10) : null
  var percent = parseFloat(match[2]) * 100
  var tps = parseFloat(match[3])
  if (!isFinite(percent) || !isFinite(tps)) return null
  var res = { kind: "pp_progress", tps: tps, percent: Math.max(0, Math.min(100, percent)) }
  if (slot !== null && isFinite(slot)) res.slot = slot
  return res
}

// Generation-speed-only view of parseTimingLine, for callers that only care
// about tg and want the previous number-or-null shape.
function parseTokensPerSecond(line) {
  var parsed = parseTimingLine(line)
  return parsed && parsed.kind === "tg" ? parsed.tps : null
}

// Live-progress text for the current slot state: a pp% (plus the prompt's
// own processing speed) while the prompt is still being ingested, tok/s
// once generation is actually producing tokens.
function metricText(showMetric, ppActive, ppPercent, tokensPerSec, ppTokensPerSec) {
  if (!showMetric) return ""
  if (ppActive) {
    // Percent first: during ingestion the question is how far along it is,
    // and its rate is the second half of the same answer. The "pp" label is
    // gone -- a percentage next to a rate is only ever the prompt, and the
    // two words cost bar width on the one state that already shows the most
    // text.
    var pct = ppPercent.toFixed(0) + "%"
    return ppTokensPerSec > 0 ? pct + " - " + ppTokensPerSec.toFixed(0) + " t/s" : pct
  }
  if (tokensPerSec > 0) return tokensPerSec.toFixed(1) + " t/s"
  return ""
}

// The mark is a Nerd Font server glyph (nf-fa-server, U+F233): it inherits the
// bar's font and colour so the widget stays monochrome, and WidgetButton gives
// a single PUA glyph the bar's fixed icon slot, so the idle mark lines up with
// every other bar icon instead of being two letters of body text. Status
// (stopped / up-idle / running) is carried by the dot overlaid on it.
var BAR_ICON = ""

// The mark identifies the widget; a live number identifies it just as well
// and says more, so the two never share the slot. The glyph shows while the
// server is idle, stopped, or has its metrics hidden; pp and tg replace it.
function barText(icon, running, showMetric, ppActive, ppPercent, tokensPerSec, ppTokensPerSec) {
  if (!running) return icon
  var m = metricText(showMetric, ppActive, ppPercent, tokensPerSec, ppTokensPerSec)
  return m ? m : icon
}

// Marks the bar text with the restart state, so a pending or waiting restart
// is visible without opening the panel:
//   draining -- "⇄" plus the still-running request's live number, if any
//   pending  -- the usual text plus " •": the page differs from what runs
function barSwitchText(base, switchState, pending) {
  if (switchState === "draining") return base && /\d/.test(base) ? "⇄ " + base : "⇄"
  return pending ? base + " •" : base
}


// Parses the environment assignment string stored in `extraEnv`:
// "NAME=value NAME2='with spaces'" into [{name, value}], plus the tokens that
// are not assignments. Names follow the shell's rule, so nothing reaching the
// launch line can be anything but an assignment; values are shell-quoted by
// the caller. Values may be bare, single-quoted or double-quoted; double
// quotes understand backslash escapes so a value can contain spaces, quotes
// or a literal backslash. The tokenizer is deliberately small: this is a
// settings field, not a shell.
// What a shell accepts as a variable name. The launch script puts names in
// unquoted, so anything else is dropped rather than trusted -- and the rule
// lives here alone, because a second copy is one that can be loosened without
// the first one noticing.
function isEnvName(name) {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(String(name))
}

function parseEnvAssignments(text) {
  var env = [], invalid = []
  var src = String(text || "")
  var i = 0

  function isSpace(ch) {
    return ch === " " || ch === "\t" || ch === "\n" || ch === "\r"
  }
  function push(name, value) {
    for (var j = 0; j < env.length; j++)
      if (env[j].name === name) { env[j].value = value; return }
    env.push({ name: name, value: value })
  }

  while (i < src.length) {
    while (i < src.length && isSpace(src[i])) i++
    if (i >= src.length) break
    var start = i
    while (i < src.length && !isSpace(src[i]) && src[i] !== "=") i++
    var name = src.slice(start, i)
    if (src[i] !== "=") {
      while (i < src.length && !isSpace(src[i])) i++
      invalid.push(src.slice(start, i))
      continue
    }
    i++
    var value = ""
    if (src[i] === '"' || src[i] === "'") {
      var quote = src[i++]
      var closed = false
      while (i < src.length) {
        if (src[i] === "\\" && quote === '"' && i + 1 < src.length) {
          value += src[i + 1]
          i += 2
          continue
        }
        if (src[i] === quote) { i++; closed = true; break }
        value += src[i++]
      }
      if (!closed) { invalid.push(src.slice(start, i)); continue }
    } else {
      var vstart = i
      while (i < src.length && !isSpace(src[i])) i++
      value = src.slice(vstart, i)
    }
    if (!isEnvName(name)) {
      invalid.push(src.slice(start, i))
      continue
    }
    push(name, value)
  }
  return { env: env, invalid: invalid }
}

// Canonical inverse of parseEnvAssignments. Any value that would not survive a
// bare token is double-quoted, with backslashes and quotes escaped.
function formatEnvAssignments(env) {
  var parts = []
  for (var i = 0; i < (env || []).length; i++) {
    var name = String(env[i].name || "")
    if (!isEnvName(name)) continue
    var value = String(env[i].value == null ? "" : env[i].value)
    if (value !== "" && !/[\s"'\\]/.test(value)) parts.push(name + "=" + value)
    else parts.push(name + '="' + value.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"')
  }
  return parts.join(" ")
}

// ---- Log triage ----

// systemd's own unit chatter. It reports *that* a unit failed, never why.
function isSystemdNoise(line) {
  var text = String(line || "")
  return /Failed with result|Main process exited|Consumed .* CPU time|Scheduled restart|^Started |^Stopping |^Stopped |Deactivated successfully/i.test(text) ||
         /^[A-Za-z0-9_.-]+\.service:/.test(text)
}

// systemd-coredump's backtrace, written into the same journal when a server
// aborts. Its frames contain words like "abort" and "assert" and arrive last,
// so without excluding them they shadow the diagnostic that actually explains
// the crash -- which is logged well before the dump.
function isCoredumpNoise(line) {
  var text = String(line || "")
  return /^#\d+\s/.test(text) ||
         /^(Stack trace of|ELF object|Module |Found module|Metadata for|Storing coredump|Coredump|Process \d+ \(|Refusing to process|GNU gdb)/i.test(text) ||
         /^\s*0x[0-9a-f]+/i.test(text)
}

// Picks the line worth showing when a server dies.
//
// Scans newest-first for the application's own error, skipping coredump
// frames and systemd's summary. Falls back to the last real output, and only
// then to systemd's message, so something useful is always reported.
function pickErrorLine(lines, lastLine) {
  var list = lines || []
  var fallback = ""
  for (var i = list.length - 1; i >= 0; i--) {
    var line = String(list[i]).trim()
    if (line === "") continue
    if (isCoredumpNoise(line)) continue
    if (isSystemdNoise(line)) {
      if (fallback === "") fallback = line
      continue
    }
    if (/error|failed|assert|abort|cannot|unable|unsupported|no such/i.test(line)) return line
    if (fallback === "" || isSystemdNoise(fallback)) fallback = line
  }
  return fallback !== "" ? fallback : String(lastLine || "")
}

// ---- Model tree / detection ----

function dirName(path) {
  var idx = String(path).lastIndexOf("/")
  return idx >= 0 ? path.slice(0, idx) : ""
}

// Directory paths from rootDir down to (but not including) `path` itself
// -- i.e. every ancestor directory that must stay expanded for `path` to
// be reachable in the flattened tree.
function ancestorDirs(path, rootDir) {
  var chain = []
  var p = dirName(path)
  while (p && p !== rootDir && p.length > rootDir.length) {
    chain.unshift(p)
    p = dirName(p)
  }
  return chain
}

/**
 * A path cut in the middle to fit, rather than at the end.
 *
 * Both ends of a path carry the meaning -- which tree it is in, and which
 * file it is -- while the middle is the part that repeats between builds.
 * Text.ElideRight would cut off "llama-server", the half that says what the
 * thing is, and leave the "/home/sxy/" that every row shares.
 *
 * @param {string} path
 * @param {number} [max] characters, including the ellipsis
 * @returns {string}
 */
function shortenPath(path, max) {
  var s = String(path === undefined || path === null ? "" : path)
  var limit = parseInt(max, 10)
  if (!isFinite(limit) || limit < 8) limit = 56
  if (s.length <= limit) return s
  // The tail gets the odd character: the filename is what is being read.
  var keep = limit - 1
  var head = Math.floor(keep / 2)
  return s.slice(0, head) + "…" + s.slice(s.length - (keep - head))
}

function baseName(path) {
  var idx = String(path).lastIndexOf("/")
  return idx >= 0 ? path.slice(idx + 1) : path
}

function isMmprojName(name) {
  return /mmproj/i.test(name)
}

// An external MTP draft sits beside the model it accelerates, the way a
// projector does ("...-FastMTP-32K.gguf", "mtp-....gguf"). It is never a
// model itself: launched on its own it is a draft-only file that cannot
// serve a chat.
function isMtpName(name) {
  return /mtp/i.test(name)
}

// Parses `find DIR \( -type d -printf "D\t%p\n" \) -o \( -type f
// -iname '*.gguf' -printf "F\t%p\n" \)` output into directory and file
// path lists. Files include mmproj and MTP siblings -- those are filtered
// out of the model list by the caller but still used to mark the model.
function parseFindOutput(raw) {
  var dirs = []
  var files = []
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var tab = line.indexOf("\t")
    if (tab < 0) continue
    var kind = line.slice(0, tab)
    var path = line.slice(tab + 1).trim()
    if (!path) continue
    if (kind === "D") dirs.push(path)
    else if (kind === "F") files.push(path)
  }
  return { dirs: dirs, files: files }
}

// Splits scanned GGUF paths into the files that are models and the companions
// that are not. A projector (`*mmproj*`) and an external MTP draft (`*mtp*`)
// both live beside the model they serve: they are mapped by directory so the
// launch path can pick them up, and kept out of the picker so neither can be
// started as a chat model.
//
// Companions are mapped only in a directory that kept a model: a folder with
// nothing else has nothing for them to accompany.
function classifyModelFiles(paths) {
  var list = paths || []
  var i, path, base, dir

  // Directories that hold an ordinary model. An MTP-named file is a draft only
  // beside one of those: a folder whose only file is named "*mtp*" is showing
  // its model, not a sidecar, and hiding it would hide the folder.
  var plainDirs = {}
  for (i = 0; i < list.length; i++) {
    base = baseName(list[i])
    if (!isMmprojName(base) && !isMtpName(base)) plainDirs[dirName(list[i])] = true
  }

  var models = []
  var visionDirs = {}
  var mtpDirs = {}
  var modelDirs = {}
  for (i = 0; i < list.length; i++) {
    path = list[i]
    base = baseName(path)
    dir = dirName(path)
    if (isMmprojName(base)) continue
    if (isMtpName(base) && plainDirs[dir]) continue
    models.push(path)
    modelDirs[dir] = true
  }
  for (i = 0; i < list.length; i++) {
    path = list[i]
    base = baseName(path)
    dir = dirName(path)
    if (!modelDirs[dir]) continue
    if (isMmprojName(base)) visionDirs[dir] = path
    else if (isMtpName(base) && plainDirs[dir]) mtpDirs[dir] = path
  }
  return { models: models, visionDirs: visionDirs, mtpDirs: mtpDirs }
}

// Best-effort quantization label pulled from the filename, e.g.
// "Qwen3.6-35B-A3B-UD-IQ4_XS.gguf" -> "UD-IQ4_XS".
function quantLabel(filename) {
  var base = String(filename || "").replace(/\.gguf$/i, "")
  var match = base.match(/(?:^|[-_.])((?:UD-)?(?:IQ|Q)\d(?:_[A-Z0-9]+)*|BF16|F16|F32)(?:[-_.]|$)/i)
  return match ? match[1].toUpperCase() : ""
}

// Strips quantization suffixes and extension to identify the base model name.
function baseModelName(filenameOrPath) {
  var base = baseName(String(filenameOrPath || "")).replace(/\.gguf$/i, "")
  return base.replace(/[-_.](?:UD-)?(?:(?:IQ|Q)\d(?:_[A-Z0-9]+)*|BF16|F16|F32)(?:[-_.]|$)/gi, "").trim()
}

// Reads gguf_probe.py's batched JSON output and derives tool-calling /
// thinking support from each model's embedded chat template -- the best
// signal available without actually running the model.
function parseProbeCapabilities(jsonText) {
  var caps = {}
  var data
  try { data = JSON.parse(jsonText || "{}") } catch (e) { return caps }
  for (var path in data) {
    var entry = data[path] || {}
    var template = String(entry["tokenizer.chat_template"] || "").toLowerCase()
    caps[path] = {
      tools: template.indexOf("tool_calls") !== -1 || template.indexOf("<tools>") !== -1,
      thinking: template.indexOf("<think") !== -1 || template.indexOf("reasoning_content") !== -1,
      mtp: !!entry.has_nextn
    }
  }
  return caps
}

// Reads the attention geometry gguf_probe.py extracts from each model's GGUF
// header, keyed by path. Used to size the KV cache: what one token costs is a
// property of the model, not the machine.
//
// Entries missing the geometry keys (an unreadable header, or a probe failure)
// are simply absent, which callers treat as "unknown" rather than zero.
function parseProbeGeometry(jsonText) {
  var out = {}
  var data
  try { data = JSON.parse(jsonText || "{}") } catch (e) { return out }
  for (var path in data) {
    var entry = data[path] || {}
    if (typeof entry.block_count !== "number") continue
    out[path] = {
      block_count: entry.block_count,
      head_count_kv: entry.head_count_kv,
      head_count: entry.head_count,
      key_length: entry.key_length,
      value_length: entry.value_length,
      embedding_length: entry.embedding_length,
      context_length: entry.context_length
    }
  }
  return out
}

// Builds a nested {type:"dir"|"file", path, name, children} tree from a
// flat model-file list, pruning to only the branches that actually lead
// to a model (no empty folders). `visionDirs` is a Set-like object of
// directory paths that contain an mmproj sibling.
function buildModelTree(rootDir, files, capsByPath, visionDirs) {
  var root = { children: [] }

  // Directory nodes are created lazily, keyed by full path, walking from
  // each file up to `rootDir` so intermediate folders exist even if
  // `find` listed them out of order. `rootDir` itself maps to the root
  // node rather than becoming a visible top-level row.
  var byPath = {}
  byPath[rootDir] = root

  function nodeFor(path) {
    if (byPath[path]) return byPath[path]
    var parent = nodeFor(dirName(path))
    var node = {
      type: "dir", path: path, name: baseName(path), children: [],
      quant: "", vision: false, tools: false, thinking: false, mtp: false
    }
    parent.children.push(node)
    byPath[path] = node
    return node
  }

  var sorted = files.slice().sort()
  for (var i = 0; i < sorted.length; i++) {
    var path = sorted[i]
    var parentDir = dirName(path)
    var parent = nodeFor(parentDir)
    var caps = (capsByPath && capsByPath[path]) || {}
    parent.children.push({
      type: "file",
      path: path,
      name: baseName(path),
      quant: quantLabel(baseName(path)),
      vision: !!(visionDirs && visionDirs[parentDir]),
      tools: !!caps.tools,
      thinking: !!caps.thinking,
      mtp: !!caps.mtp
    })
  }

  function sortNode(node) {
    node.children.sort(function(a, b) {
      if (a.type !== b.type) return a.type === "dir" ? -1 : 1
      return a.name.localeCompare(b.name)
    })
    for (var j = 0; j < node.children.length; j++)
      if (node.children[j].type === "dir") sortNode(node.children[j])
  }
  sortNode(root)
  return root.children
}

// Flattens the tree into visible rows only, skipping children of
// collapsed directories. Accordion semantics: `expanded[path] === true`
// is the only thing that counts as expanded (default collapsed), so at
// most one directory chain is ever open at a time -- the caller is
// responsible for clearing any previously expanded path before setting
// a new one.
function flattenTree(nodes, expanded, depth, out) {
  depth = depth || 0
  out = out || []
  for (var i = 0; i < nodes.length; i++) {
    var node = nodes[i]
    out.push({ node: node, depth: depth })
    if (node.type === "dir" && expanded[node.path] === true) {
      flattenTree(node.children, expanded, depth + 1, out)
    }
  }
  return out
}

// Every file node in the tree, regardless of which directories are
// currently expanded -- for logic that needs to know what models exist
// (validating/defaulting selectedModel), as opposed to what's on screen.
function collectFiles(nodes, out) {
  out = out || []
  for (var i = 0; i < nodes.length; i++) {
    var node = nodes[i]
    if (node.type === "file") out.push(node)
    else if (node.type === "dir") collectFiles(node.children, out)
  }
  return out
}

// Splits a free-form "additional arguments" string into argv tokens,
// respecting single/double quotes (e.g. --alias "my model" -x -> ["--alias",
// "my model", "-x"]) so users can pass values containing spaces.
function parseArgs(str) {
  var out = []
  var s = String(str || "")
  var i = 0
  while (i < s.length) {
    while (i < s.length && /\s/.test(s[i])) i++
    if (i >= s.length) break
    var quote = null
    var tok = ""
    while (i < s.length) {
      var c = s[i]
      if (quote) {
        if (c === quote) { quote = null; i++; continue }
        tok += c; i++; continue
      }
      if (c === '"' || c === "'") { quote = c; i++; continue }
      if (/\s/.test(c)) break
      tok += c; i++
    }
    out.push(tok)
  }
  return out
}

// Recommended cache-type-v for a given cache-type-k, when k is a TurboQuant
// tier. V one tier more aggressive than K is the one real-world-validated
// pairing -- turbo4 K / turbo3 V (both bare, non-tcq) on Qwen3.6-35B-A3B --
// extended by degrading one step within the same family (bare vs _tcq)
// since no further data point exists yet. vbr and turbo8 pair with
// themselves -- vbr already manages both sides dynamically, and turbo8 is
// the ladder's top (nothing more conservative to pair it with). No bare
// turbo1 exists, so turbo2 bottoms out at turbo1_tcq.
var turboVForK = {
  vbr: "vbr",
  turbo8: "turbo8",
  turbo4: "turbo3",
  turbo3: "turbo2",
  turbo2: "turbo1_tcq",
  turbo3_tcq: "turbo2_tcq",
  turbo2_tcq: "turbo1_tcq",
  turbo1_tcq: "turbo1_tcq"
}

function recommendedCacheTypeV(cacheTypeK) {
  return turboVForK[String(cacheTypeK || "").trim()] || null
}

// True for any --cache-type value that only the TurboQuant-fork binary
// understands (vbr and the fixed turboN_* tiers). Stock llama-server would
// reject these, so launchServerProcess() uses this to pick the binary.
function isTurboQuantCacheType(v) {
  return /^(vbr|turbo\d(_tcq)?)$/i.test(String(v || "").trim())
}

// Extra args are stored/edited as one semicolon-separated string so a
// multi-token flag ("--np 1") can sit in its own list entry without needing
// shell-quote escaping. Each piece is still shell-word-split by parseArgs
// when the server actually launches.
function splitExtraArgs(str) {
  return String(str || "")
    .split(";")
    .map(function(s) { return s.trim() })
    .filter(function(s) { return s !== "" })
}

// Chunks a list of tuning rows into sub-pages.
//
// Each entry carries a weight, and a row is never split across a page
// boundary: the vision projector's path field belongs with the mode control
// that reveals it, so that row weighs two and moves as one.
//
// `firstPageReserved` is room the first page owes to something that is not a
// row -- the note naming arguments that could not be split.
//
// A page always comes back, even for an empty list: the section renders the
// current page, and there is no such thing as no page to be on.
function paginateRows(rows, capacity, firstPageReserved) {
  var list = rows || []
  var perPage = Math.max(1, capacity || 1)
  var reserved = Math.max(0, firstPageReserved || 0)
  var pages = []
  var current = []
  var used = 0

  for (var i = 0; i < list.length; i++) {
    var weight = Math.max(1, list[i].weight || 1)
    var room = perPage - (pages.length === 0 ? reserved : 0)
    // `used > 0` is what keeps a row heavier than a whole page from looping:
    // it lands on a page of its own rather than being deferred forever.
    if (used > 0 && used + weight > room) {
      pages.push(current)
      current = []
      used = 0
    }
    current.push(list[i])
    used += weight
  }
  if (current.length > 0 || pages.length === 0) pages.push(current)
  return pages
}

// ---- Prompt-cache housekeeping ----
//
// Slot files are "<prefix>.slot<N>.bin". A cache whose model has been deleted
// or moved is never reclaimed by anything else, and a slot is the size of a
// context, so a library churned over a few months leaves gigabytes behind.

// The prefix a slot file belongs to, or "" when the name is not a slot file.
// Anything unrecognised returns "" so the sweep leaves it alone.
function slotFilePrefix(name) {
  var m = /^(.+)\.slot\d+\.bin$/.exec(String(name || ""))
  return m ? m[1] : ""
}

// Parses "<size>\t<name>" lines (find -printf '%s\t%f\n') into {name, size}.
function parseSlotListing(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "") continue
    var tab = line.indexOf("\t")
    if (tab <= 0) continue
    var size = parseInt(line.slice(0, tab), 10)
    var name = line.slice(tab + 1)
    // A name with a path separator did not come from this flat listing.
    if (!isFinite(size) || name === "" || name.indexOf("/") !== -1) continue
    out.push({ name: name, size: size })
  }
  return out
}

// The slot files no model backs any more. `keep` holds every prefix still
// claimed by a known model, in both the hashed and the pre-hash spelling.
function slotOrphans(files, keep) {
  var list = files || []
  var keepList = keep || []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var prefix = slotFilePrefix(list[i] && list[i].name)
    if (prefix === "") continue
    if (keepList.indexOf(prefix) === -1) out.push(list[i])
  }
  return out
}

function totalSlotBytes(files) {
  var list = files || []
  var total = 0
  for (var i = 0; i < list.length; i++) total += (list[i] && list[i].size) || 0
  return total
}

// Bytes as the panel shows them: one decimal, binary units.
function formatBytes(bytes) {
  var n = Number(bytes) || 0
  if (n <= 0) return "0 B"
  var units = ["B", "KB", "MB", "GB", "TB"]
  var i = 0
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
  return (i === 0 ? String(Math.round(n)) : n.toFixed(1)) + " " + units[i]
}

// ---- Crash loops ----
//
// The transient unit carries Restart=on-failure, which is what keeps a server
// alive across a transient fault. It also hides the opposite case: a server
// that cannot start at all goes active -> failed -> active every few seconds,
// and a watch that only asks `is-active` sees "active" or "activating" every
// time. A model the build cannot load therefore read as "starting..." until
// the ten-minute startup timeout, while systemd restarted it twenty times.
//
// systemd counts the restarts, so the count is the signal: climbing while we
// are still waiting for the endpoint means it is looping, not starting.

// Two restarts rather than one: a single retry is what Restart=on-failure is
// for, and a server that comes up on the second go is working.
var RESTARTS_BEFORE_LOOP = 2

/**
 * Parses `systemctl show -p ActiveState -p NRestarts --value` output, which is
 * one value per line in the order asked for.
 * @returns {{activeState: string, restarts: number}}
 */
function parseUnitState(text) {
  var lines = String(text || "").split("\n")
  var out = { activeState: "", restarts: 0 }
  if (lines.length > 0) out.activeState = String(lines[0] || "").trim()
  if (lines.length > 1) {
    var n = parseInt(String(lines[1] || "").trim(), 10)
    if (isFinite(n) && n >= 0) out.restarts = n
  }
  return out
}

/**
 * Whether a unit is restarting in a loop rather than starting up.
 *
 * @param {number} restarts  NRestarts now
 * @param {number} baseline  NRestarts when this launch began
 * @param {number} [threshold]
 */
function isCrashLooping(restarts, baseline, threshold) {
  var now = parseInt(restarts, 10)
  var base = parseInt(baseline, 10)
  if (!isFinite(now)) return false
  if (!isFinite(base) || base < 0) base = 0
  var limit = isFinite(threshold) && threshold > 0 ? threshold : RESTARTS_BEFORE_LOOP
  return (now - base) >= limit
}

// ---- Settings file ----

// Whether a settings file can be read, and what it holds.
//
// A file that is present but unparseable must not be treated as "no settings".
// loadSettings used to fall through to the defaults and set settingsLoaded
// anyway, so the debounced save wrote those defaults back 200 ms later --
// losing the selected model, the per-backend ports, the model directories, the
// setup flag and the per-instance assignments. None of those are mirrored
// anywhere (the tuning profiles are, in models.ini), so one mistyped comma in
// a file people are invited to look at cost the whole setup, with no backup
// and no message.
//
// A missing or empty file is a first run, not a broken one: that has to keep
// working, or a fresh install would never save anything.
//
// @returns {{parsed: object|null, broken: boolean}}
function readSettings(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw)
  if (text.trim() === "") return { parsed: null, broken: false }
  var parsed = null
  try { parsed = JSON.parse(text) } catch (e) { parsed = null }
  // A valid JSON scalar ("null", "7", a bare string) is not a settings object
  // either, and writing over it would lose whatever the file really was.
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed))
    return { parsed: null, broken: true }
  return { parsed: parsed, broken: false }
}

// ---- Untrusted text ----
//
// QML Text defaults to Text.AutoText, which interprets markup-shaped input as
// rich text -- and rich text fetches what it is pointed at, so a single
// `<img src="http://host/x">` in a string the plugin displays becomes a
// network request from Omarchy's unsandboxed shell. The plugin's own Text
// elements declare Text.PlainText, but the shared components it renders
// through (tooltips, dropdown rows, button labels) own their Text and expose
// no format, so anything dynamic handed to one of those is neutralised here
// first. Omarchy ships no helper for this.
//
// Nothing the plugin displays in those places legitimately contains angle
// brackets: model file names, build labels, flags and endpoints do not, and a
// chat template's `<|im_start|>` only ever appears in the log view, which is
// a plugin-owned PlainText element and is not routed through here.
var PLAIN_TEXT_LIMIT = 400

function plainText(value, limit) {
  var s = String(value === undefined || value === null ? "" : value)
  // Tag-shaped runs, including one left unclosed at the end of the string.
  s = s.replace(/<[^>]*>?/g, "")
  // Any stray bracket, so nothing can be reassembled across a replacement.
  s = s.replace(/[<>]/g, "")
  // Control characters, line separators and zero-width/bidi marks: a label is
  // one line, and an invisible character is only ever there to mislead.
  s = s.replace(/[\u0000-\u001f\u007f\u200b-\u200f\u202a-\u202e\u2028\u2029\u2066-\u2069\ufeff]/g, " ")
  s = s.replace(/\s+/g, " ").replace(/^ | $/g, "")
  var max = (typeof limit === "number" && limit > 0) ? Math.floor(limit) : PLAIN_TEXT_LIMIT
  if (s.length > max) s = s.slice(0, Math.max(1, max - 1)) + "…"
  return s
}

if (typeof module !== "undefined") {
  module.exports = {
    parseUnitState: parseUnitState,
    isCrashLooping: isCrashLooping,
    readSettings: readSettings,
    plainText: plainText,
    statusLabel: statusLabel,
    slotFilePrefix: slotFilePrefix,
    parseSlotListing: parseSlotListing,
    slotOrphans: slotOrphans,
    totalSlotBytes: totalSlotBytes,
    formatBytes: formatBytes,
    stopPlan: stopPlan,
    parseTimingLine: parseTimingLine,
    parsePromptProgressLine: parsePromptProgressLine,
    isSystemdNoise: isSystemdNoise,
    isCoredumpNoise: isCoredumpNoise,
    pickErrorLine: pickErrorLine,
    parseTokensPerSecond: parseTokensPerSecond,
    metricText: metricText,
    BAR_ICON: BAR_ICON,
    barSwitchText: barSwitchText,
    isEnvName: isEnvName,
    parseEnvAssignments: parseEnvAssignments,
    formatEnvAssignments: formatEnvAssignments,
    barText: barText,
    dirName: dirName,
    ancestorDirs: ancestorDirs,
    baseName: baseName,
    baseModelName: baseModelName,
    isMtpName: isMtpName,
    classifyModelFiles: classifyModelFiles,
    parseFindOutput: parseFindOutput,
    quantLabel: quantLabel,
    parseProbeCapabilities: parseProbeCapabilities,
    parseProbeGeometry: parseProbeGeometry,
    paginateRows: paginateRows,
    buildModelTree: buildModelTree,
    flattenTree: flattenTree,
    collectFiles: collectFiles,
    splitExtraArgs: splitExtraArgs,
    parseArgs: parseArgs,
    recommendedCacheTypeV: recommendedCacheTypeV,
    isTurboQuantCacheType: isTurboQuantCacheType,
    shortenPath: shortenPath
  }
}
